#!/usr/bin/env sh
# Destroys every container and volume, then starts from an empty database
# where the legacy seed is executed as-is.
set -eu
cd "$(dirname "$0")/.."
docker compose down -v
docker compose up -d --wait
