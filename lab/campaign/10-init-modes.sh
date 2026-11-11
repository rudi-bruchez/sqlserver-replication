#!/bin/bash
# The three initialization modes other than a snapshot (campaign item 8): creation,
# delivery of changes made after creation, and what becomes of changes made while a
# subscription is dropped and re-added. Run through lab/campaign.sh.
#
# Objects: the table m_t1 of Sales (rows 1 to 3), the publication m_ip
# (allow_initialize_from_backup = true, immediate_sync = false, independent agent,
# snapshot agent with a schedule that never fires and never started), a COPY_ONLY
# backup of Sales in /var/opt/mssql/data/m_bak.bak taken after the publication exists
# (and a second one, m_bak2.bak, for I2.backup.gap-fresh), and three push subscriber
# databases on the same instance:
#   m_isub1  created by the script with m_t1 and the same rows (I1);
#   m_isub2  restored from the backup (I2);
#   m_isub3  restored from the same backup (I3).
# Modes, run in this order, each subscription kept until the end:
#   I1.support-only  @sync_type = 'replication support only'
#   I2.backup        @sync_type = 'initialize with backup', the backup file
#   I3.lsn           @sync_type = 'initialize from lsn', @subscriptionlsn = the backup's
#                    last_lsn converted to binary(10)
# Rows (ids N01, N02 delivered rows; N11/N12, N21/N22 the two rows of a gap case,
# G1 inserted while the subscription is absent, G2 after the re-add):
#   <mode>.create      result of sp_addsubscription + sp_addpushsubscription_agent and
#                      the stored sync_type, nosync_type, status.
#   <mode>.delivered   yes when N01 (inserted after creation) and N02 (inserted after
#                      30 s idle) both reach the subscriber, each within 120 s. The
#                      second row catches an agent whose watermark moved past the
#                      publisher's log (the poisoning of fix round 1).
#   I1.support-only.gap         drop, G1, re-add support only, G2.
#   I2.backup.gap-original      drop, G1, re-add with the original backup file, G2.
#   I2.backup.gap-fresh         drop, G1, a fresh COPY_ONLY backup restored over the
#                               subscriber, re-add with it, G2.
#   I3.lsn.gap-resume           drop, G1, re-add from the first 10 bytes of the
#                               subscriber's MSreplication_subscriptions
#                               transaction_timestamp read before the drop, G2.
#   I3.lsn.gap-original         drop, G1, re-add from the original backup LSN, G2.
#   A gap case waits up to 120 s for G2 or for an error of the new agent. Its result is
#   blocked(<error codes>) when the agent logged an error and G2 did not arrive,
#   otherwise g1=yes|no,g2=yes|no. G1 was committed before G2, so once G2 is there the
#   state of G1 is final. The detail has g1, g2, the error codes (pk_violation when the
#   text is a PRIMARY KEY violation), missing=[ids at the publisher absent at the
#   subscriber] and extra=[ids at the subscriber absent at the publisher].
# For I2 and I3 the details also give seqno_vs_backup_lsn (equal, after, before): where
# the first 10 bytes of MSsubscriptions.subscription_seqno stand against the backup LSN.
# Details print relations, never raw LSNs, agent or constraint names, so that two runs
# give the same file.
# The LSN conversion: the brief's formula, CAST(lsn / 1e15 AS binary(4)) + ..., casts a
# numeric to binary and gives the numeric's internal bytes, not the three integers. The
# script splits the value with exact modulo arithmetic and converts each part through
# bigint. Every LSN is checked BEFORE the call that uses it: the backup LSN right after it
# is computed, before any subscription exists (round trip to the numeric equal, and not
# beyond the log end of Sales from sys.dm_db_log_stats), the resume LSN before its re-add
# (not beyond the log end, not before the backup LSN). A wrong LSN reaching
# sp_addsubscription is stored in MSrepl_transactions; the idle distribution agents of the
# publisher database then move their watermark past it and every subscription of Sales
# stops without an error (fix round 1; dropping the subscription does not repair it).
# Asserted (exit 1 with the rows on stderr otherwise): every .create is ok, every
# .delivered is yes, I2.backup.gap-fresh has g1=yes,g2=yes with missing=[] extra=[], Sales
# stays without a log backup chain (last_log_backup_lsn NULL before and after the
# COPY_ONLY backups), and msdb keeps no backup or restore history of the run. 11 rows.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"

pub=m_ip
bak=/var/opt/mssql/data/m_bak.bak
bak2=/var/opt/mssql/data/m_bak2.bak
dbs="m_isub1 m_isub2 m_isub3"

rows=()
r() { rows+=("R|$1|$2|$3"); }
need() { local v; for v in "$@"; do [ -n "${!v}" ] || { echo "10-init-modes: empty field $v" >&2; exit 1; }; done; }

# The last line of what a batch prints, a word or number optionally followed by /number.
last() {
    local out
    out=$(sql -b -h -1 -Q "SET NOCOUNT ON; $1" </dev/null 2>&1) || { printf '%s\n' "$out" >&2; return 1; }
    out=$(printf '%s\n' "$out" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' | tail -n 1)
    [[ $out =~ ^[0-9a-z]+(/-?[0-9]+)*$ ]] || { printf 'last: unexpected value: %s\n' "$out" >&2; return 1; }
    printf '%s\n' "$out"
}

# try STATEMENTS: runs them in Sales outside a transaction, prints ok or the error number.
try() {
    last "USE Sales; DECLARE @e nvarchar(10) = N'ok';
BEGIN TRY $1 END TRY
BEGIN CATCH SET @e = CONVERT(nvarchar(10), ERROR_NUMBER()); WHILE @@TRANCOUNT > 0 ROLLBACK; END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK;
SELECT @e"
}

cleaned=0
cleanup() {
    [ "$cleaned" = 1 ] && return
    cleaned=1
    stop_m_agents
    local d
    sql -Q "SET NOCOUNT ON; USE Sales;
BEGIN TRY IF EXISTS (SELECT 1 FROM dbo.syspublications WHERE name = N'$pub')
    EXEC sp_dropsubscription @publication = N'$pub', @article = N'all', @subscriber = N'all'; END TRY BEGIN CATCH END CATCH;
WHILE @@TRANCOUNT > 0 ROLLBACK;
BEGIN TRY IF EXISTS (SELECT 1 FROM dbo.syspublications WHERE name = N'$pub')
    EXEC sp_droppublication @publication = N'$pub'; END TRY BEGIN CATCH END CATCH;
WHILE @@TRANCOUNT > 0 ROLLBACK;
DROP TABLE IF EXISTS dbo.m_t1;" </dev/null >&2 || true
    for d in $dbs; do
        sql -Q "SET NOCOUNT ON; IF DB_ID(N'$d') IS NOT NULL BEGIN ALTER DATABASE [$d] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$d]; END;
EXEC msdb.dbo.sp_delete_database_backuphistory @database_name = N'$d';" </dev/null >&2 || true
    done
    # Sales had no backup history when the run started (checked below): deleting all of
    # its history restores msdb as it was.
    if [ "${sales_history_checked:-0}" = 1 ]; then
        sql -Q "SET NOCOUNT ON; EXEC msdb.dbo.sp_delete_database_backuphistory @database_name = N'Sales';" </dev/null >&2 || true
    fi
    podman exec repllab rm -f "$bak" "$bak2" >&2 || true
    podman exec repllab find /var/opt/mssql/data/ReplData/unc -mindepth 1 -maxdepth 1 -iname '*_m_*' -exec rm -rf {} + >&2 || true
}
trap cleanup EXIT

# Leftovers of an earlier run fail this run (the trap removes them).
left=$(sql_value "SELECT (SELECT COUNT(*) FROM Sales.dbo.syspublications WHERE name = N'$pub') + (SELECT COUNT(*) FROM sys.databases WHERE name IN (N'm_isub1', N'm_isub2', N'm_isub3')) + (SELECT COUNT(*) FROM Sales.sys.objects WHERE name LIKE N'm\_%' ESCAPE N'\')")
left_files=$(podman exec repllab find /var/opt/mssql/data -iname 'm_*')
if [ "$left" != 0 ] || [ -n "$left_files" ]; then
    echo "10-init-modes: leftovers of an earlier run (objects=$left files=$left_files); removing them and failing" >&2
    exit 1
fi
# msdb history: none for Sales and none restored into an m_ database, so that the
# cleanup can delete what this run adds and leave msdb as it found it.
hist=$(sql_value "SELECT (SELECT COUNT(*) FROM msdb.dbo.backupset WHERE database_name = N'Sales') + (SELECT COUNT(*) FROM msdb.dbo.restorehistory WHERE destination_database_name LIKE N'm\_%' ESCAPE N'\')")
if [ "$hist" != 0 ]; then
    echo "10-init-modes: msdb has $hist backup or restore history rows for Sales or m_ databases; the cleanup could not restore msdb exactly" >&2
    exit 1
fi
sales_history_checked=1
logchain() { sql_value "SELECT ISNULL(CONVERT(varchar(30), last_log_backup_lsn), 'null') FROM sys.database_recovery_status WHERE database_id = DB_ID(N'Sales')"; }
logchain_before=$(logchain)

now() { sql_value "SELECT CONVERT(varchar(23), SYSDATETIME(), 121)"; }
agent_pred() { echo "a.publication = N'$pub' AND a.subscriber_db = N'$1'"; }
present() { # DB ID : yes or no
    sql_value "SELECT CASE WHEN EXISTS (SELECT 1 FROM $1.dbo.m_t1 WHERE id = $2) THEN 'yes' ELSE 'no' END"
}
# Errors logged since MARK by the distribution agent of the subscription to DB: the
# distinct error codes, followed by (pk_violation) when one of the texts is a PRIMARY KEY
# violation, or none. No text: it names the agent and the constraint.
agent_errors() { # DB MARK
    local from="FROM distribution.dbo.MSdistribution_history h JOIN distribution.dbo.MSdistribution_agents a ON a.id = h.agent_id JOIN distribution.dbo.MSrepl_errors e ON e.id = h.error_id WHERE $(agent_pred "$1") AND h.time >= '$2' AND h.error_id <> 0"
    sql_value "SELECT ISNULL((SELECT STRING_AGG(CONVERT(nvarchar(4000), c), N'/') WITHIN GROUP (ORDER BY c) FROM (SELECT DISTINCT e.error_code AS c $from AND e.error_code <> N'') x), N'none')
 + CASE WHEN EXISTS (SELECT 1 $from AND e.error_text LIKE N'%Violation of PRIMARY KEY%') THEN N'(pk_violation)' ELSE N'' END"
}
error_since() { # DB MARK : the predicate 'the agent logged an error since MARK'
    echo "EXISTS (SELECT 1 FROM distribution.dbo.MSdistribution_history h JOIN distribution.dbo.MSdistribution_agents a ON a.id = h.agent_id WHERE $(agent_pred "$1") AND h.time >= '$2' AND h.error_id <> 0)"
}
compare() { # DB : missing=[..] extra=[..]
    sql_value "SELECT CONCAT(N'missing=[', ISNULL((SELECT STRING_AGG(CONVERT(nvarchar(4000), id), N',') WITHIN GROUP (ORDER BY id) FROM Sales.dbo.m_t1 p WHERE NOT EXISTS (SELECT 1 FROM $1.dbo.m_t1 s WHERE s.id = p.id)), N''), N'] extra=[', ISNULL((SELECT STRING_AGG(CONVERT(nvarchar(4000), id), N',') WITHIN GROUP (ORDER BY id) FROM $1.dbo.m_t1 s WHERE NOT EXISTS (SELECT 1 FROM Sales.dbo.m_t1 p WHERE p.id = s.id)), N''), N']')"
}
sub_state() { # DB : the stored sync_type, nosync_type, status of the subscription to DB
    local w="FROM Sales.dbo.syssubscriptions s JOIN Sales.dbo.sysarticles a ON a.artid = s.artid JOIN Sales.dbo.syspublications p ON p.pubid = a.pubid WHERE p.name = N'$pub' AND s.dest_db = N'$1' AND s.srvid >= 0"
    sql_value "SELECT CONCAT(N'sync_type=', ISNULL((SELECT STRING_AGG(CONVERT(nvarchar(10), s.sync_type), N'/') $w), N'none'),
 N' nosync_type=', ISNULL((SELECT STRING_AGG(CONVERT(nvarchar(10), s.nosync_type), N'/') $w), N'none'),
 N' status=', ISNULL((SELECT STRING_AGG(CONVERT(nvarchar(10), s.status), N'/') $w), N'none'))"
}
# Where the first 10 bytes of the subscription_seqno of the subscription to DB stand
# against the binary(10) BIN: equal, after, before, or none (no subscription row).
seqno_vs() { # DB BIN
    sql_value "SELECT ISNULL((SELECT TOP 1 CONVERT(nvarchar(10), CASE WHEN SUBSTRING(s.subscription_seqno, 1, 10) = $2 THEN N'equal' WHEN SUBSTRING(s.subscription_seqno, 1, 10) > $2 THEN N'after' ELSE N'before' END) FROM distribution.dbo.MSsubscriptions s JOIN distribution.dbo.MSpublications p ON p.publication_id = s.publication_id WHERE p.publication = N'$pub' AND s.subscriber_db = N'$1'), N'none')"
}
ins() { sql -b -Q "SET NOCOUNT ON; INSERT Sales.dbo.m_t1 VALUES ($1, $1)" </dev/null >&2; }
# The log end of Sales as binary(10), for 'not beyond the log end'.
log_end_bin="(SELECT CONVERT(binary(4), N'0x' + LEFT(e, 8), 1) + CONVERT(binary(4), N'0x' + SUBSTRING(e, 10, 8), 1) + CONVERT(binary(2), N'0x' + RIGHT(e, 4), 1) FROM (SELECT CONVERT(nvarchar(30), log_end_lsn) AS e FROM sys.dm_db_log_stats(DB_ID(N'Sales'))) x)"
not_beyond_log_end() { # BIN : yes when 0 < BIN <= the log end of Sales
    sql_value "SELECT CASE WHEN $1 > 0x00000000000000000000 AND $1 <= $log_end_bin THEN 'yes' ELSE 'no' END"
}

# The publication, its table and rows, and the snapshot agent that never runs.
sql -b <<SQL >&2
SET NOCOUNT ON;
USE Sales;
CREATE TABLE dbo.m_t1 (id int PRIMARY KEY, a int);
INSERT dbo.m_t1 VALUES (1, 1), (2, 2), (3, 3);
EXEC sp_addpublication @publication = N'$pub', @status = N'active', @allow_push = N'true',
     @independent_agent = N'true', @immediate_sync = N'false', @allow_initialize_from_backup = N'true',
     @repl_freq = N'continuous', @sync_method = N'concurrent';
EXEC sp_addpublication_snapshot @publication = N'$pub', @frequency_type = 1, @active_start_date = 99991231,
     @job_login = NULL, @job_password = NULL, @publisher_security_mode = 1;
EXEC sp_addarticle @publication = N'$pub', @article = N'm_t1', @source_owner = N'dbo', @source_object = N'm_t1';
SQL

# The backup and its last_lsn, converted and checked before anything uses it.
sql -b -Q "BACKUP DATABASE Sales TO DISK = N'$bak' WITH INIT, COPY_ONLY" </dev/null >&2
logchain_after=$(logchain)
lsn=$(sql_value "SELECT TOP 1 CONVERT(varchar(30), last_lsn) FROM msdb.dbo.backupset WHERE database_name = N'Sales' AND is_copy_only = 1 ORDER BY backup_set_id DESC")
need logchain_after lsn
conv="DECLARE @lsn numeric(25,0) = $lsn;
DECLARE @vlf bigint = CONVERT(bigint, (@lsn - @lsn % 1000000000000000) / 1000000000000000),
        @blk bigint = CONVERT(bigint, (@lsn % 1000000000000000 - @lsn % 100000) / 100000),
        @slot bigint = CONVERT(bigint, @lsn % 100000);
DECLARE @b binary(10) = SUBSTRING(CONVERT(binary(8), @vlf), 5, 4) + SUBSTRING(CONVERT(binary(8), @blk), 5, 4) + SUBSTRING(CONVERT(binary(8), @slot), 7, 2);"
lsnbin=$(sql_value "$conv SELECT CONVERT(varchar(30), @b, 1)")
roundtrip=$(sql_value "$conv SELECT CASE WHEN CONVERT(numeric(25,0), CONVERT(bigint, SUBSTRING(@b, 1, 4))) * 1000000000000000 + CONVERT(numeric(25,0), CONVERT(bigint, SUBSTRING(@b, 5, 4))) * 100000 + CONVERT(bigint, SUBSTRING(@b, 9, 2)) = @lsn THEN 'equal' ELSE 'differs' END")
brief_formula=$(sql_value "DECLARE @lsn numeric(25,0) = $lsn; SELECT CONVERT(varchar(30), CAST(@lsn / 1000000000000000 AS binary(4)) + CAST((@lsn / 100000) % 10000000000 AS binary(4)) + CAST(@lsn % 100000 AS binary(2)), 1)")
need lsnbin roundtrip brief_formula
lsn_in_log=$(not_beyond_log_end "$lsnbin")
need lsn_in_log
if [ "$roundtrip" != equal ] || [ "$lsn_in_log" != yes ]; then
    echo "10-init-modes: backup LSN check failed before any subscription: roundtrip=$roundtrip not_beyond_log_end=$lsn_in_log" >&2
    exit 1
fi
brief_matches=no; [ "${brief_formula,,}" = "${lsnbin,,}" ] && brief_matches=yes

for d in m_isub2 m_isub3; do
    sql -b -Q "RESTORE DATABASE $d FROM DISK = N'$bak' WITH MOVE N'Sales' TO N'/var/opt/mssql/data/$d.mdf', MOVE N'Sales_log' TO N'/var/opt/mssql/data/${d}_log.ldf', RECOVERY" </dev/null >&2
done
sql -b -Q "SET NOCOUNT ON; CREATE DATABASE m_isub1;" </dev/null >&2
sql -b -Q "SET NOCOUNT ON; USE m_isub1; CREATE TABLE dbo.m_t1 (id int PRIMARY KEY, a int); INSERT dbo.m_t1 SELECT id, a FROM Sales.dbo.m_t1;" </dev/null >&2

add_sql() { # DB SYNC_ARGS
    echo "EXEC sp_addsubscription @publication = N'$pub', @subscriber = @@SERVERNAME, @destination_db = N'$1',
     @subscription_type = N'Push', $2, @article = N'all';
EXEC sp_addpushsubscription_agent @publication = N'$pub', @subscriber = @@SERVERNAME, @subscriber_db = N'$1',
     @job_login = NULL, @job_password = NULL, @subscriber_security_mode = 1;"
}
support_args="@sync_type = N'replication support only'"
backup_args() { echo "@sync_type = N'initialize with backup', @backupdevicetype = N'disk', @backupdevicename = N'$1'"; }
lsn_args() { echo "@sync_type = N'initialize from lsn', @subscriptionlsn = $1"; }

delivered() { # ID DB N [seqno] : N01, then 30 s idle, then N02; seqno adds the seqno relation
    local id=$1 db=$2 n=$3 mark d1=no d2=no res errs cmp
    mark=$(now)
    ins "${n}01"
    wait_until 120 "SELECT CASE WHEN EXISTS (SELECT 1 FROM $db.dbo.m_t1 WHERE id = ${n}01) THEN 1 ELSE 0 END" && d1=yes
    sleep 30
    ins "${n}02"
    wait_until 120 "SELECT CASE WHEN EXISTS (SELECT 1 FROM $db.dbo.m_t1 WHERE id = ${n}02) THEN 1 ELSE 0 END" && d2=yes
    errs=$(agent_errors "$db" "$mark")
    cmp=$(compare "$db")
    need errs cmp
    res=no; [ "$d1" = yes ] && [ "$d2" = yes ] && res=yes
    local extra=""
    [ "${4:-}" = seqno ] && extra=" seqno_vs_backup_lsn_after_delivery=$(seqno_vs "$db" "$lsnbin")"
    r "$id" "$res" "first=${n}01:$d1 after_30s_idle=${n}02:$d2 errors=$errs $cmp$extra"
}

# gap ID DB G1 G2 SYNC_ARGS [HOOK]: drop, insert G1, run HOOK, re-add with SYNC_ARGS,
# insert G2, wait; HOOK runs between G1 and the re-add (a fresh backup and restore).
gap() {
    local id=$1 db=$2 g1id=$3 g2id=$4 args=$5 hook=${6:-} drop agents_left mark readd g1 g2 errs cmp st res
    drop=$(try "EXEC sp_dropsubscription @publication = N'$pub', @article = N'all', @subscriber = @@SERVERNAME, @destination_db = N'$db';")
    agents_left=$(sql_value "SELECT COUNT(*) FROM distribution.dbo.MSdistribution_agents a WHERE $(agent_pred "$db")")
    ins "$g1id"
    [ -n "$hook" ] && "$hook"
    mark=$(now)
    readd=$(try "$(add_sql "$db" "$args")")
    ins "$g2id"
    need drop agents_left readd
    if [ "$readd" = ok ]; then
        wait_until 120 "SELECT CASE WHEN EXISTS (SELECT 1 FROM $db.dbo.m_t1 WHERE id = $g2id) OR $(error_since "$db" "$mark") THEN 1 ELSE 0 END" || true
    fi
    g1=$(present "$db" "$g1id")
    g2=$(present "$db" "$g2id")
    errs=$(agent_errors "$db" "$mark")
    cmp=$(compare "$db")
    st=$(sub_state "$db")
    need g1 g2 errs cmp st
    [ "$db" != m_isub1 ] && st+=" seqno_vs_backup_lsn=$(seqno_vs "$db" "$lsnbin")"
    if [ "$readd" != ok ]; then res="readd=$readd"
    elif [ "$errs" != none ] && [ "$g2" = no ]; then res="blocked(${errs%%(*})"
    else res="g1=$g1,g2=$g2"; fi
    r "$id" "$res" "drop=$drop agent_rows_after_drop=$agents_left readd=$readd rows=$g1id:$g1/$g2id:$g2 errors_after_readd=$errs $cmp $st${7:-}"
}

# Hook of I2.backup.gap-fresh: a new COPY_ONLY backup restored over m_isub2.
fresh_backup() {
    sql -b -Q "BACKUP DATABASE Sales TO DISK = N'$bak2' WITH INIT, COPY_ONLY" </dev/null >&2
    sql -b -Q "ALTER DATABASE m_isub2 SET SINGLE_USER WITH ROLLBACK IMMEDIATE; RESTORE DATABASE m_isub2 FROM DISK = N'$bak2' WITH REPLACE, MOVE N'Sales' TO N'/var/opt/mssql/data/m_isub2.mdf', MOVE N'Sales_log' TO N'/var/opt/mssql/data/m_isub2_log.ldf', RECOVERY; ALTER DATABASE m_isub2 SET MULTI_USER;" </dev/null >&2
}

# The seqno is not read here: right after sp_addsubscription it is either the backup
# LSN or a later one, depending on whether the agent has started (two runs differed);
# .delivered reads it once the agent has run.
create() { # ID DB SYNC_ARGS [EXTRA]
    local res st
    res=$(try "$(add_sql "$2" "$3")")
    st=$(sub_state "$2")
    need res st
    r "$1" "$res" "$st${4:-}"
    [ "$res" = ok ]
}

# I1
if create I1.support-only.create m_isub1 "$support_args"; then
    delivered I1.support-only.delivered m_isub1 1
    gap I1.support-only.gap m_isub1 111 112 "$support_args"
fi

# I2
if create I2.backup.create m_isub2 "$(backup_args "$bak")"; then
    delivered I2.backup.delivered m_isub2 2 seqno
    gap I2.backup.gap-original m_isub2 211 212 "$(backup_args "$bak")"
    gap I2.backup.gap-fresh m_isub2 221 222 "$(backup_args "$bak2")" fresh_backup
fi

# I3
if create I3.lsn.create m_isub3 "$(lsn_args "$lsnbin")" " roundtrip=$roundtrip not_beyond_log_end=$lsn_in_log brief_formula_matches=$brief_matches"; then
    delivered I3.lsn.delivered m_isub3 3 seqno
    # The subscriber's last applied transaction, read before the drop, checked before use.
    ts=$(sql_value "SELECT ISNULL((SELECT TOP 1 CONVERT(varchar(30), CONVERT(binary(10), SUBSTRING(transaction_timestamp, 1, 10)), 1) FROM m_isub3.dbo.MSreplication_subscriptions WHERE publication = N'$pub'), 'none')")
    need ts
    [ "$ts" != none ] || { echo "10-init-modes: no MSreplication_subscriptions row in m_isub3" >&2; exit 1; }
    ts_in_log=$(not_beyond_log_end "$ts")
    ts_after_backup=$(sql_value "SELECT CASE WHEN $ts >= $lsnbin THEN 'yes' ELSE 'no' END")
    need ts_in_log ts_after_backup
    if [ "$ts_in_log" != yes ] || [ "$ts_after_backup" != yes ]; then
        echo "10-init-modes: resume LSN check failed before the re-add: not_beyond_log_end=$ts_in_log not_before_backup_lsn=$ts_after_backup" >&2
        exit 1
    fi
    gap I3.lsn.gap-resume m_isub3 311 312 "$(lsn_args "$ts")" "" " resume_lsn=subscriber_transaction_timestamp not_beyond_log_end=$ts_in_log after_backup_lsn=$ts_after_backup"
    gap I3.lsn.gap-original m_isub3 321 322 "$(lsn_args "$lsnbin")"
fi

# Controls.
bad=0
control() { echo "10-init-modes: control failed: $*" >&2; bad=1; }
field() { printf '%s\n' "${rows[@]}" | awk -F'|' -v id="$1" -v n="$2" '$2 == id { print $n }'; }
[ "${#rows[@]}" = 11 ] || control "${#rows[@]} rows, expected 11"
for id in I1.support-only I2.backup I3.lsn; do
    [ "$(field "$id.create" 3)" = ok ] || control "$id.create: $(field "$id.create" 3)"
    [ "$(field "$id.delivered" 3)" = yes ] || control "$id.delivered: $(field "$id.delivered" 3)"
done
[ "$(field I2.backup.gap-fresh 3)" = "g1=yes,g2=yes" ] || control "I2.backup.gap-fresh: $(field I2.backup.gap-fresh 3)"
[[ $(field I2.backup.gap-fresh 4) == *" missing=[] extra=[] "* ]] || control "I2.backup.gap-fresh subscriber differs: $(field I2.backup.gap-fresh 4)"
[ "$logchain_before" = null ] && [ "$logchain_after" = null ] && [ "$(logchain)" = null ] \
    || control "Sales log backup chain changed: last_log_backup_lsn $logchain_before -> $logchain_after"

cleanup
hist_after=$(sql_value "SELECT (SELECT COUNT(*) FROM msdb.dbo.backupset WHERE database_name = N'Sales') + (SELECT COUNT(*) FROM msdb.dbo.restorehistory WHERE destination_database_name LIKE N'm\_%' ESCAPE N'\')")
[ "$hist_after" = 0 ] || control "msdb keeps $hist_after backup or restore history rows after the cleanup"
if [ "$bad" != 0 ]; then
    for row in "${rows[@]}"; do echo "row: $row" >&2; done
    exit 1
fi
for row in "${rows[@]}"; do printf '%s\n' "$row"; done
echo "R|TOTAL|${#rows[@]}"
