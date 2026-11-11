#!/bin/bash
# What the structural operations of the planner do on each publication kind
# (campaign items 2, 3 and 4; docs/analysis/step-1-analysis.md section 9). Run through
# lab/campaign.sh.
#
# Four kinds of publication on the tables m_t1, m_t2 (and m_t3 for C4) of Sales, each
# with a push subscription to the database m_sub and a delivered snapshot:
#   imm-conc      immediate_sync = 1, sync_method = concurrent, own distribution agent
#   imm-native    immediate_sync = 1, sync_method = native
#   nonimm-conc   immediate_sync = 0, sync_method = concurrent, shared agent ('ALL')
#   nonimm-native immediate_sync = 0, sync_method = native
# Five cases, each built fresh on each kind and committed (what the agents do after the
# change is the outcome):
#   C1 sp_dropsubscription @article = 'all': result, subscription rows, agent row and job left
#   C2 sp_dropsubscription @article = 'm_t2' then sp_droparticle m_t2
#   C3 C2 then sp_addarticle m_t2 again, extended as C4 says, snapshot started and
#      delivered: tables bulk copied, status of the m_t2 subscription, rows of m_t2 at
#      the subscriber (before and after), whether the marker of m_t1 survives
#   C4 sp_addarticle m_t3 and extension of the subscription (imm kinds: nothing, the
#      subscription is extended at once, lab row 9; nonimm-native sp_addsubscription
#      @article = 'm_t3'; nonimm-conc @article = 'all'), snapshot started and delivered:
#      tables bulk copied, whether a marker row inserted at the subscriber in m_t1
#      before the extension survives
#   C5 sp_droppublication after sp_dropsubscription all: result, 18752 (the log reader
#      message) seen or not
# Flags, from 05-snapshot-flag (lab/results/2022/05-snapshot-flag.txt):
# @force_invalidate_snapshot = immediate_sync_ready, read just before the call;
# @force_reinit_subscription (a status 2 article) is taken by none of the procedures
# called here. Every row records ready= and the flags passed. A call refused with the
# flags the rule gives is a finding and is recorded, not retried.
# The script asserts the Step 3 controls (C1 leaves 0 rows on every kind; C4 on
# nonimm-conc bulk copies m_t3 only and the marker survives) and exits 1 on a
# mismatch, printing its rows on stderr as "row: ...". 20 rows.
# Debugging only: M_ONLY='C3.imm-native C4.nonimm-conc' runs those rows alone (no controls, and the run exits 1 so that it is never accepted).
set -euo pipefail
shopt -s extglob
. "$(dirname "$0")/../lib.sh"
mark=$(sql_value "SELECT CONVERT(nvarchar(30), SYSDATETIME(), 121)")

kinds="imm-conc imm-native nonimm-conc nonimm-native"
cases="C1 C2 C3 C4 C5"
pubs="m_pic m_pin m_pnc m_pnn"

rows=()
r() { rows+=("R|$1|$2|$3"); }

# The last line of what a batch prints, which must be a word or a number optionally
# followed by /number parts (an informational line taken for a result is refused).
last() {
    local out
    out=$(sql -b -h -1 -Q "SET NOCOUNT ON; $1" </dev/null 2>&1) || { printf '%s\n' "$out" >&2; return 1; }
    out=$(printf '%s\n' "$out" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' | tail -n 1)
    [[ $out =~ ^[0-9a-z]+(/-?[0-9]+)*$ ]] || { printf 'last: unexpected value: %s\n' "$out" >&2; return 1; }
    printf '%s\n' "$out"
}

# try STATEMENTS : runs them in Sales outside a transaction, prints ok or the error
# number; a refused replication procedure leaves its transaction open, so it is rolled back.
try() {
    last "USE Sales; DECLARE @e nvarchar(10) = N'ok';
BEGIN TRY $1 END TRY
BEGIN CATCH SET @e = CONVERT(nvarchar(10), ERROR_NUMBER()); WHILE @@TRANCOUNT > 0 ROLLBACK; END CATCH;
SELECT @e"
}

teardown() { # PUB : everything of one publication, and the subscriber database
    stop_m_agents
    purge_stopped_orphans "$mark"
    sql -Q "SET NOCOUNT ON; USE Sales;
BEGIN TRY IF EXISTS (SELECT 1 FROM dbo.syspublications WHERE name = N'$1')
    EXEC sp_dropsubscription @publication = N'$1', @article = N'all', @subscriber = N'all'; END TRY BEGIN CATCH END CATCH;
BEGIN TRY IF EXISTS (SELECT 1 FROM dbo.syspublications WHERE name = N'$1')
    EXEC sp_droppublication @publication = N'$1'; END TRY BEGIN CATCH END CATCH;
IF DB_ID(N'm_sub') IS NOT NULL
BEGIN
    ALTER DATABASE m_sub SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE m_sub;
END" </dev/null >&2 || true
    podman exec repllab find /var/opt/mssql/data/ReplData/unc -mindepth 1 -maxdepth 1 -iname '*_m_*' -exec rm -rf {} + >&2 || true
}

cleaned=0
cleanup() {
    [ "$cleaned" = 1 ] && return
    cleaned=1
    for p in $pubs; do teardown "$p"; done
    sql -Q "SET NOCOUNT ON; USE Sales; DROP TABLE IF EXISTS dbo.m_t1, dbo.m_t2, dbo.m_t3" </dev/null >&2 || true
}
trap cleanup EXIT

# Leftovers of an earlier run are not absorbed: they fail this run (the exit guard),
# and the trap removes them.
left=$(sql_value "SELECT (SELECT COUNT(*) FROM Sales.dbo.syspublications WHERE name LIKE N'm\_p__' ESCAPE N'\') + (SELECT COUNT(*) FROM sys.databases WHERE name = N'm_sub') + (SELECT COUNT(*) FROM Sales.sys.objects WHERE name LIKE N'm\_%' ESCAPE N'\')") \
    || exit 1
left_files=$(podman exec repllab find /var/opt/mssql/data/ReplData/unc -mindepth 1 -maxdepth 1 -iname '*_m_*')
if [ "$left" != 0 ] || [ -n "$left_files" ]; then
    echo "06-structural: leftovers of an earlier run (objects=$left files=$left_files); removing them and failing" >&2
    exit 1
fi

sql -Q "SET NOCOUNT ON; USE Sales;
CREATE TABLE dbo.m_t1 (id int PRIMARY KEY, a int); CREATE TABLE dbo.m_t2 (id int PRIMARY KEY, a int); CREATE TABLE dbo.m_t3 (id int PRIMARY KEY, a int)" </dev/null

# Per kind: pub, imm, sm, and the call that extends the subscription to the article ART.
set_kind() { # KIND
    kind=$1
    case $kind in
        imm-conc)      pub=m_pic; imm=true;  sm=concurrent ;;
        imm-native)    pub=m_pin; imm=true;  sm=native ;;
        nonimm-conc)   pub=m_pnc; imm=false; sm=concurrent ;;
        nonimm-native) pub=m_pnn; imm=false; sm=native ;;
    esac
}
extend_sql() { # ART : the extension call of the kind, empty when the subscription extends itself
    case $kind in
        imm-*) echo "" ;;
        nonimm-native) echo "EXEC sp_addsubscription @publication = N'$pub', @subscriber = @@SERVERNAME, @destination_db = N'm_sub', @article = N'$1';" ;;
        nonimm-conc) echo "EXEC sp_addsubscription @publication = N'$pub', @subscriber = @@SERVERNAME, @destination_db = N'm_sub', @article = N'all';" ;;
    esac
}
agent_pred() { # the distribution agent of the subscription to m_sub
    case $kind in
        imm-*) echo "a.publication = N'$pub' AND a.subscriber_db = N'm_sub'" ;;
        nonimm-*) echo "a.publication = N'ALL' AND a.subscriber_db = N'm_sub'" ;;
    esac
}

# The snapshot of the publication, started after MARK, has finished and the distribution
# agent delivered it.
snapshot_done() { # MARK
    wait_until 300 "SELECT CASE WHEN EXISTS (SELECT 1 FROM distribution.dbo.MSsnapshot_history h JOIN distribution.dbo.MSsnapshot_agents a ON a.id = h.agent_id WHERE a.publication = N'$pub' AND h.time >= '$1' AND h.runstatus = 2)
        AND EXISTS (SELECT 1 FROM distribution.dbo.MSdistribution_history h JOIN distribution.dbo.MSdistribution_agents a ON a.id = h.agent_id WHERE $(agent_pred) AND h.time >= '$1' AND h.comments LIKE N'Delivered snapshot%') THEN 1 ELSE 0 END"
}
bulk_tables() { # MARK : tables bulk copied to m_sub since MARK, sorted, space separated
    sql_value "SELECT ISNULL(STRING_AGG(CONVERT(nvarchar(4000), t), ' ') WITHIN GROUP (ORDER BY t), 'none') FROM (SELECT DISTINCT SUBSTRING(h.comments, 30, CHARINDEX('''', h.comments, 30) - 30) AS t FROM distribution.dbo.MSdistribution_history h JOIN distribution.dbo.MSdistribution_agents a ON a.id = h.agent_id WHERE $(agent_pred) AND h.time >= '$1' AND h.comments LIKE N'Bulk copied data into table ''%') x"
}
now() { sql_value "SELECT CONVERT(varchar(23), SYSDATETIME(), 121)"; }
ready() { sql_value "SELECT ISNULL((SELECT CONVERT(nvarchar(10), immediate_sync_ready) FROM Sales.dbo.syspublications WHERE name = N'$pub'), N'none')"; }
art_status() { # ARTICLE : statuses of its subscription to m_sub, or none
    sql_value "SELECT ISNULL((SELECT STRING_AGG(CONVERT(nvarchar(10), s.status), N'/') FROM Sales.dbo.syssubscriptions s JOIN Sales.dbo.sysarticles a ON a.artid = s.artid JOIN Sales.dbo.syspublications p ON p.pubid = a.pubid WHERE p.name = N'$pub' AND a.name = N'$1' AND s.srvid >= 0), N'none')"
}
sub_rows() { # all subscription rows of the publication
    sql_value "SELECT COUNT(*) FROM Sales.dbo.syssubscriptions s JOIN Sales.dbo.sysarticles a ON a.artid = s.artid JOIN Sales.dbo.syspublications p ON p.pubid = a.pubid WHERE p.name = N'$pub' AND s.srvid >= 0"
}
sub_count() { # TABLE : rows of the table at the subscriber, absent when it does not exist
    local p
    p=$(sql_value "SELECT CASE WHEN OBJECT_ID(N'm_sub.dbo.$1') IS NULL THEN N'absent' ELSE N'present' END") || return 1
    if [ "$p" = absent ]; then echo absent; else sql_value "SELECT COUNT(*) FROM m_sub.dbo.$1"; fi
}

# Builds the publication of the kind with a delivered snapshot and an active push
# subscription to m_sub. The snapshot agent gets a schedule that never fires; snapshots
# run only when this script starts them.
build() { # KIND
    set_kind "$1"
    local mark
    mark=$(now)
    sql <<SQL
SET NOCOUNT ON;
USE Sales;
DELETE dbo.m_t1; DELETE dbo.m_t2; DELETE dbo.m_t3;
INSERT dbo.m_t1 VALUES (1, 1); INSERT dbo.m_t2 VALUES (1, 1); INSERT dbo.m_t3 VALUES (1, 1);
CREATE DATABASE m_sub;
GO
USE Sales;
DECLARE @srv sysname = @@SERVERNAME;
EXEC sp_addpublication @publication = N'$pub', @status = N'active', @allow_push = N'true',
     @independent_agent = N'$imm', @immediate_sync = N'$imm', @repl_freq = N'continuous', @sync_method = N'$sm';
EXEC sp_addpublication_snapshot @publication = N'$pub', @frequency_type = 1, @active_start_date = 99991231,
     @job_login = NULL, @job_password = NULL, @publisher_security_mode = 1;
EXEC sp_addarticle @publication = N'$pub', @article = N'm_t1', @source_owner = N'dbo', @source_object = N'm_t1';
EXEC sp_addarticle @publication = N'$pub', @article = N'm_t2', @source_owner = N'dbo', @source_object = N'm_t2';
EXEC sp_addsubscription @publication = N'$pub', @subscriber = @srv, @destination_db = N'm_sub',
     @subscription_type = N'Push', @sync_type = N'automatic', @article = N'all';
EXEC sp_addpushsubscription_agent @publication = N'$pub', @subscriber = @srv, @subscriber_db = N'm_sub',
     @job_login = NULL, @job_password = NULL, @subscriber_security_mode = 1;
EXEC sp_startpublication_snapshot @publication = N'$pub';
GO
SQL
    snapshot_done "$mark" || { echo "$kind: first snapshot not delivered" >&2; exit 1; }
    [ "$(sub_count m_t2)" = 1 ] || { echo "$kind: m_t2 not delivered to m_sub" >&2; exit 1; }
}

# Starts the snapshot and waits for its delivery; prints nothing.
snapshot_and_wait() { # MARK
    sql -Q "SET NOCOUNT ON; EXEC Sales.dbo.sp_startpublication_snapshot @publication = N'$pub'" </dev/null >&2
    snapshot_done "$1" || { echo "$kind: snapshot not delivered after $1" >&2; exit 1; }
}

want() { [ -z "${M_ONLY:-}" ] || [[ " $M_ONLY " == *" $1 "* ]]; }

c1() {
    local rd job res left_rows agents jobs
    rd=$(ready)
    job=$(sql_value "SELECT CONVERT(varchar(36), CONVERT(uniqueidentifier, a.job_id)) FROM distribution.dbo.MSdistribution_agents a WHERE $(agent_pred)")
    res=$(try "EXEC sp_dropsubscription @publication = N'$pub', @article = N'all', @subscriber = N'all';")
    left_rows=$(sub_rows)
    agents=$(sql_value "SELECT COUNT(*) FROM distribution.dbo.MSdistribution_agents a WHERE $(agent_pred)")
    jobs=$(sql_value "SELECT COUNT(*) FROM msdb.dbo.sysjobs WHERE job_id = '$job'")
    r "C1.$kind" "$res" "ready=$rd flags=none rows_left=$left_rows agent_rows_left=$agents agent_job_left=$jobs"
}

# Fails the run when a variable named in the arguments is empty: errexit does not reach
# into a $(...) that feeds a read, so an empty field must be refused here.
need() { local v; for v in "$@"; do [ -n "${!v}" ] || { echo "06-structural: empty field $v" >&2; exit 1; }; done; }

# The drop of m_t2 shared by C2 and C3; sets the globals rd st d rd2 inv d2: ready,
# art_status, dropsub result, ready before droparticle, flag passed, droparticle result.
drop_m_t2() {
    rd=$(ready); st=$(art_status m_t2)
    d=$(try "EXEC sp_dropsubscription @publication = N'$pub', @article = N'm_t2', @subscriber = @@SERVERNAME, @destination_db = N'm_sub';")
    rd2=$(ready); inv=$rd2; [ "$inv" = none ] && inv=0
    d2=$(try "EXEC sp_droparticle @publication = N'$pub', @article = N'm_t2', @force_invalidate_snapshot = $inv;")
    need rd st d rd2 inv d2
}

c2() {
    local arts subs
    drop_m_t2
    arts=$(sql_value "SELECT COUNT(*) FROM Sales.dbo.sysarticles a JOIN Sales.dbo.syspublications p ON p.pubid = a.pubid WHERE p.name = N'$pub'")
    subs=$(sub_rows)
    r "C2.$kind" "dropsub=$d,droparticle=$d2" "ready=$rd art_status=$st ready_before_droparticle=$rd2 flags=sp_droparticle:inv=$inv articles_left=$arts subscription_rows_left=$subs"
}

c3() {
    local mark add ext rd3 inv3 st_after st_end bulk before after marker pub_rows
    sql -Q "SET NOCOUNT ON; INSERT m_sub.dbo.m_t1 VALUES (99, 99)" </dev/null
    drop_m_t2
    if [ "$d" != ok ] || [ "$d2" != ok ]; then
        r "C3.$kind" "dropsub=$d,droparticle=$d2" "ready=$rd art_status=$st ready_before_droparticle=$rd2 flags=sp_droparticle:inv=$inv not re-added"
        return
    fi
    before=$(sub_count m_t2)
    sql -Q "SET NOCOUNT ON; INSERT Sales.dbo.m_t2 VALUES (2, 2)" </dev/null
    rd3=$(ready); inv3=$rd3; [ "$inv3" = none ] && inv3=0
    mark=$(now)
    add=$(try "EXEC sp_addarticle @publication = N'$pub', @article = N'm_t2', @source_owner = N'dbo', @source_object = N'm_t2', @force_invalidate_snapshot = $inv3;")
    ext=none
    local call; call=$(extend_sql m_t2)
    [ -n "$call" ] && ext=$(try "$call")
    st_after=$(art_status m_t2)
    snapshot_and_wait "$mark"
    bulk=$(bulk_tables "$mark")
    after=$(sub_count m_t2)
    st_end=$(art_status m_t2)
    marker=$(sql_value "SELECT COUNT(*) FROM m_sub.dbo.m_t1 WHERE id = 99")
    pub_rows=$(sql_value "SELECT COUNT(*) FROM Sales.dbo.m_t2")
    r "C3.$kind" "dropsub=$d,droparticle=$d2,addarticle=$add,extend=$ext" "ready=$rd art_status=$st flags=sp_droparticle:inv=$inv,sp_addarticle:inv=$inv3 ready_before_addarticle=$rd3 m_t2_status_before_snapshot=$st_after bulk=[$bulk] m_t2_status_after=$st_end subscriber_m_t2_rows=$before then $after (publisher has $pub_rows) m_t1_marker_survived=$marker"
}

c4() {
    local rd inv add ext call mark subs bulk marker m3 st
    rd=$(ready); inv=$rd; [ "$inv" = none ] && inv=0
    sql -Q "SET NOCOUNT ON; INSERT m_sub.dbo.m_t1 VALUES (99, 99)" </dev/null
    mark=$(now)
    add=$(try "EXEC sp_addarticle @publication = N'$pub', @article = N'm_t3', @source_owner = N'dbo', @source_object = N'm_t3', @force_invalidate_snapshot = $inv;")
    subs=$(art_status m_t3)
    ext=none
    call=$(extend_sql m_t3)
    [ -n "$call" ] && ext=$(try "$call")
    st=$(art_status m_t3)
    snapshot_and_wait "$mark"
    bulk=$(bulk_tables "$mark")
    marker=$(sql_value "SELECT COUNT(*) FROM m_sub.dbo.m_t1 WHERE id = 99")
    m3=$(sub_count m_t3)
    r "C4.$kind" "addarticle=$add,extend=$ext" "ready=$rd flags=sp_addarticle:inv=$inv m_t3_status_after_add=$subs m_t3_status_after_extension=$st bulk=[$bulk] marker_survived=$marker subscriber_m_t3_rows=$m3"
}

c5() {
    local rd d out drop err seen left agents jobs job djob
    rd=$(ready)
    job=$(sql_value "SELECT CONVERT(varchar(36), CONVERT(uniqueidentifier, a.job_id)) FROM distribution.dbo.MSdistribution_agents a WHERE $(agent_pred)")
    d=$(try "EXEC sp_dropsubscription @publication = N'$pub', @article = N'all', @subscriber = N'all';")
    # The output of sp_droppublication is read as text: an 18752 raised as an error is
    # caught, one printed as a message has no number, so its text is looked for.
    out=$(sql -b -Q "SET NOCOUNT ON; USE Sales; DECLARE @e nvarchar(10) = N'ok';
BEGIN TRY EXEC sp_droppublication @publication = N'$pub'; END TRY
BEGIN CATCH SET @e = CONVERT(nvarchar(10), ERROR_NUMBER()); WHILE @@TRANCOUNT > 0 ROLLBACK; END CATCH;
SELECT N'RESULT=' + @e" </dev/null 2>&1)
    drop=$(printf '%s\n' "$out" | sed -n 's/^RESULT=\(.*\)$/\1/p' | tr -d '[:space:]')
    [ -n "$drop" ] || { printf 'c5: no result in: %s\n' "$out" >&2; exit 1; }
    seen=no
    printf '%s\n' "$out" | grep -q -e '18752' -e 'Only one Log Reader Agent or log-related procedure' && seen=yes
    left=$(sql_value "SELECT COUNT(*) FROM Sales.dbo.syspublications WHERE name = N'$pub'")
    agents=$(sql_value "SELECT COUNT(*) FROM distribution.dbo.MSdistribution_agents a WHERE a.publication IN (N'$pub', N'ALL') AND a.subscriber_db = N'm_sub'")
    jobs=$(sql_value "SELECT COUNT(*) FROM msdb.dbo.sysjobs WHERE name LIKE N'%-$pub-%'")
    djob=$(sql_value "SELECT COUNT(*) FROM msdb.dbo.sysjobs WHERE job_id = '$job'")
    r "C5.$kind" "dropsub=$d,droppublication=$drop" "ready=$rd flags=none 18752_seen=$seen (one attempt; Sales keeps its other publications) publication_left=$left agent_rows_left=$agents dist_job_left_by_id=$djob jobs_named_after_publication_left=$jobs"
}

for c in $cases; do
    for k in $kinds; do
        want "$c.$k" || continue
        build "$k"
        "$(echo "$c" | tr 'C' 'c')"
        teardown "$pub"
    done
done

# Controls: each mismatch is said on stderr; any fails the run.
bad=0
control() { echo "06-structural: control failed: $*" >&2; bad=1; }
field() { # ID N
    printf '%s\n' "${rows[@]}" | awk -F'|' -v id="$1" -v n="$2" '$2 == id { print $n }'
}
if [ -z "${M_ONLY:-}" ]; then
    [ "${#rows[@]}" = 20 ] || control "${#rows[@]} rows, expected 20"
    for k in $kinds; do
        [[ $(field "C1.$k" 4) == *" rows_left=0 "* ]] || control "C1.$k does not leave 0 rows: $(field "C1.$k" 4)"
        case $k in imm-*) want_ext=none ;; *) want_ext=ok ;; esac
        [[ $(field "C4.$k" 3) == "addarticle=ok,extend=$want_ext" ]] || control "C4.$k: $(field "C4.$k" 3), expected extend=$want_ext"
    done
    [[ $(field C4.nonimm-conc 4) == *" bulk=[m_t3] "* ]] || control "C4.nonimm-conc does not bulk copy m_t3 only: $(field C4.nonimm-conc 4)"
    [[ $(field C4.nonimm-conc 4) == *" marker_survived=1 "* ]] || control "the marker does not survive on C4.nonimm-conc: $(field C4.nonimm-conc 4)"
fi
if [ -n "${M_ONLY:-}" ]; then
    for row in "${rows[@]}"; do echo "row: $row" >&2; done
    echo "06-structural: debug run (M_ONLY set), results not accepted" >&2
    exit 1
fi
if [ "$bad" != 0 ]; then
    for row in "${rows[@]}"; do echo "row: $row" >&2; done
    exit 1
fi
cleanup
for row in "${rows[@]}"; do printf '%s\n' "$row"; done
echo "R|TOTAL|${#rows[@]}"
