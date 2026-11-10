#!/bin/bash
# Self-test fixture: restarts the instance during the run. Expected: GUARD restart.
# It brings the lab back up itself, so the next script finds it running.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"
sql -Q "SHUTDOWN WITH NOWAIT" >/dev/null 2>&1 || true
# The container stops with the instance; wait for that before starting it again.
for _ in $(seq 1 60); do
    [ "$(podman inspect -f '{{.State.Running}}' repllab)" = false ] && break
    sleep 1
done
podman start repllab >/dev/null
wait_until 120 "SELECT 1"
# Wait for recovery too, so that only the restart guard can see what happened.
# sys.databases says ONLINE before the databases are started (Msg 904 on first use):
# query each one, a failure counts as not yet.
wait_until 120 "SELECT CASE WHEN (SELECT COUNT(*) FROM tempdb.sys.objects) > 0
  AND (SELECT COUNT(*) FROM Sales.sys.objects) > 0 AND (SELECT COUNT(*) FROM SalesSub.sys.objects) > 0
  AND (SELECT COUNT(*) FROM distribution.sys.objects) > 0 AND (SELECT COUNT(*) FROM msdb.sys.objects) > 0
  THEN 1 ELSE 0 END"
echo 'R|a|ok|'
echo 'R|TOTAL|1'
