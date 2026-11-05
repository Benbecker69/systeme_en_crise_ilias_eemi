#!/bin/sh
# Creates the login role used by the no-code tool before the legacy seed runs.
# Business privileges are granted later by sql/migration.sql.
set -eu

psql -v ON_ERROR_STOP=1 \
     --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
     -v app_user="$DIRECTUS_DB_USER" -v app_password="$DIRECTUS_DB_PASSWORD" <<'SQL'
CREATE ROLE :"app_user" LOGIN PASSWORD :'app_password';
-- The tool stores its own system tables (directus_*) in the public schema
GRANT USAGE, CREATE ON SCHEMA public TO :"app_user";
SQL
