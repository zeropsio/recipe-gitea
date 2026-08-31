#!/usr/bin/env bash

# https://docs.gitea.com/runner/installation/binary/
# https://docs.gitea.com/runner/registration/

set -euo pipefail

cd /var/www
export HOME="${HOME:-/home/zerops}"

for var in GITEA_INSTANCE_URL RUNNER_LABELS; do
  if [ -z "${!var:-}" ]; then
    echo "runner-init.sh: $var is not set, aborting"
    exit 1
  fi
done

if [ -z "${RUNNER_REGISTRATION_TOKEN:-}" ]; then
  echo "runner-init.sh: RUNNER_REGISTRATION_TOKEN is not set yet - add it as a sensitive env variable of this service (see README), restarting ..."
  exit 1
fi

echo "runner-init.sh: waiting for $GITEA_INSTANCE_URL ..."
for _ in $(seq 1 20); do
  wget -q -O /dev/null "$GITEA_INSTANCE_URL/api/healthz" && break
  sleep 3
done
if ! wget -q -O /dev/null "$GITEA_INSTANCE_URL/api/healthz"; then
  echo "runner-init.sh: $GITEA_INSTANCE_URL is not reachable, restarting ..."
  exit 1
fi

# Each container registers itself as a separate runner named after its hostname. The .runner file
# lives in the deploy dir, so a plain restart reuses the registration while a recreated container
# registers fresh (the old registration stays behind as an offline runner - see README).
if [ ! -f .runner ]; then
  echo "runner-init.sh: registering runner $HOSTNAME ..."
  gitea-runner register \
    --no-interactive \
    --instance "$GITEA_INSTANCE_URL" \
    --token "$RUNNER_REGISTRATION_TOKEN" \
    --name "$HOSTNAME" \
    --labels "$RUNNER_LABELS"
fi

echo "runner-init.sh: done"
