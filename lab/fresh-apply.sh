#!/bin/bash
# The central scenario of the design's "Testing" (plan 4 Task 13): from an instance with no
# replication, sqlrepl apply a file, export what it made, and plan both the export and the
# file, each of which must be empty. Run directly, not through lab/campaign.sh, whose
# restart guard would reject a script that stops the lab (as lab/distributor-defaults.sh).
# Usage: lab/fresh-apply.sh [2019|2022|2025] (default 2022; only 2022 has run). Needs
# MSSQL_SA_PASSWORD.
#
# What it does: builds sqlrepl into a temporary folder; shuts repllab down with SHUTDOWN
# WITH NOWAIT (the host cannot hold a second 4 GB instance next to it); starts the
# container m-fresh (same image as the lab, 127.0.0.1:11981, MSSQL_MEMORY_LIMIT_MB=4096,
# SQL Agent on, /var/opt/mssql/ReplData created and owned by mssql, since
# sp_adddistpublisher refuses a missing working directory with 21037) and waits for SQL
# Server and its Agent; runs lab/fresh/setup.sql (m_fresh_pub with dbo.m_t1, 20 rows, and
# the empty m_fresh_sub); writes lab/fresh/create.yaml with {server} replaced by the
# @@SERVERNAME of m-fresh and {admin_secret} by the name of the distributor_admin secret,
# whose value it generates from /dev/urandom, exports and never prints. Then:
#   FA.apply          sqlrepl apply -f <create.yaml> -server <name>=tcp:127.0.0.1,11981
#                     -user sa -param encrypt=disable -auto-approve -wait 10m: its exit
#                     code, expected 0 (applied and every delivery confirmed)
#   FA.delivered      SELECT COUNT(*) FROM m_fresh_sub.dbo.m_t1, expected 20
#   FA.export_plan    sqlrepl export of m_fresh_pub, then sqlrepl plan of that export:
#                     "no changes" when plan exits 0 and its first line ends with
#                     "no changes.", else rc<code> and the line
#   FA.file_plan      sqlrepl plan of the same create.yaml, read the same way
# The sa password reaches sqlrepl through SQLREPL_PASSWORD, the admin password through its
# own variable; neither is on a command line. The apply and plan calls get -env with a
# missing file, so that no .env of the working directory is read (export has no -env and
# reads none). create.yaml omits working_directory, so the delivery is confirmed through
# the root apply reads at the distributor (R50b).
#
# It writes lab/results/VERSION/fresh-apply.txt in the result format only when every row
# has its expected value; otherwise it prints the rows on stderr and exits 1. On success
# and on failure alike (trap), it removes m-fresh with podman rm -f, starts the lab again
# with lab/start.sh VERSION and removes the temporary folder.
set -euo pipefail
lab=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$lab")
version=${1:-2022}
case $version in
    2019|2022|2025) ;;
    *) echo "usage: $0 [2019|2022|2025]" >&2; exit 2 ;;
esac
: "${MSSQL_SA_PASSWORD:?MSSQL_SA_PASSWORD must be set}"
. "$lab/lib.sh"

out=$lab/results/$version/fresh-apply.txt
address=tcp:127.0.0.1,11981

# lab_sql: sqlcmd on repllab (lib.sh's sql, before it is redefined for m-fresh).
lab_sql() {
    SQLCMDPASSWORD=$MSSQL_SA_PASSWORD podman exec -i -e SQLCMDPASSWORD repllab \
        /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -W -s '|' "$@"
}
# From here sql, sql_value and wait_until talk to m-fresh.
sql() {
    SQLCMDPASSWORD=$MSSQL_SA_PASSWORD podman exec -i -e SQLCMDPASSWORD m-fresh \
        /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -W -s '|' "$@"
}
running() { [ "$(podman inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }
die() { echo "fresh-apply: $*" >&2; exit 1; }

work=""
finish() {
    local status=$?
    set +e
    echo "fresh-apply: removing m-fresh and restarting the lab" >&2
    podman rm -f m-fresh >/dev/null 2>&1
    [ -n "$work" ] && rm -rf "$work"
    if ! bash "$lab/start.sh" "$version"; then
        echo "fresh-apply: lab/start.sh $version failed" >&2
        status=1
    fi
    exit "$status"
}

# A leftover m-fresh is this script's own container (an earlier run killed midway), or
# lab/distributor-defaults.sh's, which removes it the same way.
podman rm -f m-fresh >/dev/null 2>&1 || true
trap finish EXIT
work=$(mktemp -d)
bin=$work/sqlrepl
(cd "$root" && go build -o "$bin" ./cmd/sqlrepl)

if running repllab; then
    lab_sql -Q "SHUTDOWN WITH NOWAIT" </dev/null >&2 || true
    for _ in $(seq 1 30); do running repllab || break; sleep 2; done
fi
running repllab && die "repllab still runs after SHUTDOWN WITH NOWAIT"

podman run -d --name m-fresh --hostname m-fresh -p 127.0.0.1:11981:1433 \
  -e ACCEPT_EULA=Y -e MSSQL_PID=Developer -e MSSQL_AGENT_ENABLED=true -e MSSQL_MEMORY_LIMIT_MB=4096 \
  -e MSSQL_SA_PASSWORD "mcr.microsoft.com/mssql/server:$version-latest" >/dev/null
for _ in $(seq 1 90); do sql -l 5 -b -Q "SELECT 1" </dev/null >/dev/null 2>&1 && break; sleep 2; done
podman exec -u 0 m-fresh bash -c 'mkdir -p /var/opt/mssql/ReplData && chown mssql /var/opt/mssql/ReplData'
banner=$(sql_value "SELECT LEFT(@@VERSION, CHARINDEX(CHAR(10), @@VERSION + CHAR(10)) - 1)")
[[ $banner == *"SQL Server $version "* ]] || die "m-fresh runs '$banner', not SQL Server $version"
fresh=$(sql_value "SELECT (SELECT COUNT(*) FROM sys.servers WHERE name = N'repl_distributor') + (SELECT COUNT(*) FROM sys.databases WHERE name = N'distribution')")
[ "$fresh" = 0 ] || die "m-fresh is not a fresh instance"
# The Agent starts after the engine accepts connections (agent-stopped AS.detect rows).
wait_until 120 "SELECT CASE WHEN EXISTS (SELECT * FROM sys.dm_server_services WHERE servicename LIKE N'SQL Server Agent%' AND status_desc = N'Running') THEN 1 ELSE 0 END" \
    || die "SQL Server Agent of m-fresh is not running"

setup=$(sql -b <"$lab/fresh/setup.sql" 2>&1) || die "setup.sql failed: $setup"
server=$(sql_value "SELECT @@SERVERNAME")

# The secret's name as model.SecretName builds it; its value meets the password policy
# (upper, lower, digit and symbol) and is never printed.
admin_secret=SQLREPL_SQL_$(printf '%s' "$server" | tr '[:lower:]' '[:upper:]' | sed 's/[^A-Z0-9]/_/g')_DISTRIBUTOR_ADMIN
admin_value="$(head -c 24 /dev/urandom | base64 | tr -d '+/=')Aa1#"
export "$admin_secret=$admin_value"
unset admin_value
export SQLREPL_PASSWORD=$MSSQL_SA_PASSWORD

desired=$work/create.yaml
sed -e "s/{server}/$server/g" -e "s/{admin_secret}/$admin_secret/g" "$lab/fresh/create.yaml" >"$desired"
noenv=$work/no.env
conn=(-user sa -param encrypt=disable -env "$noenv")

rows=()
r() { rows+=("R|$1|$2|$3"); }
# The expected values, which the controls at the end compare and the details print.
want_delivered=20

# first_line FILE: the first line of a plan's output, for the rows and the detail.
first_line() { sed -n '1p' "$1"; }
# plan_row ID RC FILE: the row of a plan run.
plan_row() {
    local line
    line=$(first_line "$3")
    if [ "$2" = 0 ] && [[ $line == *"no changes." ]]; then
        r "$1" "no changes" "first_line=$line"
    else
        r "$1" "rc$2" "first_line=$line"
    fi
}

echo "fresh-apply: sqlrepl apply of create.yaml on $server"
rc=0
"$bin" apply -f "$desired" -server "$server=$address" "${conn[@]}" -auto-approve -wait 10m \
    >"$work/apply.out" 2>&1 || rc=$?
cat "$work/apply.out"
r FA.apply "$rc" "expected=0 last_line=$(tail -n 1 "$work/apply.out")"

delivered=$(sql_value "SELECT COUNT(*) FROM m_fresh_sub.dbo.m_t1" 2>/dev/null) || delivered=error
r FA.delivered "$delivered" "expected=$want_delivered table=m_fresh_sub.dbo.m_t1"

rc=0
"$bin" export -publisher "$address" -database m_fresh_pub -server "$server=$address" \
    -user sa -param encrypt=disable -o "$work/export.yaml" >"$work/export.out" 2>&1 || rc=$?
if [ "$rc" = 0 ]; then
    cat "$work/export.out"
    rc=0
    "$bin" plan -f "$work/export.yaml" -server "$server=$address" "${conn[@]}" \
        >"$work/export-plan.out" 2>&1 || rc=$?
    cat "$work/export-plan.out"
    plan_row FA.export_plan "$rc" "$work/export-plan.out"
else
    cat "$work/export.out"
    r FA.export_plan "export-rc$rc" "first_line=$(first_line "$work/export.out")"
fi

rc=0
"$bin" plan -f "$desired" -server "$server=$address" "${conn[@]}" >"$work/file-plan.out" 2>&1 || rc=$?
cat "$work/file-plan.out"
plan_row FA.file_plan "$rc" "$work/file-plan.out"

# Controls.
expected=(FA.apply=0 "FA.delivered=$want_delivered" "FA.export_plan=no changes" "FA.file_plan=no changes")
bad=0
for i in "${!expected[@]}"; do
    id=${expected[$i]%%=*} want=${expected[$i]#*=}
    got=$(printf '%s\n' "${rows[$i]}" | cut -d'|' -f3)
    [[ ${rows[$i]} == "R|$id|"* ]] || { echo "fresh-apply: row $i is not $id: ${rows[$i]}" >&2; bad=1; continue; }
    [ "$got" = "$want" ] || { echo "fresh-apply: $id is '$got', expected '$want'" >&2; bad=1; }
done
if [ "$bad" != 0 ]; then
    for row in "${rows[@]}"; do echo "row: $row" >&2; done
    exit 1
fi
mkdir -p "$(dirname "$out")"
{ echo "# $banner"; printf '%s\n' "${rows[@]}"; echo "R|TOTAL|${#rows[@]}"; } >"$out"
echo "ok fresh-apply: ${#rows[@]} cases -> ${out#"$root"/}"
