#!/bin/bash
# Flag matrix of sp_changepublication and sp_changearticle on a snapshot publication
# (campaign item 7). Run through lab/campaign.sh.
#
# Builds m_snap on the tables m_t1 and m_t2 of Sales: @repl_freq = N'snapshot' (the
# other options are the defaults, so immediate_sync = 0, independent_agent = 0, and
# the push subscription to m_sub uses the shared 'ALL' agent of m_sub), its snapshot
# agent with a schedule that never fires, one push subscription to the database
# m_sub, and the snapshot generated and delivered. It then feeds
# 09-snapshot-pub-matrix.sql to sql on standard input: 23 publication properties,
# 21 article properties and 3 filter or column operations, each run with the four flag
# combinations inside a transaction rolled back in the same batch, 47 rows.
#
# Controls, asserted before the rows are printed; a failure exits 1.
#  - Stored values: the properties the matrix changes hold a value different from the
#    one the matrix sets (a case on the stored value would be a no-op).
#  - Rule of 05-snapshot-flag (docs/analysis/step-1-analysis.md section 5): a
#    procedure asks for @force_invalidate_snapshot only when immediate_sync_ready = 1,
#    and for @force_reinit_subscription only when the operated article's subscription
#    has status 2 (active). m_snap has immediate_sync = 0, so ready is 0, the snapshot
#    is never invalidated, and the subscription is at status 2. Predicted: every row
#    reads ready=0 and status=2, no cell is 20607, and sp_changearticle schema_option
#    on m_t2 is f00=20608,f10=20608,f01=ok,f11=ok (the shape of the SalesRef row A13 of
#    02-matrix).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/../lib.sh"

expected_rows=47

cleaned=0
cleanup() {
    [ "$cleaned" = 1 ] && return
    cleaned=1
    sql >&2 <<'SQL' || true
SET NOCOUNT ON;
USE Sales;
BEGIN TRY IF EXISTS (SELECT 1 FROM dbo.syspublications WHERE name = N'm_snap')
    EXEC sp_dropsubscription @publication = N'm_snap', @article = N'all', @subscriber = N'all'; END TRY BEGIN CATCH END CATCH;
BEGIN TRY IF EXISTS (SELECT 1 FROM dbo.syspublications WHERE name = N'm_snap')
    EXEC sp_droppublication @publication = N'm_snap'; END TRY BEGIN CATCH END CATCH;
DROP VIEW IF EXISTS dbo.m_v1;
DROP PROCEDURE IF EXISTS dbo.m_f1;
DROP TABLE IF EXISTS dbo.m_t1, dbo.m_t2;
GO
IF DB_ID(N'm_sub') IS NOT NULL
BEGIN
    ALTER DATABASE m_sub SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE m_sub;
END;
SQL
    podman exec repllab find /var/opt/mssql/data/ReplData/unc -mindepth 1 -maxdepth 1 -iname '*_m_*' -exec rm -rf {} + >&2 || true
}
trap cleanup EXIT

# Leftovers of an earlier run are not absorbed: they fail this run, the trap removes them.
left=$(sql_value "SELECT (SELECT COUNT(*) FROM Sales.dbo.syspublications WHERE name = N'm_snap') + (SELECT COUNT(*) FROM sys.databases WHERE name = N'm_sub') + (SELECT COUNT(*) FROM Sales.sys.objects WHERE name LIKE N'm\_%' ESCAPE N'\')") \
    || exit 1
left_files=$(podman exec repllab find /var/opt/mssql/data/ReplData/unc -mindepth 1 -maxdepth 1 -iname '*_m_*')
if [ "$left" != 0 ] || [ -n "$left_files" ]; then
    echo "09-snapshot-pub: leftovers of an earlier run (objects=$left files=$left_files); removing them and failing" >&2
    exit 1
fi

mark0=$(sql_value "SELECT CONVERT(varchar(23), SYSDATETIME(), 121)")

# sp_addsubscription refuses to run in a transaction (15002): this batch opens none.
# A snapshot publication takes the default @immediate_sync of its @repl_freq.
sql <<'SQL'
SET NOCOUNT ON;
USE Sales;
CREATE TABLE dbo.m_t1 (id int PRIMARY KEY, a int, b int); INSERT dbo.m_t1 VALUES (1, 1, 1);
CREATE TABLE dbo.m_t2 (id int PRIMARY KEY, a int, b int); INSERT dbo.m_t2 VALUES (1, 1, 1);
GO
CREATE VIEW dbo.m_v1 AS SELECT id, a, b FROM dbo.m_t1;
GO
CREATE DATABASE m_sub;
GO
USE Sales;
DECLARE @srv sysname = @@SERVERNAME;
EXEC sp_addpublication @publication = N'm_snap', @status = N'active', @allow_push = N'true', @repl_freq = N'snapshot';
EXEC sp_addpublication_snapshot @publication = N'm_snap', @frequency_type = 1, @active_start_date = 99991231,
     @job_login = NULL, @job_password = NULL, @publisher_security_mode = 1;
EXEC sp_addarticle @publication = N'm_snap', @article = N'm_t1', @source_owner = N'dbo', @source_object = N'm_t1';
EXEC sp_addarticle @publication = N'm_snap', @article = N'm_t2', @source_owner = N'dbo', @source_object = N'm_t2';
EXEC sp_addsubscription @publication = N'm_snap', @subscriber = @srv, @destination_db = N'm_sub',
     @subscription_type = N'Push', @sync_type = N'automatic', @article = N'all';
EXEC sp_addpushsubscription_agent @publication = N'm_snap', @subscriber = @srv, @subscriber_db = N'm_sub',
     @job_login = NULL, @job_password = NULL, @subscriber_security_mode = 1;
GO
SQL

sql -Q "SET NOCOUNT ON; EXEC Sales.dbo.sp_startpublication_snapshot @publication = N'm_snap'" </dev/null
# The snapshot agent reports completion and the distribution agent delivered it. The
# distribution agent is the shared 'ALL' agent of m_sub, or an agent named m_snap.
wait_until 180 "SELECT CASE WHEN EXISTS (SELECT 1 FROM distribution.dbo.MSsnapshot_history h JOIN distribution.dbo.MSsnapshot_agents a ON a.id = h.agent_id WHERE a.publication = N'm_snap' AND h.time >= '$mark0' AND h.runstatus = 2)
    AND EXISTS (SELECT 1 FROM distribution.dbo.MSdistribution_history h JOIN distribution.dbo.MSdistribution_agents a ON a.id = h.agent_id WHERE a.subscriber_db = N'm_sub' AND a.subscriber_id >= 0 AND h.time >= '$mark0' AND h.comments LIKE N'Delivered snapshot%') THEN 1 ELSE 0 END" \
    || { echo "m_snap: snapshot not delivered" >&2; exit 1; }

# Stored values: each one differs from the value the matrix sets.
stored=$(sql_value "SELECT CASE WHEN
    (SELECT COUNT(*) FROM Sales.dbo.syspublications WHERE name = N'm_snap' AND repl_freq = 1 AND immediate_sync = 0 AND independent_agent = 0 AND allow_anonymous = 0
        AND allow_pull = 0 AND allow_push = 1 AND retention = 336 AND sync_method = 0 AND snapshot_in_defaultfolder = 1 AND alt_snapshot_folder IS NULL
        AND allow_subscription_copy = 0 AND replicate_ddl = 1 AND status = 1 AND enabled_for_internet = 0 AND compress_snapshot = 0
        AND pre_snapshot_script IS NULL AND post_snapshot_script IS NULL AND ftp_address IS NULL AND immediate_sync_ready = 0) = 1
    AND (SELECT COUNT(*) FROM Sales.dbo.sysarticles WHERE name IN (N'm_t1', N'm_t2') AND schema_option = 0x0000000000030071 AND pre_creation_cmd = 1
        AND dest_table = name AND dest_owner = N'dbo' AND ins_cmd = N'SQL' AND upd_cmd = N'SQL' AND del_cmd = N'SQL' AND creation_script IS NULL
        AND fire_triggers_on_snapshot = 0 AND type = 1 AND status = 16) = 2
    AND (SELECT COUNT(*) FROM Sales.dbo.syssubscriptions s JOIN Sales.dbo.sysarticles a ON a.artid = s.artid WHERE a.name IN (N'm_t1', N'm_t2') AND s.srvid >= 0 AND s.status = 2) = 2
    THEN 1 ELSE 0 END") || exit 1
if [ "$stored" != 1 ]; then
    echo "09-snapshot-pub: control failed: m_snap does not hold the starting values the matrix assumes" >&2
    sql -Q "SET NOCOUNT ON; SELECT immediate_sync, independent_agent, allow_anonymous, allow_pull, allow_push, retention, sync_method, snapshot_in_defaultfolder, immediate_sync_ready, status FROM Sales.dbo.syspublications WHERE name = N'm_snap'" </dev/null >&2 || true
    exit 1
fi

out=$(sql -h -1 < "$here/09-snapshot-pub-matrix.sql")
printf '%s\n' "$out" | grep -v '^R|' >&2 || true
rows=$(printf '%s\n' "$out" | grep '^R|' | grep -v '^R|TOTAL|' || true)
n=$(printf '%s\n' "$rows" | grep -c '^R|' || true)
sql_total=$(printf '%s\n' "$out" | sed -n 's/^R|TOTAL|//p')
if [ "$n" != "$expected_rows" ] || [ "$sql_total" != "$n" ]; then
    echo "09-snapshot-pub: $n rows (sql said '$sql_total'), expected $expected_rows" >&2
    exit 1
fi

bad=0
control() { echo "09-snapshot-pub: control failed: $*" >&2; bad=1; }
# every row read in the state the rule needs: not ready, subscription active
notstate=$(printf '%s\n' "$rows" | grep -vc ' (ready=0 status=2)$' || true)
[ "$notstate" = 0 ] || { control "$notstate rows not read at ready=0 status=2:"; printf '%s\n' "$rows" | grep -v ' (ready=0 status=2)$' >&2 || true; }
# immediate_sync_ready = 0: no operation asks for @force_invalidate_snapshot
asked=$(printf '%s\n' "$rows" | grep -c '=20607' || true)
[ "$asked" = 0 ] || { control "$asked rows ask for @force_invalidate_snapshot (20607) although ready=0:"; printf '%s\n' "$rows" | grep '=20607' >&2 || true; }
# reinit needed, invalidation not: the shape of SalesRef A13
cells=$(printf '%s\n' "$rows" | awk -F'|' '$4 ~ /^m_snap.m_t2 article schema_option / { print $3 }')
[ "$cells" = "f00=20608,f10=20608,f01=ok,f11=ok" ] \
    || control "m_t2 schema_option is '$cells', predicted f00=20608,f10=20608,f01=ok,f11=ok"
[ "$bad" = 0 ] || exit 1
cleanup
printf '%s\n' "$rows"
echo "R|TOTAL|$n"
