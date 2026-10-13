
# --- Observability stack (appended to user_data.sh, and run again by the deploy_stack SSM document) ---
# Installs the stack/ folder of this repository on the host and keeps the stack running with systemd, so a
# fresh host comes up by itself. Nothing secret lives here: the Grafana password is read from SSM Parameter
# Store by stack/start.sh with the instance role.
install -d -o ubuntu -g ubuntu /opt/observability
%{ for name, content in files ~}
echo '${content}' | base64 -d | gunzip > "/opt/observability/${name}"
%{ endfor ~}
chmod +x /opt/observability/*.sh

# Non-secret settings for the scripts.
printf 'SSM_PREFIX=%s\n' '${ssm_prefix}' > /opt/observability/settings.env
chown -R ubuntu: /opt/observability

# start.sh fails until the SSM parameter GRAFANA_PASSWORD exists (it is created outside Terraform),
# so systemd retries it every 30 seconds instead of needing a manual step.
cat > /etc/systemd/system/observability-stack.service <<'UNIT'
[Unit]
Description=Observability stack (docker compose)
After=docker.service network-online.target
Requires=docker.service
StartLimitIntervalSec=0

[Service]
Type=oneshot
RemainAfterExit=yes
User=ubuntu
ExecStart=/opt/observability/start.sh
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
UNIT

# Docker only restarts a container that exits; this timer restarts the ones its healthchecks report as unhealthy.
cat > /etc/systemd/system/observability-healthcheck.service <<'UNIT'
[Unit]
Description=Restart unhealthy containers of the observability stack
After=docker.service

[Service]
Type=oneshot
User=ubuntu
ExecStart=/opt/observability/restart_unhealthy.sh
UNIT
cat > /etc/systemd/system/observability-healthcheck.timer <<'UNIT'
[Unit]
Description=Check the observability stack every minute

[Timer]
OnBootSec=5min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable observability-stack.service
systemctl enable --now observability-healthcheck.timer
# restart, not start: on a redeploy the service is already active and must run start.sh again to apply the new files.
systemctl restart --no-block observability-stack.service
