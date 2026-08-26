#!/usr/bin/env bash

set -euo pipefail

for secret in JWT_SECRET LFS_JWT_SECRET SECRET_KEY INTERNAL_TOKEN; do
  if [ -z "${!secret:-}" ]; then
    echo "start.sh: secret $secret not set yet, restarting ..."
    exit 1
  fi
done

echo "start.sh: rendering /etc/gitea/app.ini ..."
zsc envReplace --silent app.ini /tmp/app.ini
sudo install -m 660 -o root -g git /tmp/app.ini /etc/gitea/app.ini

echo "start.sh: starting gitea ..."
exec sudo -u git /usr/local/bin/gitea web --config /etc/gitea/app.ini
