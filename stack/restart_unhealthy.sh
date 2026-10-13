#!/bin/bash
# Restarts the stack containers that Docker reports as unhealthy. Docker itself only restarts a container that
# exits, so a hung process would stay up forever. Run every minute by observability-healthcheck.timer.
set -euo pipefail

export PATH="/usr/local/bin:$PATH"

while read -r id name; do
  echo "restarting unhealthy container $name"
  docker restart "$id" > /dev/null
done < <(docker ps --filter health=unhealthy --filter label=com.docker.compose.project=observability \
  --format '{{.ID}} {{.Names}}')
