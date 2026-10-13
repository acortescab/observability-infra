#!/bin/bash
# Shared helpers for the observability scripts. Source it, do not execute it.
# Secrets are read from SSM Parameter Store with the instance role: nothing secret is stored on disk.

export PATH="/usr/local/bin:$PATH"

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Non-secret settings (SSM_PREFIX), written by the bootstrap.
set -a
# shellcheck disable=SC1091
[ -f "$STACK_DIR/settings.env" ] && . "$STACK_DIR/settings.env"
set +a

SSM_PREFIX="${SSM_PREFIX:-/observability}"

# Instance metadata (IMDSv2 is required on these hosts).
imds() {
  local token
  token="$(curl -fsS -X PUT http://169.254.169.254/latest/api/token \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')"
  curl -fsS -H "X-aws-ec2-metadata-token: $token" \
    "http://169.254.169.254/latest/meta-data/$1"
}

AWS_REGION="${AWS_REGION:-$(imds placement/region)}"
export AWS_DEFAULT_REGION="$AWS_REGION"

ssm_get() {
  aws ssm get-parameter --name "$SSM_PREFIX/$1" --with-decryption \
    --query Parameter.Value --output text
}
