#!/bin/bash
# Starts the observability stack with docker compose. The Grafana password and the telemetry bucket name come
# from SSM and the OTLP ports bind only the private IP.
set -euo pipefail

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GRAFANA_PASSWORD="$(ssm_get GRAFANA_PASSWORD)"
OBS_BIND_IP="$(imds local-ipv4)"
TELEMETRY_BUCKET="$(ssm_get TELEMETRY_BUCKET)"
export GRAFANA_PASSWORD OBS_BIND_IP TELEMETRY_BUCKET AWS_REGION

cd "$STACK_DIR"
# --force-recreate: the configs are bind-mounted files, which compose does not notice changing.
docker compose up -d --force-recreate
