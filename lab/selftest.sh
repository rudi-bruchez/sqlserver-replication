#!/bin/bash
# Self-test of the campaign runner: runs campaign.sh on each fixture of
# lab/selftest/ and checks that it trips the guard the fixture is written for.
# Needs MSSQL_SA_PASSWORD in the environment and the lab running (lab/start.sh).
# Prints PASS or FAIL per fixture; exits non-zero if any line is FAIL.
set -uo pipefail
lab=$(cd "$(dirname "$0")" && pwd)

# Fixture and expected outcome: "ok" for exit 0, otherwise the guard name.
# restart.sh stays last: it restarts the instance.
fixtures=(
    "good.sql ok"
    "total-mismatch.sql total"
    "no-results.sql results"
    "uncaught.sql uncaught"
    "residue.sql residue"
    "residue-job.sh residue"
    "residue-schema.sql residue"
    "residue-file.sh residue"
    "residue-folder.sh residue"
    "wait-timeout.sh results"
    "sqlvalue-error.sh uncaught"
    "exit-status.sh exit"
    "truncated.sql truncated"
    "truncated-columns.sql truncated"
    "duplicate-ids.sql total"
    "restart.sh restart"
)

# Removes what a fixture left on purpose, so that the next one sees no residue.
# Prints nothing on success, the reason otherwise.
cleanup() {
    local query
    case $1 in
        residue.sql) query="DROP TABLE IF EXISTS Sales.dbo.m_left;
            SELECT COUNT(*) FROM Sales.sys.objects WHERE name = N'm_left';" ;;
        residue-job.sh) query="IF EXISTS (SELECT * FROM msdb.dbo.sysjobs WHERE name = N'REPLLAB-Sales-m_ghost-1')
                EXEC msdb.dbo.sp_delete_job @job_name = N'REPLLAB-Sales-m_ghost-1';
            SELECT COUNT(*) FROM msdb.dbo.sysjobs WHERE name = N'REPLLAB-Sales-m_ghost-1';" ;;
        residue-schema.sql) query="EXEC Sales.sys.sp_executesql N'DROP TYPE IF EXISTS dbo.m_t; DROP SCHEMA IF EXISTS m_s;';
            SELECT (SELECT COUNT(*) FROM Sales.sys.types WHERE name = N'm_t') + (SELECT COUNT(*) FROM Sales.sys.schemas WHERE name = N'm_s');" ;;
        residue-file.sh|residue-folder.sh)
            local path=/var/opt/mssql/data/ReplData/M_LEFT.bak
            [ "$1" = residue-folder.sh ] && path=/var/opt/mssql/data/ReplData/unc/REPLLAB_SALES_m_ghost
            podman exec repllab rm -rf "$path" || { echo "cleanup failed: rm $path"; return; }
            podman exec repllab test ! -e "$path" || echo "cleanup failed: $path still there"
            return ;;
        *) return 0 ;;
    esac
    if [ ! -f "$lab/lib.sh" ]; then echo "cleanup impossible: lib.sh missing"; return; fi
    local left
    left=$( . "$lab/lib.sh" && sql_value "$query" 2>&1 ) || { echo "cleanup failed: $left"; return; }
    [ "$left" = 0 ] || echo "cleanup failed: $left object(s) left"
}

failed=0
for entry in "${fixtures[@]}"; do
    read -r fixture expected <<<"$entry"
    out=$("$lab/campaign.sh" selftest "$lab/selftest/$fixture" 2>&1)
    status=$?
    guard=$(printf '%s\n' "$out" | sed -n 's/^GUARD \([a-z]*\) failed:.*/\1/p' | head -n 1)
    if [ "$expected" = ok ]; then
        if [ "$status" -eq 0 ] && [ -z "$guard" ]; then verdict=PASS
        else verdict="FAIL $fixture: expected exit 0, got exit $status${guard:+, GUARD $guard}"; fi
    else
        if [ "$status" -ne 0 ] && [ "$guard" = "$expected" ]; then verdict=PASS
        else verdict="FAIL $fixture: expected GUARD $expected, got exit $status${guard:+, GUARD $guard}"; fi
    fi
    if [ "$verdict" != PASS ]; then
        # The last lines of the runner's output say what happened.
        verdict="$verdict ($(printf '%s\n' "$out" | tail -n 2 | tr '\n' ' ' | cut -c1-300))"
    fi
    problem=$(cleanup "$fixture")
    if [ -n "$problem" ]; then
        [ "$verdict" = PASS ] && verdict="FAIL $fixture: $problem" || verdict="$verdict; $problem"
    fi
    if [ "$verdict" = PASS ]; then echo "PASS $fixture"; else echo "$verdict"; failed=1; fi
done

rm -rf "$lab/results/selftest"
exit "$failed"
