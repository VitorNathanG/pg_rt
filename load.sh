#!/usr/bin/env bash
# Reload the whole engine from source into the running container.
set -euo pipefail
cd "$(dirname "$0")"

psql() { docker exec -i pg_rt psql -U rt -d rt -v ON_ERROR_STOP=1 -q "$@"; }

for f in sql/*.sql; do
  printf '%-24s' "$(basename "$f")"
  psql < "$f"
  echo ok
done
