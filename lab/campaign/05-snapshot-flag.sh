#!/bin/bash
# When the replication procedures ask for @force_invalidate_snapshot and
# @force_reinit_subscription, depending on the state of the publication's snapshot
# (campaign item 1; docs/analysis/step-1-analysis.md section 5). Run through
# lab/campaign.sh.
#
# Seven publications on the tables m_t1 and m_t2 of Sales, one per state, each with a
# push subscription to its own database m_sub<n>:
#   S1 m_s1  immediate_sync = 1, snapshot generated and delivered
#   S2 m_s2  immediate_sync = 1, subscription added, snapshot agent never started
#   S3 m_s3  immediate_sync = 0 (shared agent), snapshot delivered
#   S4 m_s4  immediate_sync = 0 (shared agent), subscription added, never started
#   S5 m_s5  immediate_sync = 1, snapshot delivered, then invalidated by
#            sp_changearticle schema_option on m_t2 with both flags at 1, not
#            regenerated: the subscription of m_t2 waits for reinitialization
#            (status 1), m_t1, which the operations touch, stays active (status 2)
#   S6 m_s6  the same with m_t1 invalidated: the operated article waits (status 1),
#            m_t2 stays active
#   S7 m_s7  immediate_sync = 1, snapshot generated before any subscription
#            (ready = 1), then a subscription added and held undelivered: the
#            subscriber database is offline while sp_addsubscription starts the
#            agent, the agent job is disabled and stopped, and the database comes
#            back online. Measured on 2022: the subscription is at status 2 at
#            once, without delivery; status 1 with ready = 1 is not reached this way.
# Nine operations, each run once per flag combination the procedure takes, every
# run inside a transaction rolled back in the same batch:
#   O1 sp_addarticle m_t3                 O6 sp_changepublication sync_method
#   O2 sp_dropsubscription + sp_droparticle m_t2
#   O3 sp_changearticle schema_option     O7 sp_articlefilter m_f1 on m_t1
#   O4 sp_changearticle description       O8 sp_articleview m_v1 on m_t1
#   O5 sp_changepublication alt_snapshot_folder
#                                         O9 sp_articlecolumn drop b on m_t1
# Rows: S<n>.O<m> with the cells f00, f10, f01, f11 (f00 and f10 only for O1 and O2:
# sp_addarticle and sp_droparticle take no @force_reinit_subscription), detail
# ready=<immediate_sync_ready read just before the operation>, art_status=<status of
# the operated article's subscription, n/a for O1, O5, O6>, sub_status=<distinct
# statuses>; then S<n>.ready, read after the nine operations. 70 rows.
# The script asserts its own state controls (expected ready per state, the article
# statuses that define S5 and S6, S7 still undelivered) and the Step 3 controls, and
# exits 1 on a mismatch: a row read in another state rejects the run.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"

# Publications whose snapshot is generated and delivered before measuring.
delivered="m_s1 m_s3 m_s5 m_s6"
# Expected immediate_sync_ready per state, S1 to S7.
expected_ready=(x 1 0 0 0 0 0 1)

cleaned=0
cleanup() {
    [ "$cleaned" = 1 ] && return
    cleaned=1
    sql >&2 <<'SQL' || true
SET NOCOUNT ON;
USE Sales;
DECLARE @p sysname, @n int = 1;
WHILE @n <= 7
BEGIN
    SET @p = N'm_s' + CONVERT(nvarchar(1), @n);
    BEGIN TRY IF EXISTS (SELECT 1 FROM dbo.syspublications WHERE name = @p)
        EXEC sp_dropsubscription @publication = @p, @article = N'all', @subscriber = N'all'; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY IF EXISTS (SELECT 1 FROM dbo.syspublications WHERE name = @p)
        EXEC sp_droppublication @publication = @p; END TRY BEGIN CATCH END CATCH;
    SET @n += 1;
END;
DROP VIEW IF EXISTS dbo.m_v1;
DROP PROCEDURE IF EXISTS dbo.m_f1;
DROP TABLE IF EXISTS dbo.m_t1, dbo.m_t2, dbo.m_t3;
GO
DECLARE @d sysname, @n int = 1, @s nvarchar(400);
WHILE @n <= 7
BEGIN
    SET @d = N'm_sub' + CONVERT(nvarchar(1), @n);
    IF DB_ID(@d) IS NOT NULL
    BEGIN
        -- S7 takes its database offline; an offline database is dropped without its files.
        IF CONVERT(sysname, DATABASEPROPERTYEX(@d, 'Status')) <> N'ONLINE'
        BEGIN
            SET @s = N'ALTER DATABASE ' + QUOTENAME(@d) + N' SET ONLINE;';
            EXEC (@s);
        END;
        SET @s = N'ALTER DATABASE ' + QUOTENAME(@d) + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE ' + QUOTENAME(@d) + N';';
        EXEC (@s);
    END;
    SET @n += 1;
END;
SQL
    podman exec repllab find /var/opt/mssql/data/ReplData/unc -mindepth 1 -maxdepth 1 -iname '*_m_*' -exec rm -rf {} + >&2 || true
}
trap cleanup EXIT

# Leftovers of an earlier run are not absorbed: they fail this run (the exit guard),
# and the trap removes them.
left=$(sql_value "SELECT (SELECT COUNT(*) FROM Sales.dbo.syspublications WHERE name LIKE N'm\_s_' ESCAPE N'\') + (SELECT COUNT(*) FROM sys.databases WHERE name LIKE N'm\_sub_' ESCAPE N'\') + (SELECT COUNT(*) FROM Sales.sys.objects WHERE name LIKE N'm\_%' ESCAPE N'\')") \
    || exit 1
left_files=$(podman exec repllab find /var/opt/mssql/data/ReplData/unc -mindepth 1 -maxdepth 1 -iname '*_m_*')
if [ "$left" != 0 ] || [ -n "$left_files" ]; then
    echo "05-snapshot-flag: leftovers of an earlier run (objects=$left files=$left_files); removing them and failing" >&2
    exit 1
fi

# Distribution agent of each publication: immediate_sync needs an independent agent;
# m_s3 and m_s4 share the 'ALL' agent of their subscriber database, as SalesRef does.
agent_pred() { # PUB
    case $1 in
        m_s1|m_s2|m_s5|m_s6|m_s7) echo "a.publication = N'$1'" ;;
        m_s3) echo "a.publication = N'ALL' AND a.subscriber_db = N'm_sub3'" ;;
        m_s4) echo "a.publication = N'ALL' AND a.subscriber_db = N'm_sub4'" ;;
    esac
}

# The snapshot of PUB, started after MARK, has finished and its tables are copied:
# the snapshot agent reports completion and the distribution agent delivered it.
snapshot_done() { # PUB MARK
    wait_until 180 "SELECT CASE WHEN EXISTS (SELECT 1 FROM distribution.dbo.MSsnapshot_history h JOIN distribution.dbo.MSsnapshot_agents a ON a.id = h.agent_id WHERE a.publication = N'$1' AND h.time >= '$2' AND h.runstatus = 2)
        AND EXISTS (SELECT 1 FROM distribution.dbo.MSdistribution_history h JOIN distribution.dbo.MSdistribution_agents a ON a.id = h.agent_id WHERE $(agent_pred "$1") AND h.time >= '$2' AND h.comments LIKE N'Delivered snapshot%') THEN 1 ELSE 0 END"
}

mark0=$(sql_value "SELECT CONVERT(varchar(23), SYSDATETIME(), 121)")

# Setup. Each snapshot agent gets a schedule that never fires; snapshots run only
# when this script starts them. sp_addsubscription refuses to run in a transaction
# (15002): this batch opens none.
# On 2022 sp_addsubscription creates and starts the push distribution job itself
# ("The distribution agent job has been implicitly created"); sp_addpushsubscription_agent
# then finds that job and only starts it again (measured: one job per subscription).
# It is still called because the scripts run unchanged on 2019, which does not
# create the job implicitly. m_s7 gets its subscription later (S7 below).
sql <<'SQL'
SET NOCOUNT ON;
USE Sales;
CREATE TABLE dbo.m_t1 (id int PRIMARY KEY, a int, b int); INSERT dbo.m_t1 VALUES (1, 1, 1);
CREATE TABLE dbo.m_t2 (id int PRIMARY KEY, a int, b int); INSERT dbo.m_t2 VALUES (1, 1, 1);
CREATE TABLE dbo.m_t3 (id int PRIMARY KEY, a int, b int); INSERT dbo.m_t3 VALUES (1, 1, 1);
CREATE DATABASE m_sub1;
CREATE DATABASE m_sub2;
CREATE DATABASE m_sub3;
CREATE DATABASE m_sub4;
CREATE DATABASE m_sub5;
CREATE DATABASE m_sub6;
CREATE DATABASE m_sub7;
GO
USE Sales;
DECLARE @srv sysname = @@SERVERNAME, @n int = 1, @p sysname, @d sysname, @imm nvarchar(5);
WHILE @n <= 7
BEGIN
    SET @p = N'm_s' + CONVERT(nvarchar(1), @n);
    SET @d = N'm_sub' + CONVERT(nvarchar(1), @n);
    SET @imm = CASE WHEN @n IN (3, 4) THEN N'false' ELSE N'true' END;
    EXEC sp_addpublication @publication = @p, @status = N'active', @allow_push = N'true',
         @independent_agent = @imm, @immediate_sync = @imm, @repl_freq = N'continuous', @sync_method = N'concurrent';
    EXEC sp_addpublication_snapshot @publication = @p, @frequency_type = 1, @active_start_date = 99991231,
         @job_login = NULL, @job_password = NULL, @publisher_security_mode = 1;
    EXEC sp_addarticle @publication = @p, @article = N'm_t1', @source_owner = N'dbo', @source_object = N'm_t1';
    EXEC sp_addarticle @publication = @p, @article = N'm_t2', @source_owner = N'dbo', @source_object = N'm_t2';
    IF @n = 7 BREAK;
    EXEC sp_addsubscription @publication = @p, @subscriber = @srv, @destination_db = @d,
         @subscription_type = N'Push', @sync_type = N'automatic', @article = N'all';
    EXEC sp_addpushsubscription_agent @publication = @p, @subscriber = @srv, @subscriber_db = @d,
         @job_login = NULL, @job_password = NULL, @subscriber_security_mode = 1;
    SET @n += 1;
END;
GO
SQL

# One snapshot at a time: run together on the shared tables, one of five snapshot
# agents failed with "Script failed for Table 'dbo.m_t2'" (seen once, m_s6).
for p in $delivered; do
    sql -Q "SET NOCOUNT ON; EXEC Sales.dbo.sp_startpublication_snapshot @publication = N'$p'" </dev/null
    snapshot_done "$p" "$mark0" || { echo "$p: snapshot not delivered" >&2; exit 1; }
done
# m_s7 has no subscription yet: its snapshot is generated, nothing is delivered.
sql -Q "SET NOCOUNT ON; EXEC Sales.dbo.sp_startpublication_snapshot @publication = N'm_s7'" </dev/null
wait_until 180 "SELECT CASE WHEN EXISTS (SELECT 1 FROM distribution.dbo.MSsnapshot_history h JOIN distribution.dbo.MSsnapshot_agents a ON a.id = h.agent_id WHERE a.publication = N'm_s7' AND h.time >= '$mark0' AND h.runstatus = 2) THEN 1 ELSE 0 END" \
    || { echo "m_s7: snapshot not generated" >&2; exit 1; }

# S5 and S6: invalidate the delivered snapshot, both flags at 1, and do not
# regenerate it; S5 through m_t2, S6 through m_t1, the article the operations touch.
sql <<'SQL'
SET NOCOUNT ON;
USE Sales;
EXEC sp_changearticle @publication = N'm_s5', @article = N'm_t2', @property = N'schema_option',
     @value = N'0x0000000000030077', @force_invalidate_snapshot = 1, @force_reinit_subscription = 1;
EXEC sp_changearticle @publication = N'm_s6', @article = N'm_t1', @property = N'schema_option',
     @value = N'0x0000000000030077', @force_invalidate_snapshot = 1, @force_reinit_subscription = 1;
SQL

# S7: a subscription added to m_s7, whose snapshot is ready, held undelivered. The
# agent that sp_addsubscription starts cannot reach the offline database; its job is
# disabled, so that nothing restarts it, and stopped if it is still running.
sql <<'SQL'
SET NOCOUNT ON;
ALTER DATABASE m_sub7 SET OFFLINE WITH ROLLBACK IMMEDIATE;
GO
USE Sales;
DECLARE @srv sysname = @@SERVERNAME;
EXEC sp_addsubscription @publication = N'm_s7', @subscriber = @srv, @destination_db = N'm_sub7',
     @subscription_type = N'Push', @sync_type = N'automatic', @article = N'all';
EXEC sp_addpushsubscription_agent @publication = N'm_s7', @subscriber = @srv, @subscriber_db = N'm_sub7',
     @job_login = NULL, @job_password = NULL, @subscriber_security_mode = 1;
DECLARE @j uniqueidentifier = (SELECT CONVERT(uniqueidentifier, job_id) FROM distribution.dbo.MSdistribution_agents
                               WHERE publication = N'm_s7' AND subscriber_db = N'm_sub7' AND subscriber_id >= 0);
EXEC msdb.dbo.sp_update_job @job_id = @j, @enabled = 0;
GO
SQL
s7_job="(SELECT CONVERT(uniqueidentifier, job_id) FROM distribution.dbo.MSdistribution_agents WHERE publication = N'm_s7' AND subscriber_db = N'm_sub7' AND subscriber_id >= 0)"
s7_running="SELECT CASE WHEN EXISTS (SELECT 1 FROM msdb.dbo.sysjobactivity WHERE job_id = $s7_job AND session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions) AND start_execution_date IS NOT NULL AND stop_execution_date IS NULL) THEN 1 ELSE 0 END"
if [ "$(sql_value "$s7_running")" = 1 ]; then
    # sp_stop_job on a job that has just ended prints its refusal past TRY: discarded,
    # the wait below decides.
    sql -Q "SET NOCOUNT ON; DECLARE @j uniqueidentifier = $s7_job; BEGIN TRY EXEC msdb.dbo.sp_stop_job @job_id = @j; END TRY BEGIN CATCH END CATCH" </dev/null >/dev/null 2>&1 || true
fi
wait_until 120 "SELECT 1 - ($s7_running)" || { echo "m_s7: distribution job still running" >&2; exit 1; }
sql -Q "SET NOCOUNT ON; ALTER DATABASE m_sub7 SET ONLINE" </dev/null
s7_delivered="SELECT COUNT(*) FROM distribution.dbo.MSdistribution_history h JOIN distribution.dbo.MSdistribution_agents a ON a.id = h.agent_id WHERE a.publication = N'm_s7' AND h.comments LIKE N'Delivered snapshot%'"

# Measurement. One batch; the rows are built in a table variable (not undone by the
# rollbacks) and printed by one SELECT at the end, so that a failing case still has
# its row. The step that raised an error is kept in SESSION_CONTEXT, which a rollback
# does not undo either.
out=$(sql -h -1 <<'SQL'
SET NOCOUNT ON;
USE Sales;
DECLARE @srv sysname = @@SERVERNAME;
DECLARE @ops TABLE (m int, cells int, art sysname NULL, stmt nvarchar(max));
INSERT @ops VALUES
 (1, 2, NULL, N'EXEC sp_set_session_context N''step'', N''sp_addarticle'';
EXEC sp_addarticle @publication = N''{pub}'', @article = N''m_t3'', @source_owner = N''dbo'', @source_object = N''m_t3'', @force_invalidate_snapshot = @i;'),
 (2, 2, N'm_t2', N'EXEC sp_set_session_context N''step'', N''sp_dropsubscription'';
EXEC sp_dropsubscription @publication = N''{pub}'', @article = N''m_t2'', @subscriber = @srv, @destination_db = N''{sub}'';
EXEC sp_set_session_context N''step'', N''sp_droparticle'';
EXEC sp_droparticle @publication = N''{pub}'', @article = N''m_t2'', @force_invalidate_snapshot = @i;'),
 (3, 4, N'm_t1', N'EXEC sp_set_session_context N''step'', N''sp_changearticle'';
EXEC sp_changearticle @publication = N''{pub}'', @article = N''m_t1'', @property = N''schema_option'', @value = N''0x000000000803509F'', @force_invalidate_snapshot = @i, @force_reinit_subscription = @r;'),
 (4, 4, N'm_t1', N'EXEC sp_set_session_context N''step'', N''sp_changearticle'';
EXEC sp_changearticle @publication = N''{pub}'', @article = N''m_t1'', @property = N''description'', @value = N''changed'', @force_invalidate_snapshot = @i, @force_reinit_subscription = @r;'),
 (5, 4, NULL, N'EXEC sp_set_session_context N''step'', N''sp_changepublication'';
EXEC sp_changepublication @publication = N''{pub}'', @property = N''alt_snapshot_folder'', @value = N''/var/opt/mssql/data/ReplAlt'', @force_invalidate_snapshot = @i, @force_reinit_subscription = @r;'),
 (6, 4, NULL, N'EXEC sp_set_session_context N''step'', N''sp_changepublication'';
EXEC sp_changepublication @publication = N''{pub}'', @property = N''sync_method'', @value = N''native'', @force_invalidate_snapshot = @i, @force_reinit_subscription = @r;'),
 (7, 4, N'm_t1', N'EXEC sp_set_session_context N''step'', N''sp_articlefilter'';
EXEC sp_articlefilter @publication = N''{pub}'', @article = N''m_t1'', @filter_name = N''m_f1'', @filter_clause = N''a > 0'', @force_invalidate_snapshot = @i, @force_reinit_subscription = @r;'),
 (8, 4, N'm_t1', N'EXEC sp_set_session_context N''step'', N''sp_articleview'';
EXEC sp_articleview @publication = N''{pub}'', @article = N''m_t1'', @view_name = N''m_v1'', @filter_clause = N''a > 0'', @force_invalidate_snapshot = @i, @force_reinit_subscription = @r;'),
 (9, 4, N'm_t1', N'EXEC sp_set_session_context N''step'', N''sp_articlecolumn'';
EXEC sp_articlecolumn @publication = N''{pub}'', @article = N''m_t1'', @column = N''b'', @operation = N''drop'', @force_invalidate_snapshot = @i, @force_reinit_subscription = @r;');
DECLARE @flags TABLE (k int, i bit, r bit, name char(3));
INSERT @flags VALUES (0, 0, 0, 'f00'), (1, 1, 0, 'f10'), (2, 0, 1, 'f01'), (3, 1, 1, 'f11');
-- m = 0 is the S<n>.ready read after the nine operations.
DECLARE @state TABLE (n int, m int, ready nvarchar(10), art_status nvarchar(10), sub_status nvarchar(100));
DECLARE @res TABLE (n int, m int, k int, cell varchar(10), step nvarchar(64), err int, msg nvarchar(400));

DECLARE @n int = 1, @m int, @k int, @cells int, @pub sysname, @sub sysname, @stmt nvarchar(max), @i bit, @r bit;
WHILE @n <= 8
BEGIN
    -- The state of the previous publication after its nine operations.
    IF @n > 1
        INSERT @state
        SELECT @n - 1, 0, ISNULL((SELECT CONVERT(nvarchar(10), immediate_sync_ready) FROM dbo.syspublications WHERE name = @pub), N'none'), NULL,
               ISNULL((SELECT STRING_AGG(CONVERT(nvarchar(10), st), N'/') WITHIN GROUP (ORDER BY st)
                       FROM (SELECT DISTINCT s.status AS st FROM dbo.syssubscriptions s JOIN dbo.sysarticles a ON a.artid = s.artid
                             JOIN dbo.syspublications p ON p.pubid = a.pubid WHERE p.name = @pub AND s.srvid >= 0) x), N'none');
    IF @n = 8 BREAK;
    SET @pub = N'm_s' + CONVERT(nvarchar(1), @n);
    SET @sub = N'm_sub' + CONVERT(nvarchar(1), @n);
    SET @m = 1;
    WHILE @m <= 9
    BEGIN
        INSERT @state
        SELECT @n, @m, ISNULL((SELECT CONVERT(nvarchar(10), immediate_sync_ready) FROM dbo.syspublications WHERE name = @pub), N'none'),
               CASE WHEN o.art IS NULL THEN N'n/a' ELSE ISNULL((SELECT STRING_AGG(CONVERT(nvarchar(10), s.status), N'/')
                       FROM dbo.syssubscriptions s JOIN dbo.sysarticles a ON a.artid = s.artid
                       JOIN dbo.syspublications p ON p.pubid = a.pubid WHERE p.name = @pub AND a.name = o.art AND s.srvid >= 0), N'none') END,
               ISNULL((SELECT STRING_AGG(CONVERT(nvarchar(10), st), N'/') WITHIN GROUP (ORDER BY st)
                       FROM (SELECT DISTINCT s.status AS st FROM dbo.syssubscriptions s JOIN dbo.sysarticles a ON a.artid = s.artid
                             JOIN dbo.syspublications p ON p.pubid = a.pubid WHERE p.name = @pub AND s.srvid >= 0) x), N'none')
        FROM @ops o WHERE o.m = @m;
        SELECT @cells = cells, @stmt = REPLACE(REPLACE(stmt, N'{pub}', @pub), N'{sub}', @sub) FROM @ops WHERE m = @m;
        SET @k = 0;
        WHILE @k < @cells
        BEGIN
            SELECT @i = i, @r = r FROM @flags WHERE k = @k;
            EXEC sp_set_session_context N'step', NULL;
            BEGIN TRY
                BEGIN TRAN;
                EXEC sp_executesql @stmt, N'@i bit, @r bit, @srv sysname', @i = @i, @r = @r, @srv = @srv;
                ROLLBACK;
                INSERT @res VALUES (@n, @m, @k, 'ok', NULL, NULL, NULL);
            END TRY
            BEGIN CATCH
                DECLARE @e int = ERROR_NUMBER(), @msg nvarchar(400) = LEFT(ERROR_MESSAGE(), 400);
                IF @@TRANCOUNT > 0 ROLLBACK;
                INSERT @res VALUES (@n, @m, @k, CONVERT(varchar(10), @e), CONVERT(nvarchar(64), SESSION_CONTEXT(N'step')), @e, @msg);
            END CATCH;
            IF @@TRANCOUNT > 0 ROLLBACK;
            SET @k += 1;
        END;
        SET @m += 1;
    END;
    SET @n += 1;
END;
EXEC sp_set_session_context N'step', NULL;

-- One line per row. Errors other than 20607 (needs @force_invalidate_snapshot) and
-- 20608 (needs @force_reinit_subscription) carry their message; every error of O2
-- says which of its two procedures raised it.
SELECT CAST(N'R|S' + CONVERT(nvarchar(1), st.n) + N'.O' + CONVERT(nvarchar(1), st.m) + N'|'
       + (SELECT STRING_AGG(CONVERT(nvarchar(20), f.name + '=' + r.cell), N',') WITHIN GROUP (ORDER BY r.k)
          FROM @res r JOIN @flags f ON f.k = r.k WHERE r.n = st.n AND r.m = st.m)
       + N'|ready=' + st.ready + N' art_status=' + st.art_status + N' sub_status=' + st.sub_status
       + ISNULL((SELECT STRING_AGG(CONVERT(nvarchar(4000), N'; ' + g.keys + N' at ' + ISNULL(g.step, N'?') + N' ' + CONVERT(nvarchar(10), g.err)
                        + ISNULL(N': ' + REPLACE(REPLACE(REPLACE(g.msg, N'|', N'/'), CHAR(13), N' '), CHAR(10), N' '), N'')), N'')
                 FROM (SELECT r.step, r.err, CASE WHEN r.err IN (20607, 20608) THEN NULL ELSE r.msg END AS msg,
                              STRING_AGG(CONVERT(nvarchar(20), f.name), N',') WITHIN GROUP (ORDER BY r.k) AS keys
                       FROM @res r JOIN @flags f ON f.k = r.k
                       WHERE r.n = st.n AND r.m = st.m AND r.err IS NOT NULL AND (st.m = 2 OR r.err NOT IN (20607, 20608))
                       GROUP BY r.step, r.err, CASE WHEN r.err IN (20607, 20608) THEN NULL ELSE r.msg END) g), N'')
       AS nvarchar(4000))
FROM @state st WHERE st.m > 0
UNION ALL
SELECT CAST(N'R|S' + CONVERT(nvarchar(1), n) + N'.ready|' + ready + N'|sub_status=' + sub_status + N' after the nine operations' AS nvarchar(4000))
FROM @state WHERE m = 0
ORDER BY 1;
SQL
)
# Anything else the batch printed (a Msg line above all) goes to the log, where
# campaign.sh reads it.
printf '%s\n' "$out" | grep -v '^R|' >&2 || true
rows=$(printf '%s\n' "$out" | grep '^R|' || true)
n=$(printf '%s\n' "$rows" | grep -c '^R|' || true)
if [ "$n" != 70 ]; then
    echo "05-snapshot-flag: $n rows, expected 70" >&2
    exit 1
fi

# State and Step 3 controls. Each mismatch is said on stderr; any fails the run.
bad=0
control() { echo "05-snapshot-flag: control failed: $*" >&2; bad=1; }
field() { # ID N : field N of row ID
    printf '%s\n' "$rows" | awk -F'|' -v id="$1" -v n="$2" '$2 == id { print $n }'
}
for s in 1 2 3 4 5 6 7; do
    want=${expected_ready[$s]}
    for o in 1 2 3 4 5 6 7 8 9; do
        d=$(field "S$s.O$o" 4)
        [[ $d == "ready=$want "* ]] || control "S$s.O$o read in another state, expected ready=$want: $d"
    done
    got=$(field "S$s.ready" 3)
    [ "$got" = "$want" ] || control "S$s.ready=$got, expected $want"
done
[ "$(field S1.O3 3)" = "f00=20607,f10=20608,f01=20607,f11=ok" ] \
    || control "S1.O3 is $(field S1.O3 3), expected f00=20607,f10=20608,f01=20607,f11=ok"
[[ $(field S3.O3 3) == *f01=ok* ]] || control "S3.O3 needs the invalidate flag: $(field S3.O3 3)"
for s in 1 2 3 4 5 6 7; do
    [ "$(field "S$s.O4" 3)" = "f00=ok,f10=ok,f01=ok,f11=ok" ] \
        || control "S$s.O4 is $(field "S$s.O4" 3), expected ok in every cell"
done
# What tells S5 from S6: which article waits for reinitialization.
[[ $(field S5.O3 4) == *" art_status=2 "* && $(field S5.O2 4) == *" art_status=1 "* ]] \
    || control "S5: m_t1 not active or m_t2 not waiting: $(field S5.O3 4) / $(field S5.O2 4)"
[[ $(field S6.O3 4) == *" art_status=1 "* && $(field S6.O2 4) == *" art_status=2 "* ]] \
    || control "S6: m_t1 not waiting or m_t2 not active: $(field S6.O3 4) / $(field S6.O2 4)"
# S7 held: nothing delivered to m_sub7, during the operations included.
d7=$(sql_value "$s7_delivered") || d7=error
[ "$d7" = 0 ] || control "S7: the snapshot was delivered ($d7 deliveries): the state was not held"
[ "$bad" = 0 ] || exit 1
cleanup
printf '%s\n' "$rows"
echo "R|TOTAL|$n"
