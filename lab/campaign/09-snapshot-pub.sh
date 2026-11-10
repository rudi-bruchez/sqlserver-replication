#!/bin/bash
# Flag matrix of sp_changepublication and sp_changearticle on snapshot publications
# (campaign item 7). Run through lab/campaign.sh.
#
# Three publications on the tables m_t1, m_t2 and m_t3 of Sales, each with one push
# subscription to its own database and its snapshot generated and delivered (snapshot
# agents with a schedule that never fires, started one at a time):
#   SNAP   m_snap   @repl_freq = N'snapshot', every other option the default. The
#                   defaults of a snapshot publication are immediate_sync = 0 and
#                   independent_agent = 0 (shared 'ALL' agent of m_sub), so
#                   immediate_sync_ready = 0. That is a property of the defaults, not
#                   of snapshot publications: SNAPI shows the other case.
#   SNAPI  m_snapi  snapshot with @immediate_sync and @independent_agent = true, ready = 1.
#   TWIN   m_tran   transactional (continuous), shared agent, ready = 0; articles with
#                   ins_cmd, upd_cmd and del_cmd = SQL (the snapshot publications' values);
#                   only the command rows are run on it.
# m_t3 (with the column c) is published with a row filter and without c in SNAP and SNAPI,
# before the subscription is added, so that "change filter clause", "drop row filter",
# "add column back" and the article `filter` property have something to act on.
# 09-snapshot-pub-matrix.sql is fed to sql on standard input: 53 cases on each snapshot
# publication (25 publication properties, 22 article properties, 6 filter or column
# operations) and 4 command cases on the twin, 53 + 53 + 4 = 110 rows, each case run with
# the four flag combinations inside a transaction rolled back in the same batch.
#
# Controls, asserted before the rows are printed; a failure exits 1.
#  - State, before the matrix: ready = 0 on m_snap and m_tran, ready = 1 on m_snapi,
#    immediate_sync / independent_agent as built, every subscription at status 2.
#  - No no-op: no stored value is asserted. Each ok cell of the matrix compares the
#    publication row, the article row and the column count before and after the call
#    inside the transaction; the detail says changed=<c>/<n> and the script requires c = n
#    on every row (a case on the stored value would show c < n).
#  - Rule of 05-snapshot-flag (docs/analysis/step-1-analysis.md section 5): a procedure
#    asks for @force_invalidate_snapshot only when immediate_sync_ready = 1, and for
#    @force_reinit_subscription only when the operated article's subscription has status 2.
#    Predicted: every SNAP and TWIN row reads ready=0 status=2, SNAPI rows ready=1
#    status=2; no SNAP cell is 20607; m_t2 schema_option is f00=20608,f10=20608,f01=ok,f11=ok
#    on m_snap (the shape of SalesRef A13 in 02-matrix) and f00=20607,f10=20608,f01=20607,f11=ok
#    on m_snapi (the shape of SalesPub A12).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/../lib.sh"

expected_rows=110

cleaned=0
cleanup() {
    [ "$cleaned" = 1 ] && return
    cleaned=1
    sql >&2 <<'SQL' || true
SET NOCOUNT ON;
USE Sales;
DECLARE @p sysname;
DECLARE c CURSOR LOCAL FOR SELECT name FROM dbo.syspublications WHERE name IN (N'm_snap', N'm_snapi', N'm_tran');
OPEN c; FETCH c INTO @p;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY EXEC sp_dropsubscription @publication = @p, @article = N'all', @subscriber = N'all'; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY EXEC sp_droppublication @publication = @p; END TRY BEGIN CATCH END CATCH;
    FETCH c INTO @p;
END;
CLOSE c; DEALLOCATE c;
DROP VIEW IF EXISTS dbo.m_v1, dbo.m_v3, dbo.m_v3i;
DROP PROCEDURE IF EXISTS dbo.m_f1, dbo.m_f3, dbo.m_f3i;
DROP TABLE IF EXISTS dbo.m_t1, dbo.m_t2, dbo.m_t3;
GO
DECLARE @d sysname, @s nvarchar(400);
DECLARE c CURSOR LOCAL FOR SELECT name FROM sys.databases WHERE name IN (N'm_sub', N'm_subi', N'm_subt');
OPEN c; FETCH c INTO @d;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @s = N'ALTER DATABASE ' + QUOTENAME(@d) + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE ' + QUOTENAME(@d) + N';';
    EXEC (@s);
    FETCH c INTO @d;
END;
CLOSE c; DEALLOCATE c;
SQL
    podman exec repllab find /var/opt/mssql/data/ReplData/unc -mindepth 1 -maxdepth 1 -iname '*_m_*' -exec rm -rf {} + >&2 || true
}
trap cleanup EXIT

# Leftovers of an earlier run are not absorbed: they fail this run, the trap removes them.
left=$(sql_value "SELECT (SELECT COUNT(*) FROM Sales.dbo.syspublications WHERE name LIKE N'm\_%' ESCAPE N'\') + (SELECT COUNT(*) FROM sys.databases WHERE name LIKE N'm\_%' ESCAPE N'\') + (SELECT COUNT(*) FROM Sales.sys.objects WHERE name LIKE N'm\_%' ESCAPE N'\')") \
    || exit 1
left_files=$(podman exec repllab find /var/opt/mssql/data/ReplData/unc -mindepth 1 -maxdepth 1 -iname '*_m_*')
if [ "$left" != 0 ] || [ -n "$left_files" ]; then
    echo "09-snapshot-pub: leftovers of an earlier run (objects=$left files=$left_files); removing them and failing" >&2
    exit 1
fi

mark0=$(sql_value "SELECT CONVERT(varchar(23), SYSDATETIME(), 121)")

# sp_addsubscription refuses to run in a transaction (15002): this batch opens none.
# The filter, the excluded column and the filter view of m_t3 are created before the
# subscription is added. The twin's articles are created with SQL commands.
sql <<'SQL'
SET NOCOUNT ON;
USE Sales;
CREATE TABLE dbo.m_t1 (id int PRIMARY KEY, a int, b int); INSERT dbo.m_t1 VALUES (1, 1, 1);
CREATE TABLE dbo.m_t2 (id int PRIMARY KEY, a int, b int); INSERT dbo.m_t2 VALUES (1, 1, 1);
CREATE TABLE dbo.m_t3 (id int PRIMARY KEY, a int, b int, c int); INSERT dbo.m_t3 VALUES (1, 1, 1, 1);
GO
CREATE VIEW dbo.m_v1 AS SELECT id, a, b FROM dbo.m_t1;
GO
CREATE DATABASE m_sub;
CREATE DATABASE m_subi;
CREATE DATABASE m_subt;
GO
USE Sales;
DECLARE @srv sysname = @@SERVERNAME, @n int = 1, @p sysname, @d sysname, @flt sysname, @vw sysname;
WHILE @n <= 3
BEGIN
    SELECT @p = CHOOSE(@n, N'm_snap', N'm_snapi', N'm_tran'), @d = CHOOSE(@n, N'm_sub', N'm_subi', N'm_subt'),
           @flt = CHOOSE(@n, N'm_f3', N'm_f3i', NULL), @vw = CHOOSE(@n, N'm_v3', N'm_v3i', NULL);
    IF @n = 1 EXEC sp_addpublication @publication = @p, @status = N'active', @allow_push = N'true', @repl_freq = N'snapshot';
    IF @n = 2 EXEC sp_addpublication @publication = @p, @status = N'active', @allow_push = N'true', @repl_freq = N'snapshot', @immediate_sync = N'true', @independent_agent = N'true';
    IF @n = 3 EXEC sp_addpublication @publication = @p, @status = N'active', @allow_push = N'true', @repl_freq = N'continuous';
    EXEC sp_addpublication_snapshot @publication = @p, @frequency_type = 1, @active_start_date = 99991231,
         @job_login = NULL, @job_password = NULL, @publisher_security_mode = 1;
    IF @n < 3
    BEGIN
        EXEC sp_addarticle @publication = @p, @article = N'm_t1', @source_owner = N'dbo', @source_object = N'm_t1';
        EXEC sp_addarticle @publication = @p, @article = N'm_t2', @source_owner = N'dbo', @source_object = N'm_t2';
        EXEC sp_addarticle @publication = @p, @article = N'm_t3', @source_owner = N'dbo', @source_object = N'm_t3';
        EXEC sp_articlefilter @publication = @p, @article = N'm_t3', @filter_name = @flt, @filter_clause = N'a > 0';
        EXEC sp_articlecolumn @publication = @p, @article = N'm_t3', @column = N'c', @operation = N'drop';
        EXEC sp_articleview @publication = @p, @article = N'm_t3', @view_name = @vw, @filter_clause = N'a > 0';
    END
    ELSE
    BEGIN
        EXEC sp_addarticle @publication = @p, @article = N'm_t1', @source_owner = N'dbo', @source_object = N'm_t1', @ins_cmd = N'SQL', @upd_cmd = N'SQL', @del_cmd = N'SQL';
        EXEC sp_addarticle @publication = @p, @article = N'm_t2', @source_owner = N'dbo', @source_object = N'm_t2', @ins_cmd = N'SQL', @upd_cmd = N'SQL', @del_cmd = N'SQL';
    END;
    EXEC sp_addsubscription @publication = @p, @subscriber = @srv, @destination_db = @d,
         @subscription_type = N'Push', @sync_type = N'automatic', @article = N'all';
    EXEC sp_addpushsubscription_agent @publication = @p, @subscriber = @srv, @subscriber_db = @d,
         @job_login = NULL, @job_password = NULL, @subscriber_security_mode = 1;
    SET @n += 1;
END;
GO
SQL

# One snapshot at a time (05: concurrent snapshot agents on shared tables failed once).
# Done = the snapshot agent reports completion after the mark and the distribution
# agent of the subscriber database delivered it.
snapshot_done() { # PUB DB
    wait_until 180 "SELECT CASE WHEN EXISTS (SELECT 1 FROM distribution.dbo.MSsnapshot_history h JOIN distribution.dbo.MSsnapshot_agents a ON a.id = h.agent_id WHERE a.publication = N'$1' AND h.time >= '$mark0' AND h.runstatus = 2)
        AND EXISTS (SELECT 1 FROM distribution.dbo.MSdistribution_history h JOIN distribution.dbo.MSdistribution_agents a ON a.id = h.agent_id WHERE a.subscriber_db = N'$2' AND a.subscriber_id >= 0 AND h.time >= '$mark0' AND h.comments LIKE N'Delivered snapshot%') THEN 1 ELSE 0 END"
}
for pd in m_snap:m_sub m_snapi:m_subi m_tran:m_subt; do
    p=${pd%%:*}; d=${pd##*:}
    sql -Q "SET NOCOUNT ON; EXEC Sales.dbo.sp_startpublication_snapshot @publication = N'$p'" </dev/null
    snapshot_done "$p" "$d" || { echo "$p: snapshot not delivered" >&2; exit 1; }
done

# State control, before the matrix: one value per publication, compared as a string.
state=$(sql_value "SELECT CONVERT(nvarchar(200), (SELECT STRING_AGG(CONVERT(nvarchar(10), p.immediate_sync) + N'/' + CONVERT(nvarchar(10), p.independent_agent) + N'/' + CONVERT(nvarchar(10), p.immediate_sync_ready) + N'/' + CONVERT(nvarchar(10), p.repl_freq), N' ') WITHIN GROUP (ORDER BY p.name)
        FROM Sales.dbo.syspublications p WHERE p.name IN (N'm_snap', N'm_snapi', N'm_tran')) + N' subs=' + (SELECT CONVERT(nvarchar(10), COUNT(*)) + N'/' + CONVERT(nvarchar(10), COUNT(DISTINCT s.status)) + N'/' + CONVERT(nvarchar(10), MIN(s.status))
        FROM Sales.dbo.syssubscriptions s JOIN Sales.dbo.sysarticles a ON a.artid = s.artid JOIN Sales.dbo.syspublications p ON p.pubid = a.pubid WHERE p.name IN (N'm_snap', N'm_snapi', N'm_tran') AND s.srvid >= 0))") || exit 1
# immediate_sync/independent_agent/ready/repl_freq, in name order m_snap m_snapi m_tran;
# subs = subscription rows, distinct statuses, the status (3 + 3 + 2 articles = 8 rows, all 2).
want="0/0/0/1 1/1/1/1 0/0/0/0 subs=8/1/2"
if [ "$state" != "$want" ]; then
    echo "09-snapshot-pub: control failed: state before the matrix is '$state', expected '$want'" >&2
    exit 1
fi

out=$(sql -h -1 < "$here/09-snapshot-pub-matrix.sql")
printf '%s\n' "$out" | grep -v '^R|' >&2 || true
rows=$(printf '%s\n' "$out" | grep '^R|' | grep -v '^R|TOTAL|' || true)
n=$(printf '%s\n' "$rows" | grep -c '^R|' || true)
sql_total=$(printf '%s\n' "$out" | sed -n 's/^R|TOTAL|//p')
if [ "$n" != "$expected_rows" ] || [ "$sql_total" != "$n" ]; then
    echo "09-snapshot-pub: $n rows (sql said '$sql_total'), expected $expected_rows" >&2
    exit 1
fi

bad=0
control() { echo "09-snapshot-pub: control failed: $*" >&2; bad=1; }
field() { # ID-REGEX LABEL-REGEX FIELD : field of the row whose id and label match
    printf '%s\n' "$rows" | awk -F'|' -v id="$1" -v lab="$2" -v n="$3" '$2 ~ id && $4 ~ lab { print $n }'
}
# every row read in the state the rule needs
for pfx_ready in SNAP:0 SNAPI:1 TWIN:0; do
    pfx=${pfx_ready%%:*}; ready=${pfx_ready##*:}
    notstate=$(printf '%s\n' "$rows" | awk -F'|' -v id="$pfx" -v want=" (ready=$ready status=2 changed=" '$2 ~ "^" id "[.]" && index($4, want) == 0 { print }')
    [ -z "$notstate" ] || { control "$pfx rows not read at ready=$ready status=2:"; printf '%s\n' "$notstate" >&2; }
done
# no row where an ok cell left the row unchanged, except the article `filter` rows: the only
# filter procedure that can be named is the article's own (a procedure parented to another
# article's filter fails with an engine assertion, Msg 3624 in sp_MSsetfilterparent, and a
# plain procedure is refused with 14049), so that row, like 02's A22, sets the stored value.
nochange=$(printf '%s\n' "$rows" | /usr/bin/grep -v ' article filter = ' | sed -n 's/.*changed=\([0-9]*\)\/\([0-9]*\))$/\1 \2 &/p' | awk '$1 != $2 { $1 = ""; $2 = ""; print }')
[ -z "$nochange" ] || { control "rows with an ok cell that changed nothing (a no-op case):"; printf '%s\n' "$nochange" >&2; }
# ready = 0 on m_snap: no operation asks for @force_invalidate_snapshot
asked=$(printf '%s\n' "$rows" | grep '^R|SNAP\.' | grep -c '=20607' || true)
[ "$asked" = 0 ] || { control "$asked SNAP rows ask for @force_invalidate_snapshot (20607) although ready=0"; }
# reinit needed, invalidation not (SalesRef A13) on m_snap; both needed (SalesPub A12) on m_snapi
cells=$(field '^SNAP[.]' '^m_snap[.]m_t2 article schema_option ' 3)
[ "$cells" = "f00=20608,f10=20608,f01=ok,f11=ok" ] \
    || control "m_snap m_t2 schema_option is '$cells', predicted f00=20608,f10=20608,f01=ok,f11=ok"
cells=$(field '^SNAPI[.]' '^m_snapi[.]m_t2 article schema_option ' 3)
[ "$cells" = "f00=20607,f10=20608,f01=20607,f11=ok" ] \
    || control "m_snapi m_t2 schema_option is '$cells', predicted f00=20607,f10=20608,f01=20607,f11=ok"
[ "$bad" = 0 ] || exit 1
cleanup
printf '%s\n' "$rows"
echo "R|TOTAL|$n"
