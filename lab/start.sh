#!/bin/bash
# Recreate the lab container and run setup.sql, then wait for the first snapshots.
# Usage: lab/start.sh [2019|2022|2025] (default 2022). Needs MSSQL_SA_PASSWORD.
set -euo pipefail
cd "$(dirname "$0")"
version=${1:-2022}
case $version in
    2019|2022|2025) ;;
    *) echo "usage: $0 [2019|2022|2025]" >&2; exit 2 ;;
esac
. ./lib.sh
podman rm -f repllab >/dev/null 2>&1 || true
podman run -d --name repllab --hostname repllab -p 127.0.0.1:11980:1433 \
  -e ACCEPT_EULA=Y -e MSSQL_PID=Developer -e MSSQL_AGENT_ENABLED=true -e MSSQL_MEMORY_LIMIT_MB=4096 \
  -e MSSQL_SA_PASSWORD "mcr.microsoft.com/mssql/server:$version-latest" >/dev/null
until sql -l 5 -b -Q "SELECT 1" >/dev/null 2>&1; do sleep 2; done
podman exec -u 0 repllab bash -c 'mkdir -p /var/opt/mssql/data/ReplData && chown mssql /var/opt/mssql/data/ReplData'
sql -l 5 -b < setup.sql | grep -E '^(Msg|Job)' -A1 || true
# setup.sql starts the snapshot agents. Campaign scripts measure from the state they
# reach: SalesPub's immediate_sync snapshot ready and every SalesSub distribution
# agent past "Delivered snapshot". syssubscriptions.status = 2 alone is not enough:
# it was already 2 while SalesRef's shared agent had failed on vCustomerFR and was
# waiting for its job-step retry, a minute before it delivered.
wait_until 300 "SELECT CASE WHEN
      (SELECT immediate_sync_ready FROM Sales.dbo.syspublications WHERE name = N'SalesPub') = 1
  AND EXISTS (SELECT * FROM Sales.dbo.syssubscriptions WHERE dest_db = N'SalesSub' AND srvid >= 0)
  AND NOT EXISTS (SELECT * FROM Sales.dbo.syssubscriptions WHERE dest_db = N'SalesSub' AND srvid >= 0 AND status <> 2)
  AND EXISTS (SELECT * FROM distribution.dbo.MSdistribution_agents
              WHERE subscriber_db = N'SalesSub' AND subscriber_id >= 0)
  AND NOT EXISTS (SELECT * FROM distribution.dbo.MSdistribution_agents a
                  WHERE a.subscriber_db = N'SalesSub' AND a.subscriber_id >= 0
                    AND NOT EXISTS (SELECT * FROM distribution.dbo.MSdistribution_history h
                                    WHERE h.agent_id = a.id AND h.comments LIKE N'Delivered snapshot%'))
  THEN 1 ELSE 0 END"
echo "lab ready: SQL Server $version"
