#!/bin/bash
# The three initialization modes other than a snapshot (campaign item 8): creation,
# delivery of a change made after creation, and what becomes of changes made while a
# subscription is dropped and re-added in the same mode. Run through lab/campaign.sh.
#
# Objects: the table m_t1 of Sales (rows 1 to 3), the publication m_ip
# (allow_initialize_from_backup = true, immediate_sync = false, independent agent,
# snapshot agent with a schedule that never fires and never started), one COPY_ONLY
# backup of Sales in /var/opt/mssql/data/m_bak.bak taken after the publication exists,
# and three push subscriber databases on the same instance:
#   m_isub1  created by the script with m_t1 and the same rows (I1);
#   m_isub2  restored from the backup (I2);
#   m_isub3  restored from the same backup (I3).
# Modes, run in this order, each subscription kept until the end:
#   I1.support-only  @sync_type = 'replication support only'
#   I2.backup        @sync_type = 'initialize with backup', the backup file
#   I3.lsn           @sync_type = 'initialize from lsn', @subscriptionlsn = the backup's
#                    last_lsn converted to binary(10)
# Rows per mode:
#   .create     result of sp_addsubscription + sp_addpushsubscription_agent; detail:
#               the stored sync_type, nosync_type, status and subscription_seqno.
#   .delivered  a row N01 inserted at the publisher after creation: whether it reaches
#               the subscriber within 120 s, the errors the subscription's distribution
#               agent logged since the insert, and the publisher ids missing at the
#               subscriber (rows the subscription never received, whatever the mode).
#   .gap        drop the subscription, insert G1 (N11), re-add in the same mode, insert
#               G2 (N12); wait up to 120 s for G2 or for an error of the new agent.
#               Result g1=yes|no,g2=yes|no. G1 was committed before G2, so once G2 is
#               there the state of G1 is final. The detail has the agent's errors after
#               the re-add, the ids missing at the subscriber and rows the subscriber has
#               that the publisher does not.
# The LSN conversion: the brief's formula, CAST(lsn / 1e15 AS binary(4)) + ..., casts
# a numeric to binary and gives the numeric's internal bytes, not the three integers
# (measured 2026-11-11: 39000000123400001 gives 0x260D0001120700010600, expected
# 0x00000027000004D20001). The script splits the numeric with exact modulo arithmetic,
# converts each part through bigint, reads the binary(10) back to a numeric and asserts
# the round trip; the detail of I3.create also shows the brief's value and whether the
# converted value equals the subscription_seqno the engine stored for I2 from the
# backup header.
# Asserted (exit 1 with the rows on stderr otherwise): every .create is ok, every
# .delivered is yes, the LSN round trip holds, Sales stays without a log backup chain
# (last_log_backup_lsn NULL before and after the COPY_ONLY backup), and msdb keeps no
# backup or restore history of the run. 9 rows.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"

pub=m_ip
bak=/var/opt/mssql/data/m_bak.bak
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
SELECT @e"
}

cleaned=0
cleanup() {
    [ "$cleaned" = 1 ] && return
    cleaned=1
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
    podman exec repllab rm -f "$bak" >&2 || true
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
logchain_before=$(sql_value "SELECT ISNULL(CONVERT(varchar(30), last_log_backup_lsn), 'null') FROM sys.database_recovery_status WHERE database_id = DB_ID(N'Sales')")
recovery=$(sql_value "SELECT recovery_model_desc FROM sys.databases WHERE name = N'Sales'")

now() { sql_value "SELECT CONVERT(varchar(23), SYSDATETIME(), 121)"; }
agent_pred() { echo "a.publication = N'$pub' AND a.subscriber_db = N'$1'"; }
present() { # DB ID : yes or no
    sql_value "SELECT CASE WHEN EXISTS (SELECT 1 FROM $1.dbo.m_t1 WHERE id = $2) THEN 'yes' ELSE 'no' END"
}
# Errors logged since MARK by the distribution agent of the subscription to DB:
# the distinct error codes and the first error text, or none.
agent_errors() { # DB MARK
    sql_value "SELECT ISNULL((SELECT STRING_AGG(CONVERT(nvarchar(4000), c), N'/') FROM (SELECT DISTINCT e.error_code AS c FROM distribution.dbo.MSdistribution_history h JOIN distribution.dbo.MSdistribution_agents a ON a.id = h.agent_id JOIN distribution.dbo.MSrepl_errors e ON e.id = h.error_id WHERE $(agent_pred "$1") AND h.time >= '$2' AND h.error_id <> 0 AND e.error_code <> N'') x), N'none')
 + ISNULL(N' first=' + (SELECT TOP 1 CONVERT(nvarchar(4000), LEFT(REPLACE(REPLACE(REPLACE(e.error_text, N'|', N'/'), CHAR(10), N' '), CHAR(13), N' '), 160)) FROM distribution.dbo.MSdistribution_history h JOIN distribution.dbo.MSdistribution_agents a ON a.id = h.agent_id JOIN distribution.dbo.MSrepl_errors e ON e.id = h.error_id WHERE $(agent_pred "$1") AND h.time >= '$2' AND h.error_id <> 0 AND e.error_code <> N'' ORDER BY e.id), N'')"
}
error_since() { # DB MARK : the predicate 'the agent logged an error since MARK'
    echo "EXISTS (SELECT 1 FROM distribution.dbo.MSdistribution_history h JOIN distribution.dbo.MSdistribution_agents a ON a.id = h.agent_id WHERE $(agent_pred "$1") AND h.time >= '$2' AND h.error_id <> 0)"
}
# Ids at the publisher missing at the subscriber, and ids at the subscriber unknown to
# the publisher, as missing=[..] extra=[..].
compare() { # DB
    sql_value "SELECT CONCAT(N'missing=[', ISNULL((SELECT STRING_AGG(CONVERT(nvarchar(4000), id), N',') WITHIN GROUP (ORDER BY id) FROM Sales.dbo.m_t1 p WHERE NOT EXISTS (SELECT 1 FROM $1.dbo.m_t1 s WHERE s.id = p.id)), N''), N'] extra=[', ISNULL((SELECT STRING_AGG(CONVERT(nvarchar(4000), id), N',') WITHIN GROUP (ORDER BY id) FROM $1.dbo.m_t1 s WHERE NOT EXISTS (SELECT 1 FROM Sales.dbo.m_t1 p WHERE p.id = s.id)), N''), N']')"
}
# The stored state of the subscription to DB: syssubscriptions sync_type, nosync_type,
# status (one value per article; a single article here) and MSsubscriptions seqno.
sub_state() { # DB
    sql_value "SELECT CONCAT(N'sync_type=', ISNULL((SELECT STRING_AGG(CONVERT(nvarchar(10), s.sync_type), N'/') FROM Sales.dbo.syssubscriptions s JOIN Sales.dbo.sysarticles a ON a.artid = s.artid JOIN Sales.dbo.syspublications p ON p.pubid = a.pubid WHERE p.name = N'$pub' AND s.dest_db = N'$1' AND s.srvid >= 0), N'none'),
 N' nosync_type=', ISNULL((SELECT STRING_AGG(CONVERT(nvarchar(10), s.nosync_type), N'/') FROM Sales.dbo.syssubscriptions s JOIN Sales.dbo.sysarticles a ON a.artid = s.artid JOIN Sales.dbo.syspublications p ON p.pubid = a.pubid WHERE p.name = N'$pub' AND s.dest_db = N'$1' AND s.srvid >= 0), N'none'),
 N' status=', ISNULL((SELECT STRING_AGG(CONVERT(nvarchar(10), s.status), N'/') FROM Sales.dbo.syssubscriptions s JOIN Sales.dbo.sysarticles a ON a.artid = s.artid JOIN Sales.dbo.syspublications p ON p.pubid = a.pubid WHERE p.name = N'$pub' AND s.dest_db = N'$1' AND s.srvid >= 0), N'none'),
 N' subscription_seqno=', ISNULL((SELECT STRING_AGG(CONVERT(nvarchar(64), s.subscription_seqno, 1), N'/') FROM distribution.dbo.MSsubscriptions s JOIN distribution.dbo.MSpublications p ON p.publication_id = s.publication_id WHERE p.publication = N'$pub' AND s.subscriber_db = N'$1'), N'none'))"
}
ins() { sql -b -Q "SET NOCOUNT ON; INSERT Sales.dbo.m_t1 VALUES ($1, $1)" </dev/null >&2; }

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

# The backup, its last_lsn, and the two restored subscriber databases.
sql -b -Q "BACKUP DATABASE Sales TO DISK = N'$bak' WITH INIT, COPY_ONLY" </dev/null >&2
logchain_after=$(sql_value "SELECT ISNULL(CONVERT(varchar(30), last_log_backup_lsn), 'null') FROM sys.database_recovery_status WHERE database_id = DB_ID(N'Sales')")
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
for d in m_isub2 m_isub3; do
    sql -b -Q "RESTORE DATABASE $d FROM DISK = N'$bak' WITH MOVE N'Sales' TO N'/var/opt/mssql/data/$d.mdf', MOVE N'Sales_log' TO N'/var/opt/mssql/data/${d}_log.ldf', RECOVERY" </dev/null >&2
done
sql -b -Q "SET NOCOUNT ON; CREATE DATABASE m_isub1;" </dev/null >&2
sql -b -Q "SET NOCOUNT ON; USE m_isub1; CREATE TABLE dbo.m_t1 (id int PRIMARY KEY, a int); INSERT dbo.m_t1 SELECT id, a FROM Sales.dbo.m_t1;" </dev/null >&2

mode_args() { # MODE
    case $1 in
        I1) echo "@sync_type = N'replication support only'" ;;
        I2) echo "@sync_type = N'initialize with backup', @backupdevicetype = N'disk', @backupdevicename = N'$bak'" ;;
        I3) echo "@sync_type = N'initialize from lsn', @subscriptionlsn = $lsnbin" ;;
    esac
}
add_sql() { # MODE DB
    echo "EXEC sp_addsubscription @publication = N'$pub', @subscriber = @@SERVERNAME, @destination_db = N'$2',
     @subscription_type = N'Push', $(mode_args "$1"), @article = N'all';
EXEC sp_addpushsubscription_agent @publication = N'$pub', @subscriber = @@SERVERNAME, @subscriber_db = N'$2',
     @job_login = NULL, @job_password = NULL, @subscriber_security_mode = 1;"
}

run_mode() { # MODE NAME DB N
    local mode=$1 name=$2 db=$3 n=$4 res st mark del errs cmp drop readd g1 g2 extra
    res=$(try "$(add_sql "$mode" "$db")")
    st=$(sub_state "$db")
    need res st
    if [ "$mode" = I3 ]; then
        local i2seq
        i2seq=$(sql_value "SELECT ISNULL((SELECT TOP 1 CONVERT(nvarchar(64), s.subscription_seqno, 1) FROM distribution.dbo.MSsubscriptions s JOIN distribution.dbo.MSpublications p ON p.publication_id = s.publication_id WHERE p.publication = N'$pub' AND s.subscriber_db = N'm_isub2'), N'none')")
        extra=" backup_last_lsn=$lsn converted=$lsnbin roundtrip=$roundtrip brief_formula=$brief_formula equals_I2_seqno_prefix=$([[ ${i2seq,,} == "${lsnbin,,}"* ]] && echo yes || echo "no($i2seq)")"
    else
        extra=""
    fi
    r "$mode.$name.create" "$res" "$st$extra"
    if [ "$res" != ok ]; then
        r "$mode.$name.delivered" "skipped" "subscription not created"
        r "$mode.$name.gap" "skipped" "subscription not created"
        return
    fi

    # .delivered
    mark=$(now)
    ins "${n}01"
    del=no
    wait_until 120 "SELECT CASE WHEN EXISTS (SELECT 1 FROM $db.dbo.m_t1 WHERE id = ${n}01) THEN 1 ELSE 0 END" && del=yes
    errs=$(agent_errors "$db" "$mark")
    cmp=$(compare "$db")
    need errs cmp
    r "$mode.$name.delivered" "$del" "row=${n}01 errors_since_insert=$errs $cmp"

    # .gap
    drop=$(try "EXEC sp_dropsubscription @publication = N'$pub', @article = N'all', @subscriber = @@SERVERNAME, @destination_db = N'$db';")
    local agents_left
    agents_left=$(sql_value "SELECT COUNT(*) FROM distribution.dbo.MSdistribution_agents a WHERE $(agent_pred "$db")")
    ins "${n}11"
    mark=$(now)
    readd=$(try "$(add_sql "$mode" "$db")")
    ins "${n}12"
    need drop agents_left readd
    if [ "$readd" = ok ]; then
        wait_until 120 "SELECT CASE WHEN EXISTS (SELECT 1 FROM $db.dbo.m_t1 WHERE id = ${n}12) OR $(error_since "$db" "$mark") THEN 1 ELSE 0 END" || true
        # An error may be logged before G2 is applied by a retry; give the agent no
        # second chance: the state read now is the result.
    fi
    g1=$(present "$db" "${n}11")
    g2=$(present "$db" "${n}12")
    errs=$(agent_errors "$db" "$mark")
    cmp=$(compare "$db")
    st=$(sub_state "$db")
    need g1 g2 errs cmp st
    r "$mode.$name.gap" "g1=$g1,g2=$g2" "drop=$drop agent_rows_after_drop=$agents_left readd=$readd rows=${n}11/${n}12 errors_after_readd=$errs $cmp $st"
}

run_mode I1 support-only m_isub1 1
run_mode I2 backup m_isub2 2
run_mode I3 lsn m_isub3 3

# Controls.
bad=0
control() { echo "10-init-modes: control failed: $*" >&2; bad=1; }
field() { printf '%s\n' "${rows[@]}" | awk -F'|' -v id="$1" -v n="$2" '$2 == id { print $n }'; }
[ "${#rows[@]}" = 9 ] || control "${#rows[@]} rows, expected 9"
for id in I1.support-only I2.backup I3.lsn; do
    [ "$(field "$id.create" 3)" = ok ] || control "$id.create: $(field "$id.create" 3)"
    [ "$(field "$id.delivered" 3)" = yes ] || control "$id.delivered: $(field "$id.delivered" 3)"
done
[ "$roundtrip" = equal ] || control "LSN round trip: $roundtrip ($lsn -> $lsnbin)"
[ "$logchain_before" = null ] && [ "$logchain_after" = null ] || control "Sales log backup chain changed: last_log_backup_lsn $logchain_before -> $logchain_after"

cleanup
hist_after=$(sql_value "SELECT (SELECT COUNT(*) FROM msdb.dbo.backupset WHERE database_name = N'Sales') + (SELECT COUNT(*) FROM msdb.dbo.restorehistory WHERE destination_database_name LIKE N'm\_%' ESCAPE N'\')")
[ "$hist_after" = 0 ] || control "msdb keeps $hist_after backup or restore history rows after the cleanup"
echo "10-init-modes: Sales recovery=$recovery last_log_backup_lsn before=$logchain_before after_backup=$logchain_after; lsn=$lsn -> $lsnbin ($roundtrip)" >&2
if [ "$bad" != 0 ]; then
    for row in "${rows[@]}"; do echo "row: $row" >&2; done
    exit 1
fi
for row in "${rows[@]}"; do printf '%s\n' "$row"; done
echo "R|TOTAL|${#rows[@]}"
