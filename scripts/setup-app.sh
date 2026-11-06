#!/usr/bin/env sh
# Builds the Directus application (run after the migration). Re-runnable.
set -eu
cd "$(dirname "$0")/.."
./scripts/run-sql.sh directus/relations.sql
docker compose run --rm outils python directus/setup.py
