#!/bin/bash
# The defaults and execution contexts of the distributor procedures (campaign item 9,
# third part), measured on a fresh instance: on the configured lab they are refused from
# everywhere (14099, 14119). Run directly, not through lab/campaign.sh, whose restart
# guard would reject a script that stops the lab.
# Usage: lab/distributor-defaults.sh VERSION (2019, 2022 or 2025). Needs MSSQL_SA_PASSWORD.
#
# What it does: shuts repllab down with SHUTDOWN WITH NOWAIT (the host cannot hold a
# second 4 GB instance next to it), starts the container m-fresh (same image as the lab,
# 127.0.0.1:11981, MSSQL_MEMORY_LIMIT_MB=4096, SQL Agent on, no setup.sql, the directory
# /var/opt/mssql/ReplData created and owned by mssql because sp_adddistpublisher defaults
# to it and refuses a missing one with 21037), then, for sp_adddistributor,
# sp_adddistributiondb and sp_adddistpublisher in this order, each called with its
# required parameters only (@distributor = @@SERVERNAME; @database = distribution;
# @publisher = @@SERVERNAME and @distribution_db = distribution):
#   X.<procedure>.<database>  the call from msdb, tempdb and master, in that order: ok,
#                             the error number or rcN. A call that succeeds is undone
#                             (sp_dropdistributor, sp_dropdistributiondb,
#                             sp_dropdistpublisher, from master) before the next database.
#   D.<procedure>.fresh.<parameter>  the call made once more from master (or from the first
#                             database where it succeeded), then one row per optional
#                             parameter as in lab/campaign/11-defaults.sh (see
#                             lab/defaults-lib.sh).
# It writes lab/results/VERSION/distributor-defaults.txt in the result format, then, on
# success and on failure alike (trap), removes m-fresh with podman rm -f and starts the lab
# again with lab/start.sh VERSION.
#
# Asserted, exit 1 otherwise (rows on stderr): X.sp_adddistributor.msdb is 5001 (the
# review's observation); every undo and every D call is ok; 3 contexts; TOTAL equals the
# sum of the per-context counts and the number of rows. A value of exactly 256 characters
# (an nvarchar(max) cut) stops the script in measure; a row of that length is padded by
# r() (lab/defaults-lib.sh). An error that escapes a call's TRY...CATCH or a value query stops the script
# (sqlcmd -b in try_in and measure), which stands for campaign.sh's uncaught guard.
set -euo pipefail
lab=$(cd "$(dirname "$0")" && pwd)
version=${1:-}
case $version in
    2019|2022|2025) ;;
    *) echo "usage: $0 2019|2022|2025" >&2; exit 2 ;;
esac
: "${MSSQL_SA_PASSWORD:?MSSQL_SA_PASSWORD must be set}"
. "$lab/lib.sh"
DEF_SCRIPT=distributor-defaults
DEF_CONTAINER=m-fresh
. "$lab/defaults-lib.sh"

out=$lab/results/$version/distributor-defaults.txt

# lab_sql: sqlcmd on repllab (lib.sh's sql, before it is redefined for m-fresh).
lab_sql() {
    SQLCMDPASSWORD=$MSSQL_SA_PASSWORD podman exec -i -e SQLCMDPASSWORD repllab \
        /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -W -s '|' "$@"
}
# From here sql, sql_value and try_in talk to m-fresh.
sql() {
    SQLCMDPASSWORD=$MSSQL_SA_PASSWORD podman exec -i -e SQLCMDPASSWORD m-fresh \
        /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -W -s '|' "$@"
}
running() { [ "$(podman inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }

finish() {
    local status=$?
    set +e
    echo "distributor-defaults: removing m-fresh and restarting the lab" >&2
    podman rm -f m-fresh >/dev/null 2>&1
    if ! bash "$lab/start.sh" "$version"; then
        echo "distributor-defaults: lab/start.sh $version failed" >&2
        status=1
    fi
    exit "$status"
}

# A leftover m-fresh is this script's own container (an earlier run killed midway).
podman rm -f m-fresh >/dev/null 2>&1 || true
trap finish EXIT

if running repllab; then
    lab_sql -Q "SHUTDOWN WITH NOWAIT" </dev/null >&2 || true
    for _ in $(seq 1 30); do running repllab || break; sleep 2; done
fi
running repllab && { echo "distributor-defaults: repllab still runs after SHUTDOWN WITH NOWAIT" >&2; exit 1; }

podman run -d --name m-fresh --hostname m-fresh -p 127.0.0.1:11981:1433 \
  -e ACCEPT_EULA=Y -e MSSQL_PID=Developer -e MSSQL_AGENT_ENABLED=true -e MSSQL_MEMORY_LIMIT_MB=4096 \
  -e MSSQL_SA_PASSWORD "mcr.microsoft.com/mssql/server:$version-latest" >/dev/null
for _ in $(seq 1 90); do sql -l 5 -b -Q "SELECT 1" </dev/null >/dev/null 2>&1 && break; sleep 2; done
podman exec -u 0 m-fresh bash -c 'mkdir -p /var/opt/mssql/ReplData && chown mssql /var/opt/mssql/ReplData'
banner=$(sql_value "SELECT LEFT(@@VERSION, CHARINDEX(CHAR(10), @@VERSION + CHAR(10)) - 1)")
[[ $banner == *"SQL Server $version "* ]] || { echo "distributor-defaults: m-fresh runs '$banner', not SQL Server $version" >&2; exit 1; }
fresh=$(sql_value "SELECT (SELECT COUNT(*) FROM sys.servers WHERE name = N'repl_distributor') + (SELECT COUNT(*) FROM sys.databases WHERE name = N'distribution')")
[ "$fresh" = 0 ] || { echo "distributor-defaults: m-fresh is not a fresh instance" >&2; exit 1; }

NC="N'no-column'"
PRE_DISTRIBUTOR="USE master;
SELECT * INTO #srv FROM sys.servers WHERE name = N'repl_distributor';
SELECT l.* INTO #ll FROM sys.linked_logins l JOIN sys.servers s ON s.server_id = l.server_id WHERE s.name = N'repl_distributor';
SELECT name, password_hash INTO #dl FROM sys.sql_logins WHERE name = N'distributor_admin';
IF (SELECT COUNT(*) FROM #srv) <> 1 OR (SELECT COUNT(*) FROM #ll) <> 1 THROW 50000, N'preamble: expected one repl_distributor server and login mapping', 1;"
MAP_DISTRIBUTOR=$(cat <<EOF
@heartbeat_interval|msdb.dbo.MSdistributor value of property heartbeat_interval (minutes; also the schedule of Replication agents checkup)|(SELECT CONVERT(nvarchar(100), value) FROM msdb.dbo.MSdistributor WHERE property = N'heartbeat_interval')
@password|master.sys.sql_logins.password_hash of distributor_admin (secret; the linked login of repl_distributor uses it)|$(secret "(SELECT password_hash FROM #dl)")
@from_scripting|no-column: a flag of the call (skips the Replication agents checkup job)|$NC
@security_mode|master.sys.linked_logins of repl_distributor (uses_self_credential, remote_name)|(SELECT CONCAT(N'uses_self_credential=', uses_self_credential, N' remote_name=', remote_name) FROM #ll)
@multi_subnet_failover|master.sys.servers.provider_string of repl_distributor|(SELECT CONVERT(nvarchar(4000), provider_string) FROM #srv)
EOF
)
PRE_DISTDB="USE master;
SELECT * INTO #ddb FROM msdb.dbo.MSdistributiondbs WHERE name = N'distribution';
SELECT type, physical_name, size INTO #mf FROM sys.master_files WHERE database_id = DB_ID(N'distribution');
IF (SELECT COUNT(*) FROM #ddb) <> 1 OR (SELECT COUNT(*) FROM #mf WHERE type = 0) <> 1 OR (SELECT COUNT(*) FROM #mf WHERE type = 1) <> 1 THROW 50000, N'preamble: expected one distribution database with one data and one log file', 1;"
folder() { echo "(SELECT LEFT(physical_name, LEN(physical_name) - CHARINDEX(N'/', REVERSE(physical_name))) FROM #mf WHERE type = $1)"; }
file() { echo "(SELECT RIGHT(physical_name, CHARINDEX(N'/', REVERSE(physical_name)) - 1) FROM #mf WHERE type = $1)"; }
mb() { echo "(SELECT CONCAT(size * 8 / 1024, N' MB') FROM #mf WHERE type = $1)"; }
MF="master.sys.master_files of the distribution database"
MAP_DISTDB=$(cat <<EOF
@data_folder|$MF, data file folder|$(folder 0)
@data_file|$MF, data file name|$(file 0)
@data_file_size|$MF, data file size at creation|$(mb 0)
@log_folder|$MF, log file folder|$(folder 1)
@log_file|$MF, log file name|$(file 1)
@log_file_size|$MF, log file size at creation|$(mb 1)
@min_distretention|msdb.dbo.MSdistributiondbs.min_distretention (hours)|(SELECT min_distretention FROM #ddb)
@max_distretention|MSdistributiondbs.max_distretention (hours)|(SELECT max_distretention FROM #ddb)
@history_retention|MSdistributiondbs.history_retention (hours)|(SELECT history_retention FROM #ddb)
@security_mode|no-column: checked by the procedure (0 needs @login, 21694), stored nowhere|$NC
@login|no-column: checked by the procedure, stored nowhere|$NC
@password|no-column: read by the procedure, stored nowhere|$NC
@createmode|no-column: how the database is created|$NC
@from_scripting|no-column: a flag of the call|$NC
@deletebatchsize_xact|MSdistributiondbs.deletebatchsize_xact|(SELECT deletebatchsize_xact FROM #ddb)
@deletebatchsize_cmd|MSdistributiondbs.deletebatchsize_cmd|(SELECT deletebatchsize_cmd FROM #ddb)
EOF
)
PRE_DISTPUB="USE master;
SELECT * INTO #dp FROM msdb.dbo.MSdistpublishers WHERE UPPER(name) = UPPER(@@SERVERNAME);
IF (SELECT COUNT(*) FROM #dp) <> 1 THROW 50000, N'preamble: expected one MSdistpublishers row', 1;"
DP="msdb.dbo.MSdistpublishers"
MAP_DISTPUB=$(cat <<EOF
@security_mode|$DP.security_mode|(SELECT security_mode FROM #dp)
@login|$DP.login|(SELECT login FROM #dp)
@password|$DP.password (secret)|$(secret "(SELECT password FROM #dp)")
@working_directory|$DP.working_directory|(SELECT working_directory FROM #dp)
@trusted|$DP.trusted|(SELECT trusted FROM #dp)
@encrypted_password|no-column: a flag of the call (how @password is passed)|$NC
@thirdparty_flag|$DP.thirdparty_flag|(SELECT thirdparty_flag FROM #dp)
@publisher_type|$DP.publisher_type|(SELECT publisher_type FROM #dp)
@storage_connection_string|$DP.storage_connection_string (secret)|$(secret "(SELECT storage_connection_string FROM #dp)")
EOF
)

bad=0
control() { echo "distributor-defaults: control failed: $*" >&2; bad=1; }

# contexts PROC CALL UNDO: the X rows, then the D call; sets D_DB.
contexts() {
    local proc=$1 stmt=$2 undo=$3 db res first=""
    for db in msdb tempdb master; do
        try_in "$db" "$stmt"; res=$TRY_RESULT
        r "X.$proc.$db" "$res" "msg=${TRY_MSG:-none}"
        if [ "$res" = ok ]; then
            [ -n "$first" ] || first=$db
            try_in master "$undo"
            [ "$TRY_RESULT" = ok ] || control "X.$proc.$db: undo gave $TRY_RESULT ($TRY_MSG)"
        fi
    done
    D_DB=master
    if [ "$(value "X.$proc.master")" != ok ] && [ -n "$first" ]; then D_DB=$first; fi
}

DISTRIBUTOR="DECLARE @srv sysname = @@SERVERNAME; EXEC @rc = sp_adddistributor @distributor = @srv;"
contexts sp_adddistributor "$DISTRIBUTOR" "EXEC @rc = sp_dropdistributor;"
try_in "$D_DB" "$DISTRIBUTOR"; dcall=$TRY_RESULT
[ "$dcall" = ok ] || control "sp_adddistributor from $D_DB: $dcall ($TRY_MSG)"
measure sp_adddistributor fresh "$MAP_DISTRIBUTOR" "$PRE_DISTRIBUTOR" "$dcall from $D_DB" ""

DISTDB="EXEC @rc = sp_adddistributiondb @database = N'distribution';"
contexts sp_adddistributiondb "$DISTDB" "EXEC @rc = sp_dropdistributiondb @database = N'distribution';"
try_in "$D_DB" "$DISTDB"; dcall=$TRY_RESULT
[ "$dcall" = ok ] || control "sp_adddistributiondb from $D_DB: $dcall ($TRY_MSG)"
measure sp_adddistributiondb fresh "$MAP_DISTDB" "$PRE_DISTDB" "$dcall from $D_DB" ""

DISTPUB="DECLARE @srv sysname = @@SERVERNAME; EXEC @rc = sp_adddistpublisher @publisher = @srv, @distribution_db = N'distribution';"
contexts sp_adddistpublisher "$DISTPUB" "DECLARE @srv sysname = @@SERVERNAME; EXEC @rc = sp_dropdistpublisher @publisher = @srv;"
try_in "$D_DB" "$DISTPUB"; dcall=$TRY_RESULT
[ "$dcall" = ok ] || control "sp_adddistpublisher from $D_DB: $dcall ($TRY_MSG)"
measure sp_adddistpublisher fresh "$MAP_DISTPUB" "$PRE_DISTPUB" "$dcall from $D_DB" ""

# Controls.
[ "$(value X.sp_adddistributor.msdb)" = 5001 ] || control "X.sp_adddistributor.msdb is '$(value X.sp_adddistributor.msdb)', expected 5001"
[ "${#COUNTS[@]}" = 3 ] || control "${#COUNTS[@]} contexts, expected 3"
nd=$(printf '%s\n' "${rows[@]}" | grep -c '^R|D\.' || true)
[ "$nd" = "$COUNT_SUM" ] || control "$nd D rows, the per-context counts add up to $COUNT_SUM"
[ "${#rows[@]}" = $((COUNT_SUM + 9)) ] || control "${#rows[@]} rows, expected $COUNT_SUM D rows and 9 X rows"
for c in "${COUNTS[@]}"; do echo "count $c"; done
echo "count sum: $COUNT_SUM"
if [ "$bad" != 0 ]; then
    for row in "${rows[@]}"; do echo "row: $row" >&2; done
    exit 1
fi
mkdir -p "$(dirname "$out")"
{ echo "# $banner"; printf '%s\n' "${rows[@]}"; echo "R|TOTAL|${#rows[@]}"; } >"$out"
echo "ok distributor-defaults: ${#rows[@]} cases -> ${out#"$(dirname "$lab")"/}"
