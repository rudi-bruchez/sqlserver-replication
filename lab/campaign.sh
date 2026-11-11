#!/bin/bash
# Runs measurement scripts against the lab and keeps their results only when the
# run can be trusted.
# Usage: lab/campaign.sh VERSION SCRIPT...
#   VERSION  2019, 2022 or 2025 (checked against @@VERSION), or a label such as
#            selftest; results go to lab/results/VERSION/<script name>.txt.
#   SCRIPT   a .sql file (fed to sqlcmd on standard input) or a .sh file (executed).
# Needs MSSQL_SA_PASSWORD in the environment and the lab running (lab/start.sh).
#
# Guards, checked after each script; the first that fails stops the run with
# "GUARD <name> failed: <detail>" and a non-zero exit:
#   alive     before and after each script, a tracer token posted on SalesPub and on
#             SalesRef reaches the subscriber within 90 s (the lab replicates);
#   restart   tempdb create_date and sqlserver_start_time unchanged (no restart);
#   exit      the script (sqlcmd for a .sql file) exited 0;
#   results   at least one R| line other than TOTAL;
#   total     exactly one R|TOTAL|n line, n equal to the number of other R| lines,
#             and no case id printed twice;
#   truncated no R| line of exactly 256 characters (sqlcmd's cut of a max column);
#   uncaught  no "Msg n, Level 11-25" or "Sqlcmd:" line in the output (stderr included);
#   residue   no m_ object, schema, type, index, login, linked server, publication,
#             agent, profile, job, snapshot folder or file left, no msdb job of a
#             replication agent category that no agent table references, no
#             MSpublisher_databases row of an m_ database, no agent history row whose
#             agent is gone;
#   export    sqlrepl export of Sales identical before and after.
# restart comes first: after a restart every other check reads a different instance.
set -uo pipefail
lab=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$lab")
. "$lab/lib.sh"

if [ $# -lt 2 ]; then
    echo "usage: $0 VERSION SCRIPT..." >&2
    exit 2
fi
version=$1; shift
: "${MSSQL_SA_PASSWORD:?MSSQL_SA_PASSWORD must be set}"
export SQLREPL_PASSWORD=$MSSQL_SA_PASSWORD

die() { echo "campaign: $*" >&2; exit 1; }
guard_failed() { echo "GUARD $1 failed: $2"; exit 1; }

bin=$lab/.bin/sqlrepl
(cd "$root" && go build -o "$bin" ./cmd/sqlrepl) || die "cannot build sqlrepl"

banner=$(sql_value "SELECT LEFT(@@VERSION, CHARINDEX(CHAR(10), @@VERSION + CHAR(10)) - 1)") \
    || die "cannot read @@VERSION: is the lab running?"
case $version in
    2019|2022|2025)
        [[ $banner == *"SQL Server $version "* ]] || die "the lab runs '$banner', not SQL Server $version" ;;
esac

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
outdir=$lab/results/$version
mkdir -p "$outdir"

tempdb_created() {
    sql_value "SELECT CONVERT(varchar(30), create_date, 126) FROM sys.databases WHERE name = N'tempdb'"
}

# The instance accepts connections about half a second before it rebuilds tempdb,
# and a read in that window still returns the previous tempdb create_date (seen in
# the self-test). The process start time is set before the first login is possible.
instance_started() {
    sql_value "SELECT CONVERT(varchar(30), sqlserver_start_time, 126) FROM sys.dm_os_sys_info"
}

lab_export() {
    "$bin" export -publisher 'tcp:127.0.0.1,11980' -distributor 'tcp:127.0.0.1,11980' \
        -database Sales -user sa -param encrypt=disable -o "$1" 2>"$1.err"
}

# Prints the residue found, as name=count pairs, or fails when a query fails.
# sysjobs catches the jobs named after an m_ publication; orphan_agent_jobs catches
# the others: a shared distribution agent's job is <publisher>-<db>-<subscriber>-N, with
# no publication in the name, so an orphan (agent row gone, job left in msdb) escapes
# the name test. It counts jobs of the three agent categories that none of the
# MSlogreader_agents, MSsnapshot_agents, MSdistribution_agents tables references.
# Measured in Task 7 (results/2022/08-pull.txt): a pull subscription's agent job lives at
# the subscriber and its MSdistribution_agents row has job_id = newid(), not that job, so
# this check flags a live pull job. Acceptable: the guard runs after a script, and any pull
# subscription an m_ script leaves is residue anyway.
# MSpublisher_databases: sp_addlogreader_agent (and sp_addpublication) insert a row for
# the publication database that disabling publish does not remove; only the drop of the
# database's last publication does (Task 10). orphan_agent_history: history rows of the
# distribution, snapshot and log reader agents whose agent row is gone and that were written
# at or after the script's start mark ($1 of residue(), SYSDATETIME() taken before the
# script runs, the same clock as the history `time`): an agent dropped while it runs logs
# its stop message after its row is gone. Rows with the comment 'Distribution agent for
# subscription added...' are excluded: sp_droppublication leaves that row of the virtual
# subscriber agent that sp_addpublication created (measured on 01-articles).
# The m_ prefix is matched with an escaped LIKE: an unescaped _ matches master, model, msdb.
residue() {
    local counts files
    counts=$(sql_value "
DECLARE @p nvarchar(10) = N'm\_%', @mark datetime = '$1';
SELECT CONCAT(
  'databases=',               (SELECT COUNT(*) FROM sys.databases WHERE name LIKE @p ESCAPE N'\'),
  ' server_principals=',      (SELECT COUNT(*) FROM sys.server_principals WHERE name LIKE @p ESCAPE N'\'),
  ' servers=',                (SELECT COUNT(*) FROM sys.servers WHERE name LIKE @p ESCAPE N'\'),
  ' Sales.objects=',          (SELECT COUNT(*) FROM Sales.sys.objects WHERE name LIKE @p ESCAPE N'\'),
  ' Sales.schemas=',          (SELECT COUNT(*) FROM Sales.sys.schemas WHERE name LIKE @p ESCAPE N'\'),
  ' Sales.types=',            (SELECT COUNT(*) FROM Sales.sys.types WHERE name LIKE @p ESCAPE N'\'),
  ' Sales.indexes=',          (SELECT COUNT(*) FROM Sales.sys.indexes WHERE name LIKE @p ESCAPE N'\'),
  ' SalesSub.objects=',       (SELECT COUNT(*) FROM SalesSub.sys.objects WHERE name LIKE @p ESCAPE N'\'),
  ' SalesSub.schemas=',       (SELECT COUNT(*) FROM SalesSub.sys.schemas WHERE name LIKE @p ESCAPE N'\'),
  ' SalesSub.types=',         (SELECT COUNT(*) FROM SalesSub.sys.types WHERE name LIKE @p ESCAPE N'\'),
  ' SalesSub.indexes=',       (SELECT COUNT(*) FROM SalesSub.sys.indexes WHERE name LIKE @p ESCAPE N'\'),
  ' syspublications=',        (SELECT COUNT(*) FROM Sales.dbo.syspublications WHERE name LIKE @p ESCAPE N'\'),
  ' MSpublications=',         (SELECT COUNT(*) FROM distribution.dbo.MSpublications WHERE publication LIKE @p ESCAPE N'\'),
  ' MSsubscriptions=',        (SELECT COUNT(*) FROM distribution.dbo.MSsubscriptions s
                                 JOIN distribution.dbo.MSpublications p ON p.publication_id = s.publication_id
                                WHERE p.publication LIKE @p ESCAPE N'\'),
  ' MSsnapshot_agents=',      (SELECT COUNT(*) FROM distribution.dbo.MSsnapshot_agents WHERE publication LIKE @p ESCAPE N'\'),
  ' MSdistribution_agents=',  (SELECT COUNT(*) FROM distribution.dbo.MSdistribution_agents
                                WHERE publication LIKE @p ESCAPE N'\' OR subscriber_db LIKE @p ESCAPE N'\'),
  ' MSagent_profiles=',       (SELECT COUNT(*) FROM msdb.dbo.MSagent_profiles WHERE profile_name LIKE @p ESCAPE N'\'),
  ' sysjobs=',                (SELECT COUNT(*) FROM msdb.dbo.sysjobs WHERE name LIKE N'%-m\_%' ESCAPE N'\'),
  ' orphan_agent_jobs=',      (SELECT COUNT(*) FROM msdb.dbo.sysjobs j
                                 JOIN msdb.dbo.syscategories c ON c.category_id = j.category_id
                                WHERE c.name IN (N'REPL-LogReader', N'REPL-Snapshot', N'REPL-Distribution')
                                  AND j.job_id NOT IN (SELECT job_id FROM distribution.dbo.MSlogreader_agents WHERE job_id IS NOT NULL)
                                  AND j.job_id NOT IN (SELECT job_id FROM distribution.dbo.MSsnapshot_agents WHERE job_id IS NOT NULL)
                                  AND j.job_id NOT IN (SELECT job_id FROM distribution.dbo.MSdistribution_agents WHERE job_id IS NOT NULL)),
  ' MSpublisher_databases=',  (SELECT COUNT(*) FROM distribution.dbo.MSpublisher_databases WHERE publisher_db LIKE @p ESCAPE N'\'),
  ' orphan_agent_history=',   (SELECT COUNT(*) FROM distribution.dbo.MSdistribution_history WHERE agent_id NOT IN (SELECT id FROM distribution.dbo.MSdistribution_agents) AND [time] >= @mark AND comments NOT LIKE N'Distribution agent for subscription added%')
                            + (SELECT COUNT(*) FROM distribution.dbo.MSsnapshot_history WHERE agent_id NOT IN (SELECT id FROM distribution.dbo.MSsnapshot_agents) AND [time] >= @mark AND comments NOT LIKE N'Distribution agent for subscription added%')
                            + (SELECT COUNT(*) FROM distribution.dbo.MSlogreader_history WHERE agent_id NOT IN (SELECT id FROM distribution.dbo.MSlogreader_agents) AND [time] >= @mark AND comments NOT LIKE N'Distribution agent for subscription added%'))") || return 1
    # Snapshot folders are named <PUBLISHER>_<DATABASE>_<PUBLICATION>, upper case;
    # matched in any case all the same, as are files at any depth under data.
    files=$(podman exec repllab find /var/opt/mssql/data/ReplData/unc -iname '*_m_*' 2>&1) || {
        echo "find in ReplData/unc failed: $files" >&2; return 1; }
    files+=$'\n'$(podman exec repllab find /var/opt/mssql/data -iname 'm_*' 2>&1) || {
        echo "find in /var/opt/mssql/data failed: $files" >&2; return 1; }
    files=$(printf '%s\n' "$files" | grep -v '^$' | tr '\n' ' ')
    printf '%s files=[%s]\n' "$counts" "$files"
}

# alive: the lab replicates. Posts a tracer token on each of the lab's publications and
# waits until every subscription of that publication has a subscriber_commit for it.
# Added after a failed break step wrote a bogus LSN into MSrepl_transactions: the idle
# distribution agents moved their watermark past it and Sales stopped replicating to
# SalesSub, with every other guard silent (the export compares configuration only).
# Tracer rows stay in MStracer_tokens and MStracer_history: accepted residue, the
# distribution cleanup job removes them. Both tokens arrive in about 10 s.
# Usage: alive WHEN (before|after) NAME; fails the run through guard_failed.
alive() {
    local pub id out
    for pub in SalesPub SalesRef; do
        id=$(sql_value "DECLARE @id int; EXEC Sales.dbo.sp_posttracertoken @publication = N'$pub', @tracer_token_id = @id OUTPUT; SELECT @id" 2>&1) \
            || guard_failed alive "$pub: cannot post a tracer token $1 $2: $id"
        [[ $id =~ ^-?[0-9]+$ ]] || guard_failed alive "$pub: no tracer token id $1 $2: $id"
        if ! out=$(wait_until 90 "
SELECT CASE WHEN
    (SELECT COUNT(*) FROM distribution.dbo.MStracer_history h WHERE h.parent_tracer_id = $id AND h.subscriber_commit IS NOT NULL)
      = (SELECT COUNT(DISTINCT CONCAT(s.subscriber_id, N'|', s.subscriber_db)) FROM distribution.dbo.MSsubscriptions s
           JOIN distribution.dbo.MSpublications p ON p.publication_id = s.publication_id
          WHERE p.publication = N'$pub' AND s.subscriber_id >= 0 AND s.subscriber_db <> N'virtual')
    AND NOT EXISTS (SELECT 1 FROM distribution.dbo.MStracer_history h WHERE h.parent_tracer_id = $id AND h.subscriber_commit IS NULL)
  THEN 1 ELSE 0 END" 2>&1); then
            guard_failed alive "$pub token $id not delivered within 90 s ($1 $2)"
        fi
    done
}

for script in "$@"; do
    [ -f "$script" ] || die "no such script: $script"
    name=$(basename "$script"); name=${name%.*}
    log=$work/$name.log

    mark=$(sql_value "SELECT CONVERT(varchar(23), SYSDATETIME(), 121)") || die "cannot read the start mark of $name"
    before_tempdb=$(tempdb_created) || die "cannot read tempdb create_date before $name"
    before_start=$(instance_started) || die "cannot read the instance start time before $name"
    lab_export "$work/before.yaml" || die "export before $name failed: $(cat "$work/before.yaml.err")"
    # Two empty or truncated exports would compare equal: require the lab's publications.
    grep -q -- '- name: SalesPub$' "$work/before.yaml" && grep -q -- '- name: SalesRef$' "$work/before.yaml" \
        || die "the export before $name does not show SalesPub and SalesRef: the lab is not in its setup state"
    alive before "$name"

    case $script in
        *.sql) sql < "$script" >"$log" 2>&1 ;;
        *.sh)  bash "$script" </dev/null >"$log" 2>&1 ;;
        *)     die "not a .sql or .sh script: $script" ;;
    esac
    status=$?

    after_tempdb=$(tempdb_created 2>&1) \
        || guard_failed restart "cannot read tempdb create_date after $name: $after_tempdb"
    [ "$after_tempdb" = "$before_tempdb" ] \
        || guard_failed restart "tempdb create_date went from $before_tempdb to $after_tempdb during $name: the instance restarted"
    after_start=$(instance_started 2>&1) \
        || guard_failed restart "cannot read the instance start time after $name: $after_start"
    [ "$after_start" = "$before_start" ] \
        || guard_failed restart "sqlserver_start_time went from $before_start to $after_start during $name: the instance restarted"

    [ "$status" -eq 0 ] || guard_failed exit "$name exited with status $status (log: $(tail -n 3 "$log" | tr '\n' ' '))"

    cases=$(grep -c -E '^R\|' "$log" | head -n 1)
    totals=$(grep -E '^R\|TOTAL\|' "$log")
    ntotals=$(grep -c -E '^R\|TOTAL\|' "$log")
    count=$(( cases - ntotals ))
    [ "$count" -ge 1 ] || guard_failed results "$name printed no R| case (log: $(tail -n 3 "$log" | tr '\n' ' '))"

    [ "$ntotals" -eq 1 ] || guard_failed total "$name printed $ntotals R|TOTAL lines, expected one"
    [[ $totals =~ ^R\|TOTAL\|([0-9]+)$ ]] || guard_failed total "$name: malformed TOTAL line: $totals"
    [ "${BASH_REMATCH[1]}" -eq "$count" ] \
        || guard_failed total "$name announced ${BASH_REMATCH[1]} cases and printed $count"
    dups=$(grep -E '^R\|' "$log" | grep -v -E '^R\|TOTAL\|' | cut -d'|' -f2 | sort | uniq -d | tr '\n' ' ')
    [ -z "$dups" ] || guard_failed total "$name printed these case ids more than once: $dups"

    # sqlcmd cuts each max column at 256 characters: the whole line when the row is
    # one concatenated column, a single |-separated field when it is several columns.
    long=$(grep -E '^R\|' "$log" | awk -F'|' '{
        hit = (length($0) == 256)
        for (i = 1; i <= NF && !hit; i++) if (length($i) == 256) hit = 1
        if (hit) print substr($0, 1, 40) }' | head -n 3 | tr '\n' ' ')
    [ -z "$long" ] || guard_failed truncated "$name: R| line or field of exactly 256 characters, an nvarchar(max) cut by sqlcmd (cast it to nvarchar(4000)): $long"

    uncaught=$(grep -E '^Msg [0-9]+, Level (1[1-9]|2[0-5])|^Sqlcmd:' "$log" | head -n 3 | tr '\n' ' ')
    [ -z "$uncaught" ] || guard_failed uncaught "$name: $uncaught"

    found=$(residue "$mark" 2>&1) || guard_failed residue "cannot check residue after $name: $found"
    if [[ $found =~ =[1-9] ]] || [[ $found != *"files=[]" ]]; then
        guard_failed residue "$name left: $found"
    fi

    # Before the export comparison: a dead lab explains a differing export.
    alive after "$name"

    lab_export "$work/after.yaml" \
        || guard_failed export "export after $name failed: $(cat "$work/after.yaml.err")"
    if ! cmp -s "$work/before.yaml" "$work/after.yaml"; then
        guard_failed export "the export of Sales changed during $name (check that nobody else used Sales): $(diff "$work/before.yaml" "$work/after.yaml" | head -n 6 | tr '\n' ' ')"
    fi

    { echo "# $banner"; grep -E '^R\|' "$log"; } >"$outdir/$name.txt"
    echo "ok $name: $count cases -> ${outdir#"$root"/}/$name.txt"
done
