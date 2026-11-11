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
export SQLREPL_TEST_DSN="sqlserver://sa:${enc}@127.0.0.1:11980?encrypt=disable"
export SQLREPL_TEST_LAB=1
go test -count=1 -v -run "$filter" "$@" 2>&1 | grep -E '^(=== RUN|--- |ok|FAIL|PASS|panic)'

