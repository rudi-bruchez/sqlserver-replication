#!/bin/bash
# Which snapshot an added article triggers, with and without immediate_sync
# (docs/analysis/step-1-analysis.md, section 9, item 2). Run after setup.sql.
# Changes the lab: adds NewA to SalesPub and NewB to SalesRef.
set -euo pipefail
sql() { podman exec -i -e SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" repllab /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -l 30 -W -s '|' "$@" | { grep -v '^$\|^DBCC\|^WARNING\|^Changed' || true; }; }

# Wait until the distribution agent of SalesSub has bulk copied a table.
wait_copy() {
    for _ in $(seq 1 60); do
        n=$(sql -h -1 -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM distribution.dbo.MSdistribution_history WHERE comments LIKE N'Bulk copied data into table ''$1''%'" | tr -d ' ')
        [ "$n" -gt 0 ] && return 0
        sleep 5
    done
    echo "timeout waiting for $1" >&2; return 1
}

sql <<'EOF'
SET NOCOUNT ON;
USE Sales;
DROP TABLE IF EXISTS dbo.NewA, dbo.NewB;
CREATE TABLE dbo.NewA (id int PRIMARY KEY, v int); INSERT dbo.NewA VALUES (1, 1);
CREATE TABLE dbo.NewB (id int PRIMARY KEY, v int); INSERT dbo.NewB VALUES (1, 1);
GO
-- Flags needed by sp_addarticle.
BEGIN TRY
    EXEC sp_addarticle @publication = N'SalesPub', @article = N'NewA', @source_owner = N'dbo', @source_object = N'NewA', @force_invalidate_snapshot = 0;
    SELECT 'SalesPub add article, flag 0' AS measure, 'ok' AS result;
END TRY BEGIN CATCH
    SELECT 'SalesPub add article, flag 0' AS measure, ERROR_NUMBER() AS result;
    -- A refused sp_addarticle leaves its transaction open (@@TRANCOUNT = 1).
    IF @@TRANCOUNT > 0 ROLLBACK;
    EXEC sp_addarticle @publication = N'SalesPub', @article = N'NewA', @source_owner = N'dbo', @source_object = N'NewA', @force_invalidate_snapshot = 1;
END CATCH;
BEGIN TRY
    EXEC sp_addarticle @publication = N'SalesRef', @article = N'NewB', @source_owner = N'dbo', @source_object = N'NewB', @force_invalidate_snapshot = 0;
    SELECT 'SalesRef add article, flag 0' AS measure, 'ok' AS result;
END TRY BEGIN CATCH
    SELECT 'SalesRef add article, flag 0' AS measure, ERROR_NUMBER() AS result;
    IF @@TRANCOUNT > 0 ROLLBACK;
    EXEC sp_addarticle @publication = N'SalesRef', @article = N'NewB', @source_owner = N'dbo', @source_object = N'NewB', @force_invalidate_snapshot = 1;
END CATCH;
GO
-- Is the existing subscription subscribed to the new article?
SELECT a.name AS article, COUNT(s.artid) AS subscriptions
FROM sysextendedarticlesview AS a LEFT JOIN syssubscriptions AS s ON s.artid = a.artid AND s.srvid >= 0
WHERE a.name IN (N'NewA', N'NewB') GROUP BY a.name;
GO
EOF

# SalesRef (immediate_sync = 0): add the article to the subscription, as Learn says.
sql -Q "SET NOCOUNT ON; USE Sales; DECLARE @srv sysname = @@SERVERNAME;
EXEC sp_addsubscription @publication = N'SalesRef', @subscriber = @srv, @destination_db = N'SalesSub', @article = N'NewB';
SELECT 'NewB subscriptions after sp_addsubscription' AS measure, COUNT(*) AS n FROM syssubscriptions s JOIN sysarticles a ON a.artid = s.artid WHERE a.name = N'NewB' AND s.srvid >= 0;"

mark=$(sql -h -1 -Q "SET NOCOUNT ON; SELECT CONVERT(varchar(23), SYSDATETIME(), 121)")
sql -Q "EXEC Sales.dbo.sp_startpublication_snapshot @publication = N'SalesPub'; EXEC Sales.dbo.sp_startpublication_snapshot @publication = N'SalesRef';"
wait_copy NewA
wait_copy NewB
sleep 10

echo "--- tables bulk copied since the snapshots started"
sql -Q "SET NOCOUNT ON; SELECT a.publication, h.comments FROM distribution.dbo.MSdistribution_history AS h
JOIN distribution.dbo.MSdistribution_agents AS a ON a.id = h.agent_id
WHERE h.time >= '$mark' AND h.comments LIKE N'Bulk copied data into table%' ORDER BY a.publication, h.comments;"
echo "--- snapshot generated, per publication"
sql -Q "SET NOCOUNT ON; SELECT a.publication, h.comments FROM distribution.dbo.MSsnapshot_history AS h
JOIN distribution.dbo.MSsnapshot_agents AS a ON a.id = h.agent_id
WHERE h.time >= '$mark' AND h.runstatus = 2 ORDER BY a.publication;"
