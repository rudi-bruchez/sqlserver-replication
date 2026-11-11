#!/bin/bash
# Self-test fixture: creates an m_ push subscription, waits until its distribution agent
# has delivered the snapshot (the agent job is then running), and drops the subscription and
# the publication without stopping the job. The agent logs a stop message after its agent row
# is gone: an orphan history row. Everything else is removed. Expected: GUARD residue
# (orphan_agent_history). selftest.sh deletes the orphan rows right after.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"

cleanup() {
    stop_m_agents
    sql >/dev/null 2>&1 <<'SQL' || true
SET NOCOUNT ON;
USE Sales;
BEGIN TRY IF EXISTS (SELECT 1 FROM dbo.syspublications WHERE name = N'm_oh')
    EXEC sp_droppublication @publication = N'm_oh'; END TRY BEGIN CATCH END CATCH;
DROP TABLE IF EXISTS dbo.m_oh_t;
IF DB_ID(N'm_oh_sub') IS NOT NULL
BEGIN
    ALTER DATABASE m_oh_sub SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE m_oh_sub;
END
SQL
    podman exec repllab find /var/opt/mssql/data/ReplData/unc -mindepth 1 -maxdepth 1 -iname '*_m_*' -exec rm -rf {} + >&2 || true
}
trap cleanup EXIT

mark0=$(sql_value "SELECT CONVERT(varchar(23), SYSDATETIME(), 121)")
sql >/dev/null <<'SQL'
SET NOCOUNT ON;
USE Sales;
CREATE TABLE dbo.m_oh_t (id int PRIMARY KEY, v int);
INSERT dbo.m_oh_t VALUES (1, 1);
CREATE DATABASE m_oh_sub;
GO
USE Sales;
DECLARE @srv sysname = @@SERVERNAME;
EXEC sp_addpublication @publication = N'm_oh', @status = N'active', @allow_push = N'true',
     @independent_agent = N'false', @immediate_sync = N'false', @repl_freq = N'continuous', @sync_method = N'native';
EXEC sp_addpublication_snapshot @publication = N'm_oh', @frequency_type = 1, @active_start_date = 99991231,
     @job_login = NULL, @job_password = NULL, @publisher_security_mode = 1;
EXEC sp_addarticle @publication = N'm_oh', @article = N'm_oh_t', @source_owner = N'dbo', @source_object = N'm_oh_t';
EXEC sp_addsubscription @publication = N'm_oh', @subscriber = @srv, @destination_db = N'm_oh_sub',
     @subscription_type = N'Push', @sync_type = N'automatic', @article = N'all';
EXEC sp_addpushsubscription_agent @publication = N'm_oh', @subscriber = @srv, @subscriber_db = N'm_oh_sub',
     @job_login = NULL, @job_password = NULL, @subscriber_security_mode = 1;
EXEC sp_startpublication_snapshot @publication = N'm_oh';
GO
SQL
wait_until 180 "SELECT CASE WHEN EXISTS (SELECT 1 FROM distribution.dbo.MSdistribution_history h JOIN distribution.dbo.MSdistribution_agents a ON a.id = h.agent_id WHERE a.subscriber_db = N'm_oh_sub' AND h.time >= '$mark0' AND h.comments LIKE N'Delivered snapshot%') THEN 1 ELSE 0 END" \
    || { echo "snapshot not delivered" >&2; exit 1; }
# The agent job runs (continuous). Dropped without stop_m_agents.
sql >/dev/null <<'SQL'
SET NOCOUNT ON;
USE Sales;
EXEC sp_dropsubscription @publication = N'm_oh', @article = N'all', @subscriber = N'all';
EXEC sp_droppublication @publication = N'm_oh';
SQL
sleep 5
echo 'R|a|ok|'
echo 'R|TOTAL|1'
