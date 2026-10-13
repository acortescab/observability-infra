# observability-infra

Terraform for one shared observability host (prod only). Every game sends OpenTelemetry (OTLP) to it.

## What gets created

- 1 Ubuntu LTS EC2 instance (`t3.medium`) in an existing **private** subnet: no public IP, no SSH, access through SSM
  Session Manager. Encrypted gp3 root disk plus a separate encrypted data disk, IMDSv2 required.
- Its bootstrap installs `stack/` and runs, with docker compose under systemd (`observability-stack.service`):
  OpenTelemetry Collector, Prometheus (15 days), Loki (7 days), Tempo (7 days) and Grafana.
- An S3 bucket (`telemetry_bucket_name`, `observability-telemetry-s3` by default) shared by Loki (`loki/`) and Tempo (`tempo/`): private,
  encrypted, TLS only, `prevent_destroy`, and a lifecycle expiry (`telemetry_expiration_days`, 14) behind their 7-day
  retention. The instance role can only read and write those two prefixes. Prometheus stays on the data volume.
- A security group that only admits OTLP (4317 gRPC, 4318 HTTP) from the registered clients. Grafana (3000) and
  Prometheus (9090) listen on loopback of the host.
- An instance role: Session Manager plus read access to `<ssm_prefix>/*`.
- Two roles for GitHub Actions (OIDC, plan and apply) and the permissions boundary (`observability-ci-boundary`) that
  caps them and the two roles of the host. See `ci_roles.tf`.
- Optional SSM String parameters (`otlp_endpoint_parameters`) set to this stack's OTLP endpoint, so a game's
  deploy script reads it like any other setting.

## Prerequisites

- Terraform >= 1.10.0 and AWS credentials. `.github/workflows/ci.yml` checks format, validity and the stack scripts on
  every pull request and comments the Terraform plan on it (needs the variable `AWS_PLAN_ROLE_ARN`, a read-only OIDC
  role separate from the apply one, and the variables `SUBNET_ID`, `ALLOWED_CLIENT_SECURITY_GROUP_IDS` and `OTLP_ENDPOINT_PARAMETERS`). `cd.yml` plans on every push to `main` and applies after approval in the `production`
  environment; it needs the repository variable `AWS_ROLE_ARN` (an OIDC role for this state key and these resources;
  the other stack's CI roles do not cover them), the same three variables (the values of `terraform.tfvars`) and the
  environment with required reviewers. Until the role exists, apply from a workstation. The apply also delivers `stack/` to the
  host (see Operations).
- A private subnet with outbound internet (NAT) in the VPC of the games. The `private_subnet_id` and `security_group_id`
  outputs of a game's infrastructure stack are exactly what `subnet_id` and `allowed_client_security_group_ids` need.
- State: S3 bucket and key in `versions.tf` (`observability/terraform.tfstate`).

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars   # edit it
terraform init
terraform fmt -recursive && terraform validate
terraform plan
terraform apply
```

Create the Grafana admin password once; systemd retries every 30 s until it exists:

```bash
aws ssm put-parameter --type SecureString --name /observability/GRAFANA_PASSWORD --value '...'
```

Open Grafana from your machine (needs the Session Manager plugin), then browse `http://localhost:3000` (user `admin`):

```bash
aws ssm start-session --target "$(terraform output -raw instance_id)" \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["3000"],"localPortNumber":["3000"]}'
```

In PowerShell (no `\` line continuation, and it mangles the JSON quotes), use one line with the shorthand syntax:

```powershell
aws ssm start-session --target (terraform output -raw instance_id) --document-name AWS-StartPortForwardingSession --parameters "portNumber=3000,localPortNumber=3000"
```

## Adding a game

1. Add its security group to `allowed_client_security_group_ids` (or its CIDR to `allowed_client_cidrs` if its VPC is
   peered) and the SSM parameter its deploy reads to `otlp_endpoint_parameters`. Delete that parameter first if it was
   created by hand.
2. Apply, then redeploy the game so it reads the endpoint.
3. Make the game identify itself with OTel resource attributes (`service.name`, `deployment.environment`, and a
   `game` attribute), e.g. `OTEL_RESOURCE_ATTRIBUTES=game=coika,deployment.environment=prod`. Dashboards and alerts
   filter on them. Every metric keeps them as labels (`resource_to_telemetry_conversion` in the Collector config).

## Operations

- Data lives on a separate encrypted EBS volume mounted on `/var/lib/docker` (`data_volume_size`, 30 GiB by default;
  it can grow but not shrink). The root disk only holds the OS. Both disks get a daily snapshot (DLM).
- The instance is never replaced by a newer AMI or an edited bootstrap (`ignore_changes` on `ami` and `user_data`).
  Instead, every apply that changes `stack/` or `bootstrap.sh` runs the SSM document `<instance_name>-deploy-stack`
  (`deploy.tf`) on the host: it rewrites `/opt/observability`, the systemd units, and restarts the stack
  (`docker compose up -d --force-recreate`). Edit `stack/`, merge, and the CD run delivers it; do not edit the host by
  hand. The apply fails if the deployment fails on the host (see the command output in Systems Manager > Run Command).
- Loki chunks/index and Tempo blocks are in the telemetry bucket, not on the disk. `start.sh` reads the bucket name from
  the SSM parameter `<ssm_prefix>/TELEMETRY_BUCKET`. The data volume still holds Prometheus, Grafana, the Loki index
  in use and the Tempo WAL, so the daily snapshots stay useful.
- Moving an existing host to S3: the apply delivers the new `stack/` by itself. To drop the old local history (it is
  not readable from S3), run on the host `docker compose down`, `docker volume rm observability_loki_data
  observability_tempo_data` (check the names with `docker volume ls`), then `./start.sh`.
- CloudWatch alarms recover the instance on new hardware when its host fails and reboot it when the OS stops
  answering. Stopping it by hand is safe: a stopped instance triggers nothing, keeps its private IP and its disks, and
  the stack comes back by itself when you start it. EBS keeps billing while it is stopped.
- Replacing the host on purpose (`terraform apply -replace=aws_instance.observability`) keeps the history (the data
  volume is re-attached) but changes the private IP; Terraform updates the endpoint parameters and each game picks it
  up on its next deploy. The data volume has `prevent_destroy`.
- If the host is down the games keep working: the OTel SDK drops telemetry it cannot send.

## Not included yet

- CPU and memory of the game hosts (needs a host-metrics Collector on each game host).
- Alert rules and notifications (Grafana alerting or Alertmanager).
- Nothing for the pipeline itself. The roles it assumes are in `ci_roles.tf`; apply them by hand once, then set the
  repository variables `AWS_ROLE_ARN` and `AWS_PLAN_ROLE_ARN` from the `ci_apply_role_arn` and `ci_plan_role_arn`
  outputs, and create the environments `plan` and `production` (see `docs/GITHUB_ACTIONS.md`).
