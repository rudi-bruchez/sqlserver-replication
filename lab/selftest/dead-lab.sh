#!/bin/bash
# Self-test fixture: stops the lab's own replication by disabling and stopping the
# SalesPub distribution agent job, then prints a valid row. Expected: GUARD alive.
# selftest.sh re-enables and starts the job right after.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"
job=$(sql_value "SELECT TOP (1) CONVERT(nvarchar(36), j.job_id) FROM distribution.dbo.MSdistribution_agents a
    JOIN msdb.dbo.sysjobs j ON j.job_id = a.job_id WHERE a.publication = N'SalesPub' AND a.subscriber_db = N'SalesSub'")
sql -Q "SET NOCOUNT ON; EXEC msdb.dbo.sp_update_job @job_id = '$job', @enabled = 0; EXEC msdb.dbo.sp_stop_job @job_id = '$job';" >/dev/null
echo 'R|a|ok|'
echo 'R|TOTAL|1'
