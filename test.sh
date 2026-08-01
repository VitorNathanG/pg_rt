#!/usr/bin/env bash
# Run the verification suite.
set -uo pipefail
cd "$(dirname "$0")"
out=$(docker exec -i pg_rt psql -U rt -d rt < test/tests.sql 2>&1)
echo "$out"
echo "-----------------------------------------------"
printf 'passed: %s   failed: %s\n' \
  "$(grep -c '^pass' <<<"$out")" "$(grep -c '^FAIL' <<<"$out")"
grep -q '^FAIL\|ERROR' <<<"$out" && exit 1 || exit 0
