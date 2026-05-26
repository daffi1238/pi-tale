#!/bin/bash
# Runs once on first Mongo init (when /data/db is empty). Creates a
# per-app user with dbOwner on the unifi + unifi_stat databases.
# The unifi-network-application container authenticates with this
# user — not with the Mongo root, which is reserved for ops.
#
# Env vars come from compose/unifi.yml (which reads them from
# compose/.env): UNIFI_DB_USER, UNIFI_DB_PASS, UNIFI_DB_NAME.
#
# Mongo's image executes everything under /docker-entrypoint-initdb.d/
# *.sh as the running mongod container, with admin auth already
# bootstrapped via MONGO_INITDB_ROOT_USERNAME / PASSWORD.

set -euo pipefail

USER="${UNIFI_DB_USER:?UNIFI_DB_USER must be set}"
PASS="${UNIFI_DB_PASS:?UNIFI_DB_PASS must be set}"
DB="${UNIFI_DB_NAME:-unifi}"

mongo --quiet "${DB}" <<EOF
db.createUser({
  user: "${USER}",
  pwd:  "${PASS}",
  roles: [
    { role: "dbOwner", db: "${DB}" },
    { role: "dbOwner", db: "${DB}_stat" }
  ]
});
EOF
