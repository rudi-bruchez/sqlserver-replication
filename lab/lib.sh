# Helpers for the lab scripts. Source it; needs MSSQL_SA_PASSWORD in the environment.
# The password reaches sqlcmd as SQLCMDPASSWORD, never on a command line.
# Exported so that `podman exec -e SQLCMDPASSWORD` and `podman run -e MSSQL_SA_PASSWORD`
# pass it by name: a value on the podman command line is visible to ps.
export MSSQL_SA_PASSWORD

# sql [sqlcmd args...]: sqlcmd inside the repllab container, standard input passed
# through (feed a script with `sql < file.sql`). No -b: sqlcmd then exits 0 on an
# SQL error, which is why campaign.sh reads the output for Msg lines.
# sqlcmd cuts an nvarchar(max) or varchar(max) column at 256 characters (-W cannot
# be combined with -y 0); campaign.sh rejects any R| line or |-separated field of
# exactly 256 characters as truncated.
# Authoring notes for campaign scripts:
# - cast every printed column to nvarchar(4000), never leave it nvarchar(max);
# - sql_value prints the server's Msg lines on stderr, which campaign.sh reads as an
#   uncaught error: a call expected to fail must be wrapped (TRY...CATCH in the query,
#   or its stderr discarded with 2>/dev/null and the failure handled in the script);
# - sql_value returns 1 for a value of exactly 256 characters: sqlcmd cuts an
#   nvarchar(max) there, and a cut value placed inside a longer R| field would escape
#   campaign.sh's truncated check. Cast the query's column to nvarchar(4000), and
#   use a .sh under set -e so that the failure ends the script and trips the exit guard.
sql() {
    SQLCMDPASSWORD=$MSSQL_SA_PASSWORD podman exec -i -e SQLCMDPASSWORD repllab \
        /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -W -s '|' "$@"
}

# sql_value QUERY: prints the single value QUERY returns, trimmed. Returns 1, with
# the server's message on stderr, when the query fails or does not return exactly
# one value (or one cut at 256 characters), so that a caller checking a condition never mistakes an error for a value.
sql_value() {
    local out
    if ! out=$(sql -b -h -1 -Q "SET NOCOUNT ON; $1" </dev/null 2>&1); then
        # The server's lines keep their line start, so that campaign.sh sees a
        # "Msg n, Level m" line in the log of a script that called sql_value.
        printf 'sql_value: query failed:\n%s\n' "$out" >&2
        return 1
    fi
    out=$(printf '%s\n' "$out" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$')
    if [ -z "$out" ] || [ "$(printf '%s\n' "$out" | wc -l)" -ne 1 ]; then
        printf 'sql_value: expected one value, got: %s\n' "$out" >&2
        return 1
    fi
    if [ "${#out}" -eq 256 ]; then
        printf 'sql_value: value of exactly 256 characters, cut by sqlcmd (cast the column to nvarchar(4000)): %s...\n' "${out:0:40}" >&2
        return 1
    fi
    printf '%s\n' "$out"
}

# wait_until TIMEOUT_SECONDS QUERY: polls every 5 s until QUERY returns 1. A query
# that fails counts as not yet. At timeout, says so on stderr and returns 1.
wait_until() {
    local timeout=$1 query=$2 start=$SECONDS
    while :; do
        [ "$(sql_value "$query" 2>/dev/null)" = 1 ] && return 0
        if (( SECONDS - start >= timeout )); then
            printf 'wait_until: timeout after %s s: %s\n' "$timeout" "$query" >&2
            return 1
        fi
        sleep 5
    done
}

# stop_m_agents: stops the running agent jobs of m_ objects (distribution agents of m_
# subscriber databases, pull agents running in an m_ database, log readers of m_
# databases, snapshot agents of m_ publications) and waits until they have stopped. An
# agent dropped while it runs logs "The process was successfully stopped" after its agent
# row is gone, leaving an orphan history row (seen once in fix round 1 of Task 10).
stop_m_agents() {
    local jobs="SELECT CONVERT(uniqueidentifier, job_id) AS job_id FROM distribution.dbo.MSdistribution_agents WHERE local_job = 1 AND subscriber_db LIKE N'm\_%' ESCAPE N'\'
 UNION SELECT CONVERT(uniqueidentifier, job_id) FROM distribution.dbo.MSlogreader_agents WHERE publisher_db LIKE N'm\_%' ESCAPE N'\'
 UNION SELECT CONVERT(uniqueidentifier, job_id) FROM distribution.dbo.MSsnapshot_agents WHERE local_job = 1 AND publication LIKE N'm\_%' ESCAPE N'\'
 UNION SELECT job_id FROM msdb.dbo.sysjobsteps WHERE subsystem = N'Distribution' AND database_name LIKE N'm\_%' ESCAPE N'\'"
    local running="SELECT ja.job_id FROM msdb.dbo.sysjobactivity ja WHERE ja.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions) AND ja.start_execution_date IS NOT NULL AND ja.stop_execution_date IS NULL AND ja.job_id IN ($jobs)"
    # A job asked to stop while it is starting can keep running (seen in 12-contexts):
    # the stop is repeated until none runs, for up to 90 s.
    local i left
    for i in $(seq 1 18); do
        left=$(sql -b -h -1 -Q "SET NOCOUNT ON; DECLARE @j uniqueidentifier, @n int = 0;
DECLARE c CURSOR LOCAL FOR $running;
OPEN c; FETCH NEXT FROM c INTO @j;
WHILE @@FETCH_STATUS = 0 BEGIN SET @n += 1; BEGIN TRY EXEC msdb.dbo.sp_stop_job @job_id = @j; END TRY BEGIN CATCH END CATCH; FETCH NEXT FROM c INTO @j; END;
CLOSE c; DEALLOCATE c;
SELECT @n;" </dev/null 2>&1) || { echo "${0##*/}: stop_m_agents: cannot stop the m_ agent jobs: $left" >&2; exit 1; }
        left=$(printf '%s\n' "$left" | sed 's/[[:space:]]//g' | grep -v '^$' | tail -n 1)
        [ "$left" = 0 ] && return 0
        sleep 5
    done
    { echo "${0##*/}: stop_m_agents: m_ agent jobs still running after 90 s: $(sql_value "SELECT ISNULL(STRING_AGG(CONVERT(nvarchar(4000), j.name), N', '), N'none') FROM msdb.dbo.sysjobs j WHERE j.job_id IN ($running)" 2>&1)" >&2; exit 1; }
}

# purge_stopped_orphans MARK [PATTERN...]: deletes the history rows that an agent wrote after
# its own agent row was gone because a measured case dropped a subscription or publication
# while the agent ran (comment 'The process was successfully stopped...'), written at or
# after MARK (a SYSDATETIME() style 121 value taken at the start of the script). It exists
# for the scripts whose measured drops hit a running agent on purpose: the stop has to
# stay in the measurement, so the expected orphan row is removed afterwards. It deletes
# only rows that meet all three conditions (time, no agent row, comment), so any other
# orphan still trips the residue guard. Each PATTERN is one more comment accepted, a raw
# LIKE string (single quotes are doubled here), for a script whose own measured outcome
# is such a row (08-pull). Prints the number of deleted rows on stderr.
purge_stopped_orphans() {
    local mark=$1 out n pat cond="comments LIKE N'The process was successfully stopped%'"
    shift
    for pat in "$@"; do cond+=" OR comments LIKE N'${pat//\'/\'\'}'"; done
    cond="($cond)"
    out=$(sql -b -h -1 -Q "SET NOCOUNT ON; DECLARE @m datetime2 = '$mark', @n int = 0;
DELETE distribution.dbo.MSdistribution_history WHERE [time] >= @m AND agent_id NOT IN (SELECT id FROM distribution.dbo.MSdistribution_agents) AND $cond; SET @n += @@ROWCOUNT;
DELETE distribution.dbo.MSlogreader_history WHERE [time] >= @m AND agent_id NOT IN (SELECT id FROM distribution.dbo.MSlogreader_agents) AND $cond; SET @n += @@ROWCOUNT;
DELETE distribution.dbo.MSsnapshot_history WHERE [time] >= @m AND agent_id NOT IN (SELECT id FROM distribution.dbo.MSsnapshot_agents) AND $cond; SET @n += @@ROWCOUNT;
SELECT @n;" </dev/null 2>&1) || { echo "${0##*/}: purge_stopped_orphans: $out" >&2; exit 1; }
    n=$(printf '%s\n' "$out" | sed 's/[[:space:]]//g' | grep -v '^$' | tail -n 1)
    [[ $n =~ ^[0-9]+$ ]] || { echo "${0##*/}: purge_stopped_orphans: unexpected output: $out" >&2; exit 1; }
    # PURGE_LOG, when set, receives the same note (campaign.sh deletes its own logs).
    echo "${0##*/}: purge_stopped_orphans: deleted $n orphan history row(s) (stop message of a dropped running agent)" | tee -a "${PURGE_LOG:-/dev/null}" >&2
}
