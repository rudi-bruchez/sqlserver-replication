#!/bin/bash
# What sp_articlefilter, sp_articleview and sp_articlecolumn do to sysarticles.filter_clause,
# the filter procedure and the synchronization view, on an article without a subscription
# and on a subscribed one (campaign item 11; spec section "Filters and views"). Run through
# lab/campaign.sh. The planner needs both: a filter set on a new article before it is
# subscribed, and a filter changed on a subscribed article.
#
# Committed state, built here and removed at the end, in Sales:
#   m_fv   immediate_sync = 0, shared agent, native sync, snapshot agent that never fires,
#          no subscription; article m_t1 (id, a, b), no filter, all columns, view m_v made
#          by sp_articleview without a clause.
#   m_fvs  the same options; article m_t2 (id, a, b), no filter, all columns, view m_vs made
#          by sp_articleview without a clause before the subscription; a push subscription
#          to the database m_fvsub, snapshot started and delivered (the state the planner
#          meets on a live publication: subscription status 2).
# The cases, F1..F8 on m_fv and F1s..F8s on m_fvs, each in a transaction rolled back, are
# in 14-filter-view-cases.sql, with their row format and the assertions; it is fed to
# sqlcmd here and its output passes through, so that its assertion error reaches the
# runner's uncaught guard. 16 rows.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/../lib.sh"
DEF_SCRIPT=14-filter-view
. "$here/../defaults-lib.sh"

cleaned=0
cleanup() {
    [ "$cleaned" = 1 ] && return
    cleaned=1
    # The distribution agent of m_fvsub runs: stopped before the subscription is dropped,
    # or it logs a history row after its agent row is gone.
    ( stop_m_agents ) || true
    sql <<'SQL' >&2 || true
SET NOCOUNT ON;
USE Sales;
IF @@TRANCOUNT > 0 ROLLBACK;
BEGIN TRY IF EXISTS (SELECT 1 FROM dbo.syspublications WHERE name = N'm_fvs')
    EXEC sp_dropsubscription @publication = N'm_fvs', @article = N'all', @subscriber = N'all'; END TRY BEGIN CATCH END CATCH;
WHILE @@TRANCOUNT > 0 ROLLBACK;
BEGIN TRY IF EXISTS (SELECT 1 FROM dbo.syspublications WHERE name = N'm_fvs')
    EXEC sp_droppublication @publication = N'm_fvs'; END TRY BEGIN CATCH END CATCH;
WHILE @@TRANCOUNT > 0 ROLLBACK;
BEGIN TRY IF EXISTS (SELECT 1 FROM dbo.syspublications WHERE name = N'm_fv')
    EXEC sp_droppublication @publication = N'm_fv'; END TRY BEGIN CATCH END CATCH;
WHILE @@TRANCOUNT > 0 ROLLBACK;
DROP VIEW IF EXISTS dbo.m_v, dbo.m_vs;
DROP PROCEDURE IF EXISTS dbo.m_f, dbo.m_fs;
DROP TABLE IF EXISTS dbo.m_t1, dbo.m_t2;
IF DB_ID(N'm_fvsub') IS NOT NULL
BEGIN
    ALTER DATABASE m_fvsub SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE m_fvsub;
END
SQL
    podman exec repllab find /var/opt/mssql/data/ReplData/unc -mindepth 1 -maxdepth 1 -iname '*_m_*' -exec rm -rf {} + >&2 || true
}
trap cleanup EXIT

# Leftovers of an earlier run are not absorbed: they fail this run, and the trap removes them.
left=$(sql_value "SELECT (SELECT COUNT(*) FROM Sales.dbo.syspublications WHERE name IN (N'm_fv', N'm_fvs')) + (SELECT COUNT(*) FROM sys.databases WHERE name = N'm_fvsub') + (SELECT COUNT(*) FROM Sales.sys.objects WHERE name LIKE N'm\_%' ESCAPE N'\')") \
    || exit 1
left_files=$(podman exec repllab find /var/opt/mssql/data/ReplData/unc -mindepth 1 -maxdepth 1 -iname '*_m_*')
if [ "$left" != 0 ] || [ -n "$left_files" ]; then
    echo "14-filter-view: leftovers of an earlier run (objects=$left files=$left_files); removing them and failing" >&2
    exit 1
fi

mark=$(sql_value "SELECT CONVERT(varchar(23), SYSDATETIME(), 121)")
sql <<'SQL' >/dev/null
SET NOCOUNT ON;
USE Sales;
CREATE TABLE dbo.m_t1 (id int PRIMARY KEY, a int, b int);
CREATE TABLE dbo.m_t2 (id int PRIMARY KEY, a int, b int);
INSERT dbo.m_t1 VALUES (1, 1, 1), (2, 2, 2);
INSERT dbo.m_t2 VALUES (1, 1, 1), (2, 2, 2);
CREATE DATABASE m_fvsub;
GO
USE Sales;
DECLARE @s sysname = @@SERVERNAME;
EXEC sp_addpublication @publication = N'm_fv', @status = N'active', @allow_push = N'true',
     @independent_agent = N'false', @immediate_sync = N'false', @repl_freq = N'continuous', @sync_method = N'native';
EXEC sp_addpublication_snapshot @publication = N'm_fv', @frequency_type = 1, @active_start_date = 99991231,
     @job_login = NULL, @job_password = NULL, @publisher_security_mode = 1;
EXEC sp_addarticle @publication = N'm_fv', @article = N'm_t1', @source_owner = N'dbo', @source_object = N'm_t1';
EXEC sp_articleview @publication = N'm_fv', @article = N'm_t1', @view_name = N'm_v';
EXEC sp_addpublication @publication = N'm_fvs', @status = N'active', @allow_push = N'true',
     @independent_agent = N'false', @immediate_sync = N'false', @repl_freq = N'continuous', @sync_method = N'native';
EXEC sp_addpublication_snapshot @publication = N'm_fvs', @frequency_type = 1, @active_start_date = 99991231,
     @job_login = NULL, @job_password = NULL, @publisher_security_mode = 1;
EXEC sp_addarticle @publication = N'm_fvs', @article = N'm_t2', @source_owner = N'dbo', @source_object = N'm_t2';
EXEC sp_articleview @publication = N'm_fvs', @article = N'm_t2', @view_name = N'm_vs';
EXEC sp_addsubscription @publication = N'm_fvs', @subscriber = @s, @destination_db = N'm_fvsub',
     @subscription_type = N'Push', @sync_type = N'automatic', @article = N'all';
EXEC sp_addpushsubscription_agent @publication = N'm_fvs', @subscriber = @s, @subscriber_db = N'm_fvsub',
     @job_login = NULL, @job_password = NULL, @subscriber_security_mode = 1;
EXEC sp_startpublication_snapshot @publication = N'm_fvs';
GO
SQL

wait_until 300 "SELECT CASE WHEN EXISTS (SELECT 1 FROM distribution.dbo.MSsnapshot_history h JOIN distribution.dbo.MSsnapshot_agents a ON a.id = h.agent_id WHERE a.publication = N'm_fvs' AND h.time >= '$mark' AND h.runstatus = 2)
    AND EXISTS (SELECT 1 FROM distribution.dbo.MSdistribution_history h JOIN distribution.dbo.MSdistribution_agents a ON a.id = h.agent_id WHERE a.publisher_db = N'Sales' AND a.subscriber_db = N'm_fvsub' AND h.time >= '$mark' AND h.comments LIKE N'Delivered snapshot%') THEN 1 ELSE 0 END" \
    || { echo "14-filter-view: the snapshot of m_fvs was not delivered" >&2; exit 1; }
status=$(sql_value "SELECT ISNULL(STRING_AGG(CONVERT(nvarchar(10), s.status), N'/'), N'none') FROM Sales.dbo.syssubscriptions s JOIN Sales.dbo.sysarticles a ON a.artid = s.artid JOIN Sales.dbo.syspublications p ON p.pubid = a.pubid WHERE p.name = N'm_fvs' AND s.srvid >= 0")
[ "$status" = 2 ] || { echo "14-filter-view: subscription status of m_fvs is $status, expected 2 (active)" >&2; exit 1; }
[ "$(sql_value "SELECT COUNT(*) FROM m_fvsub.dbo.m_t2")" = 2 ] || { echo "14-filter-view: m_t2 not delivered to m_fvsub" >&2; exit 1; }

# The cases print the rows, the TOTAL line and, when an assertion fails, one Msg 50000.
sql < "$here/14-filter-view-cases.sql" | grep -v -e '^Changed database context' -e '^ *$' -e '^-*$' || true
cleanup
