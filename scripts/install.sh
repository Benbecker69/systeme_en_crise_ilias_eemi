#!/usr/bin/env sh
# Full installation from scratch, in one command:
# .env -> empty database + seed -> migration -> SQL tests -> application -> rights checks.
# WARNING: destroys the existing containers and volumes (scripts/reset.sh).
set -eu
cd "$(dirname "$0")/.."
step() { printf '\n===== %s\n' "$1"; }
step "1/6 .env file";                        ./scripts/init-env.sh
step "2/6 Empty database + seed";            ./scripts/reset.sh
step "3/6 Migration";                        ./scripts/run-sql.sh sql/migration.sql > /dev/null
step "4/6 SQL tests (idempotency + integrity)"; ./scripts/test.sh
step "5/6 Directus application";             ./scripts/setup-app.sh
step "6/6 Access rights checks";             ./scripts/verify-app.sh
cat <<'MSG'

===== Installation complete
  Application: http://localhost:8055
  pgAdmin:     http://localhost:5050
  PostgreSQL:  localhost:5433, database maintenancepro
  Accounts: docs/guide-installation.md, passwords in .env
MSG
