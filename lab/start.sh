#!/bin/bash
# Recreate the lab container and run setup.sql. Needs MSSQL_SA_PASSWORD in the environment.
set -euo pipefail
cd "$(dirname "$0")"
podman rm -f repllab >/dev/null 2>&1 || true
podman run -d --name repllab --hostname repllab -p 127.0.0.1:11980:1433 \
  -e ACCEPT_EULA=Y -e MSSQL_PID=Developer -e MSSQL_AGENT_ENABLED=true -e MSSQL_MEMORY_LIMIT_MB=4096 \
  -e MSSQL_SA_PASSWORD="$MSSQL_SA_PASSWORD" mcr.microsoft.com/mssql/server:2022-latest >/dev/null
sql() { podman exec -i -e SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" repllab /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -l 5 -b "$@"; }
until sql -Q "SELECT 1" >/dev/null 2>&1; do sleep 2; done
podman exec -u 0 repllab bash -c 'mkdir -p /var/opt/mssql/data/ReplData && chown mssql /var/opt/mssql/data/ReplData'
sql < setup.sql | grep -E '^(Msg|Job)' -A1 || true
