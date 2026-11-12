#!/bin/bash
# The preconditions apply checks (plan 4 Task 1): the msdb permission its job operations
# need (R55), whether a disabled snapshot job starts a scheduled run (spec apply step 3),
# and the facts the LSN check of an `initialization: lsn` subscription reads (R57).
# Run through lab/campaign.sh.
#
# Objects: database m_ap_db with dbo.m_t1 (id int PRIMARY KEY, a int), 10 rows, published
# (sp_replicationdboption, sp_addlogreader_agent); publication m_ap_p (transactional,
# native, independent agent) with its snapshot agent on a schedule that never fires and
# the article m_t1; publication m_ap_p0 (same, allow_initialize_from_backup false, no
# snapshot agent) with the article m_t1. Both publications exist before the backup, so
# that AP.lsn.no_backup_flag measures the flag and not the order of the calls.
# Logins m_ap_oper (msdb user in SQLAgentOperatorRole), m_ap_user (SQLAgentUserRole) and
# m_ap_none (msdb user, no role), each with a password generated here, passed to sqlcmd on
# standard input and never printed. Each also has a user in distribution with SELECT on
# the database: the prologue reads MSsnapshot_agents and MSreplservers there, which the
# login running apply at the distributor reads anyway, so that the row measures msdb.
#
# Rows, for each login L (as L: EXECUTE AS LOGIN in one batch, REVERT after, errors caught;
# result ok, the error number, or rc<n> when a procedure returned n without raising):
#   AP.perm.L.is_operator  IS_ROLEMEMBER(N'SQLAgentOperatorRole') in msdb, 0 or 1.
#   AP.perm.L.prologue     the job prologue plan prints (jobLookup in internal/plan/agents.go,
#                          the snapshot agent of m_ap_p), run through EXEC.
#   AP.perm.L.activity     the JobIdle read (internal/plan/lists.go) on that job.
#   AP.perm.L.disable      msdb.dbo.sp_update_job @job_id, @enabled = 0 on that job (owned
#                          by sa); detail enabled_after (read as sa), then back to 1 as sa.
#   AP.perm.L.start        msdb.dbo.sp_start_job @job_id; detail ran (a snapshot history
#                          run started since the call); then wait idle as sa.
#   A refused call's detail names the object of a permission error (on=object.database)
#   and the Msg numbers printed outside the catch; never the message, which holds job ids.
# AP.disabled_schedule  sp_changepublication_snapshot to every minute, starting today at
#   00:00, then at once sp_update_job @enabled = 0 (both in one batch, at least 5 s after a
#   minute boundary and 20 s before the next); wait 150 s; runs=<n> is the snapshot history
#   runs started since the disable, detail the job's sysjobactivity starts since then and
#   the schedule read back. Then the schedule goes back to never firing.
# AP.lsn.restorehistory    a COPY_ONLY backup of m_ap_db restored as m_ap_sub: the
#   last_lsn of the backupset row msdb.dbo.restorehistory of destination m_ap_sub joins to,
#   against the last_lsn of the backupset whose media family is the backup file (equal,
#   differs, none).
# AP.lsn.backupset_database  that backupset row's database_name is m_ap_db and its
#   server_name the lab's @@SERVERNAME, both compared under the server's collation
#   (db=yes|no server=yes|no); the detail says whether server_name has the same case.
# AP.lsn.log_end_format    log_end_lsn of sys.dm_db_log_stats(DB_ID(N'm_ap_db')) written
#   as text matches ^[0-9A-F]{8}:[0-9A-F]{8}:[0-9A-F]{4}$ (yes, or no with its form).
# AP.lsn.no_backup_flag    sp_addsubscription to m_ap_sub on m_ap_p0, @sync_type =
#   N'initialize from lsn', @subscriptionlsn = the backup's last_lsn converted as
#   10-init-modes.sh does and checked (round trip, not beyond the log end of m_ap_db)
#   before the call: ok or the error number; when ok the subscription is dropped at once.
# Asserted (exit 1 with the rows on stderr otherwise): 20 rows, the LSN checks pass,
# msdb keeps no backup or restore history of m_ap_db or m_ap_sub after the cleanup, no
# m_ap_ user is left in msdb or distribution (the residue guard counts no database user),
# and MSreplservers has the same rows before and after.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"
mark=$(sql_value "SELECT CONVERT(nvarchar(30), SYSDATETIME(), 121)")

db=m_ap_db
sub=m_ap_sub
pub=m_ap_p
pub0=m_ap_p0
bak=/var/opt/mssql/data/m_ap_db.bak
logins="m_ap_oper m_ap_user m_ap_none"

rows=()
r() { rows+=("R|$1|$2|$3"); }
need() { local v; for v in "$@"; do [ -n "${!v}" ] || { echo "20-apply: empty field $v" >&2; exit 1; }; done; }

# try STATEMENTS: runs them in m_ap_db as sa outside a transaction, prints ok or the error number.
try() {
    local out
    out=$(sql -b -h -1 -Q "SET NOCOUNT ON; USE $db; DECLARE @e nvarchar(10) = N'ok';
BEGIN TRY $1 END TRY
BEGIN CATCH SET @e = CONVERT(nvarchar(10), ERROR_NUMBER()); WHILE @@TRANCOUNT > 0 ROLLBACK; END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK;
SELECT @e" </dev/null 2>&1) || { printf '%s\n' "$out" >&2; return 1; }
    printf '%s\n' "$out" | sed -e 's/[[:space:]]*$//' | grep -v '^$' | tail -n 1
}

cleaned=0
cleanup() {
    [ "$cleaned" = 1 ] && return
    cleaned=1
    stop_m_agents
    local d l
    sql -Q "SET NOCOUNT ON;
IF DB_ID(N'$db') IS NOT NULL
BEGIN
    EXEC (N'USE $db;
BEGIN TRY IF EXISTS (SELECT 1 FROM dbo.syspublications WHERE name = N''$pub0'')
    EXEC sp_dropsubscription @publication = N''$pub0'', @article = N''all'', @subscriber = N''all''; END TRY BEGIN CATCH END CATCH;
WHILE @@TRANCOUNT > 0 ROLLBACK;
BEGIN TRY IF EXISTS (SELECT 1 FROM dbo.syspublications WHERE name = N''$pub0'')
    EXEC sp_droppublication @publication = N''$pub0''; END TRY BEGIN CATCH END CATCH;
WHILE @@TRANCOUNT > 0 ROLLBACK;
BEGIN TRY IF EXISTS (SELECT 1 FROM dbo.syspublications WHERE name = N''$pub'')
    EXEC sp_droppublication @publication = N''$pub''; END TRY BEGIN CATCH END CATCH;
WHILE @@TRANCOUNT > 0 ROLLBACK;');
    BEGIN TRY EXEC sp_replicationdboption @dbname = N'$db', @optname = N'publish', @value = N'false'; END TRY BEGIN CATCH END CATCH;
    WHILE @@TRANCOUNT > 0 ROLLBACK;
END;" </dev/null >&2 || true
    for d in $sub $db; do
        sql -Q "SET NOCOUNT ON; IF DB_ID(N'$d') IS NOT NULL BEGIN ALTER DATABASE [$d] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$d]; END;
EXEC msdb.dbo.sp_delete_database_backuphistory @database_name = N'$d';" </dev/null >&2 || true
    done
    for l in $logins; do
        sql -Q "SET NOCOUNT ON;
USE msdb; IF USER_ID(N'$l') IS NOT NULL DROP USER [$l];
USE distribution; IF USER_ID(N'$l') IS NOT NULL DROP USER [$l];
IF SUSER_ID(N'$l') IS NOT NULL DROP LOGIN [$l];" </dev/null >&2 || true
    done
    podman exec repllab rm -f "$bak" >&2 || true
    podman exec repllab find /var/opt/mssql/data/ReplData/unc -mindepth 1 -maxdepth 1 -iname '*_m_*' -exec rm -rf {} + >&2 || true
    purge_stopped_orphans "$mark"
}
trap cleanup EXIT

# Leftovers of an earlier run fail this run (the trap removes them).
left=$(sql_value "SELECT (SELECT COUNT(*) FROM sys.databases WHERE name IN (N'$db', N'$sub'))
 + (SELECT COUNT(*) FROM sys.server_principals WHERE name LIKE N'm\_ap\_%' ESCAPE N'\')
 + (SELECT COUNT(*) FROM msdb.sys.database_principals WHERE name LIKE N'm\_ap\_%' ESCAPE N'\')
 + (SELECT COUNT(*) FROM distribution.sys.database_principals WHERE name LIKE N'm\_ap\_%' ESCAPE N'\')")
left_files=$(podman exec repllab find /var/opt/mssql/data -iname 'm_ap_*')
if [ "$left" != 0 ] || [ -n "$left_files" ]; then
    echo "20-apply: leftovers of an earlier run (objects=$left files=$left_files); removing them and failing" >&2
    exit 1
fi
# msdb history: none for the two databases, so that the cleanup leaves msdb as it found it.
msdb_history() { sql_value "SELECT (SELECT COUNT(*) FROM msdb.dbo.backupset WHERE database_name IN (N'$db', N'$sub')) + (SELECT COUNT(*) FROM msdb.dbo.restorehistory WHERE destination_database_name IN (N'$db', N'$sub'))"; }
hist=$(msdb_history)
if [ "$hist" != 0 ]; then
    echo "20-apply: msdb has $hist backup or restore history rows for $db or $sub; the cleanup could not restore msdb exactly" >&2
    exit 1
fi
replservers() { sql_value "SELECT CONVERT(nvarchar(4000), STRING_AGG(CONVERT(nvarchar(4000), CONCAT(srvid, N'=', srvname)), N',') WITHIN GROUP (ORDER BY srvid)) FROM distribution.dbo.MSreplservers"; }
replservers_before=$(replservers)
need replservers_before

srv=$(sql_value "SELECT CONVERT(nvarchar(128), @@SERVERNAME)")
need srv

# The database, its table and rows, the two publications.
sql -b <<SQL >&2
SET NOCOUNT ON;
CREATE DATABASE $db;
GO
USE $db;
CREATE TABLE dbo.m_t1 (id int PRIMARY KEY, a int);
INSERT dbo.m_t1 SELECT TOP (10) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), 1 FROM sys.all_columns;
EXEC sp_replicationdboption @dbname = N'$db', @optname = N'publish', @value = N'true';
EXEC sp_addlogreader_agent @job_login = NULL, @job_password = NULL, @publisher_security_mode = 1;
EXEC sp_addpublication @publication = N'$pub', @status = N'active', @allow_push = N'true',
     @independent_agent = N'true', @repl_freq = N'continuous', @sync_method = N'native';
EXEC sp_addpublication_snapshot @publication = N'$pub', @frequency_type = 1, @active_start_date = 99991231,
     @job_login = NULL, @job_password = NULL, @publisher_security_mode = 1;
EXEC sp_addarticle @publication = N'$pub', @article = N'm_t1', @source_owner = N'dbo', @source_object = N'm_t1';
EXEC sp_addpublication @publication = N'$pub0', @status = N'active', @allow_push = N'true',
     @independent_agent = N'true', @repl_freq = N'continuous', @sync_method = N'native',
     @allow_initialize_from_backup = N'false';
EXEC sp_addarticle @publication = N'$pub0', @article = N'm_t1', @source_owner = N'dbo', @source_object = N'm_t1';
SQL

# The three logins. The passwords stay in this shell and reach sqlcmd on standard input.
pw_oper="$(openssl rand -base64 18)Aa1!"
pw_user="$(openssl rand -base64 18)Aa1!"
pw_none="$(openssl rand -base64 18)Aa1!"
sql -b <<SQL >/dev/null 2>&1 || { echo "20-apply: cannot create the logins" >&2; exit 1; }
SET NOCOUNT ON;
CREATE LOGIN m_ap_oper WITH PASSWORD = N'$pw_oper';
CREATE LOGIN m_ap_user WITH PASSWORD = N'$pw_user';
CREATE LOGIN m_ap_none WITH PASSWORD = N'$pw_none';
SQL
unset pw_oper pw_user pw_none
sql -b <<SQL >&2
SET NOCOUNT ON;
USE msdb;
CREATE USER m_ap_oper FOR LOGIN m_ap_oper;
CREATE USER m_ap_user FOR LOGIN m_ap_user;
CREATE USER m_ap_none FOR LOGIN m_ap_none;
ALTER ROLE SQLAgentOperatorRole ADD MEMBER m_ap_oper;
ALTER ROLE SQLAgentUserRole ADD MEMBER m_ap_user;
GO
USE distribution;
CREATE USER m_ap_oper FOR LOGIN m_ap_oper;
CREATE USER m_ap_user FOR LOGIN m_ap_user;
CREATE USER m_ap_none FOR LOGIN m_ap_none;
GRANT SELECT TO m_ap_oper;
GRANT SELECT TO m_ap_user;
GRANT SELECT TO m_ap_none;
SQL

jobid=$(sql_value "SELECT CONVERT(varchar(36), CONVERT(uniqueidentifier, job_id)) FROM distribution.dbo.MSsnapshot_agents WHERE publication = N'$pub' AND publisher_db = N'$db' AND local_job = 1")
agentid=$(sql_value "SELECT id FROM distribution.dbo.MSsnapshot_agents WHERE publication = N'$pub' AND publisher_db = N'$db' AND local_job = 1")
need jobid agentid

# The texts plan prints: jobLookup (internal/plan/agents.go) for the snapshot agent of
# m_ap_p, and jobIdle (internal/plan/lists.go), verbatim but for the names.
prologue="DECLARE @job_id uniqueidentifier;
SELECT @job_id = sj.job_id FROM [distribution].dbo.MSsnapshot_agents AS a JOIN [distribution].dbo.MSreplservers AS ps ON ps.srvid = a.publisher_id JOIN msdb.dbo.sysjobs AS sj ON sj.job_id = CONVERT(uniqueidentifier, a.job_id) WHERE UPPER(ps.srvname) = UPPER(N'$srv') AND a.publisher_db = N'$db' AND a.publication = N'$pub' AND a.local_job = 1;
IF @job_id IS NULL THROW 50000, N'the job of publications[$pub].snapshot_agent does not exist', 1;"
jobidle="NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobactivity AS ja WHERE ja.job_id = @job_id AND ja.session_id = (SELECT MAX(ss.session_id) FROM msdb.dbo.syssessions AS ss) AND (ja.run_requested_date IS NOT NULL OR ja.start_execution_date IS NOT NULL) AND ja.stop_execution_date IS NULL)"
q() { printf '%s' "${1//\'/\'\'}"; } # doubles the quotes for an EXEC (N'...')

now() { sql_value "SELECT CONVERT(varchar(23), GETDATE(), 121)"; }
wait_idle() {
    sleep 3
    wait_until 180 "DECLARE @job_id uniqueidentifier = '$jobid'; SELECT CASE WHEN $jobidle THEN 1 ELSE 0 END" \
        || { echo "20-apply: the snapshot job of $pub is still busy after 180 s" >&2; exit 1; }
}
enabled() { sql_value "SELECT enabled FROM msdb.dbo.sysjobs WHERE job_id = '$jobid'"; }

# as LOGIN STATEMENTS: runs STATEMENTS as LOGIN from msdb, @job_id set to the snapshot
# job, @res ok unless a statement sets it; an error caught sets it to its number and the
# detail to the object of a permission error. Prints result|detail, the Msg numbers
# printed outside the catch appended to the detail.
as() {
    local out res msgs
    out=$(sql -d msdb -h -1 -Q "SET NOCOUNT ON; DECLARE @res nvarchar(20) = N'ok', @det nvarchar(4000) = N'', @rc int = 0, @m nvarchar(4000), @i int;
DECLARE @job_id uniqueidentifier = '$jobid';
EXECUTE AS LOGIN = N'$1';
BEGIN TRY $2 END TRY
BEGIN CATCH
    SET @res = CONVERT(nvarchar(20), ERROR_NUMBER());
    SET @m = ERROR_MESSAGE(); SET @i = CHARINDEX(N'on the object ''', @m);
    IF @i > 0 BEGIN
        SET @m = SUBSTRING(@m, @i + 15, 4000);
        SET @det = CONCAT(N'on=', LEFT(@m, CHARINDEX(N'''', @m) - 1));
        SET @i = CHARINDEX(N'database ''', @m);
        IF @i > 0 BEGIN SET @m = SUBSTRING(@m, @i + 10, 4000); SET @det = CONCAT(@det, N'.', LEFT(@m, CHARINDEX(N'''', @m) - 1)); END
    END
    WHILE @@TRANCOUNT > 0 ROLLBACK;
END CATCH;
REVERT;
SELECT CONCAT(N'@@', @res, N'|', @det)" </dev/null 2>&1) || true
    res=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*@@//p' | tail -n 1)
    msgs=$(printf '%s\n' "$out" | sed -n 's/^Msg \([0-9]*\),.*/\1/p' | sort -u | tr '\n' '/' | sed 's,/$,,')
    [ -n "$res" ] || res="batch-aborted|"
    [ -n "$msgs" ] && res+=" msgs=$msgs"
    printf '%s\n' "$res"
}
row() { # ID RESULT|DETAIL [EXTRA]
    local v=$2
    r "$1" "${v%%|*}" "$(printf '%s' "${v#*|}${3:-}" | sed 's/^ //')"
}

for l in $logins; do
    v=$(as "$l" "SELECT @res = CONVERT(nvarchar(20), IS_ROLEMEMBER(N'SQLAgentOperatorRole'));")
    row "AP.perm.$l.is_operator" "$v"

    v=$(as "$l" "EXEC (N'$(q "$prologue")');")
    row "AP.perm.$l.prologue" "$v"

    v=$(as "$l" "EXEC sp_executesql N'DECLARE @idle int; SELECT @idle = CASE WHEN $(q "$jobidle") THEN 1 ELSE 0 END;', N'@job_id uniqueidentifier', @job_id = @job_id;")
    row "AP.perm.$l.activity" "$v"

    v=$(as "$l" "EXEC @rc = msdb.dbo.sp_update_job @job_id = @job_id, @enabled = 0; IF @rc <> 0 SET @res = CONCAT(N'rc', @rc);")
    en=$(enabled); need en
    sql -b -Q "SET NOCOUNT ON; EXEC msdb.dbo.sp_update_job @job_id = '$jobid', @enabled = 1;" </dev/null >&2
    row "AP.perm.$l.disable" "$v" " enabled_after=$en"

    smark=$(now)
    v=$(as "$l" "EXEC @rc = msdb.dbo.sp_start_job @job_id = @job_id; IF @rc <> 0 SET @res = CONCAT(N'rc', @rc);")
    wait_idle
    ran=$(sql_value "SELECT CASE WHEN EXISTS (SELECT 1 FROM distribution.dbo.MSsnapshot_history WHERE agent_id = $agentid AND start_time >= '$smark') THEN 'yes' ELSE 'no' END")
    need ran
    row "AP.perm.$l.start" "$v" " ran=$ran"
done

# The disabled schedule. The batch runs between 5 s and 40 s past a minute, so that no
# minute boundary falls between the schedule change and the disable.
while :; do
    s=$(sql_value "SELECT DATEPART(second, GETDATE())")
    [ "$s" -ge 5 ] && [ "$s" -le 40 ] && break
    sleep 2
done
dmark=$(sql -d "$db" -b -h -1 -Q "SET NOCOUNT ON;
DECLARE @d int = CONVERT(int, CONVERT(char(8), GETDATE(), 112));
EXEC sp_changepublication_snapshot @publication = N'$pub', @frequency_type = 4, @frequency_interval = 1,
     @frequency_subday = 4, @frequency_subday_interval = 1, @active_start_date = @d, @active_start_time_of_day = 0;
EXEC msdb.dbo.sp_update_job @job_id = '$jobid', @enabled = 0;
SELECT CONVERT(varchar(23), GETDATE(), 121)" </dev/null 2>&1) || { printf '20-apply: the schedule change and disable failed: %s\n' "$dmark" >&2; exit 1; }
dmark=$(printf '%s\n' "$dmark" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' | tail -n 1)
[[ $dmark =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9:.]+$ ]] || { echo "20-apply: unexpected disable mark: $dmark" >&2; exit 1; }
sleep 150
runs=$(sql_value "SELECT COUNT(DISTINCT start_time) FROM distribution.dbo.MSsnapshot_history WHERE agent_id = $agentid AND start_time >= '$dmark'")
starts=$(sql_value "SELECT COUNT(*) FROM msdb.dbo.sysjobactivity WHERE job_id = '$jobid' AND (start_execution_date >= '$dmark' OR run_requested_date >= '$dmark')")
sched=$(sql_value "SELECT CONVERT(nvarchar(4000), STRING_AGG(CONVERT(nvarchar(4000), CONCAT(N'freq_type=', s.freq_type, N' subday_type=', s.freq_subday_type, N' subday_interval=', s.freq_subday_interval, N' schedule_enabled=', s.enabled)), N';')) FROM msdb.dbo.sysjobschedules js JOIN msdb.dbo.sysschedules s ON s.schedule_id = js.schedule_id WHERE js.job_id = '$jobid'")
en=$(enabled)
need runs starts sched en
r AP.disabled_schedule "runs=$runs" "job_starts=$starts job_enabled=$en $sched waited=150s"
back=$(try "EXEC sp_changepublication_snapshot @publication = N'$pub', @frequency_type = 1, @active_start_date = 99991231;")
[ "$back" = ok ] || { echo "20-apply: the schedule of $pub could not go back to never firing: $back" >&2; exit 1; }

# The LSN bounds.
sql -b -Q "BACKUP DATABASE $db TO DISK = N'$bak' WITH INIT, COPY_ONLY" </dev/null >&2
sql -b -Q "RESTORE DATABASE $sub FROM DISK = N'$bak' WITH MOVE N'$db' TO N'/var/opt/mssql/data/$sub.mdf', MOVE N'${db}_log' TO N'/var/opt/mssql/data/${sub}_log.ldf', RECOVERY" </dev/null >&2
bset="(SELECT TOP 1 b.backup_set_id FROM msdb.dbo.backupset b JOIN msdb.dbo.backupmediafamily f ON f.media_set_id = b.media_set_id WHERE f.physical_device_name = N'$bak' ORDER BY b.backup_set_id DESC)"
rset="(SELECT TOP 1 h.backup_set_id FROM msdb.dbo.restorehistory h WHERE h.destination_database_name = N'$sub' ORDER BY h.restore_history_id DESC)"
lsn=$(sql_value "SELECT CONVERT(varchar(30), last_lsn) FROM msdb.dbo.backupset WHERE backup_set_id = $bset")
need lsn
res=$(sql_value "SELECT CASE WHEN $rset IS NULL THEN 'none' WHEN (SELECT last_lsn FROM msdb.dbo.backupset WHERE backup_set_id = $rset) = $lsn THEN 'equal' ELSE 'differs' END")
same=$(sql_value "SELECT CASE WHEN $rset = $bset THEN 'yes' ELSE 'no' END")
need res same
r AP.lsn.restorehistory "$res" "same_backupset_row=$same"
res=$(sql_value "SELECT CONCAT(N'db=', CASE WHEN database_name = N'$db' THEN N'yes' ELSE N'no' END, N' server=', CASE WHEN server_name = @@SERVERNAME THEN N'yes' ELSE N'no' END) FROM msdb.dbo.backupset WHERE backup_set_id = $rset")
case_same=$(sql_value "SELECT CASE WHEN CONVERT(varbinary(256), server_name) = CONVERT(varbinary(256), CONVERT(nvarchar(128), @@SERVERNAME)) THEN 'yes' ELSE 'no' END FROM msdb.dbo.backupset WHERE backup_set_id = $rset")
need res case_same
r AP.lsn.backupset_database "$res" "server_name_same_case=$case_same"
logend=$(sql_value "SELECT CONVERT(nvarchar(30), log_end_lsn) FROM sys.dm_db_log_stats(DB_ID(N'$db'))")
need logend
if [[ $logend =~ ^[0-9A-F]{8}:[0-9A-F]{8}:[0-9A-F]{4}$ ]]; then
    r AP.lsn.log_end_format yes "form=8:8:4 hex upper"
else
    r AP.lsn.log_end_format no "form=$(printf '%s' "$logend" | sed 's/[0-9]/9/g; s/[A-Fa-f]/x/g')"
fi

# The backup's last_lsn as binary(10), converted and checked as 10-init-modes.sh does.
log_end_bin="(SELECT CONVERT(binary(4), N'0x' + LEFT(e, 8), 1) + CONVERT(binary(4), N'0x' + SUBSTRING(e, 10, 8), 1) + CONVERT(binary(2), N'0x' + RIGHT(e, 4), 1) FROM (SELECT CONVERT(nvarchar(30), log_end_lsn) AS e FROM sys.dm_db_log_stats(DB_ID(N'$db'))) x)"
conv="DECLARE @lsn numeric(25,0) = $lsn;
DECLARE @vlf bigint = CONVERT(bigint, (@lsn - @lsn % 1000000000000000) / 1000000000000000),
        @blk bigint = CONVERT(bigint, (@lsn % 1000000000000000 - @lsn % 100000) / 100000),
        @slot bigint = CONVERT(bigint, @lsn % 100000);
DECLARE @b binary(10) = SUBSTRING(CONVERT(binary(8), @vlf), 5, 4) + SUBSTRING(CONVERT(binary(8), @blk), 5, 4) + SUBSTRING(CONVERT(binary(8), @slot), 7, 2);"
lsnbin=$(sql_value "$conv SELECT CONVERT(varchar(30), @b, 1)")
roundtrip=$(sql_value "$conv SELECT CASE WHEN CONVERT(numeric(25,0), CONVERT(bigint, SUBSTRING(@b, 1, 4))) * 1000000000000000 + CONVERT(numeric(25,0), CONVERT(bigint, SUBSTRING(@b, 5, 4))) * 100000 + CONVERT(bigint, SUBSTRING(@b, 9, 2)) = @lsn THEN 'equal' ELSE 'differs' END")
need lsnbin roundtrip
lsn_in_log=$(sql_value "SELECT CASE WHEN $lsnbin > 0x00000000000000000000 AND $lsnbin <= $log_end_bin THEN 'yes' ELSE 'no' END")
need lsn_in_log
if [ "$roundtrip" != equal ] || [ "$lsn_in_log" != yes ]; then
    echo "20-apply: backup LSN check failed before the subscription: roundtrip=$roundtrip not_beyond_log_end=$lsn_in_log" >&2
    exit 1
fi
res=$(try "EXEC sp_addsubscription @publication = N'$pub0', @subscriber = @@SERVERNAME, @destination_db = N'$sub',
     @subscription_type = N'Push', @sync_type = N'initialize from lsn', @subscriptionlsn = $lsnbin, @article = N'all';")
need res
dropped=none
if [ "$res" = ok ]; then
    dropped=$(try "EXEC sp_dropsubscription @publication = N'$pub0', @article = N'all', @subscriber = @@SERVERNAME, @destination_db = N'$sub';")
fi
r AP.lsn.no_backup_flag "$res" "allow_initialize_from_backup=false roundtrip=$roundtrip not_beyond_log_end=$lsn_in_log drop=$dropped"

# Controls.
bad=0
control() { echo "20-apply: control failed: $*" >&2; bad=1; }
[ "${#rows[@]}" = 20 ] || control "${#rows[@]} rows, expected 20"

cleanup
hist_after=$(msdb_history)
[ "$hist_after" = 0 ] || control "msdb keeps $hist_after backup or restore history rows after the cleanup"
users_after=$(sql_value "SELECT (SELECT COUNT(*) FROM msdb.sys.database_principals WHERE name LIKE N'm\_ap\_%' ESCAPE N'\') + (SELECT COUNT(*) FROM distribution.sys.database_principals WHERE name LIKE N'm\_ap\_%' ESCAPE N'\')")
[ "$users_after" = 0 ] || control "$users_after m_ap_ users left in msdb or distribution"
[ "$(replservers)" = "$replservers_before" ] || control "MSreplservers changed: $replservers_before -> $(replservers)"
if [ "$bad" != 0 ]; then
    for row in "${rows[@]}"; do echo "row: $row" >&2; done
    exit 1
fi
for row in "${rows[@]}"; do printf '%s\n' "$row"; done
echo "R|TOTAL|${#rows[@]}"
