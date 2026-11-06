#!/usr/bin/env sh
# Runs a project SQL file inside the PostgreSQL container (stops on first error).
# Example: ./scripts/run-sql.sh sql/migration.sql
set -eu
cd "$(dirname "$0")/.."
[ $# -eq 1 ] || { echo "usage: $0 <file.sql>" >&2; exit 1; }
[ -f "$1" ] || { echo "File not found: $1" >&2; exit 1; }
docker compose exec -T db sh -c "psql -v ON_ERROR_STOP=1 -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -f /work/$1"
