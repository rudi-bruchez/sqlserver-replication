#!/bin/bash
# Transient errors during drops, and whether a retry of the failed statement succeeds
# (campaign item 10; spec, end of section "apply": 1205 and 18752 met by the panel). Run
# through lab/campaign.sh.
#
# Ten cycles. Each creates the publication m_tr<n> (immediate_sync = 0, concurrent sync,
# snapshot agent that never fires) with the one article m_tt, a push subscription to the
# database m_sub (created for the cycle), starts the snapshot and waits until the
# distribution agent has delivered it and a row inserted afterwards (which proves the log
# reader and the agent run); then inserts two more rows and, while the log reader of the
# publication database runs (checked, never stopped), drops the subscription with
# @article = N'all' and the publication with sp_droppublication.
# The cycles vary three things, so that each combination is seen at least once:
#   db     Sales (the lab's log reader; Sales keeps SalesPub and SalesRef, so m_tr<n> is
#          never its last publication) or m_trdb (a database of this script, published,
#          with its own log reader; m_tr<n> is its only publication, so the drop is the
#          drop of the last one, which drops that log reader agent and its job (measured
#          by this script, logreader_agent_left=0): each m_trdb cycle after the first
#          adds it again with sp_addlogreader_agent and starts it, and says so in
#          logreader_added_by_cycle);
#   agent  own (independent_agent = true) or shared (independent_agent = false, the
#          publisher database's 'ALL' agent to m_sub);
#   stop   yes: the subscription's distribution agent job is stopped before the drops;
#          no: it is dropped while it runs. An agent dropped while it runs logs "The process
#          was successfully stopped" after its row is gone (Task 10): that orphan history
#          row is counted in the cycle's row (orphan_history=), then deleted by agent id
#          (the id read before the drop, and only while no agent row has that id), since
#          the runner's residue guard rejects any orphan history.
# Every statement of a cycle runs outside a transaction in TRY...CATCH; an error is
# recorded, and the statement is run once more, the second result recorded as retry=.
# Errors are taken from three places: the calls (the caught error number, and any
# "Msg n, Level 11-25", 18752 or deadlock text in what the call printed), and the
# replication agents (distribution.dbo.MSrepl_errors rows and agent history rows with
# runstatus 6, failure, of any agent, from the start of the cycle to the end of the
# settle wait after the drops).
# One row per cycle:
#   R|T<nn>|<sorted distinct error numbers seen, or none>|db=.. agent=.. dist_agent_stopped=..
#     logreader_added_by_cycle=<yes|no> logreader_running=yes
#     logreader_after_drop=<running|stopped|dropped, read after the settle>
#     logreader_agent_left=<rows of MSlogreader_agents for the database>
#     calls=[step:result ...] retries=[step:result ...|none]
#     agent_errors=[codes|none] agent_failures=N orphan_history=N (distribution and snapshot
#     agents of the cycle) orphan_logreader_history=N (the m_trdb log reader the drop removed)
#     left=[...]
# Asserted (exit 1 at the first failure, with the rows on stderr): every build step ends ok,
# the snapshot and a later change are delivered, the log reader of the publication
# database runs at the drop, nothing of the publication is left after the drops
# (syspublications row, distribution agent row, agent job), 10 rows.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/../lib.sh"
DEF_SCRIPT=13-transient
. "$here/../defaults-lib.sh"

# n db agent stop
CYCLES="1 Sales own yes
2 m_trdb own yes
3 Sales shared no
4 m_trdb shared no
5 Sales own no
6 m_trdb own no
7 Sales shared yes
8 m_trdb shared yes
9 Sales own yes
10 m_trdb own no"
EXPECTED_ROWS=10

fail() { echo "13-transient: $*" >&2; for row in "${rows[@]}"; do echo "row: $row" >&2; done; exit 1; }
need() { local v; for v in "$@"; do [ -n "${!v}" ] || fail "empty field $v"; done; }
now() { sql_value "SELECT CONVERT(varchar(23), SYSDATETIME(), 121)"; }

# Agent ids this script dropped; the cleanup deletes their orphan history rows only.
DROPPED_DIST_IDS=(); DROPPED_LR_IDS=()

# job_running JOB_ID: 1 when the job runs in the current Agent session.
job_running() {
    sql_value "SELECT CASE WHEN EXISTS (SELECT 1 FROM msdb.dbo.sysjobactivity WHERE session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions) AND job_id = '$1' AND start_execution_date IS NOT NULL AND stop_execution_date IS NULL) THEN 1 ELSE 0 END"
}

# stop_job JOB_ID: stops one job and repeats until it no longer runs (a job asked to stop
# while it starts can keep running, seen in 12-contexts), up to 90 s.
stop_job() {
    local i
    for i in $(seq 1 18); do
        [ "$(job_running "$1")" = 0 ] && return 0
        sql -Q "SET NOCOUNT ON; BEGIN TRY EXEC msdb.dbo.sp_stop_job @job_id = '$1'; END TRY BEGIN CATCH END CATCH" </dev/null >/dev/null 2>&1 || true
        sleep 5
    done
    fail "job $1 still running after 90 s"
}

delete_orphans() { # removes the orphan history rows of the agents this script dropped
    local ids
    if [ "${#DROPPED_DIST_IDS[@]}" -gt 0 ]; then
        ids=$(IFS=,; echo "${DROPPED_DIST_IDS[*]}")
        sql -Q "SET NOCOUNT ON; DELETE distribution.dbo.MSdistribution_history WHERE agent_id IN ($ids) AND agent_id NOT IN (SELECT id FROM distribution.dbo.MSdistribution_agents)" </dev/null >&2
    fi
    if [ "${#DROPPED_LR_IDS[@]}" -gt 0 ]; then
        ids=$(IFS=,; echo "${DROPPED_LR_IDS[*]}")
        sql -Q "SET NOCOUNT ON; DELETE distribution.dbo.MSlogreader_history WHERE agent_id IN ($ids) AND agent_id NOT IN (SELECT id FROM distribution.dbo.MSlogreader_agents)" </dev/null >&2
    fi
}

cleaned=0
cleanup() {
    [ "$cleaned" = 1 ] && return
    cleaned=1
    # Here, at the end, every m_ agent is stopped, the m_trdb log reader included.
    ( stop_m_agents ) || true
    local d
    for d in Sales m_trdb; do
        sql -Q "SET NOCOUNT ON; IF DB_ID(N'$d') IS NOT NULL AND OBJECT_ID(N'[$d].dbo.syspublications') IS NOT NULL
EXEC (N'USE [$d];
DECLARE @p sysname;
DECLARE c CURSOR LOCAL FOR SELECT name FROM dbo.syspublications WHERE name LIKE N''m\_tr%'' ESCAPE N''\'';
OPEN c; FETCH NEXT FROM c INTO @p;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY EXEC sp_dropsubscription @publication = @p, @article = N''all'', @subscriber = N''all''; END TRY BEGIN CATCH END CATCH;
    WHILE @@TRANCOUNT > 0 ROLLBACK;
    BEGIN TRY EXEC sp_droppublication @publication = @p; END TRY BEGIN CATCH END CATCH;
    WHILE @@TRANCOUNT > 0 ROLLBACK;
    FETCH NEXT FROM c INTO @p;
END;
CLOSE c; DEALLOCATE c;')" </dev/null >&2 || true
    done
    sql <<'SQL' >&2 || true
SET NOCOUNT ON;
USE master;
IF DB_ID(N'm_trdb') IS NOT NULL
BEGIN
    BEGIN TRY EXEC sp_replicationdboption @dbname = N'm_trdb', @optname = N'publish', @value = N'false'; END TRY BEGIN CATCH END CATCH;
    WHILE @@TRANCOUNT > 0 ROLLBACK;
    ALTER DATABASE m_trdb SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE m_trdb;
END
IF DB_ID(N'm_sub') IS NOT NULL
BEGIN
    ALTER DATABASE m_sub SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE m_sub;
END
GO
USE Sales;
DROP TABLE IF EXISTS dbo.m_tt;
SQL
    delete_orphans || true
    podman exec repllab find /var/opt/mssql/data/ReplData/unc -mindepth 1 -maxdepth 1 -iname '*_m_*' -exec rm -rf {} + >&2 || true
}
trap cleanup EXIT

# Leftovers of an earlier run are not absorbed: they fail this run, and the trap removes them.
left=$(sql_value "SELECT (SELECT COUNT(*) FROM Sales.dbo.syspublications WHERE name LIKE N'm\_tr%' ESCAPE N'\') + (SELECT COUNT(*) FROM sys.databases WHERE name IN (N'm_sub', N'm_trdb')) + (SELECT COUNT(*) FROM Sales.sys.objects WHERE name LIKE N'm\_%' ESCAPE N'\')") \
    || exit 1
left_files=$(podman exec repllab find /var/opt/mssql/data/ReplData/unc -mindepth 1 -maxdepth 1 -iname '*_m_*')
if [ "$left" != 0 ] || [ -n "$left_files" ]; then
    echo "13-transient: leftovers of an earlier run (objects=$left files=$left_files); removing them and failing" >&2
    exit 1
fi

# The second publication database and its log reader, started once and left running.
sql <<'SQL' >/dev/null
SET NOCOUNT ON;
USE Sales;
CREATE TABLE dbo.m_tt (id int PRIMARY KEY, a int);
INSERT dbo.m_tt VALUES (1, 1), (2, 2);
CREATE DATABASE m_trdb;
GO
USE m_trdb;
CREATE TABLE dbo.m_tt (id int PRIMARY KEY, a int);
INSERT dbo.m_tt VALUES (1, 1), (2, 2);
GO
USE master;
EXEC sp_replicationdboption @dbname = N'm_trdb', @optname = N'publish', @value = N'true';
GO
SQL
sales_lr_job=$(sql_value "SELECT CONVERT(varchar(36), CONVERT(uniqueidentifier, job_id)) FROM distribution.dbo.MSlogreader_agents WHERE publisher_db = N'Sales'")
sales_lr_id=$(sql_value "SELECT id FROM distribution.dbo.MSlogreader_agents WHERE publisher_db = N'Sales'")
need sales_lr_job sales_lr_id

# step NAME DB STATEMENTS: runs STATEMENTS in DB outside a transaction, in TRY...CATCH.
# Sets STEP_RESULT (ok or the error number) and STEP_SEEN (error numbers found in what the
# call printed: Msg lines of level 11 to 25, 18752 and 1205 by their text).
STEP_RESULT=""; STEP_SEEN=""
step_once() {
    local out line
    out=$(sql -h -1 <<<"SET NOCOUNT ON; USE [$2];
DECLARE @e nvarchar(20) = N'ok';
BEGIN TRY
$3
END TRY
BEGIN CATCH
    SET @e = CONVERT(nvarchar(20), ERROR_NUMBER());
END CATCH;
WHILE @@TRANCOUNT > 0 ROLLBACK;
SELECT N'#result|' + @e;" 2>&1) || fail "step $1 in $2: sqlcmd failed"
    line=$(printf '%s\n' "$out" | grep '^#result|' | tail -n 1 | tr -d '[:space:]')
    [ -n "$line" ] || fail "step $1 in $2: no result line"
    STEP_RESULT=${line#\#result|}
    [[ $STEP_RESULT =~ ^(ok|[0-9]+)$ ]] || fail "step $1: unexpected result $STEP_RESULT"
    STEP_SEEN=$(
        printf '%s\n' "$out" | sed -n -E 's/^Msg ([0-9]+), Level (1[1-9]|2[0-5]),.*/\1/p'
        printf '%s\n' "$out" | grep -q -i -e 'Only one Log Reader Agent or log-related procedure' && echo 18752
        printf '%s\n' "$out" | grep -q -i -e 'deadlocked on' && echo 1205
        true)
}

# step NAME DB STATEMENTS: step_once, and on an error one retry. Appends to calls, retries,
# seen; sets STEP_FINAL to the result of the last attempt.
step() {
    step_once "$@"
    calls+="$1:$STEP_RESULT "
    [ "$STEP_RESULT" = ok ] || seen+="$STEP_RESULT "
    [ -z "$STEP_SEEN" ] || seen+="$(echo $STEP_SEEN) "
    STEP_FINAL=$STEP_RESULT
    if [ "$STEP_RESULT" != ok ] || [ -n "$STEP_SEEN" ]; then
        step_once "$@"
        retries+="$1:$STEP_RESULT "
        [ "$STEP_RESULT" = ok ] || seen+="$STEP_RESULT "
        [ -z "$STEP_SEEN" ] || seen+="$(echo $STEP_SEEN) "
        STEP_FINAL=$STEP_RESULT
    fi
}

cycle() { # N DB AGENT STOP
    local n=$1 db=$2 agent=$3 stop=$4 id pub ind mark lrid added lrleft lorph aid ajob sid lr lrrun lrafter orph i stopped agerr agfail pubs agents jobs res
    id=$(printf 'T%02d' "$n"); pub=m_tr$n
    calls=""; retries=""; seen=""
    case $agent in own) ind=true ;; shared) ind=false ;; esac
    mark=$(now); need mark
    # m_trdb: the log reader agent is added (the drop of the database's last publication
    # dropped the previous one) and started; the cycle waits until it runs.
    added=no
    if [ "$db" = m_trdb ]; then
        if [ "$(sql_value "SELECT COUNT(*) FROM distribution.dbo.MSlogreader_agents WHERE publisher_db = N'm_trdb'")" = 0 ]; then
            step addlogreader m_trdb "EXEC sp_addlogreader_agent @job_login = NULL, @job_password = NULL, @publisher_security_mode = 1;"
            [ "$STEP_FINAL" = ok ] || fail "$id: sp_addlogreader_agent gave $STEP_FINAL"
            added=yes
        fi
        lr=$(sql_value "SELECT CONVERT(varchar(36), CONVERT(uniqueidentifier, job_id)) FROM distribution.dbo.MSlogreader_agents WHERE publisher_db = N'm_trdb'")
        lrid=$(sql_value "SELECT id FROM distribution.dbo.MSlogreader_agents WHERE publisher_db = N'm_trdb'")
        need lr lrid
        if [ "$(job_running "$lr")" = 0 ]; then
            sql -Q "SET NOCOUNT ON; EXEC msdb.dbo.sp_start_job @job_id = '$lr'" </dev/null >/dev/null
            wait_until 60 "SELECT CASE WHEN EXISTS (SELECT 1 FROM msdb.dbo.sysjobactivity WHERE session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions) AND job_id = '$lr' AND start_execution_date IS NOT NULL AND stop_execution_date IS NULL) THEN 1 ELSE 0 END" \
                || fail "$id: the log reader of m_trdb does not start"
        fi
    else
        lr=$sales_lr_job; lrid=$sales_lr_id
    fi
    sql -Q "SET NOCOUNT ON; CREATE DATABASE m_sub;" </dev/null >/dev/null

    step addpub "$db" "EXEC sp_addpublication @publication = N'$pub', @status = N'active', @allow_push = N'true', @independent_agent = N'$ind', @immediate_sync = N'false', @repl_freq = N'continuous', @sync_method = N'concurrent';"
    [ "$STEP_FINAL" = ok ] || fail "$id: sp_addpublication gave $STEP_FINAL"
    step addsnapshot "$db" "EXEC sp_addpublication_snapshot @publication = N'$pub', @frequency_type = 1, @active_start_date = 99991231, @job_login = NULL, @job_password = NULL, @publisher_security_mode = 1;"
    [ "$STEP_FINAL" = ok ] || fail "$id: sp_addpublication_snapshot gave $STEP_FINAL"
    step addarticle "$db" "EXEC sp_addarticle @publication = N'$pub', @article = N'm_tt', @source_owner = N'dbo', @source_object = N'm_tt';"
    [ "$STEP_FINAL" = ok ] || fail "$id: sp_addarticle gave $STEP_FINAL"
    step addsub "$db" "DECLARE @s sysname = @@SERVERNAME; EXEC sp_addsubscription @publication = N'$pub', @subscriber = @s, @destination_db = N'm_sub', @subscription_type = N'Push', @sync_type = N'automatic', @article = N'all';"
    [ "$STEP_FINAL" = ok ] || fail "$id: sp_addsubscription gave $STEP_FINAL"
    step addagent "$db" "DECLARE @s sysname = @@SERVERNAME; EXEC sp_addpushsubscription_agent @publication = N'$pub', @subscriber = @s, @subscriber_db = N'm_sub', @job_login = NULL, @job_password = NULL, @subscriber_security_mode = 1;"
    [ "$STEP_FINAL" = ok ] || fail "$id: sp_addpushsubscription_agent gave $STEP_FINAL"
    step startsnapshot "$db" "EXEC sp_startpublication_snapshot @publication = N'$pub';"
    [ "$STEP_FINAL" = ok ] || fail "$id: sp_startpublication_snapshot gave $STEP_FINAL"

    local apred="a.publisher_db = N'$db' AND a.subscriber_db = N'm_sub' AND a.publication = N'$([ "$agent" = own ] && echo "$pub" || echo ALL)'"
    aid=$(sql_value "SELECT a.id FROM distribution.dbo.MSdistribution_agents a WHERE $apred")
    ajob=$(sql_value "SELECT CONVERT(varchar(36), CONVERT(uniqueidentifier, a.job_id)) FROM distribution.dbo.MSdistribution_agents a WHERE $apred")
    sid=$(sql_value "SELECT a.id FROM distribution.dbo.MSsnapshot_agents a WHERE a.publisher_db = N'$db' AND a.publication = N'$pub'")
    need aid ajob sid
    wait_until 300 "SELECT CASE WHEN EXISTS (SELECT 1 FROM distribution.dbo.MSsnapshot_history h WHERE h.agent_id = $sid AND h.time >= '$mark' AND h.runstatus = 2)
        AND EXISTS (SELECT 1 FROM distribution.dbo.MSdistribution_history h WHERE h.agent_id = $aid AND h.time >= '$mark' AND h.comments LIKE N'Delivered snapshot%') THEN 1 ELSE 0 END" \
        || fail "$id: snapshot not delivered"
    sql -Q "SET NOCOUNT ON; INSERT [$db].dbo.m_tt VALUES (100 + $n, $n)" </dev/null
    wait_until 120 "SELECT CASE WHEN EXISTS (SELECT 1 FROM m_sub.dbo.m_tt WHERE id = 100 + $n) THEN 1 ELSE 0 END" \
        || fail "$id: the change made after the snapshot was not delivered"

    stopped=no
    if [ "$stop" = yes ]; then stop_job "$ajob"; stopped=yes; fi
    # The log reader keeps working during the drops: two more rows to read.
    sql -Q "SET NOCOUNT ON; INSERT [$db].dbo.m_tt VALUES (200 + $n, $n), (300 + $n, $n)" </dev/null
    lrrun=$(job_running "$lr")
    [ "$lrrun" = 1 ] || fail "$id: the log reader of $db is not running at the drop"

    DROPPED_DIST_IDS+=("$aid")
    [ "$db" = Sales ] || DROPPED_LR_IDS+=("$lrid")
    step dropsub "$db" "EXEC sp_dropsubscription @publication = N'$pub', @article = N'all', @subscriber = N'all';"
    step droppub "$db" "EXEC sp_droppublication @publication = N'$pub';"

    # Settle: a running agent dropped with its job logs its last history row a few seconds
    # after the drop. Wait until it is there (up to 30 s) when the agent was not stopped,
    # 10 s otherwise.
    if [ "$stopped" = no ]; then
        wait_until 30 "SELECT CASE WHEN EXISTS (SELECT 1 FROM distribution.dbo.MSdistribution_history WHERE agent_id = $aid AND agent_id NOT IN (SELECT id FROM distribution.dbo.MSdistribution_agents)) THEN 1 ELSE 0 END" 2>/dev/null || true
    else
        sleep 10
    fi
    lrleft=$(sql_value "SELECT COUNT(*) FROM distribution.dbo.MSlogreader_agents WHERE publisher_db = N'$db'")
    lrafter=stopped; [ "$(job_running "$lr")" = 1 ] && lrafter=running
    [ "$(sql_value "SELECT COUNT(*) FROM msdb.dbo.sysjobs WHERE job_id = '$lr'")" = 0 ] && lrafter=dropped
    orph=$(sql_value "SELECT (SELECT COUNT(*) FROM distribution.dbo.MSdistribution_history WHERE agent_id = $aid AND agent_id NOT IN (SELECT id FROM distribution.dbo.MSdistribution_agents)) + (SELECT COUNT(*) FROM distribution.dbo.MSsnapshot_history WHERE agent_id = $sid AND agent_id NOT IN (SELECT id FROM distribution.dbo.MSsnapshot_agents))")
    lorph=$(sql_value "SELECT COUNT(*) FROM distribution.dbo.MSlogreader_history WHERE agent_id = $lrid AND agent_id NOT IN (SELECT id FROM distribution.dbo.MSlogreader_agents)")
    agerr=$(sql_value "SELECT ISNULL(STRING_AGG(CONVERT(nvarchar(4000), c), N',') WITHIN GROUP (ORDER BY c), N'none') FROM (SELECT DISTINCT CASE WHEN ISNULL(error_code, N'') = N'' THEN N'nocode' ELSE CONVERT(nvarchar(100), error_code) END AS c FROM distribution.dbo.MSrepl_errors WHERE time >= '$mark') x")
    agfail=$(sql_value "SELECT (SELECT COUNT(*) FROM distribution.dbo.MSdistribution_history WHERE time >= '$mark' AND runstatus = 6) + (SELECT COUNT(*) FROM distribution.dbo.MSlogreader_history WHERE time >= '$mark' AND runstatus = 6) + (SELECT COUNT(*) FROM distribution.dbo.MSsnapshot_history WHERE time >= '$mark' AND runstatus = 6)")
    pubs=$(sql_value "SELECT COUNT(*) FROM [$db].dbo.syspublications WHERE name = N'$pub'")
    agents=$(sql_value "SELECT COUNT(*) FROM distribution.dbo.MSdistribution_agents a WHERE $apred")
    jobs=$(sql_value "SELECT COUNT(*) FROM msdb.dbo.sysjobs WHERE job_id = '$ajob' OR name LIKE N'%-$pub-%'")
    need orph lorph agerr agfail pubs agents jobs lrafter lrleft
    # The agent errors are numbers too: they join the cycle's list.
    [ "$agerr" = none ] || seen+="${agerr//,/ } "

    local rt=${retries% }
    [ -n "$rt" ] || rt=none
    res=$(echo $seen | tr ' ' '\n' | { grep -v '^$' || true; } | sort -n -u | tr '\n' ',' | sed 's/,$//')
    [ -n "$res" ] || res=none
    r "$id" "$res" "db=$db agent=$agent dist_agent_stopped=$stopped logreader_added_by_cycle=$added logreader_running=yes logreader_after_drop=$lrafter logreader_agent_left=$lrleft calls=[${calls% }] retries=[$rt] agent_errors=[$agerr] agent_failures=$agfail orphan_history=$orph orphan_logreader_history=$lorph left=[publication=$pubs dist_agent_row=$agents jobs=$jobs]"
    [ "$pubs" = 0 ] && [ "$agents" = 0 ] && [ "$jobs" = 0 ] || fail "$id: the publication is not gone: publication=$pubs dist_agent_row=$agents jobs=$jobs"

    delete_orphans
    sql -Q "SET NOCOUNT ON; ALTER DATABASE m_sub SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE m_sub;" </dev/null >/dev/null
    podman exec repllab find /var/opt/mssql/data/ReplData/unc -mindepth 1 -maxdepth 1 -iname "*_$pub" -exec rm -rf {} + >&2 || true
}

mapfile -t cycle_lines <<<"$CYCLES"
for line in "${cycle_lines[@]}"; do
    # shellcheck disable=SC2086
    cycle $line
done

[ "${#rows[@]}" = "$EXPECTED_ROWS" ] || fail "${#rows[@]} rows, expected $EXPECTED_ROWS"
cleanup
for row in "${rows[@]}"; do printf '%s\n' "$row"; done
echo "R|TOTAL|${#rows[@]}"
