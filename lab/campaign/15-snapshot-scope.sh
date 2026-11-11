#!/bin/bash
# The scope of a snapshot generation after an article is added (campaign item 12 of the
# plan/apply design): which tables the agent generates, which tables it locks and for how
# long, the -defer-full-snapshot sequence step by step, whether each invalidating operation
# leaves a subscription status that awaits a delivery, and extending a subscription that a
# reinit-flagged change has just marked. Run through lab/campaign.sh.
#
# Objects. In Sales: m_t1 (1,000,000 rows with a 100-byte pad), m_t2 (100 rows), m_t3,
# m_t4, m_t5, m_t6 (one row each). The database m_w holds the writers' log. The
# publications are created per phase (A to E, then F, then B) and dropped as soon as their
# cases are done, to keep few m_ agents alive (see droppub). Every publication
# has a snapshot agent whose schedule never fires (@frequency_type = 1,
# @active_start_date = 99991231) and a push subscription to a database of its own, its
# snapshot generated and delivered before anything is measured:
#   m_sc_<imm|non>_<method>, method in native, character, concurrent, concurrent_c, dbsnap
#     (sync_method 'database snapshot'): m_t1, m_t2; subscriber m_d_<imm|non>_<method>.
#     imm: immediate_sync and independent agent; non: neither (shared distribution agent).
#   m_df_<native|concurrent>_<anon|noanon>: immediate_sync, independent agent,
#     allow_anonymous true (anon) or false (noanon); m_t1, m_t2; subscriber m_e_<suffix>,
#     and m_l_<suffix>, the subscriber added after the restore.
#   m_df_<native|concurrent>_race: as noanon, for the restore that does not wait.
#
# Rows:
#   A.<imm|non>.<method>   add m_t3 by the rules of the spec (imm: sp_addarticle with the
#       flags it needs, the subscription is extended by the server; non native/character:
#       sp_addarticle then sp_addsubscription @article = 'm_t3'; non concurrent/concurrent_c:
#       sp_addsubscription @article = 'all'; non dbsnap: 'm_t3', then 'all' if refused), then
#       one snapshot run with three timed writers (one UPDATE of one row every 50 ms on
#       m_t1, m_t2, m_t3). Result: files=[tables with a file in the run's folder]. Detail:
#       the flags, the extension, hist_bcp / hist_schema (tables named by a bulk copy or a
#       schema script line of the snapshot history), articles (the "A snapshot of N
#       article(s)" line), delivered (tables applied at the subscriber), gen (the run's
#       duration), w_<table> (the longest single UPDATE), t2_vs_t1, overlap_t1_t2 (the two
#       longest waits overlap in time), t1_ends_at_gen_end (within 500 ms of the history's
#       last line), and the state after the run.
#   B.<pub>.<step>   the deferred sequence of the spec on the m_df_ publications: 1a
#       allow_anonymous false (anon only), 1b immediate_sync false, 2a sp_addarticle m_t3,
#       2b the extension, 3 generate and wait, 4a immediate_sync true, 4b allow_anonymous
#       true (anon only), 5a a subscription to m_l_<suffix> added after the restore, 5b the
#       next run of the agent and what each subscriber receives. On _race: 1b, 2a, 2b, then
#       race: the agent started and immediate_sync restored at once, without waiting.
#   C.<method>.<op>   on each m_sc_imm_ publication (ready snapshot, all delivered), each
#       invalidating operation run in a transaction rolled back, with the first flag
#       combination that works (f00, f10, f01, f11 in that order); the state is read
#       inside the transaction: ready, every subscription status, the inactive articles
#       (sysarticles.status without 0x1), and awaits=yes when a status is not 2 or a
#       subscribed article is inactive.
#   D.<non_native|non_concurrent|imm_native|imm_concurrent>.<step>   on the m_sc_
#       publication after A (the imm_ variants try to reproduce the 14058 and 14100 refusals
#       the review of e220523 reported; on them sp_addarticle extends the subscription):
#       sync_method_probe, the change of sync_method within its family (character,
#       concurrent_c), rolled back; change, a reinit-flagged change (sp_changearticle
#       schema_option on m_t1, committed with the flags it needs); then the addition of m_t4
#       and its extension by the rule (extend_rule; extend_all on native when the rule is
#       refused), a snapshot, and when the extension was refused, the extension after that
#       snapshot and a second one; then the other order, extend_then_change: m_t5 added and
#       extended first, schema_option changed back after, and a snapshot.
#   F.<variant>   writes to an article added to a publication without immediate_sync, and
#       the delivery of its snapshot: m_fx_dbsnap_before / _during / _none and
#       m_fx_native_before (article m_t2, subscriber m_f_<variant>), m_t6 added and extended,
#       then one run: one UPDATE of m_t6 5 s before the start (before), ten UPDATEs in the 5 s
#       after the start (during), none, and before under native. Result: the tables
#       delivered, with the agent's last failure when nothing was delivered. Added after A
#       under dbsnap failed to deliver m_t3 with "Could not find stored procedure
#       'dbo.sp_MSupd_dbom_t3'" while the m_t3 writer ran (two of the four dbsnap rows of the
#       first two runs). Nothing is asserted on F.
#   E.<step>   what sets the subscription status and the article's active bit, the
#       generation or the delivery: on m_sc_non_character after A, its distribution agent
#       disabled and stopped, m_t4 added and extended (extended), generated
#       (generated_undelivered), then the agent enabled and started (delivered).
# Flag cells: f<i><r>, i = @force_invalidate_snapshot, r = @force_reinit_subscription;
# each result names the first that worked, the detail the refusals before it (probe=).
#
# The rows of each phase are printed when the phase ends (and appended to SNAP_RAW), so
# that a later failure leaves them in the log; R|TOTAL comes last. A watchdog ends the run
# at the first sign of memory trouble (see memcheck).
#
# Values that change between runs (times, durations, job names) never appear raw: a
# duration is a bucket (ms<1000, ms<30000, ms>=30000: the same run took 2 s on an idle lab
# and 8 s on a loaded one) and waits are compared; overlap_t1_t2 and t1_ends_at_gen_end are
# n/a unless both writers waited at least one second. SNAP_RAW, when set, names a file the
# raw values (durations, offsets) are appended to.
#
# Asserted (exit 1, rows on stderr): under native with immediate_sync the writer on m_t2
# waits about as long as the one on m_t1 (t2_vs_t1=similar, w_t1 at least 250 ms); under
# dbsnap every writer waits under one second; the deferred sequence with the wait
# generates only m_t3 before the restore (B.*.3 files=[m_t3]) and leaves every
# subscription active (status 2) after the restore. Nothing is asserted on what a
# concurrent generation without immediate_sync covers.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"
mark=$(sql_value "SELECT CONVERT(varchar(23), SYSDATETIME(), 121)")
raw=${SNAP_RAW:-/dev/null}
tmp=$(mktemp -d)
srv=$(sql_value "SELECT @@SERVERNAME")
unc=/var/opt/mssql/data/ReplData/unc
tables="m_t1 m_t2 m_t3 m_t4 m_t5"
methods="native character concurrent concurrent_c dbsnap"
fx="dbsnap_before dbsnap_during dbsnap_none native_before"
df_pubs="m_df_native_anon m_df_native_noanon m_df_concurrent_anon m_df_concurrent_noanon m_df_native_race m_df_concurrent_race"

rows=()
r() { rows+=("R|$1|$2|$3"); }
# flush: prints the rows not printed yet, at the end of each phase, so that a later failure
# keeps them in the log; they also go to SNAP_RAW.
printed=0
flush() {
    local i
    for (( i = printed; i < ${#rows[@]}; i++ )); do printf '%s\n' "${rows[$i]}"; rawlog "row ${rows[$i]}"; done
    printed=${#rows[@]}
}
rawlog() { printf '%s\n' "$*" >>"$raw"; }
esc() { printf '%s' "${1//\'/\'\'}"; }
syncval() { [ "$1" = dbsnap ] && echo 'database snapshot' || echo "$1"; }

# sq QUERY: runs QUERY in Sales and prints its last output line; fails on an error.
sq() {
    local out
    out=$(sql -d Sales -b -h -1 -Q "SET NOCOUNT ON; $1" </dev/null 2>&1) || {
        memcheck "$out"
        printf '15-snapshot-scope: query failed: %s\n%s\n' "${1:0:300}" "$out" >&2; return 1; }
    printf '%s\n' "$out" | sed -e 's/[[:space:]]*$//' | grep -v '^$' | tail -n 1
}
# sx STATEMENTS: runs them in Sales, output to the log.
sx() {
    local out rc=0
    out=$(sql -d Sales -b -Q "SET NOCOUNT ON; $1" </dev/null 2>&1) || rc=$?
    printf '%s\n' "$out" >&2
    if [ "$rc" != 0 ]; then memcheck "$out"; return "$rc"; fi
}

# Memory trouble. In a second run of a first version, about 26 continuous m_ distribution
# agents, which run inside sqlservr and share its MSSQL_MEMORY_LIMIT_MB, wedged the lab:
# error 701, logins refused (17803, login timeouts), every query on
# RESOURCE_SEMAPHORE_QUERY_COMPILE. The script now stops at the first sign of it: a failed
# call whose output shows 701, 17803 or a login timeout (memcheck), or a watchdog that reads
# the errorlog and probes a login every 10 s. Either one leaves the reason in $memflag and
# ends the script; the teardown then stops the m_ agents first, within a deadline.
memflag=$tmp/memory_trouble
memcheck() { # OUTPUT of a failed call
    if printf '%s\n' "$1" | grep -q -E 'Msg 701,|Msg 17803,|Error: 701|Error: 17803|Login timeout expired|insufficient system memory'; then
        printf 'a call failed with: %s\n' "$(printf '%s\n' "$1" | grep -m1 -E '701|17803|Login timeout|insufficient' | tr -d '\r')" >"$memflag"
        echo "15-snapshot-scope: MEMORY TROUBLE: $(cat "$memflag")" >&2
        exit 1
    fi
}
# kill_tree PID: TERM to every descendant of PID except the calling subshell.
kill_tree() {
    local c
    for c in $(pgrep -P "$1" || true); do
        [ "$c" = "$BASHPID" ] && continue
        kill_tree "$c"
        kill -TERM "$c" 2>/dev/null || true
    done
}
watchdog() { # MAIN_PID ERRORLOG_START_LINE
    local main=$1 from=$(( $2 + 1 )) fails=0 hit p
    while kill -0 "$main" 2>/dev/null; do
        sleep 10
        hit=$(podman exec repllab sh -c "tail -n +$from /var/opt/mssql/log/errorlog | grep -m1 -E 'Error: (701|17803),'" 2>/dev/null || true)
        # memcheck may have fired inside a command substitution, whose exit ends only that
        # subshell: its file is the signal.
        if [ -f "$memflag" ]; then hit="$hit $(cat "$memflag")"; fi
        if timeout 45 bash -c '. "$1"; sql -l 30 -h -1 -Q "SELECT 1" </dev/null >/dev/null 2>&1' _ "$libsh"; then fails=0; else fails=$(( fails + 1 )); fi
        if [ -n "$hit" ] || (( fails >= 2 )); then
            echo "watchdog: ${hit:-two login probes in a row failed}" >"$memflag"
            # The clients inside the container first: a hung sqlcmd outlives its podman exec.
            for p in $(podman exec repllab ps -eo pid,args 2>/dev/null | awk '/[s]qlcmd/ { print $1 }'); do
                podman exec repllab kill -9 "$p" 2>/dev/null || true
            done
            kill_tree "$main"
            kill -TERM "$main" 2>/dev/null || true
            return 0
        fi
    done
}
now() { sql_value "SELECT CONVERT(varchar(23), SYSDATETIME(), 121)"; }
# try STATEMENTS: runs them outside a transaction, prints ok or the error numbers.
try() {
    sq "DECLARE @e nvarchar(100) = N'ok';
BEGIN TRY $1 END TRY
BEGIN CATCH SET @e = CONVERT(nvarchar(10), ERROR_NUMBER()); WHILE @@TRANCOUNT > 0 ROLLBACK; END CATCH;
WHILE @@TRANCOUNT > 0 ROLLBACK;
SELECT @e"
}

# The state of PUB as a SQL expression: ready, immediate_sync, allow_anonymous, every
# subscription row (db:article=status), the inactive articles, awaits.
state_expr() {
    local w="FROM dbo.syssubscriptions s JOIN dbo.sysarticles a ON a.artid = s.artid JOIN dbo.syspublications p ON p.pubid = a.pubid WHERE p.name = N'$1' AND s.srvid >= 0"
    echo "CONCAT(N'ready=', (SELECT CONVERT(nvarchar(5), immediate_sync_ready) FROM dbo.syspublications WHERE name = N'$1'),
 N' imm=', (SELECT CONVERT(nvarchar(5), immediate_sync) FROM dbo.syspublications WHERE name = N'$1'),
 N' anon=', (SELECT CONVERT(nvarchar(5), allow_anonymous) FROM dbo.syspublications WHERE name = N'$1'),
 N' subs=[', ISNULL((SELECT STRING_AGG(CONVERT(nvarchar(4000), s.dest_db + N':' + a.name + N'=' + CONVERT(nvarchar(5), s.status)), N',') WITHIN GROUP (ORDER BY s.dest_db, a.name) $w), N''),
 N'] inactive=[', ISNULL((SELECT STRING_AGG(CONVERT(nvarchar(4000), a.name), N',') WITHIN GROUP (ORDER BY a.name) FROM dbo.sysarticles a JOIN dbo.syspublications p ON p.pubid = a.pubid WHERE p.name = N'$1' AND a.status & 1 = 0), N''),
 N'] awaits=', CASE WHEN EXISTS (SELECT 1 $w AND (s.status <> 2 OR a.status & 1 = 0)) THEN N'yes' ELSE N'no' END)"
}
state() { sq "SELECT $(state_expr "$1")"; }

# flags MODE PUB CELLS STMT: STMT takes @i (@force_invalidate_snapshot) and @r
# (@force_reinit_subscription). Tries f00, f10, f01, f11 (the first CELLS of them), each
# in a transaction rolled back. MODE commit: runs the first that worked for real. MODE
# probe: reads the state of PUB inside the transaction of the first that worked.
# Prints <cell or refused>|<refusals before it>|<state read in the transaction>.
flags() {
    local mode=$1 pub=$2 cells=$3 stmt=$4 inside="" after=""
    [ "$mode" = probe ] && inside="SET @st = $(state_expr "$pub");"
    [ "$mode" = commit ] && after="IF @ok IS NOT NULL BEGIN SELECT @i = i, @r = r FROM @f WHERE name = @ok; EXEC sp_executesql @stmt, N'@i bit, @r bit', @i = @i, @r = @r; END;"
    sq "DECLARE @f TABLE (k int, i bit, r bit, name varchar(3));
INSERT @f VALUES (0, 0, 0, 'f00'), (1, 1, 0, 'f10'), (2, 0, 1, 'f01'), (3, 1, 1, 'f11');
DECLARE @k int = 0, @i bit, @r bit, @ok varchar(3) = NULL, @errs nvarchar(400) = N'', @st nvarchar(4000) = NULL,
        @stmt nvarchar(max) = N'$(esc "$stmt")';
WHILE @k < $cells AND @ok IS NULL
BEGIN
    SELECT @i = i, @r = r FROM @f WHERE k = @k;
    BEGIN TRY
        BEGIN TRAN;
        EXEC sp_executesql @stmt, N'@i bit, @r bit', @i = @i, @r = @r;
        $inside
        SELECT @ok = name FROM @f WHERE k = @k;
        ROLLBACK;
    END TRY
    BEGIN CATCH
        SET @errs += (SELECT name FROM @f WHERE k = @k) + N':' + CONVERT(nvarchar(10), ERROR_NUMBER()) + N',';
    END CATCH;
    WHILE @@TRANCOUNT > 0 ROLLBACK;
    SET @k += 1;
END;
$after
SELECT CONCAT(ISNULL(@ok, 'refused'), N'|', CASE WHEN @errs = N'' THEN N'none' ELSE LEFT(@errs, LEN(@errs) - 1) END, N'|', ISNULL(@st, N''))"
}

# ms bucket.
bucket() {
    local v=$1
    if ! [[ $v =~ ^[0-9]+$ ]]; then echo none
    elif (( v < 1000 )); then echo 'ms<1000'
    elif (( v < 30000 )); then echo 'ms<30000'
    else echo 'ms>=30000'; fi
}
# B against A: both_short when both under 1000 ms, similar when the shorter is at least
# 60% of the longer, else shorter or longer.
compare() {
    local a=$1 b=$2 lo hi
    if [ "$a" = none ] || [ "$b" = none ]; then echo none; return; fi
    if (( a < 1000 && b < 1000 )); then echo both_short; return; fi
    lo=$(( a < b ? a : b )); hi=$(( a < b ? b : a ))
    if (( lo * 10 >= hi * 6 )); then echo similar
    elif (( b < a )); then echo shorter
    else echo longer; fi
}

# Timed writers. Each is a sqlcmd loop running in the background: one UPDATE of row 1,
# its duration logged in m_w.dbo.wlog, then 50 ms of pause, until its run is stopped.
wpids=()
wstart() { # RUN TABLE...
    local run=$1 t; shift
    sql -b -Q "SET NOCOUNT ON; INSERT m_w.dbo.ctl VALUES ('$run', 0)" </dev/null >&2
    for t in "$@"; do
        sql -b -h -1 -Q "SET NOCOUNT ON; SET LOCK_TIMEOUT 120000;
DECLARE @t0 datetime2(3), @e int, @end datetime2 = DATEADD(second, 900, SYSDATETIME());
WHILE NOT EXISTS (SELECT 1 FROM m_w.dbo.ctl WHERE run = '$run' AND stop = 1) AND SYSDATETIME() < @end
BEGIN
    SET @t0 = SYSDATETIME(); SET @e = NULL;
    BEGIN TRY UPDATE Sales.dbo.$t SET a = a + 1 WHERE id = 1; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH;
    INSERT m_w.dbo.wlog VALUES ('$run', N'$t', @@SPID, @t0, SYSDATETIME(), DATEDIFF(millisecond, @t0, SYSDATETIME()), @e);
    WAITFOR DELAY '00:00:00.050';
END" </dev/null >"$tmp/w.$run.$t" 2>&1 &
        wpids+=($!)
    done
    sleep 2
}
wstop() { # RUN
    local p bad=0
    sql -b -Q "SET NOCOUNT ON; UPDATE m_w.dbo.ctl SET stop = 1 WHERE run = '$1'" </dev/null >&2
    for p in "${wpids[@]}"; do wait "$p" || bad=1; done
    wpids=()
    # A writer's own failure is a real error: its output reaches the log.
    if [ "$bad" = 1 ] || grep -q -E '^Msg |^Sqlcmd:' "$tmp"/w."$1".* 2>/dev/null; then
        cat "$tmp"/w."$1".* >&2
        echo "15-snapshot-scope: a writer of $1 failed" >&2
        exit 1
    fi
}
# The longest UPDATE of each table of RUN: "table ms start_off end_off count errors;..."
# with the offsets in ms from MARK.
wstats() { # RUN MARK
    sq "DECLARE @m datetime2 = '$2';
SELECT ISNULL(STRING_AGG(CONVERT(nvarchar(4000), CONCAT(tbl, N' ', ms, N' ', DATEDIFF(millisecond, @m, t0), N' ', DATEDIFF(millisecond, @m, t1), N' ', n, N' ', errs)), N';') WITHIN GROUP (ORDER BY tbl), N'none')
FROM (SELECT tbl, ms, t0, t1, ROW_NUMBER() OVER (PARTITION BY tbl ORDER BY ms DESC, t0) AS rn, COUNT(*) OVER (PARTITION BY tbl) AS n,
             SUM(CASE WHEN err IS NULL THEN 0 ELSE 1 END) OVER (PARTITION BY tbl) AS errs
      FROM m_w.dbo.wlog WHERE run = '$1') x WHERE rn = 1"
}

# Snapshot runs.
pubdir() { echo "$unc/${srv^^}_SALES_${1^^}"; }
folders() { podman exec repllab find "$(pubdir "$1")" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort || true; }
# The tables that have a file in the folders given: <article>_<artid>[#n].<ext>.
files_in() {
    [ $# -eq 0 ] && { echo ""; return; }
    podman exec repllab sh -c 'for d in "$@"; do ls -1 "$d"; done' sh "$@" \
        | sed -E 's/\.[A-Za-z]+$//; s/#[0-9]+$//; s/_[0-9]+$//' | sort -u | paste -sd, -
}
done_query() { # PUB MARK
    echo "SELECT CASE WHEN EXISTS (SELECT 1 FROM distribution.dbo.MSsnapshot_history h JOIN distribution.dbo.MSsnapshot_agents a ON a.id = h.agent_id WHERE a.publication = N'$1' AND a.publisher_db = N'Sales' AND h.time >= '$2' AND h.runstatus IN (2, 6)) THEN 1 ELSE 0 END"
}
# What the snapshot history of PUB says since MARK:
# "<final runstatus> <start offset> <end offset> <articles> [bcp tables] [schema tables]".
tabvals="(VALUES (N'm_t1'), (N'm_t2'), (N'm_t3'), (N'm_t4'), (N'm_t5'), (N'm_t6')) v(t)"
gen_info() { # PUB MARK
    sq "DECLARE @m datetime2 = '$2';
WITH h AS (SELECT h.time, h.runstatus, CONVERT(nvarchar(4000), h.comments) AS c FROM distribution.dbo.MSsnapshot_history h
           JOIN distribution.dbo.MSsnapshot_agents a ON a.id = h.agent_id WHERE a.publication = N'$1' AND a.publisher_db = N'Sales' AND h.time >= @m)
SELECT CONCAT(
  ISNULL((SELECT TOP 1 CONVERT(varchar(5), runstatus) FROM h WHERE runstatus IN (2, 6) ORDER BY time DESC), 'none'), ' ',
  ISNULL(CONVERT(varchar(12), DATEDIFF(millisecond, @m, (SELECT MIN(time) FROM h))), 'none'), ' ',
  ISNULL(CONVERT(varchar(12), DATEDIFF(millisecond, @m, (SELECT MAX(time) FROM h WHERE runstatus IN (2, 6)))), 'none'), ' ',
  CASE WHEN EXISTS (SELECT 1 FROM h WHERE c LIKE N'%snapshot was not generated%') THEN 'not_generated'
       ELSE ISNULL((SELECT TOP 1 CASE WHEN CHARINDEX(N' article(s)', c) > CHARINDEX(N'A snapshot of ', c) + 14 THEN SUBSTRING(c, CHARINDEX(N'A snapshot of ', c) + 14, CHARINDEX(N' article(s)', c) - CHARINDEX(N'A snapshot of ', c) - 14) END FROM h WHERE c LIKE N'%A snapshot of % article(s) was generated%'), 'none') END, ' ',
  '[', ISNULL((SELECT STRING_AGG(t, N',') WITHIN GROUP (ORDER BY t) FROM $tabvals WHERE EXISTS (SELECT 1 FROM h WHERE c LIKE N'%Bulk copied snapshot data for article ''' + t + N'[ '']%')), N''), '] ',
  '[', ISNULL((SELECT STRING_AGG(t, N',') WITHIN GROUP (ORDER BY t) FROM $tabvals WHERE EXISTS (SELECT 1 FROM h WHERE c LIKE N'%Generating schema scripts for article ''' + t + N'''%')), N''), ']')"
}
# The tables applied at subscriber database DB since MARK, followed by (no_delivery) when
# the agent logged no "Delivered snapshot" line, with the text of its last failure if any.
delivered() { # DB MARK
    sq "DECLARE @m datetime2 = '$2';
WITH h AS (SELECT h.time, h.runstatus, CONVERT(nvarchar(4000), h.comments) AS c FROM distribution.dbo.MSdistribution_history h
           JOIN distribution.dbo.MSdistribution_agents a ON a.id = h.agent_id WHERE a.subscriber_db = N'$1' AND a.subscriber_id >= 0 AND h.time >= @m)
SELECT CONCAT('[', ISNULL((SELECT STRING_AGG(t, N',') WITHIN GROUP (ORDER BY t) FROM $tabvals
                           WHERE EXISTS (SELECT 1 FROM h WHERE c LIKE N'Applied script ''' + t + N'[_]%.sch''%' OR c LIKE N'Bulk copied data into table ''' + t + N'''%')), N''), ']',
              CASE WHEN EXISTS (SELECT 1 FROM h WHERE c LIKE N'Delivered snapshot%') THEN N''
                   ELSE N'(no_delivery' + ISNULL(N',agent_failed=' + (SELECT TOP 1 REPLACE(LEFT(c, 300), N'|', N'/') FROM h WHERE runstatus = 6 ORDER BY time DESC), N'') + N')' END)"
}
delivered_query() { # DB MARK
    echo "SELECT CASE WHEN EXISTS (SELECT 1 FROM distribution.dbo.MSdistribution_history h JOIN distribution.dbo.MSdistribution_agents a ON a.id = h.agent_id WHERE a.subscriber_db = N'$1' AND a.subscriber_id >= 0 AND h.time >= '$2' AND h.comments LIKE N'Delivered snapshot%') THEN 1 ELSE 0 END"
}

# snap PUB WRITERS_RUN|- DB...: one run of the agent of PUB, waited for, then the
# deliveries to each DB waited for (up to 150 s each). Sets SNAP_FILES, SNAP_INFO (gen,
# history, deliveries), SNAP_MARK, SNAP_START, SNAP_END (offsets from SNAP_MARK).
# RACE, when set, is run right after the start (the restore that does not wait).
snap() {
    local pub=$1 wrun=$2 db before after new info st d
    shift 2
    before=$(folders "$pub")
    [ "$wrun" != - ] && wstart "$wrun" m_t1 m_t2 m_t3
    SNAP_MARK=$(now)
    sx "EXEC sp_startpublication_snapshot @publication = N'$pub'"
    RACE_OUT=""
    [ -n "${RACE:-}" ] && RACE_OUT=$($RACE)
    wait_until 300 "$(done_query "$pub" "$SNAP_MARK")" || { echo "15-snapshot-scope: $pub: the snapshot run did not end" >&2; exit 1; }
    [ "$wrun" != - ] && wstop "$wrun"
    for db in "$@"; do
        wait_until 150 "$(delivered_query "$db" "$SNAP_MARK")" || true
    done
    sleep 5
    after=$(folders "$pub")
    new=$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | grep -v '^$' || true)
    # shellcheck disable=SC2086
    SNAP_FILES=$(files_in $new)
    info=$(gen_info "$pub" "$SNAP_MARK")
    read -r st SNAP_START SNAP_END SNAP_ARTS SNAP_BCP SNAP_SCH <<<"$info"
    local gen=none
    [ "$SNAP_START" != none ] && [ "$SNAP_END" != none ] && gen=$(( SNAP_END - SNAP_START ))
    SNAP_INFO="run=$( [ "$st" = 2 ] && echo ok || echo "status$st" ) folders=$(printf '%s\n' "$new" | grep -c . || true) hist_bcp=$SNAP_BCP hist_schema=$SNAP_SCH articles=$SNAP_ARTS gen=$(bucket "$gen")"
    rawlog "snap $pub gen_ms=$gen files=[$SNAP_FILES] $info"
    local list=("$@")
    if [ "${#DELIV_DBS[@]}" -gt 0 ]; then list=("${DELIV_DBS[@]}"); fi
    for db in "${list[@]}"; do
        d=$(delivered "$db" "$SNAP_MARK")
        SNAP_INFO+=" delivered($db)=$d"
        if [[ $d == *no_delivery* ]]; then
            rawlog "no delivery to $db since $SNAP_MARK, its agent's lines: $(sq "SELECT CONVERT(nvarchar(4000), LEFT(ISNULL(STRING_AGG(CONVERT(nvarchar(max), CONCAT(CONVERT(varchar(23), h.time, 121), N' ', h.runstatus, N' ', CONVERT(nvarchar(300), h.comments))), N' ~ ') WITHIN GROUP (ORDER BY h.timestamp), N'none'), 4000)) FROM distribution.dbo.MSdistribution_history h JOIN distribution.dbo.MSdistribution_agents a ON a.id = h.agent_id WHERE a.subscriber_db = N'$db' AND a.subscriber_id >= 0 AND h.time >= DATEADD(minute, -2, CONVERT(datetime2, '$SNAP_MARK'))")"
        fi
    done
    DELIV_DBS=()
}
DELIV_DBS=()

# Writer analysis of RUN against the last snap: sets W_DETAIL.
wdetail() { # RUN
    local s line t ms so eo n e t1=none t2=none s1 e1 s2 e2
    s=$(wstats "$1" "$SNAP_MARK")
    rawlog "writers $1 gen=[$SNAP_START,$SNAP_END] $s"
    W_DETAIL=""
    W_T1=none; W_T2=none; W_MAX=0
    if [ "$s" = none ]; then W_DETAIL=" writers=none"; return 0; fi
    IFS=';' read -r -a parts <<<"$s"
    for line in "${parts[@]}"; do
        read -r t ms so eo n e <<<"$line"
        W_DETAIL+=" w_$t=$(bucket "$ms")"
        if [ "$e" != 0 ]; then W_DETAIL+="(errors)"; fi
        if [ "$t" = m_t1 ]; then t1=$ms; s1=$so; e1=$eo; fi
        if [ "$t" = m_t2 ]; then t2=$ms; s2=$so; e2=$eo; fi
    done
    W_DETAIL+=" t2_vs_t1=$(compare "$t1" "$t2")"
    if [ "$t1" = none ] || [ "$t2" = none ] || (( t1 < 1000 || t2 < 1000 )); then
        W_DETAIL+=" overlap_t1_t2=n/a t1_ends_at_gen_end=n/a"
    else
        local lo=$(( s1 > s2 ? s1 : s2 )) hi=$(( e1 < e2 ? e1 : e2 ))
        W_DETAIL+=" overlap_t1_t2=$( (( lo < hi )) && echo yes || echo no )"
        if [ "$SNAP_END" != none ]; then
            local dd=$(( e1 - SNAP_END )); dd=${dd#-}
            W_DETAIL+=" t1_ends_at_gen_end=$( (( dd <= 500 )) && echo yes || echo no )"
        fi
    fi
    W_T1=$t1; W_T2=$t2
    W_MAX=$(printf '%s\n' "${parts[@]}" | awk '{ if ($2 > m) m = $2 } END { print m + 0 }')
}

cleaned=0
cleanup() {
    [ "$cleaned" = 1 ] && return
    cleaned=1
    [ -n "${wdpid:-}" ] && kill "$wdpid" 2>/dev/null
    if [ -f "$memflag" ]; then
        local why cp t=0
        why=$(cat "$memflag")
        echo "15-snapshot-scope: MEMORY TROUBLE: $why; stopping the m_ agents and tearing down, within 300 s" >&2
        ( teardown ) &
        cp=$!
        while kill -0 "$cp" 2>/dev/null && (( t < 300 )); do sleep 5; t=$(( t + 5 )); done
        if kill -0 "$cp" 2>/dev/null; then
            kill_tree "$cp"; kill -TERM "$cp" 2>/dev/null || true
            echo "15-snapshot-scope: MEMORY TROUBLE: the teardown did not end within 300 s; m_ objects are left and the lab needs a restart" >&2
        fi
        rm -rf "$tmp"
        echo "15-snapshot-scope: MEMORY TROUBLE: $why" >&2
        return
    fi
    teardown
}
teardown() {
    sql -Q "SET NOCOUNT ON; IF DB_ID(N'm_w') IS NOT NULL UPDATE m_w.dbo.ctl SET stop = 1" </dev/null >&2 2>&1 || true
    local p; for p in "${wpids[@]}"; do wait "$p" 2>/dev/null || true; done
    stop_m_agents
    purge_stopped_orphans "$mark"
    sql -d Sales -Q "SET NOCOUNT ON;
DECLARE @p sysname;
DECLARE c CURSOR LOCAL FOR SELECT name FROM dbo.syspublications WHERE name LIKE N'm\_%' ESCAPE N'\';
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
DROP VIEW IF EXISTS dbo.m_v1;
DROP PROCEDURE IF EXISTS dbo.m_f1;
DROP TABLE IF EXISTS dbo.m_t1, dbo.m_t2, dbo.m_t3, dbo.m_t4, dbo.m_t5, dbo.m_t6;" </dev/null >&2 || true
    sql -Q "SET NOCOUNT ON;
DECLARE @d sysname, @s nvarchar(400);
DECLARE c CURSOR LOCAL FOR SELECT name FROM sys.databases WHERE name LIKE N'm\_%' ESCAPE N'\';
OPEN c; FETCH NEXT FROM c INTO @d;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @s = N'ALTER DATABASE ' + QUOTENAME(@d) + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE ' + QUOTENAME(@d) + N';';
    BEGIN TRY EXEC (@s); END TRY BEGIN CATCH PRINT ERROR_MESSAGE(); END CATCH;
    FETCH NEXT FROM c INTO @d;
END;
CLOSE c; DEALLOCATE c;" </dev/null >&2 || true
    podman exec repllab find "$unc" -mindepth 1 -maxdepth 1 -iname '*_m_*' -exec rm -rf {} + >&2 || true
    rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 1' TERM INT
libsh=$(cd "$(dirname "$0")/.." && pwd)/lib.sh
errlog_lines=$(podman exec repllab sh -c 'wc -l < /var/opt/mssql/log/errorlog')
watchdog "$$" "$errlog_lines" &
wdpid=$!

# Leftovers of an earlier run fail this run (the trap removes them).
left=$(sql_value "SELECT (SELECT COUNT(*) FROM Sales.dbo.syspublications WHERE name LIKE N'm\_%' ESCAPE N'\') + (SELECT COUNT(*) FROM sys.databases WHERE name LIKE N'm\_%' ESCAPE N'\') + (SELECT COUNT(*) FROM Sales.sys.objects WHERE name LIKE N'm\_%' ESCAPE N'\')")
left_files=$(podman exec repllab find "$unc" -mindepth 1 -maxdepth 1 -iname '*_m_*')
if [ "$left" != 0 ] || [ -n "$left_files" ]; then
    echo "15-snapshot-scope: leftovers of an earlier run (objects=$left files=$left_files); removing them and failing" >&2
    exit 1
fi
rawlog "=== 15-snapshot-scope $(date -u +%FT%TZ)"
start_s=$SECONDS

# Setup: tables, databases, publications.
sql -b <<'SQL' >&2
SET NOCOUNT ON;
USE Sales;
CREATE TABLE dbo.m_t1 (id int PRIMARY KEY, a int, b int, pad char(100) NOT NULL DEFAULT 'x');
INSERT dbo.m_t1 (id, a, b) SELECT TOP (1000000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), 1, 1 FROM sys.all_columns x CROSS JOIN sys.all_columns y;
CREATE TABLE dbo.m_t2 (id int PRIMARY KEY, a int, b int);
INSERT dbo.m_t2 SELECT TOP (100) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), 1, 1 FROM sys.all_columns;
CREATE TABLE dbo.m_t3 (id int PRIMARY KEY, a int, b int); INSERT dbo.m_t3 VALUES (1, 1, 1);
CREATE TABLE dbo.m_t4 (id int PRIMARY KEY, a int, b int); INSERT dbo.m_t4 VALUES (1, 1, 1);
CREATE TABLE dbo.m_t5 (id int PRIMARY KEY, a int, b int); INSERT dbo.m_t5 VALUES (1, 1, 1);
CREATE TABLE dbo.m_t6 (id int PRIMARY KEY, a int, b int); INSERT dbo.m_t6 VALUES (1, 1, 1);
CREATE DATABASE m_w;
GO
USE m_w;
CREATE TABLE dbo.wlog (run varchar(60), tbl sysname, spid int, t0 datetime2(3), t1 datetime2(3), ms int, err int NULL);
CREATE TABLE dbo.ctl (run varchar(60) PRIMARY KEY, stop bit);
GO
SQL

# pub NAME SYNC IMM ANON DB [ARTICLES]: a publication on m_t1 and m_t2 (or ARTICLES) with a
# push subscription to DB.
pub() {
    local name=$1 sync=$2 imm=$3 anon=$4 db=$5 arts=${6:-m_t1 m_t2} t adds=""
    for t in $arts; do adds+="EXEC sp_addarticle @publication = N'$name', @article = N'$t', @source_owner = N'dbo', @source_object = N'$t';
"; done
    sql -b -Q "SET NOCOUNT ON; CREATE DATABASE [$db];" </dev/null >&2
    sx "EXEC sp_addpublication @publication = N'$name', @status = N'active', @allow_push = N'true',
     @independent_agent = N'$imm', @immediate_sync = N'$imm', @allow_anonymous = N'$anon', @repl_freq = N'continuous', @sync_method = N'$sync';
EXEC sp_addpublication_snapshot @publication = N'$name', @frequency_type = 1, @active_start_date = 99991231,
     @job_login = NULL, @job_password = NULL, @publisher_security_mode = 1;
$adds
EXEC sp_addsubscription @publication = N'$name', @subscriber = N'$srv', @destination_db = N'$db',
     @subscription_type = N'Push', @sync_type = N'automatic', @article = N'all';
EXEC sp_addpushsubscription_agent @publication = N'$name', @subscriber = N'$srv', @subscriber_db = N'$db',
     @job_login = NULL, @job_password = NULL, @subscriber_security_mode = 1;"
}
initial() { # PUB DB: the first snapshot, generated and delivered.
    local m
    m=$(now)
    sx "EXEC sp_startpublication_snapshot @publication = N'$1'"
    wait_until 300 "$(done_query "$1" "$m")" || { echo "15-snapshot-scope: $1: initial snapshot not generated" >&2; exit 1; }
    wait_until 300 "$(delivered_query "$2" "$m")" || { echo "15-snapshot-scope: $1: initial snapshot not delivered to $2" >&2; exit 1; }
}
# droppub PUB DB...: stops the agents of PUB (its snapshot agent, the distribution agents of
# the DBs), drops its subscriptions and the publication, then the DBs and its folder. The
# script creates its publications per phase and drops them as soon as their cases are done:
# the agents run inside sqlservr and share its memory limit (MSSQL_MEMORY_LIMIT_MB = 4096),
# and the 26 continuous distribution agents of a first version, all alive at once, wedged
# the lab in its second run (error 701, logins refused, every query waiting on
# RESOURCE_SEMAPHORE_QUERY_COMPILE).
droppub() {
    local pub=$1 d i n=x jobs running
    shift
    jobs="SELECT CONVERT(uniqueidentifier, job_id) FROM distribution.dbo.MSsnapshot_agents WHERE publication = N'$pub' AND publisher_db = N'Sales' AND local_job = 1"
    for d in "$@"; do jobs+=" UNION SELECT CONVERT(uniqueidentifier, job_id) FROM distribution.dbo.MSdistribution_agents WHERE subscriber_db = N'$d' AND local_job = 1"; done
    running="FROM msdb.dbo.sysjobactivity ja WHERE ja.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions) AND ja.start_execution_date IS NOT NULL AND ja.stop_execution_date IS NULL AND ja.job_id IN ($jobs)"
    for i in $(seq 1 18); do
        n=$(sql_value "SELECT COUNT(*) $running")
        if [ "$n" = 0 ]; then break; fi
        # sp_stop_job on a job that has just ended prints its refusal past TRY: discarded.
        sql -Q "SET NOCOUNT ON; DECLARE @j uniqueidentifier; DECLARE c CURSOR LOCAL FOR SELECT ja.job_id $running;
OPEN c; FETCH NEXT FROM c INTO @j;
WHILE @@FETCH_STATUS = 0 BEGIN BEGIN TRY EXEC msdb.dbo.sp_stop_job @job_id = @j; END TRY BEGIN CATCH END CATCH; FETCH NEXT FROM c INTO @j; END;
CLOSE c; DEALLOCATE c;" </dev/null >/dev/null 2>&1 || true
        sleep 5
    done
    [ "$n" = 0 ] || { echo "15-snapshot-scope: droppub $pub: its agents still run after 90 s" >&2; exit 1; }
    sx "EXEC sp_dropsubscription @publication = N'$pub', @article = N'all', @subscriber = N'all';
EXEC sp_droppublication @publication = N'$pub';"
    for d in "$@"; do
        sql -b -Q "SET NOCOUNT ON; ALTER DATABASE [$d] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$d];" </dev/null >&2
    done
    podman exec repllab find "$unc" -mindepth 1 -maxdepth 1 -iname "*_SALES_$pub" -exec rm -rf {} + >&2 || true
}

# Phase 1 (A, C, D, E): the m_sc_ publications. One initial snapshot at a time
# (05-snapshot-flag saw one fail when run together).
for imm in imm non; do
    flag=false; [ "$imm" = imm ] && flag=true
    for m in $methods; do
        pub "m_sc_${imm}_$m" "$(syncval "$m")" "$flag" false "m_d_${imm}_$m"
        initial "m_sc_${imm}_$m" "m_d_${imm}_$m"
    done
done
rawlog "setup done after $(( SECONDS - start_s )) s"

# --- A: add m_t3 and generate, every sync_method, with and without immediate_sync.
for imm in imm non; do
    for m in $methods; do
        p=m_sc_${imm}_$m; db=m_d_${imm}_$m
        IFS='|' read -r add probe _ <<<"$(flags commit "$p" 2 "EXEC sp_addarticle @publication = N'$p', @article = N'm_t3', @source_owner = N'dbo', @source_object = N'm_t3', @force_invalidate_snapshot = @i;")"
        ext=auto
        if [ "$imm" = non ]; then
            case $m in
                concurrent|concurrent_c) ext="all:$(try "EXEC sp_addsubscription @publication = N'$p', @subscriber = N'$srv', @destination_db = N'$db', @subscription_type = N'Push', @sync_type = N'automatic', @article = N'all';")" ;;
                *) ext="m_t3:$(try "EXEC sp_addsubscription @publication = N'$p', @subscriber = N'$srv', @destination_db = N'$db', @subscription_type = N'Push', @sync_type = N'automatic', @article = N'm_t3';")"
                   if [ "$ext" != m_t3:ok ]; then
                       ext+=",all:$(try "EXEC sp_addsubscription @publication = N'$p', @subscriber = N'$srv', @destination_db = N'$db', @subscription_type = N'Push', @sync_type = N'automatic', @article = N'all';")"
                   fi ;;
            esac
        fi
        before=$(state "$p")
        snap "$p" "A.$imm.$m" "$db"
        wdetail "A.$imm.$m"
        after=$(state "$p")
        r "A.$imm.$m" "files=[$SNAP_FILES]" "add=$add probe=$probe extend=$ext before_run:$before $SNAP_INFO$W_DETAIL after_run:$after"
        if [ "$imm" = imm ] && [ "$m" = native ]; then A_NATIVE_T1=$W_T1; fi
        if [ "$m" = dbsnap ]; then eval "A_DBSNAP_MAX_$imm=$W_MAX"; fi
    done
done
rawlog "A done after $(( SECONDS - start_s )) s"
flush

# --- C: each invalidating operation on the immediate_sync publications, rolled back.
for m in $methods; do
    p=m_sc_imm_$m; db=m_d_imm_$m
    other=native; [ "$m" = native ] && other=concurrent
    ready0=$(sq "SELECT CONVERT(nvarchar(5), immediate_sync_ready) FROM dbo.syspublications WHERE name = N'$p'")
    while IFS='~' read -r op cells stmt; do
        IFS='|' read -r res probe st <<<"$(flags probe "$p" "$cells" "$stmt")"
        r "C.$m.$op" "$res" "ready_before=$ready0 probe=$probe in_tran:${st:-none}"
    done <<EOF
addarticle~2~EXEC sp_addarticle @publication = N'$p', @article = N'm_t4', @source_owner = N'dbo', @source_object = N'm_t4', @force_invalidate_snapshot = @i;
droparticle~2~EXEC sp_dropsubscription @publication = N'$p', @article = N'm_t2', @subscriber = N'$srv', @destination_db = N'$db'; EXEC sp_droparticle @publication = N'$p', @article = N'm_t2', @force_invalidate_snapshot = @i;
schema_option~4~EXEC sp_changearticle @publication = N'$p', @article = N'm_t1', @property = N'schema_option', @value = N'0x0000000000030077', @force_invalidate_snapshot = @i, @force_reinit_subscription = @r;
sync_method~4~EXEC sp_changepublication @publication = N'$p', @property = N'sync_method', @value = N'$other', @force_invalidate_snapshot = @i, @force_reinit_subscription = @r;
alt_snapshot_folder~4~EXEC sp_changepublication @publication = N'$p', @property = N'alt_snapshot_folder', @value = N'/var/opt/mssql/data/ReplAlt', @force_invalidate_snapshot = @i, @force_reinit_subscription = @r;
articlefilter~4~EXEC sp_articlefilter @publication = N'$p', @article = N'm_t1', @filter_name = N'm_f1', @filter_clause = N'a > 0', @force_invalidate_snapshot = @i, @force_reinit_subscription = @r;
articleview~4~EXEC sp_articleview @publication = N'$p', @article = N'm_t1', @view_name = N'm_v1', @filter_clause = N'a > 0', @force_invalidate_snapshot = @i, @force_reinit_subscription = @r;
articlecolumn~4~EXEC sp_articlecolumn @publication = N'$p', @article = N'm_t1', @column = N'b', @operation = N'drop', @force_invalidate_snapshot = @i, @force_reinit_subscription = @r;
immediate_sync_false~4~EXEC sp_changepublication @publication = N'$p', @property = N'immediate_sync', @value = N'false', @force_invalidate_snapshot = @i, @force_reinit_subscription = @r;
EOF
done
rawlog "C done after $(( SECONDS - start_s )) s"
flush
for m in character concurrent_c dbsnap; do droppub "m_sc_imm_$m" "m_d_imm_$m"; done
droppub m_sc_non_concurrent_c m_d_non_concurrent_c
droppub m_sc_non_dbsnap m_d_non_dbsnap

# --- D: extending a subscription that a reinit-flagged change has just marked. The change
# is sp_changearticle schema_option on m_t1. The sync_method change within the same family
# is probed too (rolled back): on native it needs no flag and marks nothing. The imm_
# variants run the same steps on the immediate_sync publications, where sp_addarticle
# extends the subscription by itself: they try to reproduce the 14058 and 14100 refusals
# of the review of e220523. Nothing is asserted on D.
for v in non_native non_concurrent imm_native imm_concurrent; do
    p=m_sc_$v; db=m_d_$v; m=${v#*_}
    if [ "$m" = native ]; then to=character; art=m_t4; else to=concurrent_c; art=all; fi
    IFS='|' read -r res probe st <<<"$(flags probe "$p" 4 "EXEC sp_changepublication @publication = N'$p', @property = N'sync_method', @value = N'$to', @force_invalidate_snapshot = @i, @force_reinit_subscription = @r;")"
    r "D.$v.sync_method_probe" "$res" "sync_method=$to probe=$probe in_tran:$st"
    so=$(sq "SELECT CONVERT(varchar(20), a.schema_option, 1) FROM dbo.sysarticles a JOIN dbo.syspublications p ON p.pubid = a.pubid WHERE p.name = N'$p' AND a.name = N'm_t1'")
    alt=0x0000000000030077; [ "${so^^}" = 0X0000000000030077 ] && alt=0x0000000000030073
    schema() { echo "EXEC sp_changearticle @publication = N'$p', @article = N'm_t1', @property = N'schema_option', @value = N'$1', @force_invalidate_snapshot = @i, @force_reinit_subscription = @r;"; }
    IFS='|' read -r res probe _ <<<"$(flags commit "$p" 4 "$(schema "$alt")")"
    r "D.$v.change" "$res" "schema_option=changed probe=$probe after:$(state "$p")"
    IFS='|' read -r res probe _ <<<"$(flags commit "$p" 2 "EXEC sp_addarticle @publication = N'$p', @article = N'm_t4', @source_owner = N'dbo', @source_object = N'm_t4', @force_invalidate_snapshot = @i;")"
    r "D.$v.addarticle" "$res" "probe=$probe after:$(state "$p")"
    ext=$(try "EXEC sp_addsubscription @publication = N'$p', @subscriber = N'$srv', @destination_db = N'$db', @subscription_type = N'Push', @sync_type = N'automatic', @article = N'$art';")
    r "D.$v.extend_rule" "$ext" "article=$art after:$(state "$p")"
    ext_all=n/a
    if [ "$art" != all ] && [ "$ext" != ok ]; then
        ext_all=$(try "EXEC sp_addsubscription @publication = N'$p', @subscriber = N'$srv', @destination_db = N'$db', @subscription_type = N'Push', @sync_type = N'automatic', @article = N'all';")
        r "D.$v.extend_all" "$ext_all" "after:$(state "$p")"
    fi
    snap "$p" - "$db"
    r "D.$v.snapshot" "files=[$SNAP_FILES]" "$SNAP_INFO after:$(state "$p")"
    if [ "$ext" != ok ] && [ "$ext_all" != ok ]; then
        ext2=$(try "EXEC sp_addsubscription @publication = N'$p', @subscriber = N'$srv', @destination_db = N'$db', @subscription_type = N'Push', @sync_type = N'automatic', @article = N'$art';")
        r "D.$v.extend_after_snapshot" "$ext2" "article=$art after:$(state "$p")"
        snap "$p" - "$db"
        r "D.$v.snapshot2" "files=[$SNAP_FILES]" "$SNAP_INFO after:$(state "$p")"
    fi
    # The other order: addition and extension first, then the reinit-flagged change back.
    IFS='|' read -r add probe _ <<<"$(flags commit "$p" 2 "EXEC sp_addarticle @publication = N'$p', @article = N'm_t5', @source_owner = N'dbo', @source_object = N'm_t5', @force_invalidate_snapshot = @i;")"
    art5=m_t5; [ "$art" = all ] && art5=all
    ext5=$(try "EXEC sp_addsubscription @publication = N'$p', @subscriber = N'$srv', @destination_db = N'$db', @subscription_type = N'Push', @sync_type = N'automatic', @article = N'$art5';")
    IFS='|' read -r res probe2 _ <<<"$(flags commit "$p" 4 "$(schema "$so")")"
    r "D.$v.extend_then_change" "add=$add,extend=$ext5,change=$res" "article=$art5 probe_add=$probe probe_change=$probe2 after:$(state "$p")"
    snap "$p" - "$db"
    r "D.$v.snapshot3" "files=[$SNAP_FILES]" "$SNAP_INFO after:$(state "$p")"
done
rawlog "D done after $(( SECONDS - start_s )) s"
flush
for m in native concurrent; do droppub "m_sc_imm_$m" "m_d_imm_$m"; done

# --- E: what sets the article's active bit and the subscription status, the generation or
# the delivery: m_t4 added to m_sc_non_character while its distribution agent is disabled
# and stopped, generated, read, then the agent enabled and the delivery read.
p=m_sc_non_character; db=m_d_non_character
djob="(SELECT CONVERT(uniqueidentifier, job_id) FROM distribution.dbo.MSdistribution_agents WHERE subscriber_db = N'$db' AND subscriber_id >= 0)"
drunning="SELECT CASE WHEN EXISTS (SELECT 1 FROM msdb.dbo.sysjobactivity WHERE job_id = $djob AND session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions) AND start_execution_date IS NOT NULL AND stop_execution_date IS NULL) THEN 1 ELSE 0 END"
sx "DECLARE @j uniqueidentifier = $djob; EXEC msdb.dbo.sp_update_job @job_id = @j, @enabled = 0;"
if [ "$(sql_value "$drunning")" = 1 ]; then
    # sp_stop_job on a job that has just ended prints its refusal past TRY: discarded,
    # the wait below decides (as in 05-snapshot-flag).
    sql -Q "SET NOCOUNT ON; DECLARE @j uniqueidentifier = $djob; BEGIN TRY EXEC msdb.dbo.sp_stop_job @job_id = @j; END TRY BEGIN CATCH END CATCH" </dev/null >/dev/null 2>&1 || true
fi
wait_until 120 "SELECT 1 - ($drunning)" || { echo "15-snapshot-scope: E: the distribution job of $db still runs" >&2; exit 1; }
IFS='|' read -r add probe _ <<<"$(flags commit "$p" 2 "EXEC sp_addarticle @publication = N'$p', @article = N'm_t4', @source_owner = N'dbo', @source_object = N'm_t4', @force_invalidate_snapshot = @i;")"
ext=$(try "EXEC sp_addsubscription @publication = N'$p', @subscriber = N'$srv', @destination_db = N'$db', @subscription_type = N'Push', @sync_type = N'automatic', @article = N'm_t4';")
r E.extended "add=$add,extend=$ext" "agent=stopped after:$(state "$p")"
DELIV_DBS=("$db")
snap "$p" -
r E.generated_undelivered "files=[$SNAP_FILES]" "agent=stopped $SNAP_INFO after:$(state "$p")"
sx "DECLARE @j uniqueidentifier = $djob; EXEC msdb.dbo.sp_update_job @job_id = @j, @enabled = 1; EXEC msdb.dbo.sp_start_job @job_id = @j;"
wait_until 150 "$(delivered_query "$db" "$SNAP_MARK")" || true
r E.delivered "$(delivered "$db" "$SNAP_MARK")" "agent=started after:$(state "$p")"
rawlog "E done after $(( SECONDS - start_s )) s"
flush
for m in native concurrent character; do droppub "m_sc_non_$m" "m_d_non_$m"; done

# --- F: writes to a new article and its delivery under database snapshot. m_t6 added to
# m_fx_<variant> (no immediate_sync, article m_t2) and extended, then one run of the agent:
# before, one UPDATE of m_t6 committed 5 s before the start; during, ten UPDATEs of m_t6, one
# every 0.5 s from the start; none, no write; native_before, the before case under native.
f_during() {
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        sql -b -Q "SET NOCOUNT ON; UPDATE Sales.dbo.m_t6 SET a = a + 1 WHERE id = 1" </dev/null >&2
        sleep 0.5
    done
}
for v in $fx; do
    sync=database\ snapshot; [[ $v == native_* ]] && sync=native
    pub "m_fx_$v" "$sync" false false "m_f_$v" m_t2
    initial "m_fx_$v" "m_f_$v"
done
for v in $fx; do
    p=m_fx_$v; db=m_f_$v
    IFS='|' read -r add probe _ <<<"$(flags commit "$p" 2 "EXEC sp_addarticle @publication = N'$p', @article = N'm_t6', @source_owner = N'dbo', @source_object = N'm_t6', @force_invalidate_snapshot = @i;")"
    ext=$(try "EXEC sp_addsubscription @publication = N'$p', @subscriber = N'$srv', @destination_db = N'$db', @subscription_type = N'Push', @sync_type = N'automatic', @article = N'm_t6';")
    case $v in
        *_before) sx "UPDATE dbo.m_t6 SET a = a + 1 WHERE id = 1"; sleep 5; snap "$p" - "$db" ;;
        *_during) RACE=f_during snap "$p" - "$db" ;;
        *) snap "$p" - "$db" ;;
    esac
    r "F.$v" "$(delivered "$db" "$SNAP_MARK")" "add=$add extend=$ext files=[$SNAP_FILES] after:$(state "$p")"
done
rawlog "F done after $(( SECONDS - start_s )) s"
flush
for v in $fx; do droppub "m_fx_$v" "m_f_$v"; done

# Phase 3 (B): the m_df_ publications.
for p in $df_pubs; do
    sfx=${p#m_df_}
    anon=false; [[ $p == *_anon ]] && anon=true
    method=${sfx%_*}
    pub "$p" "$method" true "$anon" "m_e_$sfx"
    [[ $p == *_race ]] || sql -b -Q "SET NOCOUNT ON; CREATE DATABASE [m_l_$sfx];" </dev/null >&2
    initial "$p" "m_e_$sfx"
done

# --- B: the deferred sequence.
step() { # ID PUB CELLS STMT: commit with the flags it needs, ready before, state after.
    local before res probe
    before=$(sq "SELECT CONVERT(nvarchar(5), immediate_sync_ready) FROM dbo.syspublications WHERE name = N'$2'")
    IFS='|' read -r res probe _ <<<"$(flags commit "$2" "$3" "$4")"
    r "$1" "$res" "ready_before=$before probe=$probe after:$(state "$2")"
}
chpub() { # PUB PROPERTY VALUE
    echo "EXEC sp_changepublication @publication = N'$1', @property = N'$2', @value = N'$3', @force_invalidate_snapshot = @i, @force_reinit_subscription = @r;"
}
# The restore of the race, run right after the agent starts.
race_restore() { flags commit "$RACE_PUB" 4 "$(chpub "$RACE_PUB" immediate_sync true)"; }
for p in $df_pubs; do
    sfx=${p#m_df_}; e=m_e_$sfx; l=m_l_$sfx
    method=${sfx%_*}
    art=m_t3; [ "$method" = concurrent ] && art=all
    r "B.$sfx.0" "start" "$(state "$p")"
    [[ $p == *_anon ]] && step "B.$sfx.1a" "$p" 4 "$(chpub "$p" allow_anonymous false)"
    step "B.$sfx.1b" "$p" 4 "$(chpub "$p" immediate_sync false)"
    step "B.$sfx.2a" "$p" 2 "EXEC sp_addarticle @publication = N'$p', @article = N'm_t3', @source_owner = N'dbo', @source_object = N'm_t3', @force_invalidate_snapshot = @i;"
    ext=$(try "EXEC sp_addsubscription @publication = N'$p', @subscriber = N'$srv', @destination_db = N'$e', @subscription_type = N'Push', @sync_type = N'automatic', @article = N'$art';")
    r "B.$sfx.2b" "$ext" "article=$art after:$(state "$p")"
    if [[ $p == *_race ]]; then
        RACE_PUB=$p RACE=race_restore snap "$p" - "$e"
        IFS='|' read -r res probe _ <<<"$RACE_OUT"
        r "B.$sfx.race" "files=[$SNAP_FILES]" "restore=$res probe=$probe $SNAP_INFO after:$(state "$p")"
        continue
    fi
    snap "$p" - "$e"
    r "B.$sfx.3" "files=[$SNAP_FILES]" "$SNAP_INFO after:$(state "$p")"
    step "B.$sfx.4a" "$p" 4 "$(chpub "$p" immediate_sync true)"
    [[ $p == *_anon ]] && step "B.$sfx.4b" "$p" 4 "$(chpub "$p" allow_anonymous true)"
    ext=$(try "EXEC sp_addsubscription @publication = N'$p', @subscriber = N'$srv', @destination_db = N'$l', @subscription_type = N'Push', @sync_type = N'automatic', @article = N'all';
EXEC sp_addpushsubscription_agent @publication = N'$p', @subscriber = N'$srv', @subscriber_db = N'$l', @job_login = NULL, @job_password = NULL, @subscriber_security_mode = 1;")
    r "B.$sfx.5a" "$ext" "after:$(state "$p")"
    DELIV_DBS=("$l" "$e")
    snap "$p" - "$l"
    r "B.$sfx.5b" "files=[$SNAP_FILES]" "$SNAP_INFO after:$(state "$p")"
done
rawlog "B done after $(( SECONDS - start_s )) s"
flush

# Controls.
# Failures are said last, so that campaign.sh's log tail shows them.
bad=0; fails=()
control() { fails+=("15-snapshot-scope: control failed: $*"); bad=1; }
field() { printf '%s\n' "${rows[@]}" | awk -F'|' -v id="$1" -v n="$2" '$2 == id { print $n }'; }
d=$(field A.imm.native 4)
[[ $d == *" t2_vs_t1=similar "* ]] || control "A.imm.native: the m_t2 writer does not wait like the m_t1 writer: $d"
[ "${A_NATIVE_T1:-0}" != none ] && (( ${A_NATIVE_T1:-0} >= 250 )) || control "A.imm.native: the m_t1 writer waited under 250 ms: $d"
for imm in imm non; do
    v=A_DBSNAP_MAX_$imm
    (( ${!v:-99999} < 1000 )) || control "A.$imm.dbsnap: a writer waited ${!v:-?} ms, not under one second"
done
for sfx in native_anon native_noanon concurrent_anon concurrent_noanon; do
    [ "$(field "B.$sfx.3" 3)" = "files=[m_t3]" ] || control "B.$sfx.3 generated $(field "B.$sfx.3" 3), expected files=[m_t3]"
    last=4a; [[ $sfx == *_anon ]] && last=4b
    d=$(field "B.$sfx.$last" 4)
    [[ $d =~ subs=\[([^]]*)\] ]] || { control "B.$sfx.$last: no subscription list: $d"; continue; }
    s=${BASH_REMATCH[1]}
    notactive=$(printf '%s\n' "$s" | tr ',' '\n' | grep -v '=2$' || true)
    [ -n "$s" ] && [ -z "$notactive" ] || control "B.$sfx.$last: a subscription is not active after the restore: $s"
done
rawlog "total $(( SECONDS - start_s )) s"
flush
if [ "$bad" != 0 ]; then
    for f in "${fails[@]}"; do echo "$f" >&2; done
    exit 1
fi
cleanup
echo "R|TOTAL|${#rows[@]}"
