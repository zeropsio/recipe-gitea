#!/usr/bin/env bash

# https://docs.gitea.com/administration/command-line#admin

# Mints the first admin user and an API token for automation, then publishes them as
# this service's own environment variables — the same way init.sh publishes the secrets
# Gitea generates for itself. Nothing is printed and nothing is passed on argv, so no
# credential reaches a log or the process list.
#
# Runner registration tokens are deliberately not minted here: `gitea actions
# generate-runner-token` is not a database command, it calls the running server over
# localhost, and nothing in this file runs with the server up. Ask the API for one
# instead, with the token below: POST /api/v1/admin/actions/runners/registration-token.
#
# Runs from the start command rather than initCommands, because init commands run
# once per deploy while the start command is re-run on every boot: the variables this
# needs are written by init.sh seconds earlier and only reach a process started after
# them. It does nothing on all but one boot — it returns early once GITEA_ADMIN_TOKEN
# is set, and re-mints if the user exists but the variable does not (an interrupted
# first run, or a deliberate rotation: delete the variable and restart the service).

set -euo pipefail

cd /var/www
CONF=/etc/gitea/app.ini
USERNAME="${GITEA_ADMIN_USERNAME:-mate}"
EMAIL="${GITEA_ADMIN_EMAIL:-$USERNAME@localhost}"

if [ -n "${GITEA_ADMIN_TOKEN:-}" ]; then
  echo "admin-init.sh: already provisioned"
  exit 0
fi

# The very first boot has none of these yet: init.sh has only just written them, and a
# variable written now reaches processes started later, not this one. start.sh is about
# to exit for the same reason and the boot after this one has everything.
for secret in JWT_SECRET LFS_JWT_SECRET SECRET_KEY INTERNAL_TOKEN; do
  if [ -z "${!secret:-}" ]; then
    echo "admin-init.sh: $secret not set yet, nothing to do on this boot"
    exit 0
  fi
done

# The admin commands read app.ini and talk to the database directly, so both have to
# exist before the web server has ever run. `gitea migrate` is the documented way:
# initDB opens the database, only migrate creates the schema.
echo "admin-init.sh: rendering $CONF and migrating the database ..."
zsc envReplace --silent app.ini /tmp/app.ini
sudo install -m 660 -o root -g zerops /tmp/app.ini "$CONF"
gitea migrate --config "$CONF"

if gitea admin user list --config "$CONF" 2>/dev/null | awk 'NR>1{print $2}' | grep -qx "$USERNAME"; then
  # The user survived but the variable did not. A token's value is readable only at
  # creation, so it cannot be recovered — mint a new one and reset the password.
  echo "admin-init.sh: $USERNAME exists, re-minting its credentials ..."
  password="$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | cut -c1-28)"
  gitea admin user change-password --config "$CONF" --username "$USERNAME" \
    --password "$password" --must-change-password=false
  token="$(gitea admin user generate-access-token --config "$CONF" --username "$USERNAME" \
    --token-name "automation-$(date +%s)" --scopes all --raw)"
else
  # --random-password and --access-token both print their value, which is why neither
  # is passed as an argument: the output is captured here and never echoed.
  echo "admin-init.sh: creating admin user $USERNAME ..."
  created="$(gitea admin user create --config "$CONF" \
    --admin --username "$USERNAME" --email "$EMAIL" \
    --random-password --must-change-password=false \
    --access-token --access-token-name automation --access-token-scopes all)"
  password="$(printf '%s' "$created" | sed -n "s/^generated random password is '\(.*\)'\$/\1/p")"
  token="$(printf '%s' "$created" | sed -n 's/^Access token was successfully created\.\.\. //p')"
fi

if [ -z "${password:-}" ] || [ -z "${token:-}" ]; then
  echo "admin-init.sh: could not read the generated credentials, aborting"
  exit 1
fi

# Published before anything else can fail. The user and the token exist in the database
# by now, and a token's value is readable only at creation — losing it here would mean a
# Gitea nobody holds the credentials for.
#
# Values go in on stdin, like init.sh does: a generated value can begin with a dash,
# which zsc would otherwise parse as a flag.
echo "admin-init.sh: publishing the credentials as environment variables ..."
printf '%s' "$password" | zsc setEnv --sensitive GITEA_ADMIN_PASSWORD -
printf '%s' "$token"    | zsc setEnv --sensitive GITEA_ADMIN_TOKEN -

echo "admin-init.sh: done"
