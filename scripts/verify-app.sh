#!/usr/bin/env sh
# Checks the access separation of the Directus application with the demo accounts.
set -eu
cd "$(dirname "$0")/.."
docker compose run --rm outils python directus/verify.py
