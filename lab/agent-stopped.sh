#!/bin/bash
# What SQL Server Agent stopped looks like from T-SQL (plan 4 Task 2, rows AS.<case>, read
# by R56's precondition and by classify's agentStopped class, R47). Measured on a throwaway
# container, never on repllab: repllab is started with MSSQL_AGENT_ENABLED=true, which sets
# sqlagent.enabled back to true at every start, whatever mssql-conf wrote (panel G). Run
# directly, not through lab/campaign.sh, which works on repllab.
# Usage: lab/agent-stopped.sh. Needs MSSQL_SA_PASSWORD. SQL Server 2022 only (the image of
# lab/start.sh 2022).
#
# What it does: starts the container m-agent (same image as the lab, 127.0.0.1:11982,
# MSSQL_MEMORY_LIMIT_MB=2048, volume m-agent-data on /var/opt/mssql) with
# MSSQL_AGENT_ENABLED=true; creates a local distributor as lab/setup.sql does, the database
# m_as_db with dbo.m_t1 (primary key, 10 rows), its log reader, the transactional
# publication m_as_p (native) with its snapshot agent on a schedule that never fires, and
# the plain msdb job m_as_job (one T-SQL step, SELECT 1). Agent running, it reads the
# candidates; then SHUTDOWN WITH NOWAIT, removes the container (the volume stays) and runs
# it again on the same volume with MSSQL_AGENT_ENABLED=false, where it reads the
# candidates again and the three stopped rows. repllab is never touched.
#
# Rows (lab/results/2022/agent-stopped.txt):
#   AS.detect.dm_server_services.<running|stopped>  status_desc of the sys.dm_server_services
#        row whose servicename starts with 'SQL Server Agent', or none
#   AS.detect.agent_sessions.<state>   count of sys.dm_exec_sessions with program_name
#        LIKE N'SQLAgent - %'
#   AS.detect.xp_servicecontrol.<state>  EXEC master.dbo.xp_servicecontrol N'QueryState',
#        N'SQLServerAGENT': its output, or the error number
#   AS.guard.stopped     jobIdle (internal/plan/lists.go) evaluated on m_as_p's snapshot job
#        found by jobLookup's text (internal/plan/agents.go): idle or busy; the detail gives
#        the same read after AS.start_job.stopped
#   AS.start_job.stopped  msdb.dbo.sp_start_job on that job: error number (or rcN), and the
#        message's first 80 characters
#   AS.startpub.stopped  sp_startpublication_snapshot @publication = N'm_as_p' in m_as_db:
#        error number (or rcN), return code, message
#
# Guards, exit 1 otherwise: with Agent running, m_as_job started by sp_start_job writes a
# history row within 30 s (GUARD agent_running, the positive control of the next one); with
# Agent stopped, m_as_job started (its sp_start_job error ignored) has no history row after
# 30 s (GUARD agent_stopped), which checks the stopped state by another way than the
# candidates; m_as_db and the snapshot job survive the restart; 9 rows.
# A trap shuts m-agent down (SHUTDOWN WITH NOWAIT), then removes it with podman rm -f and the
# volume with podman volume rm, on success and failure alike.
set -euo pipefail
lab=$(cd "$(dirname "$0")" && pwd)
: "${MSSQL_SA_PASSWORD:?MSSQL_SA_PASSWORD must be set}"
. "$lab/lib.sh"

C=m-agent
V=m-agent-data
image=mcr.microsoft.com/mssql/server:2022-latest
out=$lab/results/2022/agent-stopped.txt

# From here sql, sql_value and wait_until talk to m-agent.
sql() {
    SQLCMDPASSWORD=$MSSQL_SA_PASSWORD podman exec -i -e SQLCMDPASSWORD "$C" \
        /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -W -s '|' "$@"
}
running() { [ "$(podman inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }
die() { echo "agent-stopped: $*" >&2; exit 1; }

shutdown_m() {
    if running "$C"; then
        sql -l 10 -Q "SHUTDOWN WITH NOWAIT" </dev/null >/dev/null 2>&1 || true
        for _ in $(seq 1 30); do running "$C" || break; sleep 2; done
    fi
}
finish() {
    local status=$?
    set +e
    echo "agent-stopped: removing $C and $V" >&2
    shutdown_m
    podman rm -f "$C" >/dev/null 2>&1
    podman volume rm "$V" >/dev/null 2>&1
    if podman container exists "$C" || podman volume exists "$V"; then
        echo "agent-stopped: $C or $V is still there" >&2
        status=1
    fi
    exit "$status"
}

# start_m AGENT: runs m-agent on the volume with MSSQL_AGENT_ENABLED=AGENT and waits for
# the instance to accept connections.
start_m() {
    podman run -d --name "$C" --hostname "$C" -p 127.0.0.1:11982:1433 -v "$V:/var/opt/mssql" \
      -e ACCEPT_EULA=Y -e MSSQL_PID=Developer -e MSSQL_AGENT_ENABLED="$1" -e MSSQL_MEMORY_LIMIT_MB=2048 \
      -e MSSQL_SA_PASSWORD "$image" >/dev/null
    for _ in $(seq 1 90); do sql -l 5 -b -Q "SELECT 1" </dev/null >/dev/null 2>&1 && return 0; sleep 2; done
    die "$C does not accept connections after 180 s"
}

# A leftover m-agent or m-agent-data is this script's own (an earlier run killed midway).
podman rm -f "$C" >/dev/null 2>&1 || true
podman volume rm "$V" >/dev/null 2>&1 || true
trap finish EXIT

rows=()
row() { rows+=("R|$1|$2|$3"); }

# marked QUERY: like sql_value, for a batch that also prints informational lines
# (sp_start_job prints "Job ... started successfully."): QUERY's value is selected with the
# prefix VAL:, and exactly one such line is expected (no -b: a batch an error aborts prints
# none). The other lines go to stderr.
marked() {
    local out info
    out=$(sql -h -1 -Q "SET NOCOUNT ON; $1" </dev/null 2>&1) || { printf 'marked: query failed:\n%s\n' "$out" >&2; return 1; }
    info=$(printf '%s\n' "$out" | grep -v '^VAL:' | sed -e 's/[[:space:]]*$//' | grep -v '^$' | tr '\n' ' ' | sed 's/ $//' || true)
    [ -z "$info" ] || echo "agent-stopped: info: $info" >&2
    [ "$(printf '%s\n' "$out" | grep -c '^VAL:')" = 1 ] || { printf 'marked: expected one VAL: line, got:\n%s\n' "$out" >&2; return 1; }
    printf '%s\n' "$out" | grep '^VAL:' | sed -e 's/^VAL://' -e 's/[[:space:]]*$//'
}

# probe BODY: runs BODY, which sets @res and @det, inside TRY...CATCH; a caught error sets
# @res to its number and @det to its message. Prints res|det.
probe() {
    marked "DECLARE @res nvarchar(4000) = N'', @det nvarchar(4000) = N'', @rc int;
BEGIN TRY $1 END TRY
BEGIN CATCH
    SET @res = CONVERT(nvarchar(20), ERROR_NUMBER());
    SET @det = CONCAT(N'rc=', ISNULL(CONVERT(nvarchar(20), @rc), N'none'), N' msg=', ERROR_MESSAGE());
    WHILE @@TRANCOUNT > 0 ROLLBACK;
END CATCH
SELECT CONVERT(nvarchar(4000), CONCAT(N'VAL:', @res, N'|', REPLACE(REPLACE(@det, CHAR(13), N' '), CHAR(10), N' ')));"
}

# callp BODY: runs BODY, a call that sets @rc (EXEC @rc = ...;), inside TRY...CATCH, with
# @@ERROR read right after it. With SQL Server Agent stopped, sp_start_job's refusal is
# printed as "HResult 0x5606, Level 16" and not raised to the CATCH, so the printed lines
# are read too. Sets CALL_RC, CALL_ERROR (@@ERROR after the call, or none), CALL_NUM (the
# caught error number, else the first printed Msg or HResult number in decimal, else
# empty), CALL_FORM (caught, Msg, HResult or none) and CALL_MSG.
callp() {
    local out val p
    out=$(sql -h -1 -Q "SET NOCOUNT ON; DECLARE @rc int, @e int, @cn int, @cm nvarchar(4000);
BEGIN TRY $1 SET @e = @@ERROR; END TRY
BEGIN CATCH SET @cn = ERROR_NUMBER(); SET @cm = ERROR_MESSAGE(); WHILE @@TRANCOUNT > 0 ROLLBACK; END CATCH
SELECT CONVERT(nvarchar(4000), CONCAT(N'VAL:', ISNULL(CONVERT(nvarchar(20), @rc), N'none'), N'|', ISNULL(CONVERT(nvarchar(20), @e), N'none'), N'|', @cn, N'|', REPLACE(REPLACE(ISNULL(@cm, N''), CHAR(13), N' '), CHAR(10), N' ')));" </dev/null 2>&1) || true
    echo "agent-stopped: call output: $(printf '%s' "$out" | tr '\n' ' ')" >&2
    [ "$(printf '%s\n' "$out" | grep -c '^VAL:')" = 1 ] || die "callp: expected one VAL: line, got: $out"
    val=$(printf '%s\n' "$out" | grep '^VAL:' | sed -e 's/^VAL://' -e 's/[[:space:]]*$//')
    IFS='|' read -r CALL_RC CALL_ERROR CALL_NUM CALL_MSG <<<"$val"
    CALL_FORM=none
    if [ -n "$CALL_NUM" ]; then
        CALL_FORM=caught
    else
        CALL_MSG=""
        p=$(printf '%s\n' "$out" | grep -v '^VAL:' | awk '/^(Msg [0-9]+|HResult 0x[0-9A-Fa-f]+), Level/ && !h { h = $0; getline m; print h "\t" m; exit }')
        if [ -n "$p" ]; then
            local head=${p%%$'\t'*}
            CALL_MSG=$(printf '%s' "${p#*$'\t'}" | sed 's/[[:space:]]*$//')
            if [[ $head =~ ^Msg\ ([0-9]+) ]]; then
                CALL_FORM=Msg; CALL_NUM=${BASH_REMATCH[1]}
            elif [[ $head =~ ^HResult\ 0x([0-9A-Fa-f]+) ]]; then
                CALL_FORM=HResult; CALL_NUM=$((16#${BASH_REMATCH[1]}))
            fi
        fi
    fi
}

# detect STATE: the three candidate rows for STATE.
detect() {
    local v
    v=$(probe "SELECT @res = ISNULL((SELECT TOP (1) CONVERT(nvarchar(60), status_desc) FROM sys.dm_server_services WHERE servicename LIKE N'SQL Server Agent%' ORDER BY servicename), N'none'),
       @det = CONCAT(N'services=', ISNULL((SELECT STRING_AGG(CONVERT(nvarchar(4000), CONCAT(servicename, N':', status_desc)), N'; ') FROM sys.dm_server_services), N'none'));")
    row "AS.detect.dm_server_services.$1" "${v%%|*}" "${v#*|}"
    v=$(probe "SELECT @res = CONVERT(nvarchar(20), COUNT(*)) FROM sys.dm_exec_sessions WHERE program_name LIKE N'SQLAgent - %';
SELECT @det = CONCAT(N'programs=', ISNULL((SELECT STRING_AGG(CONVERT(nvarchar(4000), p), N', ') WITHIN GROUP (ORDER BY p) FROM (SELECT DISTINCT program_name AS p FROM sys.dm_exec_sessions WHERE program_name LIKE N'SQLAgent - %') AS d), N'none'));")
    row "AS.detect.agent_sessions.$1" "${v%%|*}" "${v#*|}"
    v=$(probe "CREATE TABLE #s (state nvarchar(4000));
INSERT #s EXEC master.dbo.xp_servicecontrol N'QueryState', N'SQLServerAGENT';
SELECT @res = ISNULL((SELECT STRING_AGG(state, N' ') FROM #s), N'no-output'), @det = CONCAT(N'rows=', (SELECT COUNT(*) FROM #s));")
    row "AS.detect.xp_servicecontrol.$1" "${v%%|*}" "${v#*|}"
}

# history_rows: the sysjobhistory rows of m_as_job written since $mark.
history_rows() {
    sql_value "SELECT COUNT(*) FROM msdb.dbo.sysjobhistory h JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id
WHERE j.name = N'm_as_job' AND msdb.dbo.agent_datetime(h.run_date, h.run_time) >= DATEADD(SECOND, -1, '$mark')"
}
start_guard_job() { callp "EXEC @rc = msdb.dbo.sp_start_job @job_name = N'm_as_job';"; }

# ---------------------------------------------------------------- Agent running
podman volume create "$V" >/dev/null
start_m true
ready=$SECONDS
podman exec -u 0 "$C" bash -c 'mkdir -p /var/opt/mssql/data/ReplData && chown mssql /var/opt/mssql/data/ReplData'
banner=$(sql_value "SELECT LEFT(@@VERSION, CHARINDEX(CHAR(10), @@VERSION + CHAR(10)) - 1)")
[[ $banner == *"SQL Server 2022 "* ]] || die "$C runs '$banner', not SQL Server 2022"
srv=$(sql_value "SELECT @@SERVERNAME")

out_setup=$(sql -b -l 30 <<SQL 2>&1
SET NOCOUNT ON;
USE master;
GO
DECLARE @srv sysname = @@SERVERNAME;
EXEC sp_adddistributor @distributor = @srv, @password = N'';
EXEC sp_adddistributiondb @database = N'distribution', @security_mode = 1;
EXEC sp_adddistpublisher @publisher = @srv, @distribution_db = N'distribution',
     @security_mode = 1, @working_directory = N'/var/opt/mssql/data/ReplData';
GO
CREATE DATABASE m_as_db;
GO
USE m_as_db;
CREATE TABLE dbo.m_t1 (id int NOT NULL PRIMARY KEY, v nvarchar(20) NOT NULL);
INSERT dbo.m_t1 (id, v) SELECT n, CONCAT(N'v', n) FROM (VALUES (1),(2),(3),(4),(5),(6),(7),(8),(9),(10)) AS t(n);
EXEC sp_replicationdboption @dbname = N'm_as_db', @optname = N'publish', @value = N'true';
EXEC sp_addlogreader_agent @job_login = NULL, @job_password = NULL, @publisher_security_mode = 1;
EXEC sp_addpublication @publication = N'm_as_p', @status = N'active', @allow_push = N'true',
     @independent_agent = N'true', @immediate_sync = N'false', @repl_freq = N'continuous', @sync_method = N'native';
EXEC sp_addpublication_snapshot @publication = N'm_as_p', @frequency_type = 1, @active_start_date = 99991231,
     @job_login = NULL, @job_password = NULL, @publisher_security_mode = 1;
EXEC sp_addarticle @publication = N'm_as_p', @article = N'm_t1', @source_owner = N'dbo', @source_object = N'm_t1';
GO
USE msdb;
EXEC dbo.sp_add_job @job_name = N'm_as_job';
EXEC dbo.sp_add_jobstep @job_name = N'm_as_job', @step_name = N's1', @subsystem = N'TSQL', @command = N'SELECT 1;', @database_name = N'master';
EXEC dbo.sp_add_jobserver @job_name = N'm_as_job';
GO
SQL
) || die "setup failed: $out_setup"

# The snapshot job as plan prints it: jobLookup (internal/plan/agents.go) for the snapshot
# agent of m_as_p, and jobIdle (internal/plan/lists.go), verbatim but for the names.
prologue="DECLARE @job_id uniqueidentifier;
SELECT @job_id = sj.job_id FROM [distribution].dbo.MSsnapshot_agents AS a JOIN [distribution].dbo.MSreplservers AS ps ON ps.srvid = a.publisher_id JOIN msdb.dbo.sysjobs AS sj ON sj.job_id = CONVERT(uniqueidentifier, a.job_id) WHERE UPPER(ps.srvname) = UPPER(N'$srv') AND a.publisher_db = N'm_as_db' AND a.publication = N'm_as_p' AND a.local_job = 1;
IF @job_id IS NULL THROW 50000, N'the job of publications[m_as_p].snapshot_agent does not exist', 1;"
jobidle="NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobactivity AS ja WHERE ja.job_id = @job_id AND ja.session_id = (SELECT MAX(ss.session_id) FROM msdb.dbo.syssessions AS ss) AND (ja.run_requested_date IS NOT NULL OR ja.start_execution_date IS NOT NULL) AND ja.stop_execution_date IS NULL)"
guard_read() { marked "$prologue SELECT CASE WHEN $jobidle THEN N'VAL:idle' ELSE N'VAL:busy' END;"; }
snapjob=$(sql_value "$prologue SELECT CONVERT(varchar(36), @job_id);")

# GUARD agent_running: Agent may still be starting; sp_start_job is retried until accepted
# (22022 while Agent is not up), for 120 s, then the job's history row is awaited for 30 s.
mark=$(sql_value "SELECT CONVERT(varchar(23), GETDATE(), 121)")
accepted=""
for _ in $(seq 1 24); do
    start_guard_job
    r="rc=$CALL_RC $CALL_FORM $CALL_NUM $CALL_MSG"
    if [ "$CALL_RC" = 0 ] && [ "$CALL_FORM" = none ]; then accepted=yes; break; fi
    sleep 5
done
[ -n "$accepted" ] || die "GUARD agent_running failed: sp_start_job of m_as_job never accepted ($r)"
agent_up=$((SECONDS - ready))
n=0
for _ in $(seq 1 15); do n=$(history_rows); [ "$n" -gt 0 ] && break; sleep 2; done
[ "$n" -gt 0 ] || die "GUARD agent_running failed: m_as_job wrote no history row in 30 s"
echo "agent-stopped: Agent running ($((agent_up)) s after the instance accepted connections), m_as_job ran"
[ "$(guard_read)" = idle ] || die "the snapshot job of m_as_p is busy with Agent running (its schedule never fires)"

detect running

# ---------------------------------------------------------------- Agent stopped
shutdown_m
running "$C" && die "$C still runs after SHUTDOWN WITH NOWAIT"
podman rm -f "$C" >/dev/null
start_m false
# Wait longer than Agent took to come up in the running phase, so that an Agent starting
# late would be up before the guard.
sleep $((agent_up + 30))
[ "$(sql_value "SELECT COUNT(*) FROM sys.databases WHERE name = N'm_as_db'")" = 1 ] || die "m_as_db did not survive the restart"
[ "$(sql_value "$prologue SELECT CONVERT(varchar(36), @job_id);")" = "$snapjob" ] || die "the snapshot job of m_as_p changed across the restart"

# GUARD agent_stopped: m_as_job, started (its error ignored), writes no history row in 30 s.
mark=$(sql_value "SELECT CONVERT(varchar(23), GETDATE(), 121)")
start_guard_job
r="rc=$CALL_RC $CALL_FORM $CALL_NUM $CALL_MSG"
sleep 30
n=$(history_rows)
[ "$n" = 0 ] || die "GUARD agent_stopped failed: m_as_job wrote $n history row(s) in 30 s (sp_start_job: $r)"
echo "agent-stopped: GUARD agent_stopped ok (sp_start_job of m_as_job: ${r:0:80})"

detect stopped

before=$(guard_read)
callp "$prologue EXEC @rc = msdb.dbo.sp_start_job @job_id = @job_id;"
after=$(guard_read)
row AS.guard.stopped "$before" "after_start_job=$after"
row AS.start_job.stopped "${CALL_NUM:-rc$CALL_RC}" "rc=$CALL_RC error=$CALL_ERROR form=$CALL_FORM msg=${CALL_MSG:0:80}"
callp "EXEC @rc = m_as_db.sys.sp_startpublication_snapshot @publication = N'm_as_p';"
row AS.startpub.stopped "${CALL_NUM:-rc$CALL_RC}" "rc=$CALL_RC error=$CALL_ERROR form=$CALL_FORM msg=$CALL_MSG"

# ---------------------------------------------------------------- results
[ "${#rows[@]}" = 9 ] || die "${#rows[@]} rows, expected 9"
mkdir -p "$(dirname "$out")"
{ echo "# $banner"; printf '%s\n' "${rows[@]}"; echo "R|TOTAL|${#rows[@]}"; } >"$out"
printf '%s\n' "${rows[@]}"
echo "ok agent-stopped: ${#rows[@]} cases -> ${out#"$(dirname "$lab")"/}"
