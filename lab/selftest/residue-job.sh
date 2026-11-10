#!/bin/bash
# Self-test fixture: leaves an SQL Agent job named like a replication job of an
# m_ publication. Expected: GUARD residue. selftest.sh deletes it right after.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"
sql -Q "SET NOCOUNT ON; EXEC msdb.dbo.sp_add_job @job_name = N'REPLLAB-Sales-m_ghost-1';"
echo 'R|a|ok|'
echo 'R|TOTAL|1'
