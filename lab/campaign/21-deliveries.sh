#!/bin/bash
# The sources apply reads to confirm that a snapshot was delivered (plan 4 Task 3, R50):
# the "Delivered snapshot" lines of MSdistribution_history and the listing of the
# publication's snapshot folder by sys.dm_os_enumerate_filesystem. Run through
# lab/campaign.sh.
#
# Objects: database m_dl_db with dbo.m_t1, dbo.m_t2, dbo.m_t3 (id int PRIMARY KEY, a int),
# 20 rows each, published (sp_replicationdboption, sp_addlogreader_agent); subscription
# databases m_dl_sub1 and m_dl_sub2 on the same instance. Three publications, native, one
# table each:
#   m_dl_pp  m_t1, allow_pull (allow_push false), independent agent, no immediate_sync,
#            snapshot agent on a schedule that never fires; a pull subscription in
#            m_dl_sub1 whose agent job is on demand (no schedule).
#   m_dl_ps  m_t2, immediate_sync, independent agent, snapshot agent every minute.
#   m_dl_pn  m_t3, no independent_agent (shared distribution agent), no immediate_sync,
#            snapshot agent on a schedule that never fires.
# T is GETDATE() read at the distributor (MSdistribution_history.time is datetime), the
# mark MAX([timestamp]) of MSdistribution_history; a history row is (agent_id, timestamp).
# An agent row is found as R50 says: MSdistribution_agents by publisher (MSreplservers),
# publisher_db, subscriber (MSreplservers), subscriber_db, publication or N'ALL',
# subscriber_id >= 0. A publication's folder is the directory of the listing of
# <working_directory>/unc whose parent_directory is <working_directory>/unc/ and whose name
# ends with _<database>_<publication>, any case; its run folders are the directories whose
# parent_directory is that folder's full_filesystem_path plus '/'. No rule uses `level`,
# which counts from the children of the folder listed.
#
# Rows:
#   DL.pull.delivered_line  m_dl_pp: subscription at the publisher, pull subscription and
#       agent in m_dl_sub1, snapshot started and its run ended, then the pull agent's job
#       started at the subscriber; within 120 s: yes when the pull agent's
#       MSdistribution_agents row has a "Delivered snapshot" row in MSdistribution_history
#       after the mark and T taken before the job start, no otherwise. Detail: the agent row
#       (id, subscription_type), the line, the run it names against the run folder of the
#       generation, subscriber_rows=<n> read in m_dl_sub1.
#   DL.listing  after m_dl_pp's generation: result parent_in_name=yes|no (a level 1 name
#       holds its parent path); detail: columns=<names> (sys.dm_exec_describe_first_result_set),
#       levels=<level:kind,...> (what each level of the unc listing holds), the levels of
#       unc, of m_dl_pp's folder and of its run folder in a listing of <working_directory>
#       (root_listing=, the argument R50 passes), the three path
#       columns of m_dl_pp's folder and of its run folder as read, whether parent_directory
#       ends with a slash, whether the run folder's parent_directory equals the folder's
#       full_filesystem_path plus '/', whether the argument with a trailing slash lists the
#       same rows, and missing_rows=<n> with the error (none) for a folder that does not
#       exist.
#   DL.s7_frequent  m_dl_ps, once immediate_sync_ready reads 1 and its snapshot job is
#       idle: T, the mark and the listing, then sp_addsubscription and
#       sp_addpushsubscription_agent (continuous) to m_dl_sub2 in one batch, the
#       subscription's status read right after. Result folder=at_T|after_T: the run named by
#       the agent's first "Delivered snapshot" line after the mark against the listing at T
#       (none when no line within 180 s). Detail: status, T and its seconds past the minute,
#       the line and its time, the runs listed at T and those listed after.
#   DL.shared_readd  m_dl_pn: push subscription to m_dl_sub2 (shared agent, continuous),
#       snapshot generated and delivered; the subscription dropped; the mark, T and the
#       listing taken; the subscription re-added with sync_type automatic; the snapshot
#       generated. Result yes when a "Delivered snapshot" line of the shared agent above the
#       mark names m_dl_pn's folder, no otherwise. Detail: the shared agent's id and job
#       before the drop, after the drop and after the re-add, the line, whether its run was
#       absent at T, the rows at the subscriber.
#   DL.shared_readd_kept  m_dl_pk (m_t1, no independent_agent) pushed to m_dl_sub2 beside
#       m_dl_pn, so the shared agent keeps m_dl_pn's subscription across the drop: added
#       with sp_addsubscription alone (the agent exists, and sp_addpushsubscription_agent
#       would re-create its job), generated and delivered, dropped, the mark, T and the
#       listing taken, re-added the same way, generated. Result yes when a "Delivered
#       snapshot" line of the shared agent above the mark names m_dl_pk's folder, no
#       otherwise. Detail: the agent id and job before the drop, after it and after the
#       re-add, the line, whether its run was absent at T, the rows at the subscriber.
# A distribution agent job found idle after a generation is started once by the script, as
# R51 has apply do; each row's detail says whether that happened (started=yes|no).
#
# Asserted (exit 1, rows on stderr): 5 rows; each publication's folder identified exactly
# once; the first delivery of m_dl_pn happened (else DL.shared_readd measures nothing);
# MSreplservers has the same rows before and after; after the cleanup no m_dl agent row,
# job or folder is left (the shared agent included).
set -eEuo pipefail
trap 'echo "21-deliveries: failed at line $LINENO: ${BASH_COMMAND:0:200}" >&2' ERR
. "$(dirname "$0")/../lib.sh"
mark=$(sql_value "SELECT CONVERT(nvarchar(30), SYSDATETIME(), 121)")

db=m_dl_db
sub1=m_dl_sub1
sub2=m_dl_sub2
unc=/var/opt/mssql/data/ReplData/unc
dist=distribution

rows=()
r() { rows+=("R|$1|$2|$3"); }
need() { local v; for v in "$@"; do [ -n "${!v}" ] || { echo "21-deliveries: empty field $v" >&2; exit 1; }; done; }
fail() { echo "21-deliveries: $*" >&2; exit 1; }

cleaned=0
cleanup() {
    [ "$cleaned" = 1 ] && return
    cleaned=1
    stop_m_agents
    local d
    sql -Q "SET NOCOUNT ON;
IF DB_ID(N'$sub1') IS NOT NULL
    EXEC (N'USE $sub1; IF OBJECT_ID(N''dbo.MSreplication_subscriptions'') IS NOT NULL
BEGIN TRY EXEC sp_droppullsubscription @publisher = @@SERVERNAME, @publisher_db = N''$db'', @publication = N''m_dl_pp''; END TRY BEGIN CATCH END CATCH;
WHILE @@TRANCOUNT > 0 ROLLBACK;');
IF DB_ID(N'$db') IS NOT NULL
BEGIN
    EXEC (N'USE $db;
DECLARE @p sysname;
DECLARE c CURSOR LOCAL FOR SELECT name FROM dbo.syspublications WHERE name LIKE N''m\_dl\_%'' ESCAPE N''\'';
OPEN c; FETCH NEXT FROM c INTO @p;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY EXEC sp_dropsubscription @publication = @p, @article = N''all'', @subscriber = N''all''; END TRY BEGIN CATCH END CATCH;
    WHILE @@TRANCOUNT > 0 ROLLBACK;
    BEGIN TRY EXEC sp_droppublication @publication = @p; END TRY BEGIN CATCH END CATCH;
    WHILE @@TRANCOUNT > 0 ROLLBACK;
    FETCH NEXT FROM c INTO @p;
END;
CLOSE c; DEALLOCATE c;');
    BEGIN TRY EXEC sp_replicationdboption @dbname = N'$db', @optname = N'publish', @value = N'false'; END TRY BEGIN CATCH END CATCH;
    WHILE @@TRANCOUNT > 0 ROLLBACK;
END;
DECLARE @j sysname;
WHILE 1 = 1
BEGIN
    SET @j = (SELECT TOP 1 name FROM msdb.dbo.sysjobs WHERE name LIKE N'%-m\_dl\_%' ESCAPE N'\');
    IF @j IS NULL BREAK;
    EXEC msdb.dbo.sp_delete_job @job_name = @j;
END;" </dev/null >&2 || true
    for d in $sub1 $sub2 $db; do
        sql -Q "SET NOCOUNT ON; IF DB_ID(N'$d') IS NOT NULL BEGIN ALTER DATABASE [$d] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$d]; END;" </dev/null >&2 || true
    done
    podman exec repllab find "$unc" -mindepth 1 -maxdepth 1 -iname '*_m_dl_*' -exec rm -rf {} + >&2 || true
    purge_stopped_orphans "$mark"
}
trap cleanup EXIT
trap 'exit 1' TERM INT

# Leftovers of an earlier run fail this run (the trap removes them).
left=$(sql_value "SELECT (SELECT COUNT(*) FROM sys.databases WHERE name IN (N'$db', N'$sub1', N'$sub2'))
 + (SELECT COUNT(*) FROM msdb.dbo.sysjobs WHERE name LIKE N'%-m\_dl\_%' ESCAPE N'\')
 + (SELECT COUNT(*) FROM $dist.dbo.MSdistribution_agents WHERE publisher_db = N'$db' OR subscriber_db IN (N'$sub1', N'$sub2'))")
left_files=$(podman exec repllab find "$unc" -mindepth 1 -maxdepth 1 -iname '*_m_dl_*')
if [ "$left" != 0 ] || [ -n "$left_files" ]; then
    fail "leftovers of an earlier run (objects=$left files=$left_files); removing them and failing"
fi
replservers() { sql_value "SELECT CONVERT(nvarchar(4000), STRING_AGG(CONVERT(nvarchar(4000), CONCAT(srvid, N'=', srvname)), N',') WITHIN GROUP (ORDER BY srvid)) FROM $dist.dbo.MSreplservers"; }
replservers_before=$(replservers)
srv=$(sql_value "SELECT CONVERT(nvarchar(128), @@SERVERNAME)")
need replservers_before srv

# ---- helpers ---------------------------------------------------------------------------
# Times are written and read in style 126 (ISO 8601 with T), which does not depend on the
# session's DATEFORMAT.
dnow() { sql_value "SELECT CONVERT(varchar(23), GETDATE(), 126)"; }
hmark() { sql_value "SELECT CONVERT(varchar(20), CONVERT(binary(8), ISNULL(MAX([timestamp]), 0x00)), 1) FROM $dist.dbo.MSdistribution_history"; }
# agent_id PUB SUBDB: the id of the subscription's distribution agent row (PUB or ALL).
agent_id() {
    sql_value "SELECT ISNULL(CONVERT(varchar(12), (SELECT a.id FROM $dist.dbo.MSdistribution_agents AS a
  JOIN $dist.dbo.MSreplservers AS ps ON ps.srvid = a.publisher_id
  JOIN $dist.dbo.MSreplservers AS rs ON rs.srvid = a.subscriber_id
 WHERE UPPER(ps.srvname) = UPPER(@@SERVERNAME) AND a.publisher_db = N'$db'
   AND UPPER(rs.srvname) = UPPER(@@SERVERNAME) AND a.subscriber_db = N'$2'
   AND a.publication = N'$1' AND a.subscriber_id >= 0)), 'none')"
}
agent_job() { sql_value "SELECT ISNULL((SELECT CONVERT(varchar(36), CONVERT(uniqueidentifier, job_id)) FROM $dist.dbo.MSdistribution_agents WHERE id = $1), 'none')"; }
# delivered AGENT MARK T: the "Delivered snapshot" lines of AGENT after MARK and at or after
# T, oldest first, each as <time>~<comments>.
delivered() {
    local out
    out=$(sql -b -h -1 -Q "SET NOCOUNT ON; SELECT CONVERT(nvarchar(4000), CONCAT(CONVERT(varchar(23), h.[time], 121), N'~', h.comments))
FROM $dist.dbo.MSdistribution_history AS h
WHERE h.agent_id = $1 AND h.[timestamp] > $2 AND h.[time] >= CONVERT(datetime, '$3', 126) AND h.comments LIKE N'Delivered snapshot%'
ORDER BY h.[timestamp]" </dev/null 2>&1) || { printf '21-deliveries: delivered: %s\n' "$out" >&2; return 1; }
    printf '%s\n' "$out" | sed -e 's/[[:space:]]*$//' | grep -v '^$' || true
}
# wait_delivered SECONDS AGENT MARK T: polls every 2 s; prints the first line, or nothing.
wait_delivered() {
    local start=$SECONDS l
    while :; do
        l=$(delivered "$2" "$3" "$4" | head -n 1)
        [ -n "$l" ] && { printf '%s\n' "$l"; return 0; }
        (( SECONDS - start >= $1 )) && return 0
        sleep 2
    done
}
# parse_line LINE: prints "<folder> <run>" of 'unc\<folder>\<run>\', or nothing.
parse_line() {
    local re="'unc\\\\([^\\\\]+)\\\\([^\\\\]+)\\\\'"
    [[ $1 =~ $re ]] && printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return 0
}
fsq="SELECT * FROM sys.dm_os_enumerate_filesystem(N'$unc', N'*')"
# pubfolders PUB: the directories whose parent is <unc>/ and whose name ends with
# _<db>_<PUB>, any case, comma separated.
pubfolders() {
    sql_value "WITH fs AS ($fsq)
SELECT ISNULL(CONVERT(nvarchar(4000), STRING_AGG(CONVERT(nvarchar(4000), file_or_directory_name), N',')), N'') + N'#'
FROM fs WHERE parent_directory = N'$unc/' AND is_directory = 1
  AND UPPER(RIGHT(file_or_directory_name, LEN(N'_${db}_$1'))) = UPPER(N'_${db}_$1')" | sed 's/#$//'
}
# runs FOLDER: the run folders of FOLDER (directories whose parent is its path), sorted.
runs() {
    sql_value "WITH fs AS ($fsq)
SELECT ISNULL(CONVERT(nvarchar(4000), STRING_AGG(CONVERT(nvarchar(4000), r.file_or_directory_name), N',') WITHIN GROUP (ORDER BY r.file_or_directory_name)), N'') + N'#'
FROM fs AS p JOIN fs AS r ON r.parent_directory = p.full_filesystem_path + N'/'
WHERE p.parent_directory = N'$unc/' AND p.is_directory = 1 AND p.file_or_directory_name = N'$1' AND r.is_directory = 1" | sed 's/#$//'
}
inlist() { [[ ",$2," == *",$1,"* ]]; }
# The snapshot agent of PUB.
snap_job() { sql_value "SELECT CONVERT(varchar(36), CONVERT(uniqueidentifier, job_id)) FROM $dist.dbo.MSsnapshot_agents WHERE publisher_db = N'$db' AND publication = N'$1' AND local_job = 1"; }
snap_agent() { sql_value "SELECT id FROM $dist.dbo.MSsnapshot_agents WHERE publisher_db = N'$db' AND publication = N'$1' AND local_job = 1"; }
idle_pred() { echo "NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobactivity AS ja WHERE ja.job_id = '$1' AND ja.session_id = (SELECT MAX(ss.session_id) FROM msdb.dbo.syssessions AS ss) AND (ja.run_requested_date IS NOT NULL OR ja.start_execution_date IS NOT NULL) AND ja.stop_execution_date IS NULL)"; }
is_idle() { [ "$(sql_value "SELECT CASE WHEN $(idle_pred "$1") THEN 1 ELSE 0 END")" = 1 ]; }
wait_idle() { wait_until "$2" "SELECT CASE WHEN $(idle_pred "$1") THEN 1 ELSE 0 END" || fail "job $1 still busy after $2 s"; }
# generate PUB: waits for the snapshot job to be idle, starts it, waits for the run's end
# (snapshot history runstatus 2) and prints the time the run started (distributor clock).
generate() {
    local job agent t
    job=$(snap_job "$1"); agent=$(snap_agent "$1"); need job agent
    wait_idle "$job" 120
    t=$(dnow)
    sql -b -Q "SET NOCOUNT ON; USE $db; EXEC sp_startpublication_snapshot @publication = N'$1';" </dev/null >&2
    wait_until 240 "SELECT CASE WHEN EXISTS (SELECT 1 FROM $dist.dbo.MSsnapshot_history WHERE agent_id = $agent AND [time] >= CONVERT(datetime, '$t', 126) AND runstatus = 2) THEN 1 ELSE 0 END" \
        || fail "$1: the snapshot run did not end within 240 s"
    sleep 1
    wait_idle "$job" 120
    printf '%s\n' "$t"
}
# start_if_idle JOBID: starts the job when it is idle; prints yes when it did, no otherwise.
start_if_idle() {
    if is_idle "$1"; then
        sql -b -Q "SET NOCOUNT ON; EXEC msdb.dbo.sp_start_job @job_id = '$1';" </dev/null >&2
        echo yes
    else
        echo no
    fi
}
subrows() { sql_value "SELECT CASE WHEN OBJECT_ID(N'$1.dbo.$2') IS NULL THEN N'absent' ELSE CONVERT(nvarchar(12), (SELECT COUNT(*) FROM $1.dbo.$2)) END"; }

# ---- setup -----------------------------------------------------------------------------
sql -b <<SQL >&2
SET NOCOUNT ON;
CREATE DATABASE $db;
CREATE DATABASE $sub1;
CREATE DATABASE $sub2;
GO
USE $db;
CREATE TABLE dbo.m_t1 (id int PRIMARY KEY, a int);
CREATE TABLE dbo.m_t2 (id int PRIMARY KEY, a int);
CREATE TABLE dbo.m_t3 (id int PRIMARY KEY, a int);
INSERT dbo.m_t1 SELECT TOP (20) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), 1 FROM sys.all_columns;
INSERT dbo.m_t2 SELECT id, a FROM dbo.m_t1;
INSERT dbo.m_t3 SELECT id, a FROM dbo.m_t1;
EXEC sp_replicationdboption @dbname = N'$db', @optname = N'publish', @value = N'true';
EXEC sp_addlogreader_agent @job_login = NULL, @job_password = NULL, @publisher_security_mode = 1;
EXEC sp_addpublication @publication = N'm_dl_pp', @status = N'active', @allow_push = N'false', @allow_pull = N'true',
     @independent_agent = N'true', @immediate_sync = N'false', @repl_freq = N'continuous', @sync_method = N'native';
EXEC sp_addpublication_snapshot @publication = N'm_dl_pp', @frequency_type = 1, @active_start_date = 99991231,
     @job_login = NULL, @job_password = NULL, @publisher_security_mode = 1;
EXEC sp_addarticle @publication = N'm_dl_pp', @article = N'm_t1', @source_owner = N'dbo', @source_object = N'm_t1';
EXEC sp_addpublication @publication = N'm_dl_pn', @status = N'active', @allow_push = N'true',
     @independent_agent = N'false', @immediate_sync = N'false', @repl_freq = N'continuous', @sync_method = N'native';
EXEC sp_addpublication_snapshot @publication = N'm_dl_pn', @frequency_type = 1, @active_start_date = 99991231,
     @job_login = NULL, @job_password = NULL, @publisher_security_mode = 1;
EXEC sp_addarticle @publication = N'm_dl_pn', @article = N'm_t3', @source_owner = N'dbo', @source_object = N'm_t3';
EXEC sp_addpublication @publication = N'm_dl_pk', @status = N'active', @allow_push = N'true',
     @independent_agent = N'false', @immediate_sync = N'false', @repl_freq = N'continuous', @sync_method = N'native';
EXEC sp_addpublication_snapshot @publication = N'm_dl_pk', @frequency_type = 1, @active_start_date = 99991231,
     @job_login = NULL, @job_password = NULL, @publisher_security_mode = 1;
EXEC sp_addarticle @publication = N'm_dl_pk', @article = N'm_t1', @source_owner = N'dbo', @source_object = N'm_t1';
SQL

# ---- DL.pull.delivered_line and DL.listing ---------------------------------------------
sql -b <<SQL >&2
SET NOCOUNT ON;
USE $db;
DECLARE @srv sysname = @@SERVERNAME;
EXEC sp_addsubscription @publication = N'm_dl_pp', @subscriber = @srv, @destination_db = N'$sub1',
     @subscription_type = N'pull', @sync_type = N'automatic', @article = N'all';
GO
USE $sub1;
DECLARE @srv sysname = @@SERVERNAME;
EXEC sp_addpullsubscription @publisher = @srv, @publisher_db = N'$db', @publication = N'm_dl_pp', @subscription_type = N'pull';
EXEC sp_addpullsubscription_agent @publisher = @srv, @publisher_db = N'$db', @publication = N'm_dl_pp',
     @distributor = @srv, @subscriber_security_mode = 1, @distributor_security_mode = 1,
     @job_login = NULL, @job_password = NULL;
SQL
pull_job=$(sql_value "SELECT CONVERT(varchar(36), CONVERT(uniqueidentifier, agent_id)) FROM $sub1.dbo.MSreplication_subscriptions")
pp_agent=$(agent_id m_dl_pp "$sub1")
pp_agent_type=$(sql_value "SELECT CONVERT(varchar(10), subscription_type) FROM $dist.dbo.MSdistribution_agents WHERE id = $pp_agent")
pp_job_sched=$(sql_value "SELECT COUNT(*) FROM msdb.dbo.sysjobschedules WHERE job_id = '$pull_job'")
need pull_job pp_agent pp_agent_type pp_job_sched
[ "$pp_agent" != none ] || fail "m_dl_pp: no distribution agent row for the pull subscription"

pp_gen=$(generate m_dl_pp)
pp_folders=$(pubfolders m_dl_pp)
[[ -n $pp_folders && $pp_folders != *,* ]] || fail "m_dl_pp: folder not identified: [$pp_folders]"
pp_runs=$(runs "$pp_folders")
[[ -n $pp_runs && $pp_runs != *,* ]] || fail "m_dl_pp: expected one run folder after the generation, got [$pp_runs]"

# DL.listing, right after the generation (the pull job is not started yet).
cols=$(sql_value "SELECT CONVERT(nvarchar(4000), STRING_AGG(CONVERT(nvarchar(4000), name), N',') WITHIN GROUP (ORDER BY column_ordinal)) FROM sys.dm_exec_describe_first_result_set(N'SELECT * FROM sys.dm_os_enumerate_filesystem(N''$unc'', N''*'')', NULL, 0)")
levels=$(sql_value "WITH fs AS ($fsq)
SELECT CONVERT(nvarchar(4000), STRING_AGG(CONVERT(nvarchar(4000), CONCAT(level, N':', kind)), N',') WITHIN GROUP (ORDER BY level, kind))
FROM (SELECT DISTINCT level, CASE WHEN is_directory = 1 THEN N'dir' ELSE N'file' END AS kind FROM fs) AS x")
pinname=$(sql_value "WITH fs AS ($fsq)
SELECT CONCAT(N'level1_parent_in_name=', CASE WHEN EXISTS (SELECT 1 FROM fs WHERE level = 1 AND (CHARINDEX(N'/', file_or_directory_name) > 0 OR CHARINDEX(N'\', file_or_directory_name) > 0)) THEN N'yes' ELSE N'no' END,
  N' any_parent_in_name=', CASE WHEN EXISTS (SELECT 1 FROM fs WHERE CHARINDEX(N'/', file_or_directory_name) > 0 OR CHARINDEX(N'\', file_or_directory_name) > 0) THEN N'yes' ELSE N'no' END,
  N' level1_rows=', (SELECT COUNT(*) FROM fs WHERE level = 1))")
folder_cols=$(sql_value "WITH fs AS ($fsq)
SELECT CONVERT(nvarchar(4000), CONCAT(N'folder=[level=', level, N' full=', full_filesystem_path, N' parent=', parent_directory, N' name=', file_or_directory_name, N']'))
FROM fs WHERE parent_directory = N'$unc/' AND file_or_directory_name = N'$pp_folders'")
run_cols=$(sql_value "WITH fs AS ($fsq)
SELECT CONVERT(nvarchar(4000), CONCAT(N'run=[level=', r.level, N' full=', r.full_filesystem_path, N' parent=', r.parent_directory, N' name=', r.file_or_directory_name,
  N'] run_parent_is_folder_full_plus_slash=', CASE WHEN r.parent_directory = p.full_filesystem_path + N'/' THEN N'yes' ELSE N'no' END))
FROM fs AS p JOIN fs AS r ON r.file_or_directory_name = N'$pp_runs' AND r.is_directory = 1 AND r.full_filesystem_path = p.full_filesystem_path + N'/' + r.file_or_directory_name
WHERE p.parent_directory = N'$unc/' AND p.file_or_directory_name = N'$pp_folders'")
slash=$(sql_value "WITH fs AS ($fsq)
SELECT CONCAT(N'parent_ends_with_slash=', CASE WHEN NOT EXISTS (SELECT 1 FROM fs WHERE RIGHT(parent_directory, 1) <> N'/') THEN N'all' WHEN NOT EXISTS (SELECT 1 FROM fs WHERE RIGHT(parent_directory, 1) = N'/') THEN N'none' ELSE N'some' END,
  N' arg_trailing_slash_same_rows=', CASE WHEN (SELECT COUNT(*) FROM (SELECT full_filesystem_path FROM fs EXCEPT SELECT full_filesystem_path FROM sys.dm_os_enumerate_filesystem(N'$unc/', N'*')) a) = 0
       AND (SELECT COUNT(*) FROM (SELECT full_filesystem_path FROM sys.dm_os_enumerate_filesystem(N'$unc/', N'*') EXCEPT SELECT full_filesystem_path FROM fs) b) = 0 THEN N'yes' ELSE N'no' END)")
missing=$(sql_value "DECLARE @r nvarchar(4000);
BEGIN TRY SELECT @r = CONCAT(N'missing_rows=', COUNT(*), N' missing_error=none') FROM sys.dm_os_enumerate_filesystem(N'$unc/m_dl_absent', N'*'); END TRY
BEGIN CATCH SET @r = CONCAT(N'missing_rows=error missing_error=', ERROR_NUMBER(), N' ', LEFT(ERROR_MESSAGE(), 120)); END CATCH;
SELECT REPLACE(@r, N'|', N'/')")
rootq="SELECT * FROM sys.dm_os_enumerate_filesystem(N'${unc%/unc}', N'*')"
root_levels=$(sql_value "WITH fs AS ($rootq)
SELECT CONVERT(nvarchar(4000), CONCAT(N'root_listing=[root=${unc%/unc}',
  N' unc_level=', ISNULL(CONVERT(varchar(5), (SELECT level FROM fs WHERE full_filesystem_path = N'$unc')), 'none'),
  N' folder_level=', ISNULL(CONVERT(varchar(5), (SELECT level FROM fs WHERE full_filesystem_path = N'$unc/$pp_folders')), 'none'),
  N' run_level=', ISNULL(CONVERT(varchar(5), (SELECT level FROM fs WHERE full_filesystem_path = N'$unc/$pp_folders/$pp_runs')), 'none'),
  N' folder_parent=', ISNULL((SELECT parent_directory FROM fs WHERE full_filesystem_path = N'$unc/$pp_folders'), N'none'), N']'))")
need cols levels pinname folder_cols run_cols slash missing root_levels
pin=no; [[ $pinname == level1_parent_in_name=yes* ]] && pin=yes
r DL.listing "parent_in_name=$pin" "columns=[$cols] levels=[$levels] $pinname $slash $folder_cols $run_cols $root_levels $missing"

# DL.pull.delivered_line: the pull agent's job started at the subscriber after the run ended.
pp_t=$(dnow); pp_mark=$(hmark); need pp_t pp_mark
pp_started=$(start_if_idle "$pull_job")
pp_line=$(wait_delivered 120 "$pp_agent" "$pp_mark" "$pp_t")
pp_rows=$(subrows "$sub1" m_t1)
if [ -n "$pp_line" ]; then
    read -r pf prun <<<"$(parse_line "$pp_line")" || true
    same=no; [[ "${pf:-}" == "$pp_folders" && "${prun:-}" == "$pp_runs" ]] && same=yes
    r DL.pull.delivered_line yes "agent=$pp_agent/type$pp_agent_type pull_job_schedules=$pp_job_sched started=$pp_started T=$pp_t line=[${pp_line#*~}] at=${pp_line%%~*} names_generated_run=$same run_folder=$pp_folders/$pp_runs subscriber_rows=$pp_rows"
else
    last=$(sql_value "SELECT ISNULL((SELECT TOP 1 CONVERT(nvarchar(300), REPLACE(comments, N'|', N'/')) FROM $dist.dbo.MSdistribution_history WHERE agent_id = $pp_agent ORDER BY [timestamp] DESC), N'none')")
    r DL.pull.delivered_line no "agent=$pp_agent/type$pp_agent_type pull_job_schedules=$pp_job_sched started=$pp_started T=$pp_t within=120s last_agent_line=[$last] run_folder=$pp_folders/$pp_runs subscriber_rows=$pp_rows"
fi

# ---- DL.s7_frequent --------------------------------------------------------------------
sql -b <<SQL >&2
SET NOCOUNT ON;
USE $db;
DECLARE @d int = CONVERT(int, CONVERT(char(8), GETDATE(), 112));
EXEC sp_addpublication @publication = N'm_dl_ps', @status = N'active', @allow_push = N'true',
     @independent_agent = N'true', @immediate_sync = N'true', @repl_freq = N'continuous', @sync_method = N'native';
EXEC sp_addpublication_snapshot @publication = N'm_dl_ps', @frequency_type = 4, @frequency_interval = 1,
     @frequency_subday = 4, @frequency_subday_interval = 1, @active_start_date = @d, @active_start_time_of_day = 0,
     @job_login = NULL, @job_password = NULL, @publisher_security_mode = 1;
EXEC sp_addarticle @publication = N'm_dl_ps', @article = N'm_t2', @source_owner = N'dbo', @source_object = N'm_t2';
SQL
ps_job=$(snap_job m_dl_ps); need ps_job
wait_until 240 "SELECT CASE WHEN (SELECT immediate_sync_ready FROM $db.dbo.syspublications WHERE name = N'm_dl_ps') = 1 THEN 1 ELSE 0 END" \
    || fail "m_dl_ps: immediate_sync_ready did not read 1 within 240 s"
sleep 1
wait_idle "$ps_job" 120
ps_folders=$(pubfolders m_dl_ps)
[[ -n $ps_folders && $ps_folders != *,* ]] || fail "m_dl_ps: folder not identified: [$ps_folders]"
ps_t=$(dnow); ps_mark=$(hmark); ps_list=$(runs "$ps_folders")
ps_running=yes; is_idle "$ps_job" && ps_running=no
need ps_t ps_mark ps_list
ps_out=$(sql -b -h -1 -Q "SET NOCOUNT ON; USE $db;
DECLARE @srv sysname = @@SERVERNAME;
EXEC sp_addsubscription @publication = N'm_dl_ps', @subscriber = @srv, @destination_db = N'$sub2',
     @subscription_type = N'Push', @sync_type = N'automatic', @article = N'all';
EXEC sp_addpushsubscription_agent @publication = N'm_dl_ps', @subscriber = @srv, @subscriber_db = N'$sub2',
     @job_login = NULL, @job_password = NULL, @subscriber_security_mode = 1, @frequency_type = 64;
SELECT CONVERT(nvarchar(100), N'STATUS=' + ISNULL(STRING_AGG(CONVERT(nvarchar(10), status), N','), N'none')) FROM (SELECT DISTINCT status FROM dbo.syssubscriptions WHERE srvid >= 0 AND dest_db = N'$sub2') AS s" </dev/null 2>&1) \
    || fail "m_dl_ps: the subscription unit failed: $ps_out"
ps_status=$(printf '%s\n' "$ps_out" | sed -n 's/^STATUS=\([0-9,a-z]*\).*$/\1/p' | tail -n 1)
ps_agent=$(agent_id m_dl_ps "$sub2"); need ps_status ps_agent
[ "$ps_agent" != none ] || fail "m_dl_ps: no distribution agent row"
ps_djob=$(agent_job "$ps_agent")
ps_line=$(wait_delivered 60 "$ps_agent" "$ps_mark" "$ps_t")
ps_started=no
if [ -z "$ps_line" ]; then
    ps_started=$(start_if_idle "$ps_djob")
    ps_line=$(wait_delivered 120 "$ps_agent" "$ps_mark" "$ps_t")
fi
ps_after=$(runs "$ps_folders")
new_runs=$(comm -13 <(tr ',' '\n' <<<"$ps_list" | sort) <(tr ',' '\n' <<<"$ps_after" | sort) | paste -sd ',' - || true)
ps_sec=${ps_t:17:2}
if [ -n "$ps_line" ]; then
    read -r sf srun <<<"$(parse_line "$ps_line")" || true
    if [[ "${sf:-}" != "$ps_folders" ]]; then res="folder=other($sf)"
    elif inlist "$srun" "$ps_list"; then res=folder=at_T
    else res=folder=after_T; fi
    r DL.s7_frequent "$res" "status_after_unit=$ps_status snapshot_job_running_at_T=$ps_running started=$ps_started T=$ps_t T_seconds=$ps_sec line=[${ps_line#*~}] at=${ps_line%%~*} run=$srun listed_at_T=[$ps_list] listed_after_T=[$new_runs]"
else
    r DL.s7_frequent folder=none "status_after_unit=$ps_status snapshot_job_running_at_T=$ps_running started=$ps_started T=$ps_t T_seconds=$ps_sec within=180s listed_at_T=[$ps_list] listed_after_T=[$new_runs] subscriber_rows=$(subrows "$sub2" m_t2)"
fi
# The every-minute schedule stops here, so that later runs do not crowd the listing.
sql -b -Q "SET NOCOUNT ON; USE $db; EXEC sp_changepublication_snapshot @publication = N'm_dl_ps', @frequency_type = 1, @active_start_date = 99991231;" </dev/null >&2

# ---- DL.shared_readd -------------------------------------------------------------------
add_pn() {
    sql -b -Q "SET NOCOUNT ON; USE $db;
DECLARE @srv sysname = @@SERVERNAME;
EXEC sp_addsubscription @publication = N'm_dl_pn', @subscriber = @srv, @destination_db = N'$sub2',
     @subscription_type = N'Push', @sync_type = N'automatic', @article = N'all';
EXEC sp_addpushsubscription_agent @publication = N'm_dl_pn', @subscriber = @srv, @subscriber_db = N'$sub2',
     @job_login = NULL, @job_password = NULL, @subscriber_security_mode = 1, @frequency_type = 64;" </dev/null >&2
}
add_pn
pn_agent1=$(agent_id ALL "$sub2"); need pn_agent1
[ "$pn_agent1" != none ] || fail "m_dl_pn: no shared agent row"
pn_job1=$(agent_job "$pn_agent1")
pn_t0=$(dnow); pn_mark0=$(hmark)
generate m_dl_pn >/dev/null
pn_started1=$(start_if_idle "$pn_job1")
pn_line1=$(wait_delivered 180 "$pn_agent1" "$pn_mark0" "$pn_t0")
[ -n "$pn_line1" ] || fail "m_dl_pn: the first delivery by the shared agent did not happen within 180 s"
pn_folders=$(pubfolders m_dl_pn)
[[ -n $pn_folders && $pn_folders != *,* ]] || fail "m_dl_pn: folder not identified: [$pn_folders]"

sql -b -Q "SET NOCOUNT ON; USE $db; EXEC sp_dropsubscription @publication = N'm_dl_pn', @article = N'all', @subscriber = @@SERVERNAME, @destination_db = N'$sub2';" </dev/null >&2
pn_agent_drop=$(agent_id ALL "$sub2")
pn_job_drop=none; [ "$pn_agent_drop" != none ] && pn_job_drop=$(agent_job "$pn_agent_drop")
pn_jobrow_drop=$(sql_value "SELECT COUNT(*) FROM msdb.dbo.sysjobs WHERE job_id = '$pn_job1'")

pn_t=$(dnow); pn_mark=$(hmark); pn_list=$(runs "$pn_folders"); need pn_t pn_mark pn_list
add_pn
pn_agent2=$(agent_id ALL "$sub2"); need pn_agent2
[ "$pn_agent2" != none ] || fail "m_dl_pn: no shared agent row after the re-add"
pn_job2=$(agent_job "$pn_agent2")
generate m_dl_pn >/dev/null
pn_started2=$(start_if_idle "$pn_job2")
pn_line=$(wait_delivered 180 "$pn_agent2" "$pn_mark" "$pn_t")
pn_rows=$(subrows "$sub2" m_t3)
same_agent=no; [ "$pn_agent2" = "$pn_agent1" ] && same_agent=yes
same_job=no; [ "$pn_job2" = "$pn_job1" ] && same_job=yes
agents="agent_before_drop=$pn_agent1 agent_after_drop=$pn_agent_drop job_row_after_drop=$pn_jobrow_drop agent_after_readd=$pn_agent2 same_agent=$same_agent same_job=$same_job first_line_at=${pn_line1%%~*} started=$pn_started1/$pn_started2"
if [ -n "$pn_line" ]; then
    read -r nf nrun <<<"$(parse_line "$pn_line")" || true
    res=no; [[ "${nf:-}" == "$pn_folders" ]] && res=yes
    absent=yes; inlist "$nrun" "$pn_list" && absent=no
    r DL.shared_readd "$res" "$agents T=$pn_t line=[${pn_line#*~}] at=${pn_line%%~*} folder=$pn_folders run_absent_at_T=$absent listed_at_T=[$pn_list] subscriber_rows=$pn_rows"
else
    r DL.shared_readd no "$agents T=$pn_t within=180s folder=$pn_folders listed_at_T=[$pn_list] subscriber_rows=$pn_rows"
fi

# ---- DL.shared_readd_kept -------------------------------------------------------------
add_pk() {
    sql -b -Q "SET NOCOUNT ON; USE $db;
DECLARE @srv sysname = @@SERVERNAME;
EXEC sp_addsubscription @publication = N'm_dl_pk', @subscriber = @srv, @destination_db = N'$sub2',
     @subscription_type = N'Push', @sync_type = N'automatic', @article = N'all';" </dev/null >&2
}
# wait_named SECONDS AGENT MARK T FOLDER: the first line after MARK and T naming FOLDER.
wait_named() {
    local start=$SECONDS l
    while :; do
        l=$(delivered "$2" "$3" "$4" | grep -F "'unc\\$5\\" | head -n 1 || true)
        [ -n "$l" ] && { printf '%s\n' "$l"; return 0; }
        (( SECONDS - start >= $1 )) && return 0
        sleep 2
    done
}
pk_agent1=$(agent_id ALL "$sub2"); need pk_agent1
[ "$pk_agent1" != none ] || fail "m_dl_pk: no shared agent before the add (m_dl_pn's should exist)"
pk_t0=$(dnow); pk_mark0=$(hmark)
add_pk
pk_agent_add=$(agent_id ALL "$sub2")
pk_job1=$(agent_job "$pk_agent_add")
generate m_dl_pk >/dev/null
pk_folders=$(pubfolders m_dl_pk)
[[ -n $pk_folders && $pk_folders != *,* ]] || fail "m_dl_pk: folder not identified: [$pk_folders]"
pk_started1=$(start_if_idle "$pk_job1")
pk_line1=$(wait_named 180 "$pk_agent_add" "$pk_mark0" "$pk_t0" "$pk_folders")
[ -n "$pk_line1" ] || fail "m_dl_pk: the first delivery by the shared agent did not happen within 180 s"

sql -b -Q "SET NOCOUNT ON; USE $db; EXEC sp_dropsubscription @publication = N'm_dl_pk', @article = N'all', @subscriber = @@SERVERNAME, @destination_db = N'$sub2';" </dev/null >&2
pk_agent_drop=$(agent_id ALL "$sub2")
pk_job_drop=none; [ "$pk_agent_drop" != none ] && pk_job_drop=$(agent_job "$pk_agent_drop")
pk_t=$(dnow); pk_mark=$(hmark); pk_list=$(runs "$pk_folders"); need pk_t pk_mark pk_list
add_pk
pk_agent2=$(agent_id ALL "$sub2"); need pk_agent2
[ "$pk_agent2" != none ] || fail "m_dl_pk: no shared agent row after the re-add"
pk_job2=$(agent_job "$pk_agent2")
pk_status=$(sql_value "SELECT CONVERT(nvarchar(100), ISNULL(STRING_AGG(CONVERT(nvarchar(10), s.status), N','), N'none')) FROM $db.dbo.syssubscriptions AS s JOIN $db.dbo.sysarticles AS a ON a.artid = s.artid JOIN $db.dbo.syspublications AS p ON p.pubid = a.pubid WHERE p.name = N'm_dl_pk' AND s.srvid >= 0")
generate m_dl_pk >/dev/null
pk_started2=$(start_if_idle "$pk_job2")
pk_line=$(wait_named 180 "$pk_agent2" "$pk_mark" "$pk_t" "$pk_folders")
pk_rows=$(subrows "$sub2" m_t1)
k_same_agent=no; [ "$pk_agent2" = "$pk_agent1" ] && [ "$pk_agent_drop" = "$pk_agent1" ] && k_same_agent=yes
k_same_job=no; [ "$pk_job2" = "$pk_job1" ] && [ "$pk_job_drop" = "$pk_job1" ] && k_same_job=yes
kagents="agent_before_add=$pk_agent1 agent_before_drop=$pk_agent_add agent_after_drop=$pk_agent_drop agent_after_readd=$pk_agent2 same_agent=$k_same_agent same_job=$k_same_job status_after_readd=$pk_status first_line_at=${pk_line1%%~*} started=$pk_started1/$pk_started2"
if [ -n "$pk_line" ]; then
    read -r kf krun <<<"$(parse_line "$pk_line")" || true
    absent=yes; inlist "$krun" "$pk_list" && absent=no
    r DL.shared_readd_kept yes "$kagents T=$pk_t line=[${pk_line#*~}] at=${pk_line%%~*} folder=$pk_folders run_absent_at_T=$absent listed_at_T=[$pk_list] subscriber_rows=$pk_rows"
else
    other=$(delivered "$pk_agent2" "$pk_mark" "$pk_t" | sed 's/^[^~]*~//' | tr '|' '/' | paste -sd '~' - || true)
    r DL.shared_readd_kept no "$kagents T=$pk_t within=180s folder=$pk_folders listed_at_T=[$pk_list] lines_above_mark=[$other] subscriber_rows=$pk_rows"
fi

# ---- controls --------------------------------------------------------------------------
cleanup
bad=0
control() { echo "21-deliveries: control failed: $*" >&2; bad=1; }
[ "${#rows[@]}" = 5 ] || control "${#rows[@]} rows, expected 5"
after=$(replservers)
[ "$after" = "$replservers_before" ] || control "MSreplservers changed: before [$replservers_before] after [$after]"
leftover=$(sql_value "SELECT (SELECT COUNT(*) FROM $dist.dbo.MSdistribution_agents WHERE publisher_db = N'$db' OR subscriber_db IN (N'$sub1', N'$sub2'))
 + (SELECT COUNT(*) FROM msdb.dbo.sysjobs WHERE name LIKE N'%-m\_dl\_%' ESCAPE N'\')
 + (SELECT COUNT(*) FROM msdb.dbo.sysjobs WHERE CONVERT(varchar(36), job_id) IN ('$pn_job1', '$pn_job2', '$pk_job2', '$pull_job'))")
[ "$leftover" = 0 ] || control "$leftover m_dl agent rows or jobs left after the cleanup"
lf=$(podman exec repllab find "$unc" -mindepth 1 -maxdepth 1 -iname '*_m_dl_*')
[ -z "$lf" ] || control "folders left: $lf"
if [ "$bad" != 0 ]; then
    for row in "${rows[@]}"; do echo "row: $row" >&2; done
    exit 1
fi
for row in "${rows[@]}"; do printf '%s\n' "$row"; done
echo "R|TOTAL|${#rows[@]}"
