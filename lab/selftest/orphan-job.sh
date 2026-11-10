#!/bin/bash
# Self-test fixture: leaves an empty job in the REPL-Distribution category, named
# like a shared distribution agent job (no m_ in the name), that no agent table
# references. Expected: GUARD residue. selftest.sh deletes it right after.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"
sql -Q "SET NOCOUNT ON; EXEC msdb.dbo.sp_add_job @job_name = N'REPLLAB-Sales-ghostsub-99', @category_name = N'REPL-Distribution';"
echo 'R|a|ok|'
echo 'R|TOTAL|1'
