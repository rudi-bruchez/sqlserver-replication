#!/bin/bash
# What the sources of the snapshot report return (campaign item 13 of the plan/apply
# design, section "Snapshot runs and their report"), under native, concurrent and
# database snapshot. Run through lab/campaign.sh.
#
# Objects. In Sales: m_t1 (1,000,000 rows with a 100-byte pad) and m_t2 (100 rows). The
# database m_w holds the logs of the timed writer and of the samplers. The login m_low has
# only public at the server and a user in distribution with SELECT on the database. Three
# publications without immediate_sync, each on m_t1 and m_t2, with a snapshot agent whose
# schedule never fires and a push subscription to a database of its own:
#   m_rs_native      native, shared distribution agent (independent_agent false)
#   m_rs_concurrent  concurrent, independent agent
#   m_rs_dbsnap      database snapshot, independent agent
# One measured run per publication: the first snapshot, started by the script, with a
# timed writer on m_t2 (one UPDATE of one row every 50 ms, its duration logged) and two
# samplers on the publisher, one every second and one every 250 ms, which read
# sys.dm_exec_requests (blocking_session_id) and sys.dm_os_waiting_tasks for the writer's
# session; the 250 ms sampler also records every session that logs in after the start.
# Right after the first start, once the job runs, sp_startpublication_snapshot is called a
# second time.
#
# Rows, per method (native, concurrent, dbsnap):
#   RS.<m>.snapshot_history      result per_article_lines=yes|no (a bulk copy line names an
#       article); detail: the articles named by bulk copy and schema lines, whether the run
#       has a start and an end line, the duration, and the distinct lines with digits
#       replaced by # and the publication by <pub>.
#   RS.<m>.distribution_history  result bulk_sums_match=yes|no (the "Bulk copied data into
#       table" lines, summed per destination table, equal the source row counts); detail:
#       the agent (shared or independent), lines per table (one or multi), whether the
#       "Delivered snapshot from the '...' sub-folder" line names the run's folder, the
#       duration, and the distinct lines normalized as above.
#   RS.<m>.filesystem_sa / filesystem_low   sys.dm_os_enumerate_filesystem on the run's
#       folder as sa / as m_low: ok or the error; files and bytes against find.
#   RS.<m>.program_names  every distinct program_name sampled among the sessions opened
#       after the start: agent_sessions, those of the publication's agents (the job names,
#       a name with the publication's, or one starting with "Snapshot Agent", when the name
#       mentions no other publication; "Snapshot Agent Smo Connection" mentions none and
#       may be the baseline agent's), and other_sessions, all the others unfiltered (the
#       script's own SQLCMD, the baseline agents); then those of the sessions that blocked
#       the writer. The snapshot job name is shown as <snapshot_job>, the distribution
#       job name as <distribution_job>, the job ids as <snapshot_job_id> and
#       <distribution_job_id>, other digits as #. A lower bound: the sampler runs every
#       250 ms, and a session that opens and closes between two samples is missed.
#   RS.<m>.sampling_1s / sampling_250ms  sees (the longest sampled lock wait is at least
#       80% of the writer's longest lock wait), under, misses (no sampled wait), or no_wait
#       (the writer never waited 250 ms on a lock); per source (req, wt) in the detail. The
#       writer measures its lock wait per UPDATE (lock_wait, the LCK_M_ delta of
#       sys.dm_exec_session_wait_stats) apart from the UPDATE's duration (measured), which
#       can be a log flush stall.
#   RS.<m>.start_running  the second sp_startpublication_snapshot: rc, @@ERROR, whether
#       TRY...CATCH caught it, and its messages (job name as <snapshot_job>).
# And once: RS.m_low.waiting_tasks, RS.m_low.exec_requests, RS.m_low.snapshot_history,
# what m_low gets on each. Durations are a bucket followed by the raw value,
# ms<30000(2101); more raw values go to the file SNAP_RAW names, when set.
#
# Asserted (exit 1, rows on stderr), from what the spec states as measured: the second
# start returns 1 with @@ERROR 0 and nothing caught, while the job runs; m_low gets error
# 300 on sys.dm_os_waiting_tasks; m_low can list the run folder and finds what find finds;
# the bulk copy lines of the distribution history sum to the row counts. Nothing is
# asserted on the program_name of the lock holder.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"
mark=$(sql_value "SELECT CONVERT(varchar(23), SYSDATETIME(), 121)")
raw=${SNAP_RAW:-/dev/null}
tmp=$(mktemp -d)
srv=$(sql_value "SELECT @@SERVERNAME")
unc=/var/opt/mssql/data/ReplData/unc
methods="native concurrent dbsnap"

rows=()
r() { rows+=("R|$1|$2|$3"); }
rawlog() { printf '%s\n' "$*" >>"$raw"; }
sq() {
    local out
    out=$(sql -d Sales -b -h -1 -Q "SET NOCOUNT ON; $1" </dev/null 2>&1) || {
        printf '16-snapshot-report-sources: query failed: %s\n%s\n' "${1:0:300}" "$out" >&2; return 1; }
    printf '%s\n' "$out" | sed -e 's/[[:space:]]*$//' | grep -v '^$' | tail -n 1
}
# lines QUERY: every output line of QUERY (one column), trimmed.
lines() {
    local out
    out=$(sql -d Sales -b -h -1 -Q "SET NOCOUNT ON; $1" </dev/null 2>&1) || {
        printf '16-snapshot-report-sources: query failed: %s\n%s\n' "${1:0:300}" "$out" >&2; return 1; }
    printf '%s\n' "$out" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' || true
}
sx() { sql -d Sales -b -Q "SET NOCOUNT ON; $1" </dev/null >&2; }
now() { sql_value "SELECT CONVERT(varchar(23), SYSDATETIME(), 121)"; }
bucket() {
    local v=$1
    if ! [[ $v =~ ^[0-9]+$ ]]; then echo none
    elif (( v < 1000 )); then echo 'ms<1000'
    elif (( v < 30000 )); then echo 'ms<30000'
    else echo 'ms>=30000'; fi
}
# bk MS: the bucket followed by the raw value, ms<30000(2101).
bk() { if [[ $1 =~ ^-?[0-9]+$ ]]; then echo "$(bucket "$1")($1)"; else echo none; fi; }
# norm PUB: digits to #, the publication name to <pub> (any case), | to /.
norm() { sed -E -e "s/$1/<pub>/Ig" -e 's/0x[0-9A-Fa-f]+/0x#/g' -e 's/[0-9]+/#/g' -e 's/\|/\//g'; }
pubdir() { echo "$unc/${srv^^}_SALES_${1^^}"; }
folders() { podman exec repllab find "$(pubdir "$1")" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort || true; }

bg=()
cleaned=0
cleanup() {
    [ "$cleaned" = 1 ] && return
    cleaned=1
    sql -Q "SET NOCOUNT ON; IF DB_ID(N'm_w') IS NOT NULL UPDATE m_w.dbo.ctl SET stop = 1" </dev/null >&2 2>&1 || true
    local p; for p in "${bg[@]}"; do wait "$p" 2>/dev/null || true; done
    stop_m_agents
    purge_stopped_orphans "$mark"
    sql -d Sales -Q "SET NOCOUNT ON;
DECLARE @p sysname;
DECLARE c CURSOR LOCAL FOR SELECT name FROM dbo.syspublications WHERE name LIKE N'm\_rs\_%' ESCAPE N'\';
OPEN c; FETCH NEXT FROM c INTO @p;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY EXEC sp_dropsubscription @publication = @p, @article = N'all', @subscriber = N'all'; END TRY BEGIN CATCH END CATCH;
    WHILE @@TRANCOUNT > 0 ROLLBACK;
    BEGIN TRY EXEC sp_droppublication @publication = @p; END TRY BEGIN CATCH END CATCH;
    WHILE @@TRANCOUNT > 0 ROLLBACK;
    FETCH NEXT FROM c INTO @p;
END;
CLOSE c; DEALLOCATE c;
DROP TABLE IF EXISTS dbo.m_t1, dbo.m_t2;" </dev/null >&2 || true
    sql -Q "SET NOCOUNT ON;
IF EXISTS (SELECT 1 FROM distribution.sys.database_principals WHERE name = N'm_low') EXEC (N'USE distribution; DROP USER m_low;');
IF SUSER_ID(N'm_low') IS NOT NULL DROP LOGIN m_low;
DECLARE @d sysname, @s nvarchar(400);
DECLARE c CURSOR LOCAL FOR SELECT name FROM sys.databases WHERE name IN (N'm_w', N'm_r_native', N'm_r_concurrent', N'm_r_dbsnap');
OPEN c; FETCH NEXT FROM c INTO @d;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @s = N'ALTER DATABASE ' + QUOTENAME(@d) + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE ' + QUOTENAME(@d) + N';';
    BEGIN TRY EXEC (@s); END TRY BEGIN CATCH PRINT ERROR_MESSAGE(); END CATCH;
    FETCH NEXT FROM c INTO @d;
END;
CLOSE c; DEALLOCATE c;" </dev/null >&2 || true
    podman exec repllab find "$unc" -mindepth 1 -maxdepth 1 -iname '*_m_rs_*' -exec rm -rf {} + >&2 || true
    rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 1' TERM INT

left=$(sql_value "SELECT (SELECT COUNT(*) FROM Sales.dbo.syspublications WHERE name LIKE N'm\_%' ESCAPE N'\') + (SELECT COUNT(*) FROM sys.databases WHERE name LIKE N'm\_%' ESCAPE N'\') + (SELECT COUNT(*) FROM Sales.sys.objects WHERE name LIKE N'm\_%' ESCAPE N'\') + (SELECT COUNT(*) FROM sys.server_principals WHERE name LIKE N'm\_%' ESCAPE N'\')")
left_files=$(podman exec repllab find "$unc" -mindepth 1 -maxdepth 1 -iname '*_m_*')
if [ "$left" != 0 ] || [ -n "$left_files" ]; then
    echo "16-snapshot-report-sources: leftovers of an earlier run (objects=$left files=$left_files); failing (remove them first: 15's teardown, or lab/start.sh)" >&2
    exit 1
fi
rawlog "=== 16-snapshot-report-sources $(date -u +%FT%TZ)"
start_s=$SECONDS

sql -b <<'SQL' >&2
SET NOCOUNT ON;
USE Sales;
CREATE TABLE dbo.m_t1 (id int PRIMARY KEY, a int, b int, pad char(100) NOT NULL DEFAULT 'x');
INSERT dbo.m_t1 (id, a, b) SELECT TOP (1000000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), 1, 1 FROM sys.all_columns x CROSS JOIN sys.all_columns y;
CREATE TABLE dbo.m_t2 (id int PRIMARY KEY, a int, b int);
INSERT dbo.m_t2 SELECT TOP (100) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), 1, 1 FROM sys.all_columns;
CREATE DATABASE m_w;
GO
USE m_w;
CREATE TABLE dbo.wlog (run varchar(60), tbl sysname, spid int, t0 datetime2(3), t1 datetime2(3), ms int, err int NULL, lock_ms bigint NULL);
CREATE TABLE dbo.ctl (run varchar(60) PRIMARY KEY, stop bit);
CREATE TABLE dbo.samp (run varchar(60), ival int, ts datetime2(3), src varchar(5), wait_ms bigint, blocker int, wait_type nvarchar(60));
CREATE TABLE dbo.sess (run varchar(60), session_id int, program_name nvarchar(256), login_time datetime);
CREATE TABLE dbo.blk (run varchar(60), session_id int, program_name nvarchar(256));
GO
-- m_low: public at the server, SELECT in distribution. Its password is never printed.
DECLARE @pw nvarchar(100) = CONVERT(nvarchar(36), NEWID()) + N'Aa1!';
EXEC (N'CREATE LOGIN m_low WITH PASSWORD = ''' + @pw + N''', CHECK_POLICY = OFF;');
GO
USE distribution;
CREATE USER m_low FOR LOGIN m_low;
GRANT SELECT TO m_low;
GO
SQL

for m in $methods; do
    p=m_rs_$m; db=m_r_$m
    sync=$m; [ "$m" = dbsnap ] && sync='database snapshot'
    ind=true; [ "$m" = native ] && ind=false
    sql -b -Q "SET NOCOUNT ON; CREATE DATABASE [$db];" </dev/null >&2
    sx "EXEC sp_addpublication @publication = N'$p', @status = N'active', @allow_push = N'true',
     @independent_agent = N'$ind', @immediate_sync = N'false', @repl_freq = N'continuous', @sync_method = N'$sync';
EXEC sp_addpublication_snapshot @publication = N'$p', @frequency_type = 1, @active_start_date = 99991231,
     @job_login = NULL, @job_password = NULL, @publisher_security_mode = 1;
EXEC sp_addarticle @publication = N'$p', @article = N'm_t1', @source_owner = N'dbo', @source_object = N'm_t1';
EXEC sp_addarticle @publication = N'$p', @article = N'm_t2', @source_owner = N'dbo', @source_object = N'm_t2';
EXEC sp_addsubscription @publication = N'$p', @subscriber = N'$srv', @destination_db = N'$db',
     @subscription_type = N'Push', @sync_type = N'automatic', @article = N'all';
EXEC sp_addpushsubscription_agent @publication = N'$p', @subscriber = N'$srv', @subscriber_db = N'$db',
     @job_login = NULL, @job_password = NULL, @subscriber_security_mode = 1;"
done

# m_low, once.
low() { # QUERY setting @r, run as m_low from master: its value, or the error number and message.
    local out
    out=$(sql -d master -b -h -1 -Q "SET NOCOUNT ON; DECLARE @r nvarchar(4000);
EXECUTE AS LOGIN = N'm_low';
BEGIN TRY $1 END TRY
BEGIN CATCH SET @r = CONCAT(N'error', ERROR_NUMBER(), N' ', REPLACE(LEFT(ERROR_MESSAGE(), 200), N'|', N'/')); END CATCH;
REVERT;
SELECT @r" </dev/null 2>&1) || { printf '16-snapshot-report-sources: m_low query failed: %s\n' "$out" >&2; return 1; }
    printf '%s\n' "$out" | sed -e 's/[[:space:]]*$//' | grep -v '^$' | tail -n 1
}
res=$(low "SELECT @r = CONCAT(N'ok rows=', CASE WHEN COUNT(*) > 0 THEN N'some' ELSE N'none' END) FROM sys.dm_os_waiting_tasks;")
r RS.m_low.waiting_tasks "${res%% *}" "${res#* }"
res=$(low "SELECT @r = CONCAT(N'ok own_session_only=', CASE WHEN COUNT(*) = SUM(CASE WHEN session_id = @@SPID THEN 1 ELSE 0 END) THEN N'yes' ELSE N'no' END) FROM sys.dm_exec_requests;")
r RS.m_low.exec_requests "${res%% *}" "${res#* }"
res=$(low "SELECT @r = CONCAT(N'ok rows=', CASE WHEN COUNT(*) > 0 THEN N'some' ELSE N'none' END) FROM distribution.dbo.MSsnapshot_history;")
r RS.m_low.snapshot_history "${res%% *}" "${res#* }"

for m in $methods; do
    p=m_rs_$m; db=m_r_$m; run=RS.$m
    sjob=$(sq "SELECT CONVERT(nvarchar(4000), name) FROM distribution.dbo.MSsnapshot_agents WHERE publication = N'$p' AND publisher_db = N'Sales'")
    sjid=$(sq "SELECT CONVERT(varchar(40), CONVERT(binary(16), CONVERT(uniqueidentifier, job_id)), 1) FROM distribution.dbo.MSsnapshot_agents WHERE publication = N'$p' AND publisher_db = N'Sales'")
    djob=$(sq "SELECT CONVERT(nvarchar(4000), name) FROM distribution.dbo.MSdistribution_agents WHERE subscriber_db = N'$db' AND subscriber_id >= 0")
    djid=$(sq "SELECT CONVERT(varchar(40), CONVERT(binary(16), CONVERT(uniqueidentifier, job_id)), 1) FROM distribution.dbo.MSdistribution_agents WHERE subscriber_db = N'$db' AND subscriber_id >= 0")
    shared=$(sq "SELECT CASE WHEN publication = N'ALL' THEN 'shared' ELSE 'independent' END FROM distribution.dbo.MSdistribution_agents WHERE subscriber_db = N'$db' AND subscriber_id >= 0")
    before=$(folders "$p")
    smark=$(now)

    # The writer, then the two samplers.
    sql -b -Q "SET NOCOUNT ON; INSERT m_w.dbo.ctl VALUES ('$run', 0)" </dev/null >&2
    sql -b -h -1 -Q "SET NOCOUNT ON; SET LOCK_TIMEOUT 120000;
DECLARE @t0 datetime2(3), @e int, @l0 bigint, @l1 bigint, @end datetime2 = DATEADD(second, 600, SYSDATETIME());
WHILE NOT EXISTS (SELECT 1 FROM m_w.dbo.ctl WHERE run = '$run' AND stop = 1) AND SYSDATETIME() < @end
BEGIN
    -- lock_ms: the session's LCK_M_ wait time during the UPDATE, so that a log flush stall
    -- is not taken for a lock wait.
    SELECT @l0 = ISNULL(SUM(wait_time_ms), 0) FROM sys.dm_exec_session_wait_stats WHERE session_id = @@SPID AND wait_type LIKE N'LCK[_]M[_]%';
    SET @t0 = SYSDATETIME(); SET @e = NULL;
    BEGIN TRY UPDATE Sales.dbo.m_t2 SET a = a + 1 WHERE id = 1; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH;
    SELECT @l1 = ISNULL(SUM(wait_time_ms), 0) FROM sys.dm_exec_session_wait_stats WHERE session_id = @@SPID AND wait_type LIKE N'LCK[_]M[_]%';
    INSERT m_w.dbo.wlog VALUES ('$run', N'm_t2', @@SPID, @t0, SYSDATETIME(), DATEDIFF(millisecond, @t0, SYSDATETIME()), @e, @l1 - @l0);
    WAITFOR DELAY '00:00:00.050';
END" </dev/null >"$tmp/w.$m" 2>&1 &
    bg+=($!)
    for ival in 1000 250; do
        delay='00:00:01.000'; [ "$ival" = 250 ] && delay='00:00:00.250'
        sess=""
        [ "$ival" = 250 ] && sess="INSERT m_w.dbo.sess (run, session_id, program_name, login_time)
    SELECT '$run', s.session_id, s.program_name, s.login_time FROM sys.dm_exec_sessions s
    WHERE s.is_user_process = 1 AND s.login_time >= '$smark' AND s.session_id <> @@SPID
      AND NOT EXISTS (SELECT 1 FROM m_w.dbo.sess x WHERE x.run = '$run' AND x.session_id = s.session_id AND x.login_time = s.login_time AND x.program_name = s.program_name);
    INSERT m_w.dbo.blk (run, session_id, program_name)
    SELECT DISTINCT '$run', s.session_id, s.program_name FROM sys.dm_exec_requests r JOIN sys.dm_exec_sessions s ON s.session_id = r.blocking_session_id
    WHERE r.session_id = @spid AND r.blocking_session_id > 0;"
        sql -b -h -1 -Q "SET NOCOUNT ON;
DECLARE @spid int = NULL, @end datetime2 = DATEADD(second, 600, SYSDATETIME());
WHILE @spid IS NULL AND SYSDATETIME() < @end
BEGIN
    SELECT TOP 1 @spid = spid FROM m_w.dbo.wlog WHERE run = '$run';
    IF @spid IS NULL WAITFOR DELAY '00:00:00.050';
END;
WHILE NOT EXISTS (SELECT 1 FROM m_w.dbo.ctl WHERE run = '$run' AND stop = 1) AND SYSDATETIME() < @end
BEGIN
    INSERT m_w.dbo.samp (run, ival, ts, src, wait_ms, blocker, wait_type)
    SELECT '$run', $ival, SYSDATETIME(), 'req', r.wait_time, r.blocking_session_id, r.wait_type FROM sys.dm_exec_requests r
    WHERE r.session_id = @spid AND r.blocking_session_id > 0
    UNION ALL
    SELECT '$run', $ival, SYSDATETIME(), 'wt', w.wait_duration_ms, w.blocking_session_id, w.wait_type FROM sys.dm_os_waiting_tasks w
    WHERE w.session_id = @spid AND w.blocking_session_id IS NOT NULL AND w.wait_type LIKE N'LCK%'
    UNION ALL
    SELECT '$run', $ival, SYSDATETIME(), 'other', r.wait_time, r.blocking_session_id, r.wait_type FROM sys.dm_exec_requests r
    WHERE r.session_id = @spid AND r.blocking_session_id = 0 AND r.wait_type IS NOT NULL AND r.wait_type <> N'WAITFOR';
    $sess
    WAITFOR DELAY '$delay';
END" </dev/null >"$tmp/s.$m.$ival" 2>&1 &
        bg+=($!)
    done
    sleep 2

    # The start, then a second start while the job runs. Its output is kept out of the
    # log: its Msg lines are the measurement, and the uncaught guard would read them.
    out=$(sql -d Sales -h -1 -Q "SET NOCOUNT ON;
DECLARE @rc1 int = -99, @e1 int = -99, @rc2 int = -99, @e2 int = -99, @c2 int = NULL, @running int = 0, @i int = 0;
DECLARE @job uniqueidentifier = (SELECT CONVERT(uniqueidentifier, job_id) FROM distribution.dbo.MSsnapshot_agents WHERE publication = N'$p' AND publisher_db = N'Sales');
EXEC @rc1 = sp_startpublication_snapshot @publication = N'$p'; SET @e1 = @@ERROR;
WHILE @i < 200 AND @running = 0
BEGIN
    SELECT @running = COUNT(*) FROM msdb.dbo.sysjobactivity ja WHERE ja.job_id = @job AND ja.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions)
      AND ja.start_execution_date IS NOT NULL AND ja.stop_execution_date IS NULL;
    IF @running = 0 WAITFOR DELAY '00:00:00.050';
    SET @i += 1;
END;
PRINT 'm_second_call';
BEGIN TRY EXEC @rc2 = sp_startpublication_snapshot @publication = N'$p'; SET @e2 = @@ERROR; END TRY BEGIN CATCH SET @c2 = ERROR_NUMBER(); END CATCH;
PRINT 'm_second_call_end';
SELECT CONCAT('RES rc1=', @rc1, ' err1=', @e1, ' running=', @running, ' rc2=', @rc2, ' err2=', @e2, ' caught2=', ISNULL(CONVERT(varchar(10), @c2), 'none'));" </dev/null 2>&1 || true)
    resline=$(printf '%s\n' "$out" | grep '^RES ' | tail -n 1 || true)
    [ -n "$resline" ] || { echo "16-snapshot-report-sources: $p: no result from the starts" >&2; exit 1; }
    msgs=$(printf '%s\n' "$out" | sed -n '/^m_second_call$/,/^m_second_call_end$/p' | grep -v -e '^m_second_call' -e '^$' \
        | sed -E -e "s/$sjob/<snapshot_job>/g" -e 's/, Server [^,]*,/,/' -e 's/^(Msg [0-9]+, Level [0-9]+), State [0-9]+.*/\1/' -e 's/\|/\//g' | paste -sd '~' - || true)

    wait_until 300 "SELECT CASE WHEN EXISTS (SELECT 1 FROM distribution.dbo.MSsnapshot_history h JOIN distribution.dbo.MSsnapshot_agents a ON a.id = h.agent_id WHERE a.publication = N'$p' AND a.publisher_db = N'Sales' AND h.time >= '$smark' AND h.runstatus IN (2, 6)) THEN 1 ELSE 0 END" \
        || { echo "16-snapshot-report-sources: $p: the run did not end" >&2; exit 1; }
    wait_until 180 "SELECT CASE WHEN EXISTS (SELECT 1 FROM distribution.dbo.MSdistribution_history h JOIN distribution.dbo.MSdistribution_agents a ON a.id = h.agent_id WHERE a.subscriber_db = N'$db' AND a.subscriber_id >= 0 AND h.time >= '$smark' AND h.comments LIKE N'Delivered snapshot%') THEN 1 ELSE 0 END" \
        || { echo "16-snapshot-report-sources: $p: the snapshot was not delivered" >&2; exit 1; }
    sql -b -Q "SET NOCOUNT ON; UPDATE m_w.dbo.ctl SET stop = 1 WHERE run = '$run'" </dev/null >&2
    for pid in "${bg[@]}"; do wait "$pid" || { cat "$tmp"/w."$m" "$tmp"/s."$m".* >&2; echo "16-snapshot-report-sources: a writer or sampler of $p failed" >&2; exit 1; }; done
    bg=()
    if grep -q -E '^Msg |^Sqlcmd:' "$tmp"/w."$m" "$tmp"/s."$m".*; then
        cat "$tmp"/w."$m" "$tmp"/s."$m".* >&2; exit 1
    fi
    after=$(folders "$p")
    runf=$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | grep -v '^$' || true)
    nf=$(printf '%s\n' "$runf" | grep -c . || true)
    [ "$nf" = 1 ] || { echo "16-snapshot-report-sources: $p: $nf new run folders" >&2; exit 1; }

    # Snapshot history.
    sh_where="FROM distribution.dbo.MSsnapshot_history h JOIN distribution.dbo.MSsnapshot_agents a ON a.id = h.agent_id WHERE a.publication = N'$p' AND a.publisher_db = N'Sales' AND h.time >= '$smark'"
    shl=$(lines "SELECT CONVERT(nvarchar(4000), h.comments) $sh_where ORDER BY h.timestamp")
    pats=$(printf '%s\n' "$shl" | norm "$p" | sort -u | paste -sd '~' -)
    sinfo=$(sq "SELECT CONCAT(
  N'start=', CASE WHEN EXISTS (SELECT 1 $sh_where AND h.runstatus = 1) THEN N'yes' ELSE N'no' END,
  N' end=', CASE WHEN EXISTS (SELECT 1 $sh_where AND h.runstatus = 2) THEN N'yes' ELSE N'no' END,
  N' ', ISNULL(CONVERT(varchar(12), DATEDIFF(millisecond, (SELECT MIN(h.time) $sh_where), (SELECT MAX(h.time) $sh_where AND h.runstatus IN (2, 6)))), 'none'),
  N' bcp=[', ISNULL((SELECT STRING_AGG(t, N',') WITHIN GROUP (ORDER BY t) FROM (VALUES (N'm_t1'), (N'm_t2')) v(t) WHERE EXISTS (SELECT 1 $sh_where AND h.comments LIKE N'%Bulk copied snapshot data for article ''' + t + N'[ '']%')), N''),
  N'] schema=[', ISNULL((SELECT STRING_AGG(t, N',') WITHIN GROUP (ORDER BY t) FROM (VALUES (N'm_t1'), (N'm_t2')) v(t) WHERE EXISTS (SELECT 1 $sh_where AND h.comments LIKE N'%Generating schema scripts for article ''' + t + N'''%')), N''), N']')")
    read -r s_start s_end s_ms s_bcp s_sch <<<"$sinfo"
    rawlog "$run snapshot_history lines=$(printf '%s\n' "$shl" | grep -c .) gen_ms=$s_ms"
    per=no; [ "$s_bcp" != "bcp=[]" ] && per=yes
    r "$run.snapshot_history" "per_article_lines=$per" "$s_bcp $s_sch $s_start $s_end gen=$(bk "$s_ms") lines=[$pats]"

    # Distribution history.
    dh_where="FROM distribution.dbo.MSdistribution_history h JOIN distribution.dbo.MSdistribution_agents a ON a.id = h.agent_id WHERE a.subscriber_db = N'$db' AND a.subscriber_id >= 0 AND h.time >= '$smark'"
    dhl=$(lines "SELECT CONVERT(nvarchar(4000), h.comments) $dh_where ORDER BY h.timestamp")
    dpats=$(printf '%s\n' "$dhl" | norm "$p" | sort -u | paste -sd '~' -)
    sums=""; match=yes
    for t in m_t1 m_t2; do
        want=$(sq "SELECT COUNT(*) FROM dbo.$t")
        got=$(printf '%s\n' "$dhl" | sed -n -E "s/^Bulk copied data into table '$t' \(([0-9]+) rows\).*/\1/p" | awk '{ s += $1; n++ } END { print s + 0, n + 0 }')
        read -r gsum gn <<<"$got"
        [ "$gsum" = "$want" ] || match=no
        nl=none; (( gn == 1 )) && nl=one; (( gn > 1 )) && nl=multi
        sums+=" lines($t)=$nl"
        rawlog "$run distribution $t rows=$gsum/$want lines=$gn"
    done
    folder=${runf##*/}
    dline=$(printf '%s\n' "$dhl" | grep '^Delivered snapshot' | tail -n 1 || true)
    names=no; [[ $dline == *"$folder"* ]] && names=yes
    dms=$(sq "SELECT ISNULL(CONVERT(varchar(12), DATEDIFF(millisecond, (SELECT MIN(h.time) $dh_where AND h.comments NOT LIKE N'Distribution agent for subscription added%' AND h.runstatus <> 4), (SELECT MAX(h.time) $dh_where AND h.comments LIKE N'Delivered snapshot%'))), 'none')")
    r "$run.distribution_history" "bulk_sums_match=$match" "agent=$shared$sums delivered_line_names_run_folder=$names delivery=$(bk "$dms") lines=[$dpats]"
    rawlog "$run delivery_ms=$dms"

    # The run's folder, as sa and as m_low, against find.
    fcount=$(podman exec repllab find "$runf" -maxdepth 1 -type f | grep -c . || true)
    fbytes=$(podman exec repllab find "$runf" -maxdepth 1 -type f -printf '%s\n' | awk '{ s += $1 } END { print s + 0 }')
    enum="SELECT @r = CONCAT(N'ok ', COUNT(*), N' ', ISNULL(SUM(size_in_bytes), 0)) FROM sys.dm_os_enumerate_filesystem(N'$runf', N'*') WHERE is_directory = 0;"
    for who in sa low; do
        if [ "$who" = sa ]; then
            res=$(sq "DECLARE @r nvarchar(4000); BEGIN TRY $enum END TRY BEGIN CATCH SET @r = CONCAT(N'error', ERROR_NUMBER(), N' ', LEFT(ERROR_MESSAGE(), 200)); END CATCH; SELECT @r")
        else
            res=$(low "$enum")
        fi
        rawlog "$run filesystem_$who $res find=$fcount $fbytes"
        if [[ $res == ok\ * ]]; then
            read -r _ c b <<<"$res"
            fm=no; [ "$c" = "$fcount" ] && fm=yes
            bm=no; [ "$b" = "$fbytes" ] && bm=yes
            r "$run.filesystem_$who" ok "files_match_find=$fm bytes_match_find=$bm"
        else
            r "$run.filesystem_$who" "${res%% *}" "$(printf '%s' "${res#* }" | tr '|' '/')"
        fi
    done

    # program_name of the sessions opened after the start that belong to the agents.
    progs=$(lines "SELECT DISTINCT CONVERT(nvarchar(4000), program_name) FROM m_w.dbo.sess WHERE run = '$run'")
    rawlog "$run sessions: $(printf '%s\n' "$progs" | paste -sd '~' -)"
    relabel() { sed -e "s/$sjid/<snapshot_job_id>/Ig" -e "s/$djid/<distribution_job_id>/Ig" -e "s/$sjob/<snapshot_job>/g" -e "s/$djob/<distribution_job>/g"; }
    # After norm, the publication's own name is <pub>: a name that mentions another one
    # (the baseline SalesPub's agent also says "Snapshot Agent ...") is not this agent's.
    allp=$(printf '%s\n' "$progs" | relabel | norm "$p" | sort -u)
    mine=$(printf '%s\n' "$allp" | grep -v -E 'Sales:[A-Za-z]|publication [A-Za-z]' | grep -e '<snapshot_job' -e '<distribution_job' -e '<pub>' -e '^Snapshot Agent' | paste -sd '~' - || true)
    others=$(comm -23 <(printf '%s\n' "$allp" | grep -v '^$') <(printf '%s\n' "$mine" | tr '~' '\n' | grep -v '^$') | paste -sd '~' - || true)
    blockers=$(lines "SELECT DISTINCT CONVERT(nvarchar(4000), program_name) FROM m_w.dbo.blk WHERE run = '$run'" | relabel | norm "$p" | sort -u | paste -sd '~' - || true)
    r "$run.program_names" "recorded" "agent_sessions=[$mine] other_sessions=[$others] writer_blocked_by=[$blockers] sampled_every=250ms"

    # Sampling against the writer.
    wmax=$(sq "SELECT ISNULL(MAX(ms), 0) FROM m_w.dbo.wlog WHERE run = '$run'")
    wlock=$(sq "SELECT ISNULL(MAX(lock_ms), 0) FROM m_w.dbo.wlog WHERE run = '$run'")
    rawlog "$run writer: $(sq "SELECT CONCAT(COUNT(*), N' updates, ', SUM(CASE WHEN ms >= 100 THEN 1 ELSE 0 END), N' of 100 ms or more, longest ', MAX(ms)) FROM m_w.dbo.wlog WHERE run = '$run'") other waits sampled: $(sq "SELECT ISNULL(STRING_AGG(CONVERT(nvarchar(4000), CONCAT(ival, N'ms:', wait_type, N'=', mx)), N', '), N'none') FROM (SELECT ival, wait_type, MAX(wait_ms) AS mx FROM m_w.dbo.samp WHERE run = '$run' AND src = 'other' GROUP BY ival, wait_type) x")"
    werr=$(sq "SELECT COUNT(*) FROM m_w.dbo.wlog WHERE run = '$run' AND err IS NOT NULL")
    for ival in 1000 250; do
        name=sampling_1s; [ "$ival" = 250 ] && name=sampling_250ms
        detail="measured=$(bk "$wmax") lock_wait=$(bk "$wlock")"; [ "$werr" != 0 ] && detail+="(errors)"
        best=0; verdicts=""
        for src in req wt; do
            smax=$(sq "SELECT ISNULL(MAX(wait_ms), -1) FROM m_w.dbo.samp WHERE run = '$run' AND ival = $ival AND src = '$src'")
            rawlog "$run $name $src sampled_max=$smax measured_max=$wmax lock_max=$wlock"
            if (( smax < 0 )); then v=misses
            elif (( smax * 10 >= wlock * 8 )); then v=sees
            else v=under; fi
            (( smax > best )) && best=$smax
            detail+=" $src=$v"
            detail+="($(bk "$( (( smax < 0 )) && echo none || echo "$smax")"))"
        done
        if (( wlock < 250 )); then res=no_wait
        elif (( best <= 0 )); then res=misses
        elif (( best * 10 >= wlock * 8 )); then res=sees
        else res=under; fi
        r "$run.$name" "$res" "$detail"
    done

    # The second start.
    read -r _ rc1 e1 running rc2 e2 c2 <<<"$resline"
    r "$run.start_running" "${rc2}" "${e2} caught2=${c2#caught2=} ${running} first:${rc1},${e1} messages=[$msgs]"
    rawlog "$run done after $(( SECONDS - start_s )) s"
done

# Controls.
# Failures are said after the rows, so that the last lines of the log, which campaign.sh
# quotes, give the reason.
bad=0; fails=()
control() { fails+=("16-snapshot-report-sources: control failed: $*"); bad=1; }
field() { printf '%s\n' "${rows[@]}" | awk -F'|' -v id="$1" -v n="$2" '$2 == id { print $n }'; }
[ "$(field RS.m_low.waiting_tasks 3)" = error300 ] || control "RS.m_low.waiting_tasks: $(field RS.m_low.waiting_tasks 3), expected error300"
for m in $methods; do
    [ "$(field "RS.$m.start_running" 3)" = rc2=1 ] || control "RS.$m.start_running returned $(field "RS.$m.start_running" 3), expected rc2=1"
    [[ $(field "RS.$m.start_running" 4) == "err2=0 caught2=none running=1 "* ]] || control "RS.$m.start_running: $(field "RS.$m.start_running" 4)"
    [ "$(field "RS.$m.filesystem_low" 3)|$(field "RS.$m.filesystem_low" 4)" = "ok|files_match_find=yes bytes_match_find=yes" ] \
        || control "RS.$m.filesystem_low: $(field "RS.$m.filesystem_low" 3) $(field "RS.$m.filesystem_low" 4)"
    [ "$(field "RS.$m.distribution_history" 3)" = bulk_sums_match=yes ] || control "RS.$m.distribution_history: $(field "RS.$m.distribution_history" 3)"
done
rawlog "total $(( SECONDS - start_s )) s"
if [ "$bad" != 0 ]; then
    for row in "${rows[@]}"; do echo "row: $row" >&2; done
    for f in "${fails[@]}"; do echo "$f" >&2; done
    exit 1
fi
cleanup
for row in "${rows[@]}"; do printf '%s\n' "$row"; done
echo "R|TOTAL|${#rows[@]}"
