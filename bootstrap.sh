
# --- Observability stack (appended to user_data.sh) ---
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
systemctl daemon-reload
systemctl enable observability-stack.service
systemctl start --no-block observability-stack.service
