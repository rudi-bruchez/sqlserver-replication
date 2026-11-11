#!/bin/bash
# Self-test fixture: writes two orphan history rows after the mark, one with the stop
# message of a dropped running agent and one with another comment, then calls
# purge_stopped_orphans. The first row must go, the second must survive and trip the
# guard. Expected: GUARD residue (orphan_agent_history=1). selftest.sh deletes the
# surviving row right after.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"
mark=$(sql_value "SELECT CONVERT(nvarchar(30), SYSDATETIME(), 121)")
sql -b -Q "SET NOCOUNT ON; INSERT distribution.dbo.MSdistribution_history (agent_id, runstatus, start_time, [time], duration, comments, current_delivery_rate, current_delivery_latency, delivered_transactions, delivered_commands, average_commands, delivery_rate, delivery_latency, total_delivered_commands, error_id, updateable_row)
SELECT v.id, 2, SYSDATETIME(), SYSDATETIME(), 0, v.c, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 FROM (VALUES (99998, N'The process was successfully stopped.'), (99999, N'Some other orphan row.')) v(id, c)" </dev/null
purge_stopped_orphans "$mark"
left=$(sql_value "SELECT ISNULL(STRING_AGG(CONVERT(nvarchar(10), agent_id), N','), N'none') FROM distribution.dbo.MSdistribution_history WHERE agent_id IN (99998, 99999)")
[ "$left" = 99999 ] || { echo "orphan-other: expected only 99999 left, got $left" >&2; exit 1; }
echo 'R|a|ok|'
echo 'R|TOTAL|1'
