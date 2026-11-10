#!/bin/bash
# Does a filter clause given to sp_addarticle, with no sp_articlefilter call,
# filter anything? (docs/analysis/step-1-analysis.md, section 9, item 7).
# Run after setup.sql. Adds NewC to SalesRef.
set -euo pipefail
sql() { podman exec -i -e SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" repllab /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -l 30 -W -s '|' "$@" | { grep -v '^$\|^DBCC\|^WARNING\|^Changed' || true; }; }

sql <<'EOF'
SET NOCOUNT ON;
USE Sales;
DROP TABLE IF EXISTS dbo.NewC;
CREATE TABLE dbo.NewC (id int PRIMARY KEY, v int);
INSERT dbo.NewC VALUES (1, 1), (2, -1);
GO
EXEC sp_addarticle @publication = N'SalesRef', @article = N'NewC', @source_owner = N'dbo', @source_object = N'NewC',
     @filter_clause = N'v > 0';
DECLARE @srv sysname = @@SERVERNAME;
EXEC sp_addsubscription @publication = N'SalesRef', @subscriber = @srv, @destination_db = N'SalesSub', @article = N'NewC';
EXEC sp_startpublication_snapshot @publication = N'SalesRef';
GO
EOF
for _ in $(seq 1 60); do
    [ "$(sql -h -1 -Q "SET NOCOUNT ON; SELECT CASE WHEN OBJECT_ID(N'SalesSub.dbo.NewC') IS NULL THEN 0 ELSE 1 END" | tr -d ' ')" = 1 ] && break
    sleep 5
done
sleep 10
echo "--- after the snapshot: rows at the subscriber (publisher has v = 1 and v = -1)"
sql -Q "SET NOCOUNT ON; SELECT id, v FROM SalesSub.dbo.NewC ORDER BY id"
sql -Q "SET NOCOUNT ON; INSERT Sales.dbo.NewC VALUES (3, 1), (4, -1)"
for _ in $(seq 1 24); do
    [ "$(sql -h -1 -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM SalesSub.dbo.NewC WHERE id >= 3" | tr -d ' ')" -gt 0 ] && break
    sleep 5
done
sleep 10
echo "--- after inserting v = 1 and v = -1 at the publisher: rows at the subscriber"
sql -Q "SET NOCOUNT ON; SELECT id, v FROM SalesSub.dbo.NewC ORDER BY id"
