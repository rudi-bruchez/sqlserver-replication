#!/bin/bash
# Self-test fixture: sql_value on a 300-character nvarchar(max), which sqlcmd cuts
# at 256 characters. sql_value must fail and, under set -e, end the script before
# the rows are printed. Expected: GUARD exit.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"
v=$(sql_value "SELECT REPLICATE(CONVERT(nvarchar(max),N'x'),300)")
echo "R|a|${#v}|"
echo 'R|TOTAL|1'
