# Helpers for the lab scripts. Source it; needs MSSQL_SA_PASSWORD in the environment.
# The password reaches sqlcmd as SQLCMDPASSWORD, never on a command line.

# sql [sqlcmd args...]: sqlcmd inside the repllab container, standard input passed
# through (feed a script with `sql < file.sql`). No -b: sqlcmd then exits 0 on an
# SQL error, which is why campaign.sh reads the output for Msg lines.
# sqlcmd cuts an nvarchar(max) or varchar(max) column at 256 characters (-W cannot
# be combined with -y 0). Cast the printed R| column to nvarchar(4000): campaign.sh
# rejects any R| line of exactly 256 characters as truncated.
sql() {
    podman exec -i -e SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" repllab \
        /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -W -s '|' "$@"
}

# sql_value QUERY: prints the single value QUERY returns, trimmed. Returns 1, with
# the server's message on stderr, when the query fails or does not return exactly
# one value, so that a caller checking a condition never mistakes an error for a value.
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
