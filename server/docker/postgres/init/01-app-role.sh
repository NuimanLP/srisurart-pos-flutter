#!/bin/sh
# Runs once on an empty volume. The application connects as pos_app, which is
# neither superuser nor table owner, so RLS (#15) cannot be bypassed silently.
# Migrations run as the owner ($POSTGRES_USER) and grant table access (#15).
set -e
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<EOSQL
CREATE ROLE pos_app LOGIN PASSWORD '${POS_APP_PASSWORD}'
  NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
GRANT CONNECT ON DATABASE "${POSTGRES_DB}" TO pos_app;
EOSQL
