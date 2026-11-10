#!/bin/bash
# What changing a subscription, a subscriber, an agent, a profile binding, a shared
# distribution agent and the distributor does (campaign item 5): the result, and
# whether it disturbs subscriptions or jobs. Run through lab/campaign.sh.
#
# Publications on the tables m_t1, m_t2, m_t3 of Sales:
#   m_p    immediate_sync = 1, own distribution agent, push subscription to m_sub
#   m_sh1  independent_agent = 0 (shared agent 'ALL'), m_t2, push subscription to m_shsub
#   m_sh2  the same on m_t3, to the same database m_shsub (so the shared agent has two
#          subscriptions)
# Snapshots run one at a time and are delivered before anything is measured. Every
# snapshot agent has a schedule that never fires.
#
# Property lists. The parameters of sp_changesubscriber, sp_changelogreader_agent,
# sp_changepublication_snapshot, sp_changedistributiondb, sp_changedistpublisher and
# sp_changesubscription are the lists of sys.all_parameters on the lab, which agree
# with their Microsoft Learn pages (fetched 2026-11-10). The property names of
# sp_changesubscription, sp_changedistributiondb and sp_changedistpublisher are values
# of a parameter and so come from Learn; SUB.m_bogus asks for a name that exists nowhere
# and records what the procedure answers. DST.sp_changedistpublisher.trusted is the
# brief's property, absent from Learn: the row records what the lab says.
#
# Rows:
#   CTL.noop        control: a rolled-back transaction that changes nothing must show nothing
#   SUB.<property>  sp_changesubscription on m_p, one property, rolled back
#   SBR.<param>     sp_changesubscriber on @@SERVERNAME, one parameter, rolled back
#   AGT.<proc>.<p>  sp_changelogreader_agent, sp_changepublication_snapshot, and the
#                   distribution agent properties of sp_changesubscription, rolled back
#   PRF.<case>      binding the snapshot agent of m_p to the profile m_prof
#   DST.<proc>.<p>  distributor settings, set then restored (not rollbackable: say so)
#   SHR.after1/2    shared agent row and job after the subscription of m_sh1, then m_sh2, is dropped
# A change row records changed_inside=[...]: which of the fingerprints (status per
# publication, syssubscriptions rows, agent rows, replication jobs, their schedules and
# steps) differ while the change is applied (n/a when the call was refused), and
# after_restore_differs=[...]: which differ once it is rolled back or restored (empty
# means nothing was left behind; a rolled-back row that differs fails the run).
#
# Asserted, exit 1 on a mismatch (rows printed on stderr as "row: ..."): the control
# shows no change, PRF.msdb-prefix is 21482, PRF.distribution-prefix is ok and stores the
# id of m_prof, two SHR rows, the row count. M_ONLY='SUB.memory_optimized SHR.after1'
# runs those rows alone (the whole setup still runs, no assertions, the run exits 1).
set -euo pipefail
. "$(dirname "$0")/../lib.sh"

EXPECTED_ROWS=75
pubs="m_p m_sh1 m_sh2"
rows=()
# A row of exactly 256 characters is what campaign.sh reads as a sqlcmd cut (the row of
# AGT.sp_changelogreader_agent.job_security_mode is 256 long by chance, message included):
# it gets a trailing period so that the guard keeps its meaning.
r() {
    local row="R|$1|$2|$3"
    (( ${#row} == 256 )) && row+=" ."
    rows+=("$row")
}
want() { [ -z "${M_ONLY:-}" ] || [[ " $M_ONLY " == *" $1 "* ]]; }

teardown() {
    sql -Q "SET NOCOUNT ON; USE Sales;
DECLARE @p sysname;
DECLARE c CURSOR LOCAL FOR SELECT name FROM dbo.syspublications WHERE name LIKE N'm\_%' ESCAPE N'\';
OPEN c; FETCH NEXT FROM c INTO @p;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY EXEC sp_dropsubscription @publication = @p, @article = N'all', @subscriber = N'all'; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC sp_droppublication @publication = @p; END TRY BEGIN CATCH END CATCH;
    FETCH NEXT FROM c INTO @p;
END;
CLOSE c; DEALLOCATE c;
DECLARE @id int;
WHILE 1 = 1
BEGIN
    SET @id = (SELECT TOP 1 profile_id FROM msdb.dbo.MSagent_profiles WHERE profile_name LIKE N'm\_%' ESCAPE N'\');
    IF @id IS NULL BREAK;
    EXEC distribution.dbo.sp_drop_agent_profile @profile_id = @id;
END;
DROP TABLE IF EXISTS dbo.m_t1, dbo.m_t2, dbo.m_t3;
GO
DECLARE @d sysname, @s nvarchar(400);
DECLARE c2 CURSOR LOCAL FOR SELECT name FROM sys.databases WHERE name IN (N'm_sub', N'm_shsub');
OPEN c2; FETCH NEXT FROM c2 INTO @d;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @s = N'ALTER DATABASE ' + QUOTENAME(@d) + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE ' + QUOTENAME(@d) + N';';
    EXEC (@s);
    FETCH NEXT FROM c2 INTO @d;
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
left=$(sql_value "SELECT (SELECT COUNT(*) FROM Sales.dbo.syspublications WHERE name LIKE N'm\_%' ESCAPE N'\') + (SELECT COUNT(*) FROM sys.databases WHERE name LIKE N'm\_%' ESCAPE N'\') + (SELECT COUNT(*) FROM Sales.sys.objects WHERE name LIKE N'm\_%' ESCAPE N'\') + (SELECT COUNT(*) FROM msdb.dbo.MSagent_profiles WHERE profile_name LIKE N'm\_%' ESCAPE N'\')") || exit 1
left_files=$(podman exec repllab find /var/opt/mssql/data/ReplData/unc -mindepth 1 -maxdepth 1 -iname '*_m_*')
if [ "$left" != 0 ] || [ -n "$left_files" ]; then
    echo "07-changes: leftovers of an earlier run (objects=$left files=$left_files); removing them and failing" >&2
    exit 1
fi

need() { local v; for v in "$@"; do [ -n "${!v}" ] || { echo "07-changes: empty field $v" >&2; exit 1; }; done; }
now() { sql_value "SELECT CONVERT(varchar(23), SYSDATETIME(), 121)"; }

# The distribution agent of a publication/subscriber database.
agent_pred() { # PUB DB
    case $1 in
        m_p) echo "a.publication = N'm_p' AND a.subscriber_db = N'm_sub'" ;;
        *)   echo "a.publication = N'ALL' AND a.subscriber_db = N'm_shsub'" ;;
    esac
}
snapshot_done() { # PUB MARK
    wait_until 300 "SELECT CASE WHEN EXISTS (SELECT 1 FROM distribution.dbo.MSsnapshot_history h JOIN distribution.dbo.MSsnapshot_agents a ON a.id = h.agent_id WHERE a.publication = N'$1' AND h.time >= '$2' AND h.runstatus = 2)
        AND EXISTS (SELECT 1 FROM distribution.dbo.MSdistribution_history h JOIN distribution.dbo.MSdistribution_agents a ON a.id = h.agent_id WHERE $(agent_pred "$1") AND h.time >= '$2' AND h.comments LIKE N'Delivered snapshot%') THEN 1 ELSE 0 END"
}

sql -Q "SET NOCOUNT ON; USE Sales;
CREATE TABLE dbo.m_t1 (id int PRIMARY KEY, a int); INSERT dbo.m_t1 VALUES (1, 1);
CREATE TABLE dbo.m_t2 (id int PRIMARY KEY, a int); INSERT dbo.m_t2 VALUES (1, 1);
CREATE TABLE dbo.m_t3 (id int PRIMARY KEY, a int); INSERT dbo.m_t3 VALUES (1, 1);
CREATE DATABASE m_sub; CREATE DATABASE m_shsub" </dev/null

# sp_addsubscription creates and starts the push agent itself on 2022; the explicit
# sp_addpushsubscription_agent call keeps the script valid on 2019.
sql <<'SQL'
SET NOCOUNT ON;
USE Sales;
DECLARE @srv sysname = @@SERVERNAME;
EXEC sp_addpublication @publication = N'm_p', @status = N'active', @allow_push = N'true',
     @independent_agent = N'true', @immediate_sync = N'true', @repl_freq = N'continuous', @sync_method = N'concurrent';
EXEC sp_addpublication_snapshot @publication = N'm_p', @frequency_type = 1, @active_start_date = 99991231,
     @job_login = NULL, @job_password = NULL, @publisher_security_mode = 1;
EXEC sp_addarticle @publication = N'm_p', @article = N'm_t1', @source_owner = N'dbo', @source_object = N'm_t1';
EXEC sp_addsubscription @publication = N'm_p', @subscriber = @srv, @destination_db = N'm_sub',
     @subscription_type = N'Push', @sync_type = N'automatic', @article = N'all';
EXEC sp_addpushsubscription_agent @publication = N'm_p', @subscriber = @srv, @subscriber_db = N'm_sub',
     @job_login = NULL, @job_password = NULL, @subscriber_security_mode = 1;
EXEC sp_addpublication @publication = N'm_sh1', @status = N'active', @allow_push = N'true',
     @independent_agent = N'false', @immediate_sync = N'false', @repl_freq = N'continuous', @sync_method = N'concurrent';
EXEC sp_addpublication_snapshot @publication = N'm_sh1', @frequency_type = 1, @active_start_date = 99991231,
     @job_login = NULL, @job_password = NULL, @publisher_security_mode = 1;
EXEC sp_addarticle @publication = N'm_sh1', @article = N'm_t2', @source_owner = N'dbo', @source_object = N'm_t2';
EXEC sp_addsubscription @publication = N'm_sh1', @subscriber = @srv, @destination_db = N'm_shsub',
     @subscription_type = N'Push', @sync_type = N'automatic', @article = N'all';
EXEC sp_addpushsubscription_agent @publication = N'm_sh1', @subscriber = @srv, @subscriber_db = N'm_shsub',
     @job_login = NULL, @job_password = NULL, @subscriber_security_mode = 1;
EXEC sp_addpublication @publication = N'm_sh2', @status = N'active', @allow_push = N'true',
     @independent_agent = N'false', @immediate_sync = N'false', @repl_freq = N'continuous', @sync_method = N'concurrent';
EXEC sp_addpublication_snapshot @publication = N'm_sh2', @frequency_type = 1, @active_start_date = 99991231,
     @job_login = NULL, @job_password = NULL, @publisher_security_mode = 1;
EXEC sp_addarticle @publication = N'm_sh2', @article = N'm_t3', @source_owner = N'dbo', @source_object = N'm_t3';
EXEC sp_addsubscription @publication = N'm_sh2', @subscriber = @srv, @destination_db = N'm_shsub',
     @subscription_type = N'Push', @sync_type = N'automatic', @article = N'all';
EXEC sp_addpushsubscription_agent @publication = N'm_sh2', @subscriber = @srv, @subscriber_db = N'm_shsub',
     @job_login = NULL, @job_password = NULL, @subscriber_security_mode = 1;
GO
SQL

# One snapshot at a time (two together on shared tables failed once in 05-snapshot-flag).
for p in $pubs; do
    mark=$(now)
    sql -Q "SET NOCOUNT ON; EXEC Sales.dbo.sp_startpublication_snapshot @publication = N'$p'" </dev/null >&2
    snapshot_done "$p" "$mark" || { echo "07-changes: snapshot of $p not delivered" >&2; exit 1; }
done
st=$(sql_value "SELECT STRING_AGG(CONVERT(nvarchar(10), s.status), N'/') FROM Sales.dbo.syssubscriptions s JOIN Sales.dbo.sysarticles a ON a.artid = s.artid JOIN Sales.dbo.syspublications p ON p.pubid = a.pubid WHERE p.name LIKE N'm\_%' ESCAPE N'\' AND s.srvid >= 0")
[ "$st" = 2/2/2 ] || { echo "07-changes: subscriptions not all active after the snapshots: $st" >&2; exit 1; }

# The profile of the PRF rows.
prof=$(sql_value "DECLARE @p int; EXEC distribution.dbo.sp_add_agent_profile @profile_id = @p OUTPUT, @profile_name = N'm_prof', @agent_type = 1, @profile_type = 1, @description = N'm_ campaign profile', @default = 0; SELECT @p")
need prof

# Fingerprint inserted into @f under phase $1: what a change could disturb.
JOBS="(SELECT j.job_id FROM msdb.dbo.sysjobs j JOIN msdb.dbo.syscategories c ON c.category_id = j.category_id WHERE c.name LIKE N'REPL-%')"
hash() { echo "ISNULL(CONVERT(nvarchar(34), HASHBYTES('MD5', CONVERT(nvarchar(max), ($1))), 2), N'empty')"; }
fp() { cat <<SQL
INSERT @f SELECT N'$1', N'status', ISNULL((SELECT CONVERT(nvarchar(100), STRING_AGG(CONVERT(nvarchar(100), q.p + N'=' + q.st), N',') WITHIN GROUP (ORDER BY q.p, q.st)) FROM (SELECT DISTINCT p.name AS p, CONVERT(nvarchar(10), s.status) AS st FROM Sales.dbo.syssubscriptions s JOIN Sales.dbo.sysarticles a ON a.artid = s.artid JOIN Sales.dbo.syspublications p ON p.pubid = a.pubid WHERE s.srvid >= 0) q), N'none')
UNION ALL SELECT N'$1', N'subs', $(hash "SELECT * FROM Sales.dbo.syssubscriptions ORDER BY artid, srvid, dest_db FOR XML RAW, BINARY BASE64")
UNION ALL SELECT N'$1', N'dist_agents', $(hash "SELECT * FROM distribution.dbo.MSdistribution_agents ORDER BY id FOR XML RAW, BINARY BASE64")
UNION ALL SELECT N'$1', N'snap_agents', $(hash "SELECT * FROM distribution.dbo.MSsnapshot_agents ORDER BY id FOR XML RAW, BINARY BASE64")
UNION ALL SELECT N'$1', N'logreader', $(hash "SELECT * FROM distribution.dbo.MSlogreader_agents ORDER BY id FOR XML RAW, BINARY BASE64")
UNION ALL SELECT N'$1', N'subscriber_info', $(hash "SELECT * FROM distribution.dbo.MSsubscriber_info ORDER BY publisher, subscriber FOR XML RAW, BINARY BASE64")
UNION ALL SELECT N'$1', N'subscriber_sched', $(hash "SELECT * FROM distribution.dbo.MSsubscriber_schedule ORDER BY publisher, subscriber, agent_type FOR XML RAW, BINARY BASE64")
UNION ALL SELECT N'$1', N'distributor', $(hash "SELECT d.*, p.name AS pname, p.distribution_db, p.security_mode, p.active, p.working_directory, p.trusted FROM msdb.dbo.MSdistributiondbs d CROSS JOIN msdb.dbo.MSdistpublishers p FOR XML RAW, BINARY BASE64")
UNION ALL SELECT N'$1', N'jobs', $(hash "SELECT * FROM msdb.dbo.sysjobs WHERE job_id IN $JOBS ORDER BY job_id FOR XML RAW, BINARY BASE64")
UNION ALL SELECT N'$1', N'schedules', $(hash "SELECT js.job_id, ss.freq_type, ss.freq_interval, ss.freq_subday_type, ss.freq_subday_interval, ss.freq_relative_interval, ss.freq_recurrence_factor, ss.active_start_date, ss.active_end_date, ss.active_start_time, ss.active_end_time, ss.enabled FROM msdb.dbo.sysjobschedules js JOIN msdb.dbo.sysschedules ss ON ss.schedule_id = js.schedule_id WHERE js.job_id IN $JOBS ORDER BY js.job_id, ss.schedule_id FOR XML RAW, BINARY BASE64")
UNION ALL SELECT N'$1', N'steps', $(hash "SELECT job_id, step_id, step_name, subsystem, command, database_name, proxy_id, flags FROM msdb.dbo.sysjobsteps WHERE job_id IN $JOBS ORDER BY job_id, step_id FOR XML RAW, BINARY BASE64");
SQL
}

# run_case ID TXN SET RESTORE READ
#   TXN 1: SET runs in a transaction, rolled back in the same batch. TXN 0: SET is
#   applied, then RESTORE (T-SQL using @vb, the value read before) puts it back.
#   READ: a scalar expression for the setting itself (N'' when there is none).
run_case() {
    local id=$1 txn=$2 set=$3 restore=$4 read=${5:-N\'\'} begin='' out line
    want "$id" || return 0
    [ "$txn" = 1 ] && begin="BEGIN TRAN;"
    [ -n "$restore" ] || restore="SET @rc = 0;"
    out=$(sql -h -1 -Q "$(cat <<SQL
SET NOCOUNT ON;
USE Sales;
DECLARE @f TABLE (ph nchar(1), k nvarchar(20), v nvarchar(100));
DECLARE @res nvarchar(20) = N'ok', @msg nvarchar(200) = N'', @rc int = 0, @vb nvarchar(400), @vi nvarchar(400) = N'', @va nvarchar(400),
        @ch nvarchar(400), @rb nvarchar(400), @inside int = 0, @note nvarchar(200) = N'';
$(fp B)
SET @vb = CONVERT(nvarchar(400), $read);
BEGIN TRY
    $begin
    $set
    IF @rc <> 0 SET @res = N'rc' + CONVERT(nvarchar(10), @rc);
    SET @inside = 1;
    $(fp I)
    SET @vi = CONVERT(nvarchar(400), $read);
    WHILE @@TRANCOUNT > 0 ROLLBACK;
END TRY
BEGIN CATCH
    SET @res = CONVERT(nvarchar(20), ERROR_NUMBER());
    SET @msg = LEFT(REPLACE(REPLACE(REPLACE(ERROR_MESSAGE(), N'|', N'/'), CHAR(13), N' '), CHAR(10), N' '), 200);
    WHILE @@TRANCOUNT > 0 ROLLBACK;
END CATCH;
BEGIN TRY
    $restore
END TRY
BEGIN CATCH
    SET @note = N' RESTORE_FAILED ' + LEFT(REPLACE(ERROR_MESSAGE(), N'|', N'/'), 150);
END CATCH;
$(fp A)
SET @va = CONVERT(nvarchar(400), $read);
SELECT @ch = ISNULL(STRING_AGG(CONVERT(nvarchar(4000), b.k), N','), N'') FROM @f b JOIN @f i ON i.k = b.k AND i.ph = N'I' WHERE b.ph = N'B' AND b.v <> i.v;
SELECT @rb = ISNULL(STRING_AGG(CONVERT(nvarchar(4000), b.k), N','), N'') FROM @f b JOIN @f a ON a.k = b.k AND a.ph = N'A' WHERE b.ph = N'B' AND b.v <> a.v;
SELECT CONVERT(nvarchar(4000), N'R|$id|' + @res + N'|' + CASE WHEN @inside = 1 THEN N'changed_inside=[' + @ch + N']' ELSE N'changed_inside=n/a(refused)' END
    + N' after_restore_differs=[' + @rb + N']'
    + CASE WHEN LEN(@vb) > 0 OR LEN(@vi) > 0 THEN N' value_before=' + ISNULL(@vb, N'NULL') + N' inside=' + CASE WHEN @inside = 1 THEN ISNULL(@vi, N'NULL') ELSE N'n/a' END + N' after=' + ISNULL(@va, N'NULL') ELSE N'' END
    + CASE WHEN @res <> N'ok' THEN N' msg=' + @msg ELSE N'' END + @note);
SQL
)" </dev/null 2>&1) || { printf '%s\n' "$out" >&2; exit 1; }
    line=$(printf '%s\n' "$out" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep '^R|' || true)
    if [ "$(printf '%s\n' "$line" | grep -c '^R|')" != 1 ]; then
        printf '07-changes: %s did not print one row:\n%s\n' "$id" "$out" >&2
        exit 1
    fi
    # R|id|res|detail
    IFS='|' read -r _ rid rres rdetail <<<"$line"
    r "$rid" "$rres" "$rdetail"
    if [[ $rdetail == *RESTORE_FAILED* ]]; then echo "07-changes: $id: restore failed: $rdetail" >&2; exit 1; fi
    local rbd=${rdetail#*after_restore_differs=[}; rbd=${rbd%%]*}
    if [ "$txn" = 1 ] && [ -n "$rbd" ]; then echo "07-changes: $id: rolled back but state differs: $rbd" >&2; exit 1; fi
    if [ "$txn" = 0 ] && [ -n "${rbd//jobs/}" ]; then echo "07-changes: $id: not restored: $rbd" >&2; exit 1; fi
}

# ---------------------------------------------------------------- control
run_case CTL.noop 1 "SET @rc = 0;" ""

# ---------------------------------------------------------------- SUB
sub() { # PROP VALUE
    echo "EXEC @rc = sys.sp_changesubscription @publication = N'm_p', @article = N'all', @subscriber = @@SERVERNAME, @destination_db = N'm_sub', @property = N'$1', @value = N'$2';"
}
SUBREAD="(SELECT CONCAT(a.subscriber_login, N'/sec=', a.subscriber_security_mode, N'/streams=', a.subscriptionstreams, N'/type=', a.subscriber_type, N'/memopt=', a.memory_optimized) FROM distribution.dbo.MSdistribution_agents a WHERE a.publication = N'm_p' AND a.subscriber_db = N'm_sub')"
for pv in subscriber_login=m_login subscriber_password=M_pass1! subscriber_security_mode=0 subscriptionstreams=2 \
          subscriber_type=3 memory_optimized=1 subscriber_catalog=m_x subscriber_datasource=m_x subscriber_location=m_x \
          subscriber_provider=m_x subscriber_providerstring=m_x m_bogus=1; do
    run_case "SUB.${pv%%=*}" 1 "$(sub "${pv%%=*}" "${pv#*=}")" "" "$SUBREAD"
done

# ---------------------------------------------------------------- SBR
sbr() { # PARAM VALUE (VALUE is a T-SQL literal)
    echo "EXEC @rc = sys.sp_changesubscriber @subscriber = @@SERVERNAME, @$1 = $2;"
}
SBRREAD="(SELECT CONCAT(i.type, N'/', i.login, N'/', i.description, N'/sec=', i.security_mode, N'/sched=', ISNULL((SELECT STRING_AGG(CONCAT(s.agent_type, N':', s.frequency_type, N',', s.frequency_interval, N',', s.frequency_subday, N',', s.frequency_subday_interval, N',', s.active_start_time_of_day, N',', s.active_end_time_of_day, N',', s.active_start_date, N',', s.active_end_date), N';') FROM distribution.dbo.MSsubscriber_schedule s WHERE s.subscriber = i.subscriber), N'none')) FROM distribution.dbo.MSsubscriber_info i WHERE i.subscriber = @@SERVERNAME)"
for pv in type=1 login=N\'m_login\' password=N\'M_pass1!\' commit_batch_size=100 status_batch_size=100 flush_frequency=1 \
          frequency_type=4 frequency_interval=1 frequency_relative_interval=1 frequency_recurrence_factor=1 \
          frequency_subday=4 frequency_subday_interval=5 active_start_time_of_day=10000 active_end_time_of_day=200000 \
          active_start_date=20300101 active_end_date=20400101 description=N\'m_desc\' security_mode=0 publisher=N\'m_x\'; do
    run_case "SBR.${pv%%=*}" 1 "$(sbr "${pv%%=*}" "${pv#*=}")" "" "$SBRREAD"
done

# ---------------------------------------------------------------- AGT
# The distribution agent properties of sp_changesubscription.
run_case AGT.sp_changesubscription.distrib_job_login 1 "$(sub distrib_job_login 'REPLLAB\m_nobody')" ""
run_case AGT.sp_changesubscription.distrib_job_password 1 "$(sub distrib_job_password 'M_pass1!')" ""
lr() { echo "EXEC @rc = sys.sp_changelogreader_agent @$1 = $2;"; }
for pv in job_login=N\'REPLLAB\\m_nobody\' job_password=N\'M_pass1!\' publisher_security_mode=0 publisher_login=N\'m_login\' \
          publisher_password=N\'M_pass1!\' publisher=N\'m_x\' job_security_mode=1; do
    run_case "AGT.sp_changelogreader_agent.${pv%%=*}" 1 "$(lr "${pv%%=*}" "${pv#*=}")" ""
done
sn() { echo "EXEC @rc = sys.sp_changepublication_snapshot @publication = N'm_p', @$1 = $2;"; }
for pv in frequency_type=4 frequency_interval=1 frequency_subday=4 frequency_subday_interval=10 frequency_relative_interval=1 \
          frequency_recurrence_factor=1 active_start_date=20300101 active_end_date=20400101 active_start_time_of_day=10000 \
          active_end_time_of_day=200000 snapshot_job_name=N\'m_job\' publisher_security_mode=0 publisher_login=N\'m_login\' \
          publisher_password=N\'M_pass1!\' job_login=N\'REPLLAB\\m_nobody\' job_password=N\'M_pass1!\' publisher=N\'m_x\' job_security_mode=1; do
    case ${pv%%=*} in
        snapshot_job_name) rd="(SELECT j.name FROM msdb.dbo.sysjobs j JOIN distribution.dbo.MSsnapshot_agents a ON j.job_id = CONVERT(uniqueidentifier, a.job_id) WHERE a.publication = N'm_p')" ;;
        *) rd="" ;;
    esac
    run_case "AGT.sp_changepublication_snapshot.${pv%%=*}" 1 "$(sn "${pv%%=*}" "${pv#*=}")" "" "$rd"
done
# frequency_type alone is refused (14278: the daily schedule needs an interval); both together:
run_case AGT.sp_changepublication_snapshot.frequency_type+frequency_interval 1 \
    "EXEC @rc = sys.sp_changepublication_snapshot @publication = N'm_p', @frequency_type = 4, @frequency_interval = 1;" ""

# ---------------------------------------------------------------- PRF
# Binds the snapshot agent of m_p to m_prof inside a transaction rolled back in the
# same batch; the profile id stored in MSsnapshot_agents is read before the rollback.
# The current database is Sales (the publication database); PRF.*.cwd-distribution
# repeat the two prefixed calls with the current database distribution, and the plain
# name (no prefix) is measured from Sales and from distribution.
prf_case() { # ID DB CALL
    local out line
    want "$1" || return 0
    out=$(sql -h -1 -Q "SET NOCOUNT ON; USE $2;
DECLARE @aid int = (SELECT id FROM distribution.dbo.MSsnapshot_agents WHERE publication = N'm_p');
DECLARE @pid int = (SELECT profile_id FROM msdb.dbo.MSagent_profiles WHERE profile_name = N'm_prof');
DECLARE @old int = (SELECT profile_id FROM distribution.dbo.MSsnapshot_agents WHERE id = @aid);
DECLARE @res nvarchar(20) = N'ok', @msg nvarchar(200) = N'', @new nvarchar(20) = N'n/a', @after int, @note nvarchar(100) = N'rolled_back';
BEGIN TRY
    BEGIN TRAN;
    EXEC $3 @agent_type = 1, @agent_id = @aid, @profile_id = @pid;
    SET @new = CONVERT(nvarchar(20), (SELECT profile_id FROM distribution.dbo.MSsnapshot_agents WHERE id = @aid));
    WHILE @@TRANCOUNT > 0 ROLLBACK;
END TRY
BEGIN CATCH
    SET @res = CONVERT(nvarchar(20), ERROR_NUMBER());
    SET @msg = LEFT(REPLACE(REPLACE(REPLACE(ERROR_MESSAGE(), N'|', N'/'), CHAR(13), N' '), CHAR(10), N' '), 200);
    WHILE @@TRANCOUNT > 0 ROLLBACK;
END CATCH;
SET @after = (SELECT profile_id FROM distribution.dbo.MSsnapshot_agents WHERE id = @aid);
IF @after <> @old
BEGIN
    EXEC distribution.dbo.sp_update_agent_profile @agent_type = 1, @agent_id = @aid, @profile_id = @old;
    SET @note = N'NOT_ROLLED_BACK restored explicitly';
END;
SELECT CONVERT(nvarchar(4000), N'R|$1|' + @res + N'|current_db=$2 call=$3 profile_id_before=' + CONVERT(nvarchar(10), @old) + N' stored_in_MSsnapshot_agents=' + @new
    + N' m_prof_id=' + CONVERT(nvarchar(10), @pid) + N' after_rollback=' + CONVERT(nvarchar(10), @after) + N' ' + @note + CASE WHEN @res <> N'ok' THEN N' msg=' + @msg ELSE N'' END);" </dev/null 2>&1) || { printf '%s\n' "$out" >&2; exit 1; }
    line=$(printf '%s\n' "$out" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep '^R|' || true)
    [ "$(printf '%s\n' "$line" | grep -c '^R|')" = 1 ] || { printf '07-changes: %s did not print one row:\n%s\n' "$1" "$out" >&2; exit 1; }
    IFS='|' read -r _ rid rres rdetail <<<"$line"
    r "$rid" "$rres" "$rdetail"
    [[ $rdetail == *NOT_ROLLED_BACK* ]] && { echo "07-changes: $1: binding not rolled back" >&2; exit 1; }
    return 0
}
prf_case PRF.msdb-prefix Sales msdb.dbo.sp_update_agent_profile
prf_case PRF.distribution-prefix Sales distribution.dbo.sp_update_agent_profile
prf_case PRF.plain-name Sales sp_update_agent_profile
prf_case PRF.msdb-prefix.cwd-distribution distribution msdb.dbo.sp_update_agent_profile
prf_case PRF.distribution-prefix.cwd-distribution distribution distribution.dbo.sp_update_agent_profile
prf_case PRF.plain-name.cwd-distribution distribution sp_update_agent_profile

# ---------------------------------------------------------------- DST
# Distributor settings are not transactional here (the call is made, then undone by a
# second call with the value read before), so a restore is checked, not assumed.
db() { echo "EXEC @rc = sys.sp_changedistributiondb @database = N'distribution', @property = N'$1', @value = $2;"; }
dbread() { echo "(SELECT CONVERT(nvarchar(100), $1) FROM msdb.dbo.MSdistributiondbs WHERE name = N'distribution')"; }
dp() { echo "EXEC @rc = sys.sp_changedistpublisher @publisher = @@SERVERNAME, @property = N'$1', @value = $2;"; }
dpread() { echo "(SELECT CONVERT(nvarchar(100), $1) FROM msdb.dbo.MSdistpublishers WHERE name = @@SERVERNAME)"; }
run_case DST.sp_changedistributiondb.min_distretention 0 "$(db min_distretention N\'2\')" "$(db min_distretention @vb | sed 's/EXEC @rc/EXEC @rc/')" "$(dbread min_distretention)"
run_case DST.sp_changedistributiondb.max_distretention 0 "$(db max_distretention N\'96\')" "$(db max_distretention @vb)" "$(dbread max_distretention)"
run_case DST.sp_changedistributiondb.history_retention 0 "$(db history_retention N\'24\')" "$(db history_retention @vb)" "$(dbread history_retention)"
run_case DST.sp_changedistpublisher.working_directory 0 "$(dp working_directory N\'/var/opt/mssql/data\')" "$(dp working_directory @vb)" "$(dpread working_directory)"
run_case DST.sp_changedistpublisher.security_mode 0 "$(dp security_mode N\'0\')" "$(dp security_mode @vb)" "$(dpread security_mode)"
run_case DST.sp_changedistpublisher.trusted 0 "$(dp trusted N\'true\')" "DECLARE @t nvarchar(10) = CASE @vb WHEN N'1' THEN N'true' ELSE N'false' END; $(dp trusted @t)" "$(dpread trusted)"
run_case DST.sp_changedistpublisher.active 0 "$(dp active N\'false\')" "DECLARE @t nvarchar(10) = CASE @vb WHEN N'1' THEN N'true' ELSE N'false' END; $(dp active @t)" "$(dpread active)"

# ---------------------------------------------------------------- SHR
# Drops the subscription of m_sh1, then of m_sh2, and says what the shared agent
# row and job (publication = 'ALL', subscriber_db = 'm_shsub') look like after each.
shr_case() { # ID PUB
    local res shared job_exists left_rows
    want "$1" || return 0
    res=$(sql -h -1 -Q "SET NOCOUNT ON; USE Sales; DECLARE @e nvarchar(10) = N'ok';
BEGIN TRY EXEC sp_dropsubscription @publication = N'$2', @article = N'all', @subscriber = N'all'; END TRY
BEGIN CATCH SET @e = CONVERT(nvarchar(10), ERROR_NUMBER()); WHILE @@TRANCOUNT > 0 ROLLBACK; END CATCH;
SELECT N'RES=' + @e" </dev/null 2>&1 | sed -n 's/^RES=//p' | tr -d '[:space:]')
    shared=$(sql_value "SELECT COUNT(*) FROM distribution.dbo.MSdistribution_agents a WHERE a.publication = N'ALL' AND a.subscriber_db = N'm_shsub'")
    job_exists=$(sql_value "SELECT COUNT(*) FROM msdb.dbo.sysjobs j JOIN distribution.dbo.MSdistribution_agents a ON j.job_id = CONVERT(uniqueidentifier, a.job_id) WHERE a.publication = N'ALL' AND a.subscriber_db = N'm_shsub'")
    left_rows=$(sql_value "SELECT COUNT(*) FROM Sales.dbo.syssubscriptions s JOIN Sales.dbo.sysarticles a ON a.artid = s.artid JOIN Sales.dbo.syspublications p ON p.pubid = a.pubid WHERE p.name IN (N'm_sh1', N'm_sh2') AND s.srvid >= 0")
    need res shared job_exists left_rows
    r "$1" "$res" "dropped=$2 shared_agent_rows=$shared shared_agent_job_exists=$job_exists subscription_rows_left_m_sh1_m_sh2=$left_rows"
}
shr_case SHR.after1 m_sh1
shr_case SHR.after2 m_sh2

# ---------------------------------------------------------------- assertions
bad=0
control() { echo "07-changes: control failed: $*" >&2; bad=1; }
field() { printf '%s\n' "${rows[@]}" | awk -F'|' -v id="$1" -v n="$2" '$2 == id { print $n }'; }
if [ -z "${M_ONLY:-}" ]; then
    [ "${#rows[@]}" = "$EXPECTED_ROWS" ] || control "${#rows[@]} rows, expected $EXPECTED_ROWS"
    [[ $(field CTL.noop 4) == "changed_inside=[] after_restore_differs=[]" ]] || control "the no-op control shows a change: $(field CTL.noop 4)"
    [ "$(field PRF.msdb-prefix 3)" = 21482 ] || control "PRF.msdb-prefix is $(field PRF.msdb-prefix 3), expected 21482"
    [ "$(field PRF.distribution-prefix 3)" = ok ] || control "PRF.distribution-prefix is $(field PRF.distribution-prefix 3), expected ok"
    [[ $(field PRF.distribution-prefix 4) == *" stored_in_MSsnapshot_agents=$prof m_prof_id=$prof "* ]] || control "PRF.distribution-prefix does not store m_prof ($prof): $(field PRF.distribution-prefix 4)"
    [ "$(printf '%s\n' "${rows[@]}" | grep -c '^R|SHR\.')" = 2 ] || control "not 2 SHR rows"
fi
if [ -n "${M_ONLY:-}" ]; then
    for row in "${rows[@]}"; do echo "row: $row" >&2; done
    echo "07-changes: debug run (M_ONLY set), results not accepted" >&2
    exit 1
fi
if [ "$bad" != 0 ]; then
    for row in "${rows[@]}"; do echo "row: $row" >&2; done
    exit 1
fi
cleanup
for row in "${rows[@]}"; do printf '%s\n' "$row"; done
echo "R|TOTAL|${#rows[@]}"
