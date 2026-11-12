#!/bin/bash
# The reverse directions of the measured properties: the change back to the default of a
# property that 02-matrix and 05-snapshot-flag measured only in the direction away from
# it (plan 3, Task 1; read by the cost table, TestCostTableMatchesRows). Run through
# lab/campaign.sh.
#
# Objects, all m_ (in Sales unless said): the table dbo.m_rv_t1 (10 rows), the subscriber
# database m_rv_sub, the files m_rv_pre.sql, m_rv_post.sql, m_rv_create.sql under
# /var/opt/mssql/data (the pre- and post-snapshot scripts and the article's creation
# script), and three publications, each with a snapshot agent whose schedule never fires:
#   I m_rv_i  immediate_sync, independent agent, sync_method native, created with the
#             non-default values replicate_ddl 0, allow_pull, allow_initialize_from_backup,
#             allow_subscription_copy, allow_partition_switch, replicate_partition_switch,
#             alt_snapshot_folder /var/opt/mssql/data/ReplAlt, snapshot_in_defaultfolder
#             false, pre_snapshot_script and post_snapshot_script, then allow_drop true;
#             article m_rv_t1 with status 8 (column names, not parameterized),
#             fire_triggers_on_snapshot true and a creation_script; a push subscription to
#             m_rv_sub, its snapshot generated and delivered (05 S1: ready 1, status 2).
#             The two snapshot scripts and the creation script are set after the delivery
#             (see the setup), then the snapshot is generated again.
#   N m_rv_n  the same without immediate_sync, independent_agent and
#             allow_subscription_copy (which needs immediate_sync, 21210): shared agent,
#             subscribed and delivered (ready 0, status 2).
#   P m_rv_p  no immediate_sync, allow_push false, allow_pull true, status inactive, no
#             article, no subscription.
# Each case runs four times, (@force_invalidate_snapshot, @force_reinit_subscription) =
# (0,0), (1,0), (0,1), (1,1), each time in a transaction rolled back in the same batch. A
# case with a preparation runs it first in the same transaction with both flags at 0.
# Rows:
#   R|RV.<state>.<case>|f00=..,f10=..,f01=..,f11=..|<procedure> <object> <property> = <value>
#     [; <cells> at <step> <error>: <message>] (ready=<immediate_sync_ready> status=<statuses>)
#   R|RV.<state>.state|ready=<n> status=<n>|   read after the cases of the state.
# A cell is ok, the error number, or rc<n> for a procedure that returned n without an
# error. Errors other than 20607 (needs @force_invalidate_snapshot) and 20608 (needs
# @force_reinit_subscription) carry their message, and so does any error of a
# preparation step. status is the distinct subscription statuses, none without one.
# The script asserts the state of each row (ready and status as above) and four cells per
# case row, and exits 1 otherwise. The count is not asserted: the plan expects 45.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"

data=/var/opt/mssql/data
alt=$data/ReplAlt
pubs="m_rv_i m_rv_n m_rv_p"

cleaned=0
cleanup() {
    [ "$cleaned" = 1 ] && return
    cleaned=1
    ( stop_m_agents ) || true
    # One publication at a time, by name: the break step of the task removes one of them.
    local p
    for p in $pubs; do
        sql >&2 <<SQL || true
SET NOCOUNT ON;
USE Sales;
BEGIN TRY IF EXISTS (SELECT 1 FROM dbo.syspublications WHERE name = N'$p')
    EXEC sp_dropsubscription @publication = N'$p', @article = N'all', @subscriber = N'all'; END TRY BEGIN CATCH END CATCH;
WHILE @@TRANCOUNT > 0 ROLLBACK;
BEGIN TRY IF EXISTS (SELECT 1 FROM dbo.syspublications WHERE name = N'$p')
    EXEC sp_droppublication @publication = N'$p'; END TRY BEGIN CATCH END CATCH;
WHILE @@TRANCOUNT > 0 ROLLBACK;
SQL
    done
    sql >&2 <<'SQL' || true
SET NOCOUNT ON;
USE Sales;
DROP TABLE IF EXISTS dbo.m_rv_t1;
GO
IF DB_ID(N'm_rv_sub') IS NOT NULL
BEGIN
    ALTER DATABASE m_rv_sub SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE m_rv_sub;
END;
SQL
    podman exec repllab find "$data/ReplData/unc" -mindepth 1 -maxdepth 1 -iname '*_m_*' -exec rm -rf {} + >&2 || true
    podman exec repllab bash -c "rm -f $data/m_rv_pre.sql $data/m_rv_post.sql $data/m_rv_create.sql;
        if [ -d $alt ]; then find $alt -mindepth 2 -maxdepth 2 -iname '*_m_*' -exec rm -rf {} +; rmdir $alt/unc 2>/dev/null; rmdir $alt 2>/dev/null; fi; true" >&2 || true
}
trap cleanup EXIT

# Leftovers of an earlier run fail this run; the trap removes them.
left=$(sql_value "SELECT (SELECT COUNT(*) FROM Sales.dbo.syspublications WHERE name LIKE N'm\_rv\_%' ESCAPE N'\') + (SELECT COUNT(*) FROM sys.databases WHERE name = N'm_rv_sub') + (SELECT COUNT(*) FROM Sales.sys.objects WHERE name LIKE N'm\_%' ESCAPE N'\')") \
    || exit 1
left_files=$(podman exec repllab bash -c "find $data/ReplData/unc -mindepth 1 -maxdepth 1 -iname '*_m_*'; find $data -maxdepth 1 -iname 'm_rv_*'; [ -d $alt ] && find $alt -iname '*_m_*'; true")
if [ "$left" != 0 ] || [ -n "$left_files" ]; then
    echo "18-reverse: leftovers of an earlier run (objects=$left files=$left_files); removing them and failing" >&2
    exit 1
fi

# The files the publications and the article name. The creation script replaces the
# generated CREATE TABLE at the subscriber; the pre- and post-snapshot scripts do nothing.
# The alternate snapshot folder does not exist on the lab: created here, removed by the
# cleanup once empty.
podman exec repllab bash -c "printf 'SELECT 1;\nGO\n' > $data/m_rv_pre.sql
printf 'SELECT 2;\nGO\n' > $data/m_rv_post.sql
printf 'CREATE TABLE dbo.m_rv_t1 (id int NOT NULL PRIMARY KEY, a int NULL, b int NULL);\nGO\n' > $data/m_rv_create.sql
mkdir -p $alt"

mark0=$(sql_value "SELECT CONVERT(varchar(23), SYSDATETIME(), 121)")

# Setup. sp_addsubscription refuses to run in a transaction (15002): this batch opens none.
# sp_addpushsubscription_agent is kept for the 2019 replay, as in 05-snapshot-flag.
sql <<'SQL'
SET NOCOUNT ON;
USE Sales;
CREATE TABLE dbo.m_rv_t1 (id int PRIMARY KEY, a int, b int);
INSERT dbo.m_rv_t1 VALUES (1, 1, 1), (2, 2, 2), (3, 3, 3), (4, 4, 4), (5, 5, 5), (6, 6, 6), (7, 7, 7), (8, 8, 8), (9, 9, 9), (10, 10, 10);
CREATE DATABASE m_rv_sub;
GO
USE Sales;
DECLARE @srv sysname = @@SERVERNAME, @p sysname, @imm nvarchar(5), @copy nvarchar(5), @n int = 1;
WHILE @n <= 2
BEGIN
    SET @p = CASE @n WHEN 1 THEN N'm_rv_i' ELSE N'm_rv_n' END;
    SET @imm = CASE @n WHEN 1 THEN N'true' ELSE N'false' END;
    SET @copy = @imm;
    EXEC sp_addpublication @publication = @p, @status = N'active', @allow_push = N'true',
         @independent_agent = @imm, @immediate_sync = @imm, @repl_freq = N'continuous', @sync_method = N'native',
         @replicate_ddl = 0, @allow_pull = N'true', @allow_initialize_from_backup = N'true',
         @allow_subscription_copy = @copy, @allow_partition_switch = N'true', @replicate_partition_switch = N'true',
         @alt_snapshot_folder = N'/var/opt/mssql/data/ReplAlt', @snapshot_in_defaultfolder = N'false';
    EXEC sp_addpublication_snapshot @publication = @p, @frequency_type = 1, @active_start_date = 99991231,
         @job_login = NULL, @job_password = NULL, @publisher_security_mode = 1;
    EXEC sp_changepublication @publication = @p, @property = N'allow_drop', @value = N'true';
    EXEC sp_addarticle @publication = @p, @article = N'm_rv_t1', @source_owner = N'dbo', @source_object = N'm_rv_t1',
         @status = 8, @fire_triggers_on_snapshot = N'true';
    EXEC sp_addsubscription @publication = @p, @subscriber = @srv, @destination_db = N'm_rv_sub',
         @subscription_type = N'Push', @sync_type = N'automatic', @article = N'all';
    EXEC sp_addpushsubscription_agent @publication = @p, @subscriber = @srv, @subscriber_db = N'm_rv_sub',
         @job_login = NULL, @job_password = NULL, @subscriber_security_mode = 1;
    SET @n += 1;
END;
EXEC sp_addpublication @publication = N'm_rv_p', @status = N'inactive', @allow_push = N'false', @allow_pull = N'true',
     @independent_agent = N'false', @immediate_sync = N'false', @repl_freq = N'continuous', @sync_method = N'native';
EXEC sp_addpublication_snapshot @publication = N'm_rv_p', @frequency_type = 1, @active_start_date = 99991231,
     @job_login = NULL, @job_password = NULL, @publisher_security_mode = 1;
GO
SQL

agent_pred() { # PUB
    case $1 in
        m_rv_i) echo "a.publication = N'm_rv_i'" ;;
        m_rv_n) echo "a.publication = N'ALL' AND a.subscriber_db = N'm_rv_sub'" ;;
    esac
}
# One snapshot at a time, generated and delivered.
for p in m_rv_i m_rv_n; do
    sql -Q "SET NOCOUNT ON; EXEC Sales.dbo.sp_startpublication_snapshot @publication = N'$p'" </dev/null
    wait_until 180 "SELECT CASE WHEN EXISTS (SELECT 1 FROM distribution.dbo.MSsnapshot_history h JOIN distribution.dbo.MSsnapshot_agents a ON a.id = h.agent_id WHERE a.publication = N'$p' AND h.time >= '$mark0' AND h.runstatus = 2)
        AND EXISTS (SELECT 1 FROM distribution.dbo.MSdistribution_history h JOIN distribution.dbo.MSdistribution_agents a ON a.id = h.agent_id WHERE $(agent_pred "$p") AND h.time >= '$mark0' AND h.comments LIKE N'Delivered snapshot%') THEN 1 ELSE 0 END" \
        || { echo "$p: snapshot not delivered" >&2; exit 1; }
    mark0=$(sql_value "SELECT CONVERT(varchar(23), SYSDATETIME(), 121)")
done

# The three scripts, set after the delivery: on Linux the distribution agent cannot run
# a pre- or post-snapshot script ("Failed to obtain the SQL Server utilities installation
# path from the registry", measured while this script was written: the agent retries and
# the snapshot is never delivered). Set with @force_invalidate_snapshot = 1, which the
# ready snapshot of m_rv_i asks for (02-matrix P33, P35, A18) and which leaves the
# subscriptions at status 2; m_rv_i's snapshot is then generated again, so that it is
# ready, and not delivered, the subscription being active.
sql <<'SQL'
SET NOCOUNT ON;
USE Sales;
DECLARE @p sysname, @n int = 1;
WHILE @n <= 2
BEGIN
    SET @p = CASE @n WHEN 1 THEN N'm_rv_i' ELSE N'm_rv_n' END;
    EXEC sp_changepublication @publication = @p, @property = N'pre_snapshot_script', @value = N'/var/opt/mssql/data/m_rv_pre.sql',
         @force_invalidate_snapshot = 1, @force_reinit_subscription = 0;
    EXEC sp_changepublication @publication = @p, @property = N'post_snapshot_script', @value = N'/var/opt/mssql/data/m_rv_post.sql',
         @force_invalidate_snapshot = 1, @force_reinit_subscription = 0;
    EXEC sp_changearticle @publication = @p, @article = N'm_rv_t1', @property = N'creation_script', @value = N'/var/opt/mssql/data/m_rv_create.sql',
         @force_invalidate_snapshot = 1, @force_reinit_subscription = 0;
    SET @n += 1;
END;
SQL
sql -Q "SET NOCOUNT ON; EXEC Sales.dbo.sp_startpublication_snapshot @publication = N'm_rv_i'" </dev/null
wait_until 180 "SELECT CASE WHEN EXISTS (SELECT 1 FROM distribution.dbo.MSsnapshot_history h JOIN distribution.dbo.MSsnapshot_agents a ON a.id = h.agent_id WHERE a.publication = N'm_rv_i' AND h.time >= '$mark0' AND h.runstatus = 2) THEN 1 ELSE 0 END" \
    || { echo "m_rv_i: snapshot not generated again" >&2; exit 1; }

# Measurement: one batch; rows built in table variables, which a rollback does not undo,
# and printed by one SELECT at the end.
out=$(sql -h -1 <<'SQL'
SET NOCOUNT ON;
USE Sales;
DECLARE @generic TABLE (ord int, cid nvarchar(60), prc char(1), prop sysname, val nvarchar(255) NULL, prep_prop sysname NULL, prep_val nvarchar(255) NULL);
INSERT @generic VALUES
 (1,  N'replicate_ddl', 'P', N'replicate_ddl', N'1', NULL, NULL),
 (2,  N'allow_pull', 'P', N'allow_pull', N'false', NULL, NULL),
 (3,  N'allow_initialize_from_backup', 'P', N'allow_initialize_from_backup', N'false', NULL, NULL),
 (4,  N'allow_subscription_copy', 'P', N'allow_subscription_copy', N'false', NULL, NULL),
 (5,  N'replicate_partition_switch', 'P', N'replicate_partition_switch', N'false', NULL, NULL),
 (6,  N'replicate_partition_switch_true', 'P', N'replicate_partition_switch', N'true', N'replicate_partition_switch', N'false'),
 (7,  N'allow_partition_switch', 'P', N'allow_partition_switch', N'false', N'replicate_partition_switch', N'false'),
 (8,  N'allow_drop', 'P', N'allow_drop', N'false', NULL, NULL),
 (9,  N'snapshot_in_defaultfolder', 'P', N'snapshot_in_defaultfolder', N'true', NULL, NULL),
 (10, N'alt_snapshot_folder.null', 'P', N'alt_snapshot_folder', NULL, NULL, NULL),
 (11, N'alt_snapshot_folder.empty', 'P', N'alt_snapshot_folder', N'', NULL, NULL),
 (12, N'pre_snapshot_script.null', 'P', N'pre_snapshot_script', NULL, NULL, NULL),
 (13, N'pre_snapshot_script.empty', 'P', N'pre_snapshot_script', N'', NULL, NULL),
 (14, N'post_snapshot_script.null', 'P', N'post_snapshot_script', NULL, NULL, NULL),
 (15, N'post_snapshot_script.empty', 'P', N'post_snapshot_script', N'', NULL, NULL),
 (16, N'fire_triggers_on_snapshot', 'A', N'fire_triggers_on_snapshot', N'false', NULL, NULL),
 (17, N'status.no_column_names', 'A', N'status', N'no column names', NULL, NULL),
 (18, N'status.parameters', 'A', N'status', N'parameters', NULL, NULL),
 (19, N'creation_script.null', 'A', N'creation_script', NULL, NULL, NULL),
 (20, N'creation_script.empty', 'A', N'creation_script', N'', NULL, NULL);
DECLARE @cases TABLE (id int IDENTITY, st char(1), pub sysname, cid nvarchar(60), prc char(1), prop sysname, val nvarchar(255) NULL, prep_prop sysname NULL, prep_val nvarchar(255) NULL);
INSERT @cases (st, pub, cid, prc, prop, val, prep_prop, prep_val)
SELECT s.st, s.pub, g.cid, g.prc, g.prop, g.val, g.prep_prop, g.prep_val
FROM (VALUES ('I', N'm_rv_i', 1), ('N', N'm_rv_n', 2)) s (st, pub, o)
CROSS JOIN @generic g
WHERE NOT (s.st = 'N' AND g.cid = N'allow_subscription_copy')
ORDER BY s.o, g.ord;
INSERT @cases (st, pub, cid, prc, prop, val, prep_prop, prep_val) VALUES
 ('P', N'm_rv_p', N'status', 'P', N'status', N'active', NULL, NULL),
 ('P', N'm_rv_p', N'allow_push', 'P', N'allow_push', N'true', NULL, NULL),
 ('P', N'm_rv_p', N'allow_push_false', 'P', N'allow_push', N'false', N'allow_push', N'true');

DECLARE @flags TABLE (k int, i bit, r bit, name char(3));
INSERT @flags VALUES (0, 0, 0, 'f00'), (1, 1, 0, 'f10'), (2, 0, 1, 'f01'), (3, 1, 1, 'f11');
DECLARE @state TABLE (id int, ready nvarchar(10), sub_status nvarchar(100));
DECLARE @res TABLE (id int, k int, cell varchar(12), step nvarchar(10), err int, msg nvarchar(400));

DECLARE @id int, @pub sysname, @prc char(1), @prop sysname, @val nvarchar(255), @pp sysname, @pv nvarchar(255),
        @k int, @i bit, @r bit, @rc int, @step nvarchar(10);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT id, pub, prc, prop, val, prep_prop, prep_val FROM @cases ORDER BY id;
OPEN c;
FETCH c INTO @id, @pub, @prc, @prop, @val, @pp, @pv;
WHILE @@FETCH_STATUS = 0
BEGIN
    INSERT @state
    SELECT @id, ISNULL((SELECT CONVERT(nvarchar(10), immediate_sync_ready) FROM dbo.syspublications WHERE name = @pub), N'nopub'),
           ISNULL((SELECT STRING_AGG(CONVERT(nvarchar(10), st), N'/') WITHIN GROUP (ORDER BY st)
                   FROM (SELECT DISTINCT s.status AS st FROM dbo.syssubscriptions s JOIN dbo.sysarticles a ON a.artid = s.artid
                         JOIN dbo.syspublications p ON p.pubid = a.pubid WHERE p.name = @pub AND s.srvid >= 0) x), N'none');
    SET @k = 0;
    WHILE @k < 4
    BEGIN
        SELECT @i = i, @r = r FROM @flags WHERE k = @k;
        SET @rc = 0;
        EXEC sp_set_session_context N'step', NULL;
        BEGIN TRY
            BEGIN TRAN;
            IF @pp IS NOT NULL
            BEGIN
                EXEC sp_set_session_context N'step', N'prep';
                EXEC @rc = sp_changepublication @publication = @pub, @property = @pp, @value = @pv,
                     @force_invalidate_snapshot = 0, @force_reinit_subscription = 0;
            END;
            IF @rc = 0
            BEGIN
                EXEC sp_set_session_context N'step', N'change';
                IF @prc = 'P'
                    EXEC @rc = sp_changepublication @publication = @pub, @property = @prop, @value = @val,
                         @force_invalidate_snapshot = @i, @force_reinit_subscription = @r;
                ELSE
                    EXEC @rc = sp_changearticle @publication = @pub, @article = N'm_rv_t1', @property = @prop, @value = @val,
                         @force_invalidate_snapshot = @i, @force_reinit_subscription = @r;
            END;
            IF @@TRANCOUNT > 0 ROLLBACK;
            IF @rc = 0
                INSERT @res VALUES (@id, @k, 'ok', NULL, NULL, NULL);
            ELSE
                INSERT @res VALUES (@id, @k, 'rc' + CONVERT(varchar(10), @rc), CONVERT(nvarchar(10), SESSION_CONTEXT(N'step')), NULL, N'returned ' + CONVERT(nvarchar(10), @rc) + N' without an error');
        END TRY
        BEGIN CATCH
            DECLARE @e int = ERROR_NUMBER(), @msg nvarchar(400) = LEFT(ERROR_MESSAGE(), 400);
            IF @@TRANCOUNT > 0 ROLLBACK;
            INSERT @res VALUES (@id, @k, CONVERT(varchar(12), @e), CONVERT(nvarchar(10), SESSION_CONTEXT(N'step')), @e, @msg);
        END CATCH;
        WHILE @@TRANCOUNT > 0 ROLLBACK;
        SET @k += 1;
    END;
    FETCH c INTO @id, @pub, @prc, @prop, @val, @pp, @pv;
END;
CLOSE c; DEALLOCATE c;
EXEC sp_set_session_context N'step', NULL;

SELECT CAST(N'R|RV.' + c.st + N'.' + c.cid + N'|'
       + (SELECT STRING_AGG(CONVERT(nvarchar(30), f.name + '=' + r.cell), N',') WITHIN GROUP (ORDER BY r.k)
          FROM @res r JOIN @flags f ON f.k = r.k WHERE r.id = c.id)
       + N'|' + CASE c.prc WHEN 'P' THEN N'sp_changepublication ' + c.pub ELSE N'sp_changearticle ' + c.pub + N'.m_rv_t1' END
       + N' ' + c.prop + N' = ' + ISNULL(N'''' + c.val + N'''', N'NULL')
       + ISNULL(N' after ' + c.prep_prop + N' = ''' + c.prep_val + N''' (flags 0)', N'')
       + ISNULL((SELECT STRING_AGG(CONVERT(nvarchar(4000), N'; ' + g.keys + N' at ' + ISNULL(g.step, N'?') + N' ' + ISNULL(CONVERT(nvarchar(10), g.err), N'')
                        + ISNULL(N': ' + REPLACE(REPLACE(REPLACE(g.msg, N'|', N'/'), CHAR(13), N' '), CHAR(10), N' '), N'')), N'')
                 FROM (SELECT r.step, r.err, CASE WHEN r.err IN (20607, 20608) AND r.step <> N'prep' THEN NULL ELSE r.msg END AS msg,
                              STRING_AGG(CONVERT(nvarchar(20), f.name), N',') WITHIN GROUP (ORDER BY r.k) AS keys
                       FROM @res r JOIN @flags f ON f.k = r.k
                       WHERE r.id = c.id AND r.cell <> 'ok' AND (r.step = N'prep' OR r.err IS NULL OR r.err NOT IN (20607, 20608))
                       GROUP BY r.step, r.err, CASE WHEN r.err IN (20607, 20608) AND r.step <> N'prep' THEN NULL ELSE r.msg END) g), N'')
       + N' (ready=' + s.ready + N' status=' + s.sub_status + N')' AS nvarchar(4000))
FROM @cases c JOIN @state s ON s.id = c.id
UNION ALL
SELECT CAST(N'R|RV.' + x.st + N'.state|ready='
       + ISNULL((SELECT CONVERT(nvarchar(10), immediate_sync_ready) FROM dbo.syspublications WHERE name = x.pub), N'nopub')
       + N' status=' + ISNULL((SELECT STRING_AGG(CONVERT(nvarchar(10), st), N'/') WITHIN GROUP (ORDER BY st)
                   FROM (SELECT DISTINCT s.status AS st FROM dbo.syssubscriptions s JOIN dbo.sysarticles a ON a.artid = s.artid
                         JOIN dbo.syspublications p ON p.pubid = a.pubid WHERE p.name = x.pub AND s.srvid >= 0) y), N'none')
       + N'|' AS nvarchar(4000))
FROM (VALUES ('I', N'm_rv_i'), ('N', N'm_rv_n'), ('P', N'm_rv_p')) x (st, pub);
SQL
)
# Anything else the batch printed (a Msg line above all) goes to the log, where
# campaign.sh reads it.
printf '%s\n' "$out" | grep -v '^R|' >&2 || true
rows=$(printf '%s\n' "$out" | grep '^R|' | sort -t'|' -k2,2 || true)
n=$(printf '%s\n' "$rows" | grep -c '^R|' || true)

# State controls: a row read in another state rejects the run.
bad=0
control() { echo "18-reverse: control failed: $*" >&2; bad=1; }
want() { case $1 in I) echo "ready=1 status=2" ;; N) echo "ready=0 status=2" ;; P) echo "ready=0 status=none" ;; esac; }
while IFS= read -r row; do
    [ -n "$row" ] || continue
    id=$(printf '%s' "$row" | cut -d'|' -f2)
    st=${id#RV.}; st=${st%%.*}
    w=$(want "$st")
    if [[ $id == *.state ]]; then
        [ "$(printf '%s' "$row" | cut -d'|' -f3)" = "$w" ] || control "$id: expected $w: $row"
    else
        [[ $(printf '%s' "$row" | cut -d'|' -f3) =~ ^f00=[^,]+,f10=[^,]+,f01=[^,]+,f11=[^,]+$ ]] || control "$id has not four cells: $row"
        [[ $row == *"($w)" ]] || control "$id read in another state, expected ($w): $row"
    fi
done <<<"$rows"
[ "$n" -gt 0 ] || control "no row"
[ "$bad" = 0 ] || exit 1
cleanup
printf '%s\n' "$rows"
echo "R|TOTAL|$n"
