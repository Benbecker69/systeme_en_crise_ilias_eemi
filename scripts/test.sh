#!/usr/bin/env sh
# 1. Re-runs the migration and checks it changes nothing (idempotency).
# 2. Runs the SQL test suite (all changes rolled back).
set -eu
cd "$(dirname "$0")/.."
snapshot() {
  docker compose exec -T db sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At -f /work/sql/tests/snapshot.sql'
}
before=$(snapshot)
[ -n "$before" ] || { echo "Snapshot failed (run the migration first)" >&2; exit 1; }
./scripts/run-sql.sh sql/migration.sql > /dev/null
after=$(snapshot)
if [ -z "$after" ] || [ "$before" != "$after" ]; then
  printf 'Idempotency FAIL\n before: %s\n after:  %s\n' "$before" "$after" >&2
  exit 1
fi
echo "--- T00 idempotency PASS ($after)"
out=$(./scripts/run-sql.sh sql/tests/test_migration.sql 2>&1) || { echo "$out" >&2; exit 1; }
echo "$out" | grep -E 'PASS|FAIL|ERROR|---|===' | sed 's/^.*NOTICE:[[:space:]]*//'
