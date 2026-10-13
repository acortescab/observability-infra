#!/bin/bash
# Starts the observability stack with docker compose. The Grafana password comes from SSM and the
# OTLP ports bind only the private IP.
set -euo pipefail

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GRAFANA_PASSWORD="$(ssm_get GRAFANA_PASSWORD)"
OBS_BIND_IP="$(imds local-ipv4)"
export GRAFANA_PASSWORD OBS_BIND_IP

cd "$STACK_DIR"
docker compose up -d
