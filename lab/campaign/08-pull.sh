#!/bin/bash
# Pull subscriptions (campaign item 6): how they are created, what they leave in the
# system tables and in msdb, what sp_change_subscription_properties accepts, and what
# each of the two drop orders leaves behind. Run through lab/campaign.sh.
#
# Objects: the publication m_pp (allow_push and allow_pull, immediate_sync = 1, own
# distribution agent, one table m_t1 of Sales, snapshot agent with a schedule that never
# fires) and the subscription databases m_psub1 and m_psub2 on the same instance.
#
# Rows:
#   P1.named     sp_addsubscription @subscription_type = pull at the publisher, then
#                sp_addpullsubscription @subscription_type = pull and
#                sp_addpullsubscription_agent in m_psub1; the snapshot is started and
#                the delivery waited for. Records the subscription_type of
#                syssubscriptions, of MSreplication_subscriptions and of the distributor
#                agent row, the MSsubscription_properties columns, the agent job (name
#                without its GUID, category, enabled, step command) and where its job id
#                is referenced.
#   P1.omitted   the same in m_psub2 without @subscription_type at the subscriber. The
#                agent is waited for until it delivers or logs an agent message code
#                (this publication does not allow anonymous subscriptions).
#   G1.orphan-guard  the "orphan agent job" predicate of campaign.sh evaluated while the
#                pull subscription of m_psub1 legitimately exists.
#   P2.<property>  one row per property of sp_change_subscription_properties, on the
#                subscription of m_psub1: read before, set to a different value, read
#                back, restore and verify. The list is the Learn page (fetched
#                2026-11-10) plus what the procedure source and the lab show (distributor,
#                memory_optimized, offload_agent and offload_server, refused as no longer
#                supported) plus m_bogus, a name that exists nowhere. The parameters of the
#                procedure are the six of sys.all_parameters on the lab, identical to the
#                Learn syntax. Fingerprints are hashed on the server: every column of
#                MSsubscription_properties and MSreplication_subscriptions, the
#                subscription rows at the publisher, the distributor agent row, the
#                agent job (row, version, steps), the counts of credentials and proxies.
#                changed_inside lists the fingerprint tokens that differ while the change
#                is applied; after_restore_differs those that still differ after the
#                restore. A secret is never printed: only the fact that it changed.
#   P3.subscriber-first / P3.publisher-first  the two drop orders on a fresh subscription
#                (m_psub1, then m_psub2), each in three rows: .step1 (state after the
#                first drop), .step2 (after the second drop) and .cleanup (what had to be
#                removed by hand, and the state after). The state lists the rows and tables
#                left in syssubscriptions, MSreplication_subscriptions,
#                MSsubscription_properties, MSsubscription_agents, MSreplication_objects,
#                msdb.dbo.sysjobs (by the job id read before the drop), the distributor
#                MSdistribution_agents and MSsubscriptions rows, and the orphan guard count.
#
# Asserted, exit 1 on a mismatch (rows printed on stderr as "row: ..."): P1.omitted has
# subscriber subscription_type = 2 (the brief's expectation, measured by the review), the
# starting value of each non-secret property is the one listed and differs from the value
# set, the row count is 42. M_ONLY='P2.hostname P3.subscriber-first.step1' runs the
# listed groups (P1, G1, P2.<property>, P3.subscriber-first, P3.publisher-first) alone;
# no assertions then, and the run exits 1 so that it is never accepted.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"

EXPECTED_ROWS=42
rows=()
r() { rows+=("R|$1|$2|$3"); }
# want GROUP: with M_ONLY set, only the groups named in it run (a P2 row by its id).
want() {
    local t
    [ -z "${M_ONLY:-}" ] && return 0
    for t in $M_ONLY; do [[ $t == "$1" || $t == "$1".* || $1 == "$t".* ]] && return 0; done
    return 1
}
need() { local v; for v in "$@"; do [ -n "${!v}" ] || { echo "08-pull: empty field $v" >&2; exit 1; }; done; }
now() { sql_value "SELECT CONVERT(varchar(23), SYSDATETIME(), 121)"; }

teardown() {
    sql -Q "SET NOCOUNT ON;
DECLARE @d sysname, @s nvarchar(400);
DECLARE c CURSOR LOCAL FOR SELECT name FROM sys.databases WHERE name IN (N'm_psub1', N'm_psub2');
OPEN c; FETCH NEXT FROM c INTO @d;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @s = N'USE ' + QUOTENAME(@d) + N'; IF OBJECT_ID(N''dbo.MSreplication_subscriptions'') IS NOT NULL BEGIN TRY EXEC sp_droppullsubscription @publisher = @@SERVERNAME, @publisher_db = N''Sales'', @publication = N''m_pp''; END TRY BEGIN CATCH END CATCH';
    BEGIN TRY EXEC (@s); END TRY BEGIN CATCH END CATCH;
    FETCH NEXT FROM c INTO @d;
END;
CLOSE c; DEALLOCATE c;
USE Sales;
BEGIN TRY IF EXISTS (SELECT 1 FROM dbo.syspublications WHERE name = N'm_pp')
    EXEC sp_dropsubscription @publication = N'm_pp', @article = N'all', @subscriber = N'all'; END TRY BEGIN CATCH END CATCH;
BEGIN TRY IF EXISTS (SELECT 1 FROM dbo.syspublications WHERE name = N'm_pp')
    EXEC sp_droppublication @publication = N'm_pp'; END TRY BEGIN CATCH END CATCH;
DECLARE @j sysname;
WHILE 1 = 1
BEGIN
    SET @j = (SELECT TOP 1 name FROM msdb.dbo.sysjobs WHERE name LIKE N'%-m\_pp-%' ESCAPE N'\');
    IF @j IS NULL BREAK;
    EXEC msdb.dbo.sp_delete_job @job_name = @j;
END;
DROP TABLE IF EXISTS dbo.m_t1;
GO
DECLARE @d2 sysname, @s2 nvarchar(400);
DECLARE c2 CURSOR LOCAL FOR SELECT name FROM sys.databases WHERE name IN (N'm_psub1', N'm_psub2');
OPEN c2; FETCH NEXT FROM c2 INTO @d2;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @s2 = N'ALTER DATABASE ' + QUOTENAME(@d2) + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE ' + QUOTENAME(@d2) + N';';
    EXEC (@s2);
    FETCH NEXT FROM c2 INTO @d2;
END;
CLOSE c2; DEALLOCATE c2;" </dev/null >&2 || true
    podman exec repllab find /var/opt/mssql/data/ReplData/unc -mindepth 1 -maxdepth 1 -iname '*_m_*' -exec rm -rf {} + >&2 || true
}
cleaned=0
cleanup() {
    [ "$cleaned" = 1 ] && return
    cleaned=1
    teardown
}
trap cleanup EXIT

# Leftovers of an earlier run fail this run (the exit guard); the trap removes them.
left=$(sql_value "SELECT (SELECT COUNT(*) FROM Sales.dbo.syspublications WHERE name LIKE N'm\_%' ESCAPE N'\') + (SELECT COUNT(*) FROM sys.databases WHERE name LIKE N'm\_%' ESCAPE N'\') + (SELECT COUNT(*) FROM Sales.sys.objects WHERE name LIKE N'm\_%' ESCAPE N'\') + (SELECT COUNT(*) FROM msdb.dbo.sysjobs WHERE name LIKE N'%-m\_%' ESCAPE N'\')") || exit 1
left_files=$(podman exec repllab find /var/opt/mssql/data/ReplData/unc -mindepth 1 -maxdepth 1 -iname '*_m_*')
if [ "$left" != 0 ] || [ -n "$left_files" ]; then
    echo "08-pull: leftovers of an earlier run (objects=$left files=$left_files); removing them and failing" >&2
    exit 1
fi

sql -Q "SET NOCOUNT ON; USE Sales;
CREATE TABLE dbo.m_t1 (id int PRIMARY KEY, a int); INSERT dbo.m_t1 VALUES (1, 1);
CREATE DATABASE m_psub1; CREATE DATABASE m_psub2" </dev/null

sql <<'SQL'
SET NOCOUNT ON;
USE Sales;
EXEC sp_addpublication @publication = N'm_pp', @status = N'active', @allow_push = N'true', @allow_pull = N'true',
     @independent_agent = N'true', @immediate_sync = N'true', @repl_freq = N'continuous', @sync_method = N'concurrent';
EXEC sp_addpublication_snapshot @publication = N'm_pp', @frequency_type = 1, @active_start_date = 99991231,
     @job_login = NULL, @job_password = NULL, @publisher_security_mode = 1;
EXEC sp_addarticle @publication = N'm_pp', @article = N'm_t1', @source_owner = N'dbo', @source_object = N'm_t1';
GO
SQL

# build DB TYPE: the subscription at the publisher, then the pull subscription and its agent
# at the subscriber (TYPE named passes @subscription_type = pull, omitted does not).
build() {
    local db=$1 type=$2 st=""
    [ "$type" = named ] && st=", @subscription_type = N'pull'"
    sql <<SQL
SET NOCOUNT ON;
USE Sales;
DECLARE @srv sysname = @@SERVERNAME;
EXEC sp_addsubscription @publication = N'm_pp', @subscriber = @srv, @destination_db = N'$db',
     @subscription_type = N'pull', @sync_type = N'automatic', @article = N'all';
GO
USE $db;
DECLARE @srv sysname = @@SERVERNAME;
EXEC sp_addpullsubscription @publisher = @srv, @publisher_db = N'Sales', @publication = N'm_pp'$st;
EXEC sp_addpullsubscription_agent @publisher = @srv, @publisher_db = N'Sales', @publication = N'm_pp',
     @distributor = @srv, @subscriber_security_mode = 1, @distributor_security_mode = 1,
     @job_login = NULL, @job_password = NULL, @frequency_type = 64;
GO
SQL
}

# delivered DB MARK: the agent of DB has delivered the snapshot since MARK.
delivered_pred() {
    echo "EXISTS (SELECT 1 FROM distribution.dbo.MSdistribution_history h JOIN distribution.dbo.MSdistribution_agents a ON a.id = h.agent_id WHERE a.subscriber_db = N'$1' AND h.time >= '$2' AND h.comments LIKE N'Delivered snapshot%')"
}
delivered() { wait_until 300 "SELECT CASE WHEN $(delivered_pred "$1" "$2") THEN 1 ELSE 0 END"; }

# The pull job of DB, read from the subscriber's own row before anything is dropped.
pull_job_id() { sql_value "SELECT CONVERT(varchar(36), CONVERT(uniqueidentifier, agent_id)) FROM $1.dbo.MSreplication_subscriptions"; }

# tbl_count DB TABLE: rows of a table of the subscription database, or absent.
tbl_count() {
    local p
    p=$(sql_value "SELECT CASE WHEN OBJECT_ID(N'$1.dbo.$2') IS NULL THEN N'absent' ELSE N'present' END") || return 1
    if [ "$p" = absent ]; then echo absent; else sql_value "SELECT COUNT(*) FROM $1.dbo.$2"; fi
}

# The "orphan agent job" predicate of lab/campaign.sh, as a count.
orphan_count() {
    sql_value "SELECT COUNT(*) FROM msdb.dbo.sysjobs j JOIN msdb.dbo.syscategories c ON c.category_id = j.category_id
 WHERE c.name IN (N'REPL-LogReader', N'REPL-Snapshot', N'REPL-Distribution')
   AND j.job_id NOT IN (SELECT job_id FROM distribution.dbo.MSlogreader_agents WHERE job_id IS NOT NULL)
   AND j.job_id NOT IN (SELECT job_id FROM distribution.dbo.MSsnapshot_agents WHERE job_id IS NOT NULL)
   AND j.job_id NOT IN (SELECT job_id FROM distribution.dbo.MSdistribution_agents WHERE job_id IS NOT NULL)"
}

# state DB JOBID: what remains of the subscription of DB, one line.
state() {
    local syssubs rs props sa ro job jr da ds orph
    syssubs=$(sql_value "SELECT COUNT(*) FROM Sales.dbo.syssubscriptions WHERE srvid >= 0 AND dest_db = N'$1'")
    rs=$(tbl_count "$1" MSreplication_subscriptions)
    props=$(tbl_count "$1" MSsubscription_properties)
    sa=$(tbl_count "$1" MSsubscription_agents)
    ro=$(tbl_count "$1" MSreplication_objects)
    job=$(sql_value "SELECT COUNT(*) FROM msdb.dbo.sysjobs WHERE job_id = '$2'")
    jr=$(sql_value "SELECT COUNT(*) FROM msdb.dbo.sysjobactivity WHERE job_id = '$2' AND session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions) AND start_execution_date IS NOT NULL AND stop_execution_date IS NULL")
    da=$(sql_value "SELECT COUNT(*) FROM distribution.dbo.MSdistribution_agents WHERE subscriber_db = N'$1'")
    ds=$(sql_value "SELECT COUNT(*) FROM distribution.dbo.MSsubscriptions WHERE subscriber_db = N'$1'")
    orph=$(orphan_count)
    need syssubs rs props sa ro job jr da ds orph
    echo "syssubscriptions=$syssubs MSreplication_subscriptions=$rs MSsubscription_properties=$props MSsubscription_agents=$sa MSreplication_objects=$ro sysjobs_by_id=$job job_running=$jr distributor_agent_rows=$da distributor_MSsubscriptions=$ds orphan_guard=$orph"
}

# call_in DB STATEMENTS: runs them in DB inside TRY, rolls back what a refused call leaves
# open, prints RESULT~message where RESULT is ok, rc<n> (return code, no error) or the error number.
call_in() {
    local out
    out=$(sql -b -h -1 -Q "SET NOCOUNT ON; USE $1; DECLARE @srv sysname = @@SERVERNAME, @rc int = 0, @e nvarchar(20) = N'', @m nvarchar(300) = N'';
BEGIN TRY $2 END TRY
BEGIN CATCH SET @e = CONVERT(nvarchar(20), ERROR_NUMBER()); SET @m = LEFT(REPLACE(REPLACE(REPLACE(ERROR_MESSAGE(), CHAR(13), N' '), CHAR(10), N' '), N'|', N'/'), 200); END CATCH;
WHILE @@TRANCOUNT > 0 ROLLBACK;
SELECT N'RES=' + CASE WHEN @e <> N'' THEN @e WHEN @rc = 0 THEN N'ok' ELSE N'rc' + CONVERT(nvarchar(10), @rc) END + N'~' + @m" </dev/null 2>&1) \
        || { printf '%s\n' "$out" >&2; return 1; }
    out=$(printf '%s\n' "$out" | sed -n 's/^RES=\(.*\)$/\1/p' | tail -n 1 | sed -e 's/[[:space:]]*$//')
    [ -n "$out" ] || { echo "08-pull: call_in: no result for: $2" >&2; return 1; }
    printf '%s\n' "$out"
}
# sqlq STRING: a T-SQL literal from a value; NULL is NULL, EMPTY is the empty string.
sqlq() {
    case $1 in
        NULL) echo "NULL" ;;
        EMPTY) echo "N''" ;;
        *) printf "N'%s'" "${1//\'/\'\'}" ;;
    esac
}

# Fingerprints: one line of name:hash tokens, hashed on the server (a secret is never
# printed). JSON per column makes every column of a row its own token.
jtok() { # PREFIX "TABLE [WHERE ...]" EXCLUDED-KEYS
    echo "(SELECT STRING_AGG(CONVERT(nvarchar(80), CONCAT(N'$1.', [key], N':', ISNULL(CONVERT(varchar(8), SUBSTRING(HASHBYTES('SHA1', CONVERT(nvarchar(4000), [value])), 1, 4), 2), 'null'))), N' ') WITHIN GROUP (ORDER BY [key]) FROM OPENJSON((SELECT * FROM $2 FOR JSON PATH, INCLUDE_NULL_VALUES), '\$[0]') WHERE [key] NOT IN ($3))"
}
h4() { echo "CONVERT(varchar(8), SUBSTRING(HASHBYTES('SHA1', $1), 1, 4), 2)"; }
fp() { # DB JOBID
    sql_value "SELECT CONVERT(nvarchar(4000), CONCAT_WS(N' ',
 $(jtok props "$1.dbo.MSsubscription_properties" "N'-'"),
 $(jtok msrs "$1.dbo.MSreplication_subscriptions" "N'time', N'transaction_timestamp'"),
 CONCAT(N'syssubs:', (SELECT $(h4 "ISNULL(STRING_AGG(CONVERT(nvarchar(200), CONCAT(artid, N'/', status, N'/', sync_type, N'/', subscription_type, N'/', update_mode, N'/', loopback_detection, N'/', queued_reinit, N'/', nosync_type, N'/', login_name, N'/', dest_db)), N';') WITHIN GROUP (ORDER BY artid), N'')") FROM Sales.dbo.syssubscriptions WHERE srvid >= 0 AND dest_db = N'$1')),
 $(jtok distagent "distribution.dbo.MSdistribution_agents WHERE subscriber_db = N'$1'" "N'-'"),
 CONCAT(N'job:', (SELECT $(h4 "CONCAT(name, N'/', enabled, N'/', category_id, N'/', description, N'/', start_step_id, N'/', CONVERT(varchar(100), owner_sid, 1))") FROM msdb.dbo.sysjobs WHERE job_id = '$2')),
 CONCAT(N'jobversion:', (SELECT version_number FROM msdb.dbo.sysjobs WHERE job_id = '$2')),
 CONCAT(N'steps:', (SELECT $(h4 "ISNULL(STRING_AGG(CONVERT(nvarchar(2000), CONCAT(step_id, N'/', subsystem, N'/', command, N'/', proxy_id, N'/', database_name, N'/', retry_attempts, N'/', retry_interval, N'/', on_success_action, N'/', on_fail_action)), N';') WITHIN GROUP (ORDER BY step_id), N'')") FROM msdb.dbo.sysjobsteps WHERE job_id = '$2')),
 CONCAT(N'credentials:', (SELECT COUNT(*) FROM sys.credentials)),
 CONCAT(N'proxies:', (SELECT COUNT(*) FROM msdb.dbo.sysproxies))))"
}
# fpdiff A B: the token names that differ between two fingerprints, comma separated.
fpdiff() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        n = split(a, A, " "); m = split(b, B, " ")
        for (i = 1; i <= n; i++) { split(A[i], x, ":"); va[x[1]] = x[2]; order[i] = x[1] }
        for (i = 1; i <= m; i++) { split(B[i], y, ":"); vb[y[1]] = y[2]; if (!(y[1] in va)) extra = extra y[1] "," }
        for (i = 1; i <= n; i++) { k = order[i]; if (va[k] != vb[k]) out = out k "," }
        s = out extra; sub(/,$/, "", s); print s }'
}
colval() { # DB COLUMN SECRET
    if [ "$3" = 1 ]; then
        sql_value "SELECT ISNULL((SELECT CASE WHEN [$2] IS NULL THEN N'NULL' ELSE N'secret#' + $(h4 "CONVERT(nvarchar(4000), [$2])") END FROM $1.dbo.MSsubscription_properties), N'none')"
    else
        sql_value "SELECT ISNULL((SELECT CASE WHEN [$2] IS NULL THEN N'NULL' WHEN CONVERT(nvarchar(200), [$2]) = N'' THEN N'EMPTY' ELSE CONVERT(nvarchar(200), [$2]) END FROM $1.dbo.MSsubscription_properties), N'none')"
    fi
}
CHANGE_CALL() { # PROPERTY VALUE
    echo "EXEC @rc = sp_change_subscription_properties @publisher = @srv, @publisher_db = N'Sales', @publication = N'm_pp', @property = N'$1', @value = $(sqlq "$2");"
}

# ---- P1 ----------------------------------------------------------------------------
# The columns of MSsubscription_properties that are not secrets and not null.
props_list() {
    sql_value "SELECT ISNULL(STRING_AGG(CONVERT(nvarchar(100), CONCAT([key], N'=', CASE WHEN [key] = N'job_step_uid' THEN N'<set>' ELSE [value] END)), N' '), N'none') FROM OPENJSON((SELECT * FROM $1.dbo.MSsubscription_properties FOR JSON PATH, INCLUDE_NULL_VALUES), '\$[0]') WHERE [key] NOT LIKE N'%password%' AND [value] IS NOT NULL"
}

p1() { # DB TYPE ID MARK
    local db=$1 type=$2 id=$3 mark=$4
    local sjob sjobeq sjobpull jid sp rp ra props jname jcat jen cmd refagent refdist distid distjob distjobexists refstep outcome msg
    jid=$(pull_job_id "$db")
    sp=$(sql_value "SELECT ISNULL(STRING_AGG(CONVERT(nvarchar(10), t), N'/'), N'none') FROM (SELECT DISTINCT subscription_type t FROM Sales.dbo.syssubscriptions WHERE srvid >= 0 AND dest_db = N'$db') x")
    ra=$(sql_value "SELECT ISNULL(STRING_AGG(CONVERT(nvarchar(10), status), N'/'), N'none') FROM (SELECT DISTINCT status FROM Sales.dbo.syssubscriptions WHERE srvid >= 0 AND dest_db = N'$db') x")
    rp=$(sql_value "SELECT CONVERT(nvarchar(10), subscription_type) FROM $db.dbo.MSreplication_subscriptions")
    props=$(props_list "$db")
    jname=$(sql_value "SELECT CONVERT(nvarchar(300), LEFT(name, LEN(name) - 36) + N'<guid>') FROM msdb.dbo.sysjobs WHERE job_id = '$jid'")
    jcat=$(sql_value "SELECT c.name FROM msdb.dbo.sysjobs j JOIN msdb.dbo.syscategories c ON c.category_id = j.category_id WHERE j.job_id = '$jid'")
    jen=$(sql_value "SELECT CONVERT(nvarchar(10), enabled) FROM msdb.dbo.sysjobs WHERE job_id = '$jid'")
    cmd=$(sql_value "SELECT CONVERT(nvarchar(500), REPLACE(REPLACE(command, CHAR(13), N' '), CHAR(10), N' ')) FROM msdb.dbo.sysjobsteps WHERE job_id = '$jid' AND subsystem = N'Distribution'")
    refagent=$(sql_value "SELECT COUNT(*) FROM $db.dbo.MSreplication_subscriptions WHERE CONVERT(uniqueidentifier, agent_id) = '$jid'")
    refstep=$(sql_value "SELECT COUNT(*) FROM $db.dbo.MSsubscription_properties p JOIN msdb.dbo.sysjobsteps s ON s.step_uid = p.job_step_uid WHERE s.job_id = '$jid'")
    refdist=$(sql_value "SELECT COUNT(*) FROM distribution.dbo.MSdistribution_agents WHERE CONVERT(uniqueidentifier, job_id) = '$jid'")
    distid=$(sql_value "SELECT CONVERT(nvarchar(20), id) + N'/type' + CONVERT(nvarchar(10), subscription_type) FROM distribution.dbo.MSdistribution_agents WHERE subscriber_db = N'$db'")
    sjob=$(sql_value "SELECT CONVERT(nvarchar(10), COUNT(*)) FROM msdb.dbo.sysjobs WHERE job_id IN (SELECT CONVERT(uniqueidentifier, distribution_jobid) FROM Sales.dbo.syssubscriptions WHERE srvid >= 0 AND dest_db = N'$db')")
    sjobeq=$(sql_value "SELECT CONVERT(nvarchar(10), COUNT(*)) FROM Sales.dbo.syssubscriptions s JOIN distribution.dbo.MSdistribution_agents a ON a.job_id = s.distribution_jobid WHERE s.srvid >= 0 AND s.dest_db = N'$db' AND a.subscriber_db = N'$db'")
    sjobpull=$(sql_value "SELECT CONVERT(nvarchar(10), COUNT(*)) FROM Sales.dbo.syssubscriptions WHERE srvid >= 0 AND dest_db = N'$db' AND CONVERT(uniqueidentifier, distribution_jobid) = '$jid'")
    distjobexists=$(sql_value "SELECT COUNT(*) FROM msdb.dbo.sysjobs WHERE job_id = (SELECT CONVERT(uniqueidentifier, job_id) FROM distribution.dbo.MSdistribution_agents WHERE subscriber_db = N'$db')")
    need sjob sjobeq sjobpull jid sp ra rp props jname jcat jen cmd refagent refstep refdist distid distjobexists
    # Delivery, or the agent's own error: both end the wait, anything else is a timeout.
    wait_until 120 "SELECT CASE WHEN $(delivered_pred "$db" "$mark") OR EXISTS (SELECT 1 FROM msdb.dbo.sysjobhistory WHERE job_id = '$jid' AND message LIKE N'%Agent message code%') THEN 1 ELSE 0 END" \
        || { echo "08-pull: $id: the pull agent neither delivered nor logged an agent message" >&2; exit 1; }
    if [ "$(sql_value "SELECT CASE WHEN $(delivered_pred "$db" "$mark") THEN 1 ELSE 0 END")" = 1 ]; then
        outcome=delivered; msg=none
    else
        outcome=agent_error
        msg=$(sql_value "SELECT TOP 1 CONVERT(nvarchar(300), LEFT(SUBSTRING(message, CHARINDEX(N'Agent message code', message), 300), CHARINDEX(CHAR(13), SUBSTRING(message, CHARINDEX(N'Agent message code', message), 300) + CHAR(13)) - 1)) FROM msdb.dbo.sysjobhistory WHERE job_id = '$jid' AND message LIKE N'%Agent message code%' ORDER BY instance_id DESC")
        msg=${msg//|//}
    fi
    need outcome msg
    r "$id" "publisher_subscription_type=$sp,subscriber_subscription_type=$rp" "syssubscriptions.status=$ra distributor_agent=$distid MSsubscription_properties=[$props] job=[$jname category=$jcat enabled=$jen command=$cmd] job_id_referenced_by: subscriber_agent_id=$refagent step_uid=$refstep MSdistribution_agents.job_id=$refdist; MSdistribution_agents.job_id_is_a_job=$distjobexists; syssubscriptions.distribution_jobid: is_the_pull_job=$sjobpull is_a_job=$sjob equals_MSdistribution_agents.job_id=$sjobeq agent_outcome=$outcome ($msg)"
}

# The pull subscription of m_psub1 is built and delivered, then the omitted one in m_psub2.
mark1=$(now)
build m_psub1 named
sql -Q "SET NOCOUNT ON; EXEC Sales.dbo.sp_startpublication_snapshot @publication = N'm_pp'" </dev/null >&2
wait_until 300 "SELECT CASE WHEN EXISTS (SELECT 1 FROM distribution.dbo.MSsnapshot_history h JOIN distribution.dbo.MSsnapshot_agents a ON a.id = h.agent_id WHERE a.publication = N'm_pp' AND h.time >= '$mark1' AND h.runstatus = 2) THEN 1 ELSE 0 END" \
    || { echo "08-pull: the snapshot of m_pp was not built" >&2; exit 1; }
delivered m_psub1 "$mark1" || { echo "08-pull: m_psub1 did not receive the snapshot" >&2; exit 1; }
if want P1; then p1 m_psub1 named P1.named "$mark1"; fi

mark2=$(now)
build m_psub2 omitted
if want P1; then p1 m_psub2 omitted P1.omitted "$mark2"; fi
# The anonymous agent keeps retrying; its subscription goes now (not one of the measured drop orders).
sql -Q "SET NOCOUNT ON; USE m_psub2; EXEC sp_droppullsubscription @publisher = @@SERVERNAME, @publisher_db = N'Sales', @publication = N'm_pp';
USE Sales; EXEC sp_dropsubscription @publication = N'm_pp', @article = N'all', @subscriber = @@SERVERNAME, @destination_db = N'm_psub2'" </dev/null >&2

# ---- G1: the orphan guard of campaign.sh while a pull subscription exists -------------
jid1=$(pull_job_id m_psub1)
need jid1
if want G1; then
    g_orph=$(orphan_count)
    g_names=$(sql_value "SELECT ISNULL(STRING_AGG(CONVERT(nvarchar(300), LEFT(j.name, LEN(j.name) - 36) + N'<guid>'), N','), N'none') FROM msdb.dbo.sysjobs j JOIN msdb.dbo.syscategories c ON c.category_id = j.category_id
 WHERE c.name IN (N'REPL-LogReader', N'REPL-Snapshot', N'REPL-Distribution')
   AND j.job_id NOT IN (SELECT job_id FROM distribution.dbo.MSlogreader_agents WHERE job_id IS NOT NULL)
   AND j.job_id NOT IN (SELECT job_id FROM distribution.dbo.MSsnapshot_agents WHERE job_id IS NOT NULL)
   AND j.job_id NOT IN (SELECT job_id FROM distribution.dbo.MSdistribution_agents WHERE job_id IS NOT NULL)")
    g_pushorph=$(sql_value "SELECT COUNT(*) FROM msdb.dbo.sysjobs WHERE name LIKE N'%-m\_%' ESCAPE N'\'")
    need g_orph g_names g_pushorph
    r "G1.orphan-guard" "orphan_agent_jobs=$g_orph" "while the pull subscription of m_psub1 exists (delivered, enabled): flagged jobs=[$g_names]; jobs with an m_ name (the sysjobs residue test)=$g_pushorph; the guard has no case for a pull job"
fi

# ---- P2 ----------------------------------------------------------------------------
# property;column read back;secret;expected start;value set;restore (BEFORE: the value read
# before, SKIP: not restorable). A start of - is not asserted.
P2_TABLE='alt_snapshot_folder;alt_snapshot_folder;0;NULL;/var/opt/mssql/data/m_altsnap;NULL
distrib_job_login;job_login;0;NULL;REPLLAB\m_user;NULL
distrib_job_password;job_password;1;NULL;m_Passw0rd1;NULL
distributor_login;distributor_login;0;EMPTY;m_dl;EMPTY
distributor_password;distributor_password;1;-;m_Passw0rd1;SKIP
distributor_security_mode;distributor_security_mode;0;1;0;1
dts_package_name;dts_package_name;0;NULL;m_pkg;NULL
dts_package_password;dts_package_password;1;NULL;m_Passw0rd1;NULL
dts_package_location;dts_package_location;0;1;distributor;subscriber
dynamic_snapshot_location;dynamic_snapshot_location;0;NULL;/var/opt/mssql/data/m_dyn;NULL
ftp_address;ftp_address;0;NULL;m_ftp.example.com;NULL
ftp_login;ftp_login;0;NULL;m_ftpuser;NULL
ftp_password;ftp_password;1;NULL;m_Passw0rd1;NULL
ftp_port;ftp_port;0;NULL;2121;NULL
hostname;hostname;0;NULL;m_host;NULL
internet_login;internet_login;0;NULL;m_inet;NULL
internet_password;internet_password;1;NULL;m_Passw0rd1;NULL
internet_security_mode;internet_security_mode;0;0;1;0
internet_timeout;internet_timeout;0;300;301;300
internet_url;internet_url;0;NULL;http://m_example.invalid/repl;NULL
merge_job_login;job_login;0;NULL;REPLLAB\m_user;NULL
merge_job_password;job_password;1;NULL;m_Passw0rd1;NULL
publisher_login;publisher_login;0;NULL;m_pl;NULL
publisher_password;publisher_password;1;NULL;m_Passw0rd1;NULL
publisher_security_mode;publisher_security_mode;0;-1;1;-1
use_ftp;use_ftp;0;0;true;false
use_web_sync;use_web_sync;0;0;true;false
working_directory;working_directory;0;NULL;/var/opt/mssql/data/m_wd;NULL
distributor;distributor;0;-;m_dist;BEFORE
memory_optimized;-;0;-;1;0
offload_agent;offload_agent;0;0;true;false
offload_server;-;0;-;m_srv;NULL
m_bogus;-;0;-;1;NULL'

p2case() { # PROPERTY COLUMN SECRET START SET RESTORE
    local prop=$1 col=$2 secret=$3 start=$4 set=$5 restore=$6
    local fp0 fp1 fp2 v0 v1 v2 res msg rres rmsg inside after rv shown_set allowed
    want "P2.$prop" || return 0
    fp0=$(fp m_psub1 "$jid1")
    v0=-; v1=-; v2=-
    if [ "$col" != - ]; then v0=$(colval m_psub1 "$col" "$secret"); fi
    need fp0 v0
    if [ "$start" != - ] && [ -z "${M_ONLY:-}" ]; then
        [ "$v0" = "$start" ] || { echo "08-pull: P2.$prop starts at '$v0', expected '$start'" >&2; exit 1; }
    fi
    res=$(call_in m_psub1 "$(CHANGE_CALL "$prop" "$set")")
    msg=${res#*~}; res=${res%%~*}
    fp1=$(fp m_psub1 "$jid1")
    if [ "$col" != - ]; then v1=$(colval m_psub1 "$col" "$secret"); fi
    need fp1 v1
    inside=$(fpdiff "$fp0" "$fp1")
    # An ok call on a property with a column must move the column (ftp_*: accepted and ignored, it must not).
    if [ -z "${M_ONLY:-}" ] && [ "$res" = ok ] && [ "$col" != - ]; then
        case $prop in
            ftp_*) [ "$v1" = "$v0" ] || { echo "08-pull: P2.$prop: an ignored property changed ($v0 -> $v1)" >&2; exit 1; } ;;
            *)     [ "$v1" != "$v0" ] || { echo "08-pull: P2.$prop: ok but the column did not change ($v0)" >&2; exit 1; } ;;
        esac
    fi
    # restore when the call said ok or the state moved anyway
    rres=skipped; rmsg=
    rv=$restore; [ "$restore" = BEFORE ] && rv=$v0
    if [ "$restore" != SKIP ] && { [ "$res" = ok ] || [ -n "$inside" ]; }; then
        rres=$(call_in m_psub1 "$(CHANGE_CALL "$prop" "$rv")")
        rmsg=${rres#*~}; rres=${rres%%~*}
    elif [ "$restore" = SKIP ]; then
        rres=not_restorable
    fi
    fp2=$(fpdiff "$fp0" "$(fp m_psub1 "$jid1")")
    if [ "$col" != - ]; then v2=$(colval m_psub1 "$col" "$secret"); fi
    need v2
    # The restore leaves nothing behind, except these secret columns (named exactly).
    if [ -z "${M_ONLY:-}" ]; then
        case $prop in
            distributor_password|distributor_security_mode) allowed=props.distributor_password ;;
            dts_package_password) allowed=props.dts_package_password ;;
            internet_password) allowed=props.internet_password ;;
            *) allowed= ;;
        esac
        [ "$fp2" = "$allowed" ] || { echo "08-pull: P2.$prop: after_restore_differs=[$fp2], allowed=[$allowed]" >&2; exit 1; }
    fi
    shown_set=$set; [ "$secret" = 1 ] && shown_set='<secret>'
    r "P2.$prop" "$res" "$col: before=$v0 set=$shown_set readback=$v1 changed_inside=[$inside] message=[${msg:-none}] restore_value=$([ "$secret" = 1 ] && echo '<secret>' || echo "$rv") restore=$rres${rmsg:+ [$rmsg]} value_after_restore=$v2 after_restore_differs=[$fp2]"
}
if want P2; then
    while IFS=';' read -r prop col secret start set restore; do
        p2case "$prop" "$col" "$secret" "$start" "$set" "$restore"
    done <<<"$P2_TABLE"
fi

# ---- P3 ----------------------------------------------------------------------------
# p3 ORDER DB: build a fresh pull subscription, then drop it in the given order, reading
# the state between the two drops.
p3() {
    local order=$1 db=$2 mark jid s0 s1 s2 s3 a1 a2 a1m a2m base agent_after first second fdb sdb actions=""
    want "P3.$order" || return 0
    mark=$(now)
    build "$db" named
    delivered "$db" "$mark" || { echo "08-pull: P3.$order: $db did not receive the snapshot" >&2; exit 1; }
    jid=$(pull_job_id "$db")
    need jid
    s0=$(state "$db" "$jid")
    if [ "$order" = subscriber-first ]; then
        fdb=$db; sdb=Sales
        first="EXEC @rc = sp_droppullsubscription @publisher = @srv, @publisher_db = N'Sales', @publication = N'm_pp';"
        second="EXEC @rc = sp_dropsubscription @publication = N'm_pp', @article = N'all', @subscriber = @srv, @destination_db = N'$db';"
    else
        fdb=Sales; sdb=$db
        first="EXEC @rc = sp_dropsubscription @publication = N'm_pp', @article = N'all', @subscriber = @srv, @destination_db = N'$db';"
        second="EXEC @rc = sp_droppullsubscription @publisher = @srv, @publisher_db = N'Sales', @publication = N'm_pp';"
    fi
    base=$(sql_value "SELECT ISNULL(MAX(instance_id), 0) FROM msdb.dbo.sysjobhistory")
    a1=$(call_in "$fdb" "$first"); a1m=${a1#*~}; a1=${a1%%~*}; s1=$(state "$db" "$jid")
    agent_after=
    if [ "$order" = publisher-first ]; then
        # The pull agent still runs after the publisher forgot the subscription: what does it say?
        wait_until 180 "SELECT CASE WHEN EXISTS (SELECT 1 FROM msdb.dbo.sysjobhistory WHERE job_id = '$jid' AND instance_id > $base AND message LIKE N'%Agent message code%') THEN 1 ELSE 0 END" \
            || { echo "08-pull: P3.$order: the pull agent logged nothing after the publisher drop" >&2; exit 1; }
        agent_after=$(sql_value "SELECT TOP 1 CONVERT(nvarchar(300), LEFT(SUBSTRING(message, CHARINDEX(N'Agent message code', message), 300), CHARINDEX(CHAR(13), SUBSTRING(message, CHARINDEX(N'Agent message code', message), 300) + CHAR(13)) - 1)) FROM msdb.dbo.sysjobhistory WHERE job_id = '$jid' AND instance_id > $base AND message LIKE N'%Agent message code%' ORDER BY instance_id")
        agent_after=${agent_after//|//}
    fi
    a2=$(call_in "$sdb" "$second"); a2m=${a2#*~}; a2=${a2%%~*}; s2=$(state "$db" "$jid")
    # Whatever remains after both drops is removed by hand, by identity.
    if [ "$(sql_value "SELECT COUNT(*) FROM msdb.dbo.sysjobs WHERE job_id = '$jid'")" != 0 ]; then
        sql -Q "SET NOCOUNT ON; EXEC msdb.dbo.sp_delete_job @job_id = '$jid'" </dev/null >&2; actions+="deleted job $jid;"
    fi
    if [ "$(tbl_count "$db" MSreplication_subscriptions)" != absent ]; then
        sql -Q "SET NOCOUNT ON; USE $db; EXEC sp_droppullsubscription @publisher = @@SERVERNAME, @publisher_db = N'Sales', @publication = N'm_pp'" </dev/null >&2; actions+="sp_droppullsubscription;"
    fi
    if [ "$(sql_value "SELECT COUNT(*) FROM Sales.dbo.syssubscriptions WHERE srvid >= 0 AND dest_db = N'$db'")" != 0 ]; then
        sql -Q "SET NOCOUNT ON; USE Sales; EXEC sp_dropsubscription @publication = N'm_pp', @article = N'all', @subscriber = @@SERVERNAME, @destination_db = N'$db'" </dev/null >&2; actions+="sp_dropsubscription;"
    fi
    s3=$(state "$db" "$jid")
    r "P3.$order.step1" "$a1" "${a1m:+message=[$a1m] }before: $s0; after the first drop ($([ "$order" = subscriber-first ] && echo 'sp_droppullsubscription at the subscriber' || echo 'sp_dropsubscription at the publisher')): $s1${agent_after:+; the pull agent then logs: $agent_after}"
    r "P3.$order.step2" "$a2" "${a2m:+message=[$a2m] }after the second drop ($([ "$order" = subscriber-first ] && echo 'sp_dropsubscription at the publisher' || echo 'sp_droppullsubscription at the subscriber')): $s2"
    r "P3.$order.cleanup" "${actions:+needed}${actions:-none_needed}" "by hand: ${actions:-nothing}; state after: $s3"
}
# The pull subscription of m_psub1 used by P2 goes first (not a measured drop order).
sql -Q "SET NOCOUNT ON; USE m_psub1; EXEC sp_droppullsubscription @publisher = @@SERVERNAME, @publisher_db = N'Sales', @publication = N'm_pp';
USE Sales; EXEC sp_dropsubscription @publication = N'm_pp', @article = N'all', @subscriber = @@SERVERNAME, @destination_db = N'm_psub1'" </dev/null >&2
p3 subscriber-first m_psub1
p3 publisher-first m_psub2

# ---- controls ----------------------------------------------------------------------
bad=0
control() { echo "08-pull: control failed: $*" >&2; bad=1; }
field() { # ID N
    printf '%s\n' "${rows[@]}" | awk -F'|' -v id="$1" -v n="$2" '$2 == id { print $n }'
}
if [ -z "${M_ONLY:-}" ]; then
    [ "${#rows[@]}" = "$EXPECTED_ROWS" ] || control "${#rows[@]} rows, expected $EXPECTED_ROWS"
    [[ $(field P1.omitted 3) == *"subscriber_subscription_type=2" ]] || control "P1.omitted: subscriber subscription_type is not 2: $(field P1.omitted 3)"
fi
if [ -n "${M_ONLY:-}" ]; then
    for row in "${rows[@]}"; do echo "row: $row" >&2; done
    echo "08-pull: debug run (M_ONLY set), results not accepted" >&2
    exit 1
fi
if [ "$bad" != 0 ]; then
    for row in "${rows[@]}"; do echo "row: $row" >&2; done
    exit 1
fi
cleanup
for row in "${rows[@]}"; do printf '%s\n' "$row"; done
echo "R|TOTAL|${#rows[@]}"
