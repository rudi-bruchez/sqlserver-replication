-- Impact matrix of sp_changepublication and sp_changearticle on a snapshot publication
-- (campaign item 7). Fed to sqlcmd on standard input by 09-snapshot-pub.sh, which has
-- built m_snap (@repl_freq = N'snapshot', articles m_t1 and m_t2, one push subscription,
-- snapshot delivered). Same cell format as 02-matrix.sql: each case runs inside a
-- transaction that is rolled back, with (@force_invalidate_snapshot,
-- @force_reinit_subscription) = (0,0), (1,0), (0,1), (1,1); a cell is "ok" or the error
-- number (20607 needs @force_invalidate_snapshot, 20608 needs @force_reinit_subscription).
-- One row per case:
--   R|SNAP.<group><nn>|f00=..,f10=..,f01=..,f11=..|<label>[; error text] (ready=<immediate_sync_ready>
--     status=<subscription status>)
-- ready and status are read just before each call; status is the operated article's
-- subscription status for the A and F cases on one article, and the distinct statuses
-- of the publication's subscriptions for the P cases. A value that differs between the
-- four cells is shown as a/b.
-- Values are different from the ones stored on m_snap (read by the script before it
-- runs this file), so that no case is a no-op.
SET NOCOUNT ON;
USE Sales;
GO
DECLARE @cases TABLE (id int IDENTITY, grp char(1), label nvarchar(200), stmt nvarchar(max), art sysname NULL);
DECLARE @cp nvarchar(max) = N'EXEC sp_changepublication @publication = N''m_snap'', @property = N''{prop}'', @value = N''{val}'', @force_invalidate_snapshot = @i, @force_reinit_subscription = @r';
DECLARE @ca nvarchar(max) = N'EXEC sp_changearticle @publication = N''m_snap'', @article = N''{art}'', @property = N''{prop}'', @value = N''{val}'', @force_invalidate_snapshot = @i, @force_reinit_subscription = @r';

DECLARE @pubprops TABLE (prop sysname, val nvarchar(400));
INSERT @pubprops VALUES
 (N'description', N'changed'),
 (N'retention', N'100'),
 (N'replicate_ddl', N'0'),
 (N'allow_pull', N'true'),
 (N'allow_push', N'false'),
 (N'allow_initialize_from_backup', N'true'),
 (N'allow_subscription_copy', N'true'),
 (N'allow_partition_switch', N'true'),
 (N'replicate_partition_switch', N'true'),
 (N'allow_drop', N'true'),
 (N'status', N'inactive'),
 (N'sync_method', N'concurrent'),
 (N'immediate_sync', N'true'),
 (N'independent_agent', N'true'),
 (N'allow_anonymous', N'true'),
 (N'alt_snapshot_folder', N'/var/opt/mssql/data/ReplAlt'),
 (N'snapshot_in_defaultfolder', N'false'),
 (N'compress_snapshot', N'true'),
 (N'pre_snapshot_script', N'/var/opt/mssql/data/pre.sql'),
 (N'post_snapshot_script', N'/var/opt/mssql/data/post.sql'),
 (N'enabled_for_internet', N'true'),
 (N'enabled_for_het_sub', N'true'),
 (N'ftp_address', N'ftp.example.com');
INSERT @cases (grp, label, stmt, art)
SELECT 'P', N'm_snap publication ' + prop + N' = ' + val,
       REPLACE(REPLACE(@cp, N'{prop}', prop), N'{val}', val), NULL
FROM @pubprops;

-- Article properties. m_t1 plays Orders (custom commands, filters), m_t2 Product.
DECLARE @artprops TABLE (art sysname, prop sysname, val nvarchar(400));
INSERT @artprops VALUES
 (N'm_t1', N'description', N'changed'), (N'm_t2', N'description', N'changed'),
 (N'm_t1', N'dest_table', N'm_t1b'), (N'm_t2', N'dest_table', N'm_t2b'),
 (N'm_t1', N'destination_owner', N'other'),
 (N'm_t1', N'ins_cmd', N'CALL sp_MSins_dbom_t1'), (N'm_t2', N'ins_cmd', N'CALL sp_MSins_dbom_t2'),
 (N'm_t1', N'upd_cmd', N'MCALL sp_MSupd_dbom_t1'),
 (N'm_t1', N'del_cmd', N'NONE'),
 (N'm_t1', N'pre_creation_cmd', N'delete'), (N'm_t2', N'pre_creation_cmd', N'none'),
 (N'm_t1', N'schema_option', N'0x000000000803509F'), (N'm_t2', N'schema_option', N'0x0000000000030077'),
 (N'm_t1', N'status', N'no column names'), (N'm_t2', N'status', N'no column names'),
 (N'm_t1', N'status', N'string literals'),
 (N'm_t1', N'status', N'owner qualified'),
 (N'm_t1', N'creation_script', N'/var/opt/mssql/data/create.sql'),
 (N'm_t1', N'fire_triggers_on_snapshot', N'true'),
 (N'm_t1', N'sync_object', N'm_v1'),
 (N'm_t1', N'type', N'logbased manualfilter');
INSERT @cases (grp, label, stmt, art)
SELECT 'A', N'm_snap.' + art + N' article ' + prop + N' = ' + val,
       REPLACE(REPLACE(REPLACE(@ca, N'{art}', art), N'{prop}', prop), N'{val}', val), art
FROM @artprops;

-- Filters and columns on subscribed articles.
INSERT @cases (grp, label, stmt, art) VALUES
 ('F', N'm_snap.m_t1 add row filter (sp_articlefilter)',
  N'EXEC sp_articlefilter @publication = N''m_snap'', @article = N''m_t1'', @filter_name = N''m_f1'', @filter_clause = N''a > 0'', @force_invalidate_snapshot = @i, @force_reinit_subscription = @r', N'm_t1'),
 ('F', N'm_snap.m_t1 drop column (sp_articlecolumn)',
  N'EXEC sp_articlecolumn @publication = N''m_snap'', @article = N''m_t1'', @column = N''b'', @operation = N''drop'', @force_invalidate_snapshot = @i, @force_reinit_subscription = @r', N'm_t1'),
 ('F', N'm_snap.m_t2 drop column (sp_articlecolumn)',
  N'EXEC sp_articlecolumn @publication = N''m_snap'', @article = N''m_t2'', @column = N''b'', @operation = N''drop'', @force_invalidate_snapshot = @i, @force_reinit_subscription = @r', N'm_t2');

DECLARE @flags TABLE (k int, i bit, r bit);
INSERT @flags VALUES (0, 0, 0), (1, 1, 0), (2, 0, 1), (3, 1, 1);
DECLARE @res TABLE (id int, k int, cell varchar(10), msg nvarchar(400), ready nvarchar(10), st nvarchar(100));

DECLARE @id int, @stmt nvarchar(max), @art sysname, @k int, @i bit, @r bit, @ready nvarchar(10), @st nvarchar(100);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT c.id, c.stmt, c.art, f.k, f.i, f.r FROM @cases AS c CROSS JOIN @flags AS f ORDER BY c.id, f.k;
OPEN c;
FETCH c INTO @id, @stmt, @art, @k, @i, @r;
WHILE @@FETCH_STATUS = 0
BEGIN
    -- State read just before the call.
    SET @ready = ISNULL((SELECT CONVERT(nvarchar(10), immediate_sync_ready) FROM dbo.syspublications WHERE name = N'm_snap'), N'none');
    SET @st = ISNULL((SELECT STRING_AGG(CONVERT(nvarchar(10), x.st), N'/') WITHIN GROUP (ORDER BY x.st)
                      FROM (SELECT DISTINCT s.status AS st FROM dbo.syssubscriptions s JOIN dbo.sysarticles a ON a.artid = s.artid
                            JOIN dbo.syspublications p ON p.pubid = a.pubid
                            WHERE p.name = N'm_snap' AND s.srvid >= 0 AND (@art IS NULL OR a.name = @art)) x), N'none');
    BEGIN TRY
        BEGIN TRAN;
        EXEC sp_executesql @stmt, N'@i bit, @r bit', @i = @i, @r = @r;
        ROLLBACK;
        INSERT @res VALUES (@id, @k, 'ok', NULL, @ready, @st);
    END TRY
    BEGIN CATCH
        DECLARE @e int = ERROR_NUMBER(), @m nvarchar(400) = LEFT(ERROR_MESSAGE(), 400);
        IF @@TRANCOUNT > 0 ROLLBACK;
        INSERT @res VALUES (@id, @k, CONVERT(varchar(10), @e), CASE WHEN @e IN (20607, 20608) THEN NULL ELSE @m END, @ready, @st);
    END CATCH;
    IF @@TRANCOUNT > 0 ROLLBACK;
    FETCH c INTO @id, @stmt, @art, @k, @i, @r;
END;
CLOSE c; DEALLOCATE c;

DECLARE @out TABLE (rn int IDENTITY, line nvarchar(4000));
INSERT @out (line)
SELECT CAST(N'R|SNAP.' + c.grp + RIGHT(N'00' + CONVERT(nvarchar(10), ROW_NUMBER() OVER (PARTITION BY c.grp ORDER BY c.id)), 2) + N'|'
       + N'f00=' + ISNULL(MAX(CASE WHEN r.k = 0 THEN r.cell END), N'?')
       + N',f10=' + ISNULL(MAX(CASE WHEN r.k = 1 THEN r.cell END), N'?')
       + N',f01=' + ISNULL(MAX(CASE WHEN r.k = 2 THEN r.cell END), N'?')
       + N',f11=' + ISNULL(MAX(CASE WHEN r.k = 3 THEN r.cell END), N'?')
       + N'|' + REPLACE(c.label, N'|', N'/')
       + ISNULL(N'; ' + REPLACE(REPLACE(MAX(r.msg), N'|', N'/'), CHAR(10), N' '), N'')
       + N' (ready=' + CASE WHEN MIN(r.ready) = MAX(r.ready) THEN MIN(r.ready) ELSE MIN(r.ready) + N'/' + MAX(r.ready) END
       + N' status=' + CASE WHEN MIN(r.st) = MAX(r.st) THEN MIN(r.st) ELSE MIN(r.st) + N'/' + MAX(r.st) END + N')' AS nvarchar(4000))
FROM @cases AS c JOIN @res AS r ON r.id = c.id
GROUP BY c.id, c.grp, c.label
ORDER BY c.id;
SELECT line FROM @out ORDER BY rn;
SELECT 'R|TOTAL|' + CONVERT(varchar(10), COUNT(*)) FROM @out;
GO
