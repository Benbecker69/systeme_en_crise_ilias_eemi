#!/usr/bin/env sh
# Creates .env from .env.example, replacing every "change-me" value with a
# random secret. Does nothing if .env already exists.
set -eu
cd "$(dirname "$0")/.."
if [ -f .env ]; then echo ".env already exists: kept as is"; exit 0; fi
secret() { od -An -tx1 -N"$1" /dev/urandom | tr -d ' \n'; }
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    DIRECTUS_SECRET=change-me*) echo "DIRECTUS_SECRET=$(secret 32)" ;;
    *=change-me*)               echo "${line%%=*}=$(secret 16)" ;;
    *)                          echo "$line" ;;
  esac
done < .env.example > .env
echo ".env created with random secrets"
