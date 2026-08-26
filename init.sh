#!/usr/bin/env bash

# https://docs.gitea.com/installation/database-prep/
# https://docs.gitea.com/installation/install-from-binary/

set -euo pipefail

echo "init.sh: creating role $DB_USER and database $DB_NAME ..."
export PGPASSWORD="$DB_ADMIN_PASSWORD"
psql -v ON_ERROR_STOP=1 -h "$DB_HOST" -p "$DB_PORT" -U "$DB_ADMIN_USER" -d "$DB_ADMIN_DB" <<SQL
CREATE ROLE $DB_USER WITH LOGIN PASSWORD '$DB_PASSWORD';
CREATE DATABASE $DB_NAME WITH OWNER $DB_USER TEMPLATE template0 ENCODING UTF8 LC_COLLATE 'en_US.UTF-8' LC_CTYPE 'en_US.UTF-8';
SQL

echo "init.sh: preparing work dir $GITEA_WORK_DIR ..."
sudo mkdir -p "$GITEA_WORK_DIR"/{custom,data,indexers,public,log}
sudo chown -R git:git "$GITEA_WORK_DIR"
sudo chmod -R 750 "$GITEA_WORK_DIR"

for secret in JWT_SECRET LFS_JWT_SECRET SECRET_KEY INTERNAL_TOKEN; do
  echo "init.sh: generating and setting secret $secret ..."
  zsc setEnv --sensitive "$secret" "$(/usr/local/bin/gitea generate secret "$secret")"
done

echo "init.sh: done"
