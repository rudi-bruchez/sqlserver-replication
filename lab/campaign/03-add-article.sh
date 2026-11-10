#!/bin/bash
# Which snapshot an added article triggers, with and without immediate_sync
# (lab/README.md rows 9 to 11; docs/analysis/step-1-analysis.md section 9, item 2).
# Three cases. Builds its own publications m_imm (immediate_sync = 1, independent
# agent) and m_nonimm (immediate_sync = 0, shared agent) on tables of Sales, and a
# subscriber database m_sub, measures, then removes everything, including the
# snapshot folders. Run through lab/campaign.sh.
#   C1.imm-add-article     row 9: flags needed by sp_addarticle on m_imm, subscription
#                          to the new article, which snapshot, what is delivered
#   C2.nonimm-add-article  row 10: the same on m_nonimm, with sp_addsubscription @article
#   C3.refused-keeps-tran  row 11: @@TRANCOUNT in the CATCH of a refused sp_addarticle
set -euo pipefail
. "$(dirname "$0")/../lib.sh"

n=0
r() { printf 'R|%s|%s|%s\n' "$1" "$2" "$3"; n=$((n + 1)); }

# The last line of what a batch prints: sp_addarticle and USE add informational lines
# ("Changed database context", "DBCC execution completed") that sql_value rejects.
last() {
    local out
    out=$(sql -b -h -1 -Q "SET NOCOUNT ON; $1" </dev/null 2>&1) || { printf '%s\n' "$out" >&2; return 1; }
    out=$(printf '%s\n' "$out" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' | tail -n 1)
    # A value is a word or number, optionally followed by /number parts: anything else
    # is an informational line taken for a result.
    [[ $out =~ ^[0-9a-z]+(/-?[0-9]+)*$ ]] || { printf 'last: unexpected value: %s\n' "$out" >&2; return 1; }
    printf '%s\n' "$out"
}

cleaned=0
cleanup() {
    [ "$cleaned" = 1 ] && return
    cleaned=1
    sql >&2 <<'SQL' || true
SET NOCOUNT ON;
USE Sales;
DECLARE @srv sysname = @@SERVERNAME;
BEGIN TRY IF EXISTS (SELECT 1 FROM dbo.syspublications WHERE name = N'm_imm')
    EXEC sp_dropsubscription @publication = N'm_imm', @article = N'all', @subscriber = N'all'; END TRY BEGIN CATCH END CATCH;
BEGIN TRY IF EXISTS (SELECT 1 FROM dbo.syspublications WHERE name = N'm_nonimm')
    EXEC sp_dropsubscription @publication = N'm_nonimm', @article = N'all', @subscriber = N'all'; END TRY BEGIN CATCH END CATCH;
BEGIN TRY IF EXISTS (SELECT 1 FROM dbo.syspublications WHERE name = N'm_imm')
    EXEC sp_droppublication @publication = N'm_imm'; END TRY BEGIN CATCH END CATCH;
BEGIN TRY IF EXISTS (SELECT 1 FROM dbo.syspublications WHERE name = N'm_nonimm')
    EXEC sp_droppublication @publication = N'm_nonimm'; END TRY BEGIN CATCH END CATCH;
DROP TABLE IF EXISTS dbo.m_a1, dbo.m_a2, dbo.m_a3, dbo.m_a4, dbo.m_b1, dbo.m_b2;
IF DB_ID(N'm_sub') IS NOT NULL
BEGIN
    ALTER DATABASE m_sub SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE m_sub;
END
SQL
    podman exec repllab find /var/opt/mssql/data/ReplData/unc -mindepth 1 -maxdepth 1 -iname '*_m_*' -exec rm -rf {} + >&2 || true
}
trap cleanup EXIT

# Leftovers of an earlier run are not absorbed: they fail this run (the exit guard),
# and the trap removes them.
left=$(sql_value "SELECT (SELECT COUNT(*) FROM Sales.dbo.syspublications WHERE name IN (N'm_imm', N'm_nonimm')) + (SELECT COUNT(*) FROM sys.databases WHERE name = N'm_sub') + (SELECT COUNT(*) FROM Sales.sys.objects WHERE name LIKE N'm\_%' ESCAPE N'\')") \
    || exit 1
left_files=$(podman exec repllab find /var/opt/mssql/data/ReplData/unc -mindepth 1 -maxdepth 1 -iname '*_m_*')
if [ "$left" != 0 ] || [ -n "$left_files" ]; then
    echo "03-add-article: leftovers of an earlier run (objects=$left files=$left_files); removing them and failing" >&2
    exit 1
fi

# Agent of each publication: m_imm has its own; m_nonimm shares the 'ALL' agent of m_sub.
agent_pred() { # PUB
    case $1 in
        m_imm) echo "a.publication = N'm_imm'" ;;
        m_nonimm) echo "a.publication = N'ALL' AND a.subscriber_db = N'm_sub'" ;;
    esac
}

mark0=$(sql_value "SELECT CONVERT(varchar(23), SYSDATETIME(), 121)")

# Setup. Each snapshot agent gets a schedule that never fires; snapshots run only
# when this script starts them.
sql <<'SQL'
SET NOCOUNT ON;
USE Sales;
CREATE TABLE dbo.m_a1 (id int PRIMARY KEY, v int); INSERT dbo.m_a1 VALUES (1, 1);
CREATE TABLE dbo.m_a2 (id int PRIMARY KEY, v int); INSERT dbo.m_a2 VALUES (1, 1);
CREATE TABLE dbo.m_a3 (id int PRIMARY KEY, v int); INSERT dbo.m_a3 VALUES (1, 1);
CREATE TABLE dbo.m_a4 (id int PRIMARY KEY, v int); INSERT dbo.m_a4 VALUES (1, 1);
CREATE TABLE dbo.m_b1 (id int PRIMARY KEY, v int); INSERT dbo.m_b1 VALUES (1, 1);
CREATE TABLE dbo.m_b2 (id int PRIMARY KEY, v int); INSERT dbo.m_b2 VALUES (1, 1);
CREATE DATABASE m_sub;
GO
USE Sales;
DECLARE @srv sysname = @@SERVERNAME;
EXEC sp_addpublication @publication = N'm_imm', @status = N'active', @allow_push = N'true',
     @independent_agent = N'true', @immediate_sync = N'true', @repl_freq = N'continuous', @sync_method = N'concurrent';
EXEC sp_addpublication_snapshot @publication = N'm_imm', @frequency_type = 1, @active_start_date = 99991231,
     @job_login = NULL, @job_password = NULL, @publisher_security_mode = 1;
EXEC sp_addarticle @publication = N'm_imm', @article = N'm_a1', @source_owner = N'dbo', @source_object = N'm_a1';
EXEC sp_addarticle @publication = N'm_imm', @article = N'm_a2', @source_owner = N'dbo', @source_object = N'm_a2';
EXEC sp_addsubscription @publication = N'm_imm', @subscriber = @srv, @destination_db = N'm_sub',
     @subscription_type = N'Push', @sync_type = N'automatic';
EXEC sp_addpushsubscription_agent @publication = N'm_imm', @subscriber = @srv, @subscriber_db = N'm_sub',
     @job_login = NULL, @job_password = NULL, @subscriber_security_mode = 1;
EXEC sp_addpublication @publication = N'm_nonimm', @status = N'active', @allow_push = N'true',
     @independent_agent = N'false', @immediate_sync = N'false', @repl_freq = N'continuous', @sync_method = N'native';
EXEC sp_addpublication_snapshot @publication = N'm_nonimm', @frequency_type = 1, @active_start_date = 99991231,
     @job_login = NULL, @job_password = NULL, @publisher_security_mode = 1;
EXEC sp_addarticle @publication = N'm_nonimm', @article = N'm_b1', @source_owner = N'dbo', @source_object = N'm_b1';
EXEC sp_addsubscription @publication = N'm_nonimm', @subscriber = @srv, @destination_db = N'm_sub',
     @subscription_type = N'Push', @sync_type = N'automatic', @article = N'all';
EXEC sp_addpushsubscription_agent @publication = N'm_nonimm', @subscriber = @srv, @subscriber_db = N'm_sub',
     @job_login = NULL, @job_password = NULL, @subscriber_security_mode = 1;
EXEC sp_startpublication_snapshot @publication = N'm_imm';
EXEC sp_startpublication_snapshot @publication = N'm_nonimm';
GO
SQL

# The snapshot of PUB, started after MARK, has finished and its tables are copied:
# the snapshot agent reports completion and the distribution agent delivered it.
snapshot_done() { # PUB MARK
    wait_until 180 "SELECT CASE WHEN EXISTS (SELECT 1 FROM distribution.dbo.MSsnapshot_history h JOIN distribution.dbo.MSsnapshot_agents a ON a.id = h.agent_id WHERE a.publication = N'$1' AND h.time >= '$2' AND h.runstatus = 2)
        AND EXISTS (SELECT 1 FROM distribution.dbo.MSdistribution_history h JOIN distribution.dbo.MSdistribution_agents a ON a.id = h.agent_id WHERE $(agent_pred "$1") AND h.time >= '$2' AND h.comments LIKE N'Delivered snapshot%') THEN 1 ELSE 0 END"
}

# The first snapshots reach the subscriber, each through its own agent.
snapshot_done m_imm "$mark0" && snapshot_done m_nonimm "$mark0" \
    || { echo "first snapshots not delivered" >&2; exit 1; }
bulk_tables() { # PUB MARK : tables bulk copied to m_sub since MARK, sorted, space separated
    sql_value "SELECT ISNULL(STRING_AGG(CONVERT(nvarchar(4000), t), ' ') WITHIN GROUP (ORDER BY t), 'none') FROM (SELECT DISTINCT SUBSTRING(h.comments, 30, CHARINDEX('''', h.comments, 30) - 30) AS t FROM distribution.dbo.MSdistribution_history h JOIN distribution.dbo.MSdistribution_agents a ON a.id = h.agent_id WHERE $(agent_pred "$1") AND h.time >= '$2' AND h.comments LIKE N'Bulk copied data into table ''%') x"
}

snap_comment() { # PUB MARK : the completion message of the snapshot agent
    sql_value "SELECT TOP 1 CONVERT(nvarchar(400), REPLACE(h.comments, N'|', N'/')) FROM distribution.dbo.MSsnapshot_history h JOIN distribution.dbo.MSsnapshot_agents a ON a.id = h.agent_id WHERE a.publication = N'$1' AND h.time >= '$2' AND h.runstatus = 2 ORDER BY h.time DESC"
}

# C1: add an article to m_imm.
ready_c1=$(sql_value "SELECT immediate_sync_ready FROM Sales.dbo.syspublications WHERE name = N'm_imm'")
flag0=$(last "USE Sales; DECLARE @e nvarchar(10) = N'ok', @t int = -1;
BEGIN TRY EXEC sp_addarticle @publication = N'm_imm', @article = N'm_a3', @source_owner = N'dbo', @source_object = N'm_a3', @force_invalidate_snapshot = 0; END TRY
BEGIN CATCH SET @e = CONVERT(nvarchar(10), ERROR_NUMBER()); SET @t = @@TRANCOUNT; IF @@TRANCOUNT > 0 ROLLBACK; END CATCH;
SELECT @e + N'/' + CONVERT(nvarchar(10), @t)")
flag0_err=${flag0%/*}
if [ "$flag0_err" != ok ]; then
    sql <<'SQL'
SET NOCOUNT ON;
USE Sales;
EXEC sp_addarticle @publication = N'm_imm', @article = N'm_a3', @source_owner = N'dbo', @source_object = N'm_a3', @force_invalidate_snapshot = 1;
SQL
fi
subs=$(sql_value "SELECT COUNT(s.artid) FROM Sales.dbo.sysextendedarticlesview a LEFT JOIN Sales.dbo.syssubscriptions s ON s.artid = a.artid AND s.srvid >= 0 WHERE a.name = N'm_a3'")
mark=$(sql_value "SELECT CONVERT(varchar(23), SYSDATETIME(), 121)")
sql <<'SQL'
SET NOCOUNT ON;
EXEC Sales.dbo.sp_startpublication_snapshot @publication = N'm_imm';
SQL
snapshot_done m_imm "$mark" || { echo "m_imm snapshot not delivered" >&2; exit 1; }
copied=$(bulk_tables m_imm "$mark")
snap=$(snap_comment m_imm "$mark")
total=$(sql_value "SELECT COUNT(*) FROM Sales.dbo.sysarticles a JOIN Sales.dbo.syspublications p ON p.pubid = a.pubid WHERE p.name = N'm_imm'")
r C1.imm-add-article "flag0=$flag0_err" "ready=$ready_c1 articles=$total subscriptions_to_new_article=$subs delivered=$copied snapshot=[$snap]"

# C2: add an article to m_nonimm.
flag0=$(last "USE Sales; DECLARE @e nvarchar(10) = N'ok';
BEGIN TRY EXEC sp_addarticle @publication = N'm_nonimm', @article = N'm_b2', @source_owner = N'dbo', @source_object = N'm_b2', @force_invalidate_snapshot = 0; END TRY
BEGIN CATCH SET @e = CONVERT(nvarchar(10), ERROR_NUMBER()); IF @@TRANCOUNT > 0 ROLLBACK; END CATCH;
SELECT @e")
subs0=$(sql_value "SELECT COUNT(s.artid) FROM Sales.dbo.sysextendedarticlesview a LEFT JOIN Sales.dbo.syssubscriptions s ON s.artid = a.artid AND s.srvid >= 0 WHERE a.name = N'm_b2'")
sql <<'SQL'
SET NOCOUNT ON;
USE Sales;
DECLARE @srv sysname = @@SERVERNAME;
EXEC sp_addsubscription @publication = N'm_nonimm', @subscriber = @srv, @destination_db = N'm_sub', @article = N'm_b2';
SQL
subs1=$(sql_value "SELECT COUNT(s.artid) FROM Sales.dbo.sysextendedarticlesview a LEFT JOIN Sales.dbo.syssubscriptions s ON s.artid = a.artid AND s.srvid >= 0 WHERE a.name = N'm_b2'")
mark=$(sql_value "SELECT CONVERT(varchar(23), SYSDATETIME(), 121)")
sql <<'SQL'
SET NOCOUNT ON;
EXEC Sales.dbo.sp_startpublication_snapshot @publication = N'm_nonimm';
SQL
snapshot_done m_nonimm "$mark" || { echo "m_nonimm snapshot not delivered" >&2; exit 1; }
copied=$(bulk_tables m_nonimm "$mark")
snap=$(snap_comment m_nonimm "$mark")
r C2.nonimm-add-article "flag0=$flag0" "subscriptions_to_new_article=$subs0 then $subs1 after sp_addsubscription delivered=$copied snapshot=[$snap]"

# C3: a refused sp_addarticle leaves its transaction open. m_imm has a valid
# snapshot again, so adding m_a4 without the flag is refused.
ready=$(sql_value "SELECT immediate_sync_ready FROM Sales.dbo.syspublications WHERE name = N'm_imm'")
out=$(last "USE Sales; DECLARE @e nvarchar(10) = N'ok', @t int = -1, @after int = -1;
BEGIN TRY EXEC sp_addarticle @publication = N'm_imm', @article = N'm_a4', @source_owner = N'dbo', @source_object = N'm_a4', @force_invalidate_snapshot = 0; END TRY
BEGIN CATCH SET @e = CONVERT(nvarchar(10), ERROR_NUMBER()); SET @t = @@TRANCOUNT; IF @@TRANCOUNT > 0 ROLLBACK; SET @after = @@TRANCOUNT; END CATCH;
SELECT @e + N'/' + CONVERT(nvarchar(10), @t) + N'/' + CONVERT(nvarchar(10), @after)")
IFS=/ read -r e t after <<<"$out"
r C3.refused-keeps-tran "$e" "ready=$ready TRANCOUNT in CATCH=$t, after ROLLBACK=$after"

cleanup
echo "R|TOTAL|$n"
