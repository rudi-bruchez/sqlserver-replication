#!/usr/bin/env bash
# Runs Go tests against the lab instance (repllab, 127.0.0.1:11980).
# Usage: MSSQL_SA_PASSWORD=... lab/gotest.sh FILTER PACKAGE...
# The password comes from the environment only and is never printed.
set -eu -o pipefail
if [ -z "${MSSQL_SA_PASSWORD:-}" ]; then
  echo "gotest.sh: MSSQL_SA_PASSWORD is not set" >&2
  exit 2
fi
if [ $# -lt 2 ]; then
  echo "usage: gotest.sh FILTER PACKAGE..." >&2
  exit 2
fi
filter=$1
shift
enc=$(python3 -I -c 'import os,urllib.parse;print(urllib.parse.quote(os.environ["MSSQL_SA_PASSWORD"],safe=""))')
export SQLREPL_ENC="$enc"
export SQLREPL_TEST_DSN="sqlserver://sa:${enc}@127.0.0.1:11980?encrypt=disable"
export SQLREPL_TEST_LAB=1
rc=0
# -p 1: the lab tests of several packages share the lab and Sales; run in parallel
# packages they deadlock on each other's drops and plan each other's objects.
out=$(go test -count=1 -p 1 -v -run "$filter" "$@" 2>&1) || rc=$?
# Redact the DSN, the encoded password and the password, reading them from the
# environment: the output is shown in full otherwise.
printf '%s\n' "$out" | python3 -I -c '
import os, sys
t = sys.stdin.read()
for k in ("SQLREPL_TEST_DSN", "SQLREPL_ENC", "MSSQL_SA_PASSWORD"):
    v = os.environ.get(k, "")
    if v:
        t = t.replace(v, "<redacted>")
sys.stdout.write(t)
'
if [ "$rc" -eq 0 ]; then
  if printf '%s\n' "$out" | grep -q '\[no tests to run\]' || ! printf '%s\n' "$out" | grep -qE '^--- (PASS|FAIL)'; then
    echo "gotest.sh: no test matched $filter" >&2
    exit 3
  fi
fi
exit "$rc"
