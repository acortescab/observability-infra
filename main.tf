locals {
  ssm_arn_base = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.ssm_prefix}"
  name_prefix  = var.instance_name

  tags = merge(
    {
      Environment = "prod"
      Project     = var.project_name
      ManagedBy   = "terraform"
    },
    var.extra_tags,
  )

  otlp_ports = { grpc = 4317, http = 4318 }

  snapshot_tag_key   = "Snapshot"
  snapshot_tag_value = local.name_prefix

  // One bucket for Loki (logs) and Tempo (traces), each under its own prefix.
  telemetry_bucket   = var.telemetry_bucket_name
  telemetry_prefixes = ["loki", "tempo"]

  // One rule per (client, port). Keys come from the variable values, so they are known at plan time.
  client_sg_rules = {
    for pair in setproduct(var.allowed_client_security_group_ids, keys(local.otlp_ports)) :
    "${pair[0]}-${pair[1]}" => { sg = pair[0], port = local.otlp_ports[pair[1]] }
  }
  client_cidr_rules = {
    for pair in setproduct(var.allowed_client_cidrs, keys(local.otlp_ports)) :
    "${pair[0]}-${pair[1]}" => { cidr = pair[0], port = local.otlp_ports[pair[1]] }
  }
}

data "aws_caller_identity" "current" {}

data "aws_subnet" "host" {
  id = var.subnet_id
}

data "aws_ami" "ubuntu_lts" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-*-${var.ubuntu_lts_version}-${var.ami_architecture == "x86_64" ? "amd64" : "arm64"}-server-*"]
  }

  filter {
    name   = "architecture"
    values = [var.ami_architecture]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

// Observability host: Docker-ready Ubuntu in a private subnet, no public IP and no SSH. Reach it with SSM
// Session Manager. The bootstrap installs the stack/ folder and starts it (docker compose under systemd).
resource "aws_instance" "observability" {
  ami                         = data.aws_ami.ubuntu_lts.id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.observability.id]
  iam_instance_profile        = aws_iam_instance_profile.observability.name

  // Block terminating the instance by mistake (console, API or destroy). The history lives on the separate data
  // volume, which survives anyway; this also protects the host itself. To remove it on purpose, set this to
  // false and apply first. Stopping the instance is still allowed.
  disable_api_termination = true

  root_block_device {
    encrypted   = true
    volume_size = var.root_volume_size
    volume_type = var.root_volume_type

    // The Data Lifecycle Manager policy below snapshots the volumes that carry this tag.
    tags = merge(local.tags, { Name = "${local.name_prefix}-so", (local.snapshot_tag_key) = local.snapshot_tag_value })
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"

    // Hop limit 2 so the containers (one network hop behind the host) can fetch the instance role credentials
    // that Loki and Tempo use to reach S3. With the default of 1, IMDSv2 answers never reach them.
    http_put_response_hop_limit = 2
  }

  user_data = join("\n", [
    templatefile("${path.module}/data_disk.sh", {
      // The NVMe device name carries the volume id without its dash.
      volume_id = replace(aws_ebs_volume.data.id, "-", "")
    }),
    file("${path.module}/user_data.sh"),
    // Same script the deploy_stack SSM document runs (deploy.tf). gzip keeps user_data well under the 16 KB limit.
    local.bootstrap,
  ])

  // The games only learn a new private IP on their next deploy: a newer AMI or an edited bootstrap must never
  // replace the host. Replacing it on purpose (terraform apply -replace=aws_instance.observability) keeps the
  // history, which lives on the data volume, but changes the private IP.
  lifecycle {
    ignore_changes = [ami, user_data]
  }

  tags = merge(local.tags, { Name = local.name_prefix })
}

// The telemetry (Prometheus, Loki, Tempo, Grafana) lives here, mounted on /var/lib/docker by data_disk.sh. It is
// its own resource so it outlives the instance: a replaced host re-attaches the same volume.
resource "aws_ebs_volume" "data" {
  availability_zone = data.aws_subnet.host.availability_zone
  size              = var.data_volume_size
  type              = var.data_volume_type
  encrypted         = true

  // The Data Lifecycle Manager policy below snapshots the volumes that carry this tag.
  tags = merge(local.tags, { Name = "${local.name_prefix}-data", (local.snapshot_tag_key) = local.snapshot_tag_value })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.observability.id
}

// AWS recovers the instance on new hardware (same id, private IP and disks) when the host fails its system status
// check. A stopped instance publishes no metric, so stopping it by hand never triggers this.
resource "aws_cloudwatch_metric_alarm" "recover" {
  alarm_name          = "${local.name_prefix}-recover"
  alarm_description   = "Recover ${local.name_prefix} when its host fails the system status check"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  dimensions          = { InstanceId = aws_instance.observability.id }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = ["arn:aws:automate:${var.aws_region}:ec2:recover"]

  tags = merge(local.tags, { Name = "${local.name_prefix}-recover" })
}

// Reboots the instance when the OS stops answering. Five consecutive minutes so a slow boot after a manual start
// never causes a reboot loop.
resource "aws_cloudwatch_metric_alarm" "reboot" {
  alarm_name          = "${local.name_prefix}-reboot"
  alarm_description   = "Reboot ${local.name_prefix} when it fails the instance status check"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_Instance"
  dimensions          = { InstanceId = aws_instance.observability.id }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = ["arn:aws:automate:${var.aws_region}:ec2:reboot"]

  tags = merge(local.tags, { Name = "${local.name_prefix}-reboot" })
}

// OTLP only from the registered clients. Grafana (3000) and Prometheus (9090) listen on loopback of the host
// and are reached through SSM sessions, so no other port is open.
resource "aws_security_group" "observability" {
  name_prefix = "${local.name_prefix}-sg-"
  description = "Security group for ${local.name_prefix}"
  vpc_id      = data.aws_subnet.host.vpc_id

  tags = merge(local.tags, { Name = "${local.name_prefix}-sg" })

  // The instance is attached to it: a replacement must create the new group and move the instance first,
  // otherwise the old one cannot be deleted while in use (the destroy hangs). name_prefix avoids a name clash.
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "otlp_from_client_sg" {
  for_each = local.client_sg_rules

  security_group_id            = aws_security_group.observability.id
  referenced_security_group_id = each.value.sg
  from_port                    = each.value.port
  ip_protocol                  = "tcp"
  to_port                      = each.value.port
}

resource "aws_vpc_security_group_ingress_rule" "otlp_from_client_cidr" {
  for_each = local.client_cidr_rules

  security_group_id = aws_security_group.observability.id
  cidr_ipv4         = each.value.cidr
  from_port         = each.value.port
  ip_protocol       = "tcp"
  to_port           = each.value.port
}

resource "aws_vpc_security_group_egress_rule" "all_traffic_ipv4" {
  security_group_id = aws_security_group.observability.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

// The instance role: Session Manager plus read access to its own SSM prefix.
data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "observability" {
  name                 = "${local.name_prefix}-role"
  assume_role_policy   = data.aws_iam_policy_document.ec2_assume_role.json
  permissions_boundary = aws_iam_policy.ci_boundary.arn

  tags = merge(local.tags, { Name = "${local.name_prefix}-role" })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.observability.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "ssm_read" {
  statement {
    sid       = "ReadObservabilityParameters"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = [local.ssm_arn_base, "${local.ssm_arn_base}/*"]
  }
}

resource "aws_iam_role_policy" "ssm_read" {
  name   = "ssm-parameters-read"
  role   = aws_iam_role.observability.id
  policy = data.aws_iam_policy_document.ssm_read.json
}

// Loki and Tempo read and write their objects under their own prefix of the telemetry bucket. The bucket and its
// objects are different resources: ListBucket goes on the bucket, the object actions on bucket/prefix/*.
data "aws_iam_policy_document" "telemetry_bucket" {
  statement {
    sid       = "ListTelemetryBucket"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.telemetry.arn]
  }

  statement {
    sid       = "ReadWriteTelemetryObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [for prefix in local.telemetry_prefixes : "${aws_s3_bucket.telemetry.arn}/${prefix}/*"]
  }
}

resource "aws_iam_role_policy" "telemetry_bucket" {
  name   = "telemetry-bucket-readwrite"
  role   = aws_iam_role.observability.id
  policy = data.aws_iam_policy_document.telemetry_bucket.json
}

resource "aws_iam_instance_profile" "observability" {
  name = "${local.name_prefix}-profile"
  role = aws_iam_role.observability.name

  tags = merge(local.tags, { Name = "${local.name_prefix}-profile" })
}

// Daily EBS snapshots of the root and data disks (telemetry history). Snapshots are incremental and crash-consistent, which
// Prometheus, Loki and Tempo recover from through their WALs.
data "aws_iam_policy_document" "dlm_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["dlm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dlm" {
  name                 = "${local.name_prefix}-dlm-role"
  assume_role_policy   = data.aws_iam_policy_document.dlm_assume_role.json
  permissions_boundary = aws_iam_policy.ci_boundary.arn

  tags = merge(local.tags, { Name = "${local.name_prefix}-dlm-role" })
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "snapshots" {
  description        = "Daily snapshots of ${local.name_prefix}"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]
    target_tags    = { (local.snapshot_tag_key) = local.snapshot_tag_value }

    schedule {
      name = "daily"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["03:00"]
      }

      retain_rule {
        count = var.snapshot_retention_days
      }

      copy_tags = true
    }
  }

  tags = merge(local.tags, { Name = "${local.name_prefix}-snapshots" })
}

// Long-term storage of Loki chunks/index and Tempo blocks. Prometheus has no S3 backend and stays on the data volume.
resource "aws_s3_bucket" "telemetry" {
  bucket = local.telemetry_bucket

  tags = merge(local.tags, { Name = local.telemetry_bucket })

  // Same protection as the data volume: the history must not vanish with a stray destroy.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "telemetry" {
  bucket = aws_s3_bucket.telemetry.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "telemetry" {
  bucket = aws_s3_bucket.telemetry.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

data "aws_iam_policy_document" "telemetry_bucket_tls" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.telemetry.arn, "${aws_s3_bucket.telemetry.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "telemetry" {
  bucket = aws_s3_bucket.telemetry.id
  policy = data.aws_iam_policy_document.telemetry_bucket_tls.json

  depends_on = [aws_s3_bucket_public_access_block.telemetry]
}

// Safety net behind the Loki and Tempo compactors, which enforce the real 7-day retention. It must stay longer than
// that retention, or objects would vanish while the indexes still point at them.
resource "aws_s3_bucket_lifecycle_configuration" "telemetry" {
  bucket = aws_s3_bucket.telemetry.id

  rule {
    id     = "expire-telemetry"
    status = "Enabled"

    filter {}

    expiration {
      days = var.telemetry_expiration_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

// The bucket name for the stack. start.sh reads it from SSM with the instance role, so the host needs no edit of
// its settings when the name changes.
resource "aws_ssm_parameter" "telemetry_bucket" {
  name  = "${var.ssm_prefix}/TELEMETRY_BUCKET"
  type  = "String"
  value = aws_s3_bucket.telemetry.id

  tags = local.tags
}

// Where the games send telemetry. Not a secret, so Terraform owns it; each game's deploy reads its own
// parameter, so a game picks up a new address on its next deploy.
resource "aws_ssm_parameter" "otlp_endpoint" {
  for_each = toset(var.otlp_endpoint_parameters)

  name  = each.value
  type  = "String"
  value = "http://${aws_instance.observability.private_ip}:4317"

  tags = local.tags
}
