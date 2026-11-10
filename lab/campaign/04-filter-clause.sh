#!/bin/bash
# Does a filter clause given to sp_addarticle, with no sp_articlefilter call,
# filter anything? (lab/README.md row 12; docs/analysis/step-1-analysis.md,
# section 9, item 7.) One case. Builds the publication m_fc (immediate_sync = 0,
# shared agent) with the article m_fc_t and a subscriber database m_fc_sub, measures,
# then removes everything, snapshot folder included. Run through lab/campaign.sh.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"

cleaned=0
cleanup() {
    [ "$cleaned" = 1 ] && return
    cleaned=1
    sql >/dev/null 2>&1 <<'SQL' || true
SET NOCOUNT ON;
USE Sales;
BEGIN TRY IF EXISTS (SELECT 1 FROM dbo.syspublications WHERE name = N'm_fc')
    EXEC sp_dropsubscription @publication = N'm_fc', @article = N'all', @subscriber = N'all'; END TRY BEGIN CATCH END CATCH;
BEGIN TRY IF EXISTS (SELECT 1 FROM dbo.syspublications WHERE name = N'm_fc')
    EXEC sp_droppublication @publication = N'm_fc'; END TRY BEGIN CATCH END CATCH;
DROP TABLE IF EXISTS dbo.m_fc_t;
IF DB_ID(N'm_fc_sub') IS NOT NULL
BEGIN
    ALTER DATABASE m_fc_sub SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE m_fc_sub;
END
SQL
    podman exec repllab find /var/opt/mssql/data/ReplData/unc -mindepth 1 -maxdepth 1 -iname '*_m_*' -exec rm -rf {} + >/dev/null 2>&1 || true
}
trap cleanup EXIT

cleanup; cleaned=0

sql <<'SQL'
SET NOCOUNT ON;
USE Sales;
CREATE TABLE dbo.m_fc_t (id int PRIMARY KEY, v int);
INSERT dbo.m_fc_t VALUES (1, 1), (2, -1);
CREATE DATABASE m_fc_sub;
GO
USE Sales;
DECLARE @srv sysname = @@SERVERNAME;
EXEC sp_addpublication @publication = N'm_fc', @status = N'active', @allow_push = N'true',
     @independent_agent = N'false', @immediate_sync = N'false', @repl_freq = N'continuous', @sync_method = N'native';
EXEC sp_addpublication_snapshot @publication = N'm_fc', @frequency_type = 1, @active_start_date = 99991231,
     @job_login = NULL, @job_password = NULL, @publisher_security_mode = 1;
EXEC sp_addarticle @publication = N'm_fc', @article = N'm_fc_t', @source_owner = N'dbo', @source_object = N'm_fc_t',
     @filter_clause = N'v > 0';
EXEC sp_addsubscription @publication = N'm_fc', @subscriber = @srv, @destination_db = N'm_fc_sub',
     @subscription_type = N'Push', @sync_type = N'automatic', @article = N'all';
EXEC sp_addpushsubscription_agent @publication = N'm_fc', @subscriber = @srv, @subscriber_db = N'm_fc_sub',
     @job_login = NULL, @job_password = NULL, @subscriber_security_mode = 1;
EXEC sp_startpublication_snapshot @publication = N'm_fc';
GO
SQL

wait_until 180 "SELECT CASE WHEN OBJECT_ID(N'm_fc_sub.dbo.m_fc_t') IS NOT NULL THEN 1 ELSE 0 END" \
    || { echo "snapshot not delivered" >&2; exit 1; }
snap_rows=$(sql_value "SELECT ISNULL(STRING_AGG(CONVERT(nvarchar(10), id), ',') WITHIN GROUP (ORDER BY id), 'none') FROM m_fc_sub.dbo.m_fc_t")

# One transaction at the publisher: a row that passes the clause and one that fails it.
sql -Q "SET NOCOUNT ON; INSERT Sales.dbo.m_fc_t VALUES (3, 1), (4, -1)" </dev/null
wait_until 180 "SELECT CASE WHEN EXISTS (SELECT 1 FROM m_fc_sub.dbo.m_fc_t WHERE id >= 3) THEN 1 ELSE 0 END" \
    || { echo "changes not delivered" >&2; exit 1; }
all_rows=$(sql_value "SELECT STRING_AGG(CONVERT(nvarchar(10), id), ',') WITHIN GROUP (ORDER BY id) FROM m_fc_sub.dbo.m_fc_t")

snap_res=filtered; [ "$snap_rows" = 1 ] || snap_res=not-filtered
chg_res=not-filtered; [ "$all_rows" = "1,3" ] && chg_res=filtered
cleanup
printf 'R|F1.filter-clause-only|snapshot=%s,changes=%s|rows at the subscriber after the snapshot: %s; after inserting v=1 and v=-1: %s (publisher snapshot had ids 1 with v=1 and 2 with v=-1)\n' \
    "$snap_res" "$chg_res" "$snap_rows" "$all_rows"
echo 'R|TOTAL|1'
