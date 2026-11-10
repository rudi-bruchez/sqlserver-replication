-- Impact matrix of sp_changepublication and sp_changearticle on snapshot publications
-- (campaign item 7). Fed to sqlcmd on standard input by 09-snapshot-pub.sh, which has
-- built three publications on the tables m_t1, m_t2 and m_t3 of Sales, each with one
-- push subscription at status 2 and its snapshot delivered:
--   SNAP   m_snap   @repl_freq = N'snapshot', every other option the default
--                   (immediate_sync = 0, shared distribution agent, ready = 0)
--   SNAPI  m_snapi  snapshot with @immediate_sync and @independent_agent = true (ready = 1)
--   TWIN   m_tran   transactional (continuous), shared agent, ready = 0, its articles
--                   created with ins_cmd, upd_cmd and del_cmd = SQL as on the snapshot
--                   publications; only the command rows are run on it, to show the
--                   contrast with the snapshot publications on its own.
-- The article `filter` row sets the article's own filter (m_f3, m_f3i): another publication's
-- filter procedure makes sp_changearticle fail an engine assertion (see the script).
-- m_t3 carries a row filter and an excluded column in the snapshot publications, created
-- before the subscription was added, so that the filter and column rows have something
-- to change.
-- Same cell format as 02-matrix.sql: each case runs inside a transaction that is rolled
-- back, with (@force_invalidate_snapshot, @force_reinit_subscription) = (0,0), (1,0),
-- (0,1), (1,1); a cell is "ok" or the error number (20607 needs
-- @force_invalidate_snapshot, 20608 needs @force_reinit_subscription). One row per case:
--   R|<PFX>.<group><nn>|f00=..,f10=..,f01=..,f11=..|<label>[; error text]
--     (ready=<immediate_sync_ready> status=<subscription status> changed=<c>/<n>)
-- ready and status are read just before each call; status is the operated article's
-- subscription status for the A and F cases, the distinct statuses of the publication's
-- subscriptions for the P cases; a value that differs between the four cells is shown as
-- a/b. changed=c/n: of the n cells that returned ok, c changed the publication or article
-- row (or the column count) inside the transaction, so a case on the stored value, a
-- no-op, shows c < n (immediate_sync_ready excluded, see the fingerprint). The script asserts c = n on every row.
SET NOCOUNT ON;
USE Sales;
GO
DECLARE @targets TABLE (ord int, pfx varchar(5), pub sysname, kind char(1), flt sysname NULL);
INSERT @targets VALUES (1, 'SNAP', N'm_snap', 'S', N'm_f3'), (2, 'SNAPI', N'm_snapi', 'I', N'm_f3i'), (3, 'TWIN', N'm_tran', 'T', NULL);

DECLARE @cases TABLE (id int IDENTITY, pfx varchar(5), pub sysname, grp char(1), label nvarchar(200), stmt nvarchar(max), art sysname NULL);
DECLARE @cp nvarchar(max) = N'EXEC sp_changepublication @publication = N''{pub}'', @property = N''{prop}'', @value = N''{val}'', @force_invalidate_snapshot = @i, @force_reinit_subscription = @r';
DECLARE @ca nvarchar(max) = N'EXEC sp_changearticle @publication = N''{pub}'', @article = N''{art}'', @property = N''{prop}'', @value = N''{val}'', @force_invalidate_snapshot = @i, @force_reinit_subscription = @r';

-- kind: S = default snapshot publication, I = snapshot with immediate_sync, * = both.
-- Values differ from the stored ones; immediate_sync and independent_agent are set to the
-- opposite of what each publication holds.
DECLARE @pubprops TABLE (n int IDENTITY, kind char(1), prop sysname, val nvarchar(400));
INSERT @pubprops (kind, prop, val) VALUES
 ('*', N'description', N'changed'),
 ('*', N'retention', N'100'),
 ('*', N'replicate_ddl', N'0'),
 ('*', N'allow_pull', N'true'),
 ('*', N'allow_push', N'false'),
 ('*', N'allow_initialize_from_backup', N'true'),
 ('*', N'allow_subscription_copy', N'true'),
 ('*', N'allow_partition_switch', N'true'),
 ('*', N'replicate_partition_switch', N'true'),
 ('*', N'allow_drop', N'true'),
 ('*', N'status', N'inactive'),
 ('*', N'sync_method', N'concurrent'),
 ('*', N'sync_method', N'character'),
 ('*', N'sync_method', N'database snapshot'),
 ('S', N'immediate_sync', N'true'), ('I', N'immediate_sync', N'false'),
 ('S', N'independent_agent', N'true'), ('I', N'independent_agent', N'false'),
 ('*', N'allow_anonymous', N'true'),
 ('*', N'alt_snapshot_folder', N'/var/opt/mssql/data/ReplAlt'),
 ('*', N'snapshot_in_defaultfolder', N'false'),
 ('*', N'compress_snapshot', N'true'),
 ('*', N'pre_snapshot_script', N'/var/opt/mssql/data/pre.sql'),
 ('*', N'post_snapshot_script', N'/var/opt/mssql/data/post.sql'),
 ('*', N'enabled_for_internet', N'true'),
 ('*', N'enabled_for_het_sub', N'true'),
 ('*', N'ftp_address', N'ftp.example.com');
INSERT @cases (pfx, pub, grp, label, stmt, art)
SELECT t.pfx, t.pub, 'P', t.pub + N' publication ' + p.prop + N' = ' + p.val,
       REPLACE(REPLACE(REPLACE(@cp, N'{pub}', t.pub), N'{prop}', p.prop), N'{val}', p.val), NULL
FROM @targets t JOIN @pubprops p ON p.kind IN ('*', t.kind)
WHERE t.kind IN ('S', 'I')
ORDER BY t.ord, p.n;

-- Article properties. m_t1 plays Orders (custom commands, filters), m_t2 Product, m_t3
-- the filtered article with an excluded column.
DECLARE @artprops TABLE (n int IDENTITY, kind char(1), art sysname, prop sysname, val nvarchar(400));
INSERT @artprops (kind, art, prop, val) VALUES
 ('*', N'm_t1', N'description', N'changed'), ('*', N'm_t2', N'description', N'changed'),
 ('*', N'm_t1', N'dest_table', N'm_t1b'), ('*', N'm_t2', N'dest_table', N'm_t2b'),
 ('*', N'm_t1', N'destination_owner', N'other'),
 ('*', N'm_t1', N'ins_cmd', N'CALL sp_MSins_dbom_t1'), ('*', N'm_t2', N'ins_cmd', N'CALL sp_MSins_dbom_t2'),
 ('*', N'm_t1', N'upd_cmd', N'MCALL sp_MSupd_dbom_t1'),
 ('*', N'm_t1', N'del_cmd', N'NONE'),
 ('*', N'm_t1', N'pre_creation_cmd', N'delete'), ('*', N'm_t2', N'pre_creation_cmd', N'none'),
 ('*', N'm_t1', N'schema_option', N'0x000000000803509F'), ('*', N'm_t2', N'schema_option', N'0x0000000000030077'),
 ('*', N'm_t1', N'status', N'include column names'), ('*', N'm_t2', N'status', N'include column names'),
 ('*', N'm_t1', N'status', N'string literals'),
 ('*', N'm_t1', N'status', N'owner qualified'),
 ('*', N'm_t1', N'creation_script', N'/var/opt/mssql/data/create.sql'),
 ('*', N'm_t1', N'fire_triggers_on_snapshot', N'true'),
 ('*', N'm_t1', N'sync_object', N'm_v1'),
 ('*', N'm_t1', N'type', N'logbased manualfilter'),
 ('*', N'm_t3', N'filter', N'{flt}'),
 -- the transactional twin: the command rows only, same values as on the snapshot publications
 ('T', N'm_t1', N'ins_cmd', N'CALL sp_MSins_dbom_t1'), ('T', N'm_t2', N'ins_cmd', N'CALL sp_MSins_dbom_t2'),
 ('T', N'm_t1', N'upd_cmd', N'MCALL sp_MSupd_dbom_t1'),
 ('T', N'm_t1', N'del_cmd', N'NONE');
INSERT @cases (pfx, pub, grp, label, stmt, art)
SELECT t.pfx, t.pub, 'A', t.pub + N'.' + a.art + N' article ' + a.prop + N' = ' + REPLACE(a.val, N'{flt}', ISNULL(t.flt, N''))
       + CASE WHEN a.prop = N'filter' THEN N' same value (a different procedure is not measurable: Msg 3624 / 14049)' ELSE N'' END,
       REPLACE(REPLACE(REPLACE(REPLACE(@ca, N'{pub}', t.pub), N'{art}', a.art), N'{prop}', a.prop), N'{val}', REPLACE(a.val, N'{flt}', ISNULL(t.flt, N''))), a.art
FROM @targets t JOIN @artprops a ON a.kind = CASE WHEN t.kind = 'T' THEN 'T' ELSE '*' END
ORDER BY t.ord, a.n;

-- Filters and columns on subscribed articles (snapshot publications only).
DECLARE @ops TABLE (n int, label nvarchar(100), art sysname, stmt nvarchar(max));
INSERT @ops VALUES
 (1, N'm_t1 add row filter (sp_articlefilter)', N'm_t1',
  N'EXEC sp_articlefilter @publication = N''{pub}'', @article = N''m_t1'', @filter_name = N''m_f1'', @filter_clause = N''a > 0'', @force_invalidate_snapshot = @i, @force_reinit_subscription = @r'),
 (2, N'm_t1 drop column (sp_articlecolumn)', N'm_t1',
  N'EXEC sp_articlecolumn @publication = N''{pub}'', @article = N''m_t1'', @column = N''b'', @operation = N''drop'', @force_invalidate_snapshot = @i, @force_reinit_subscription = @r'),
 (3, N'm_t2 drop column (sp_articlecolumn)', N'm_t2',
  N'EXEC sp_articlecolumn @publication = N''{pub}'', @article = N''m_t2'', @column = N''b'', @operation = N''drop'', @force_invalidate_snapshot = @i, @force_reinit_subscription = @r'),
 (4, N'm_t3 change row filter clause (sp_articlefilter)', N'm_t3',
  N'EXEC sp_articlefilter @publication = N''{pub}'', @article = N''m_t3'', @filter_name = N''{flt}'', @filter_clause = N''a > 5'', @force_invalidate_snapshot = @i, @force_reinit_subscription = @r'),
 (5, N'm_t3 drop row filter (sp_articlefilter NULL clause)', N'm_t3',
  N'EXEC sp_articlefilter @publication = N''{pub}'', @article = N''m_t3'', @filter_name = N''{flt}'', @filter_clause = NULL, @force_invalidate_snapshot = @i, @force_reinit_subscription = @r'),
 (6, N'm_t3 add column back (sp_articlecolumn)', N'm_t3',
  N'EXEC sp_articlecolumn @publication = N''{pub}'', @article = N''m_t3'', @column = N''c'', @operation = N''add'', @force_invalidate_snapshot = @i, @force_reinit_subscription = @r');
INSERT @cases (pfx, pub, grp, label, stmt, art)
SELECT t.pfx, t.pub, 'F', t.pub + N'.' + o.label, REPLACE(REPLACE(o.stmt, N'{pub}', t.pub), N'{flt}', t.flt), o.art
FROM @targets t CROSS JOIN @ops o WHERE t.kind IN ('S', 'I')
ORDER BY t.ord, o.n;

DECLARE @flags TABLE (k int, i bit, r bit);
INSERT @flags VALUES (0, 0, 0), (1, 1, 0), (2, 0, 1), (3, 1, 1);
DECLARE @res TABLE (id int, k int, cell varchar(10), msg nvarchar(400), ready nvarchar(10), st nvarchar(100), chg int);

DECLARE @id int, @stmt nvarchar(max), @pub sysname, @art sysname, @k int, @i bit, @r bit, @ready nvarchar(10), @st nvarchar(100), @fp0 nvarchar(max), @fp1 nvarchar(max);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT c.id, c.stmt, c.pub, c.art, f.k, f.i, f.r FROM @cases AS c CROSS JOIN @flags AS f ORDER BY c.id, f.k;
OPEN c;
FETCH c INTO @id, @stmt, @pub, @art, @k, @i, @r;
WHILE @@FETCH_STATUS = 0
BEGIN
    -- State read just before the call.
    SET @ready = ISNULL((SELECT CONVERT(nvarchar(10), immediate_sync_ready) FROM dbo.syspublications WHERE name = @pub), N'none');
    SET @st = ISNULL((SELECT STRING_AGG(CONVERT(nvarchar(10), x.st), N'/') WITHIN GROUP (ORDER BY x.st)
                      FROM (SELECT DISTINCT s.status AS st FROM dbo.syssubscriptions s JOIN dbo.sysarticles a ON a.artid = s.artid
                            JOIN dbo.syspublications p ON p.pubid = a.pubid
                            WHERE p.name = @pub AND s.srvid >= 0 AND (@art IS NULL OR a.name = @art)) x), N'none');
    -- Fingerprint of what the case may change: the publication row, the article row, the column count.
    -- immediate_sync_ready is left out: any call with @force_invalidate_snapshot = 1 flips it from 1 to 0
    -- on an immediate_sync publication even when the call changes nothing else.
    SET @fp0 = REPLACE(REPLACE(CONVERT(nvarchar(max), (SELECT * FROM dbo.syspublications WHERE name = @pub FOR XML RAW, BINARY BASE64)), N' immediate_sync_ready="1"', N''), N' immediate_sync_ready="0"', N'')
             + ISNULL(CONVERT(nvarchar(max), (SELECT a.* FROM dbo.sysarticles a JOIN dbo.syspublications p ON p.pubid = a.pubid WHERE p.name = @pub AND a.name = @art FOR XML RAW, BINARY BASE64)), N'')
             + ISNULL(CONVERT(nvarchar(20), (SELECT COUNT(*) FROM dbo.sysarticlecolumns c2 JOIN dbo.sysarticles a ON a.artid = c2.artid JOIN dbo.syspublications p ON p.pubid = a.pubid WHERE p.name = @pub AND a.name = @art)), N'');
    BEGIN TRY
        BEGIN TRAN;
        EXEC sp_executesql @stmt, N'@i bit, @r bit', @i = @i, @r = @r;
        SET @fp1 = REPLACE(REPLACE(CONVERT(nvarchar(max), (SELECT * FROM dbo.syspublications WHERE name = @pub FOR XML RAW, BINARY BASE64)), N' immediate_sync_ready="1"', N''), N' immediate_sync_ready="0"', N'')
             + ISNULL(CONVERT(nvarchar(max), (SELECT a.* FROM dbo.sysarticles a JOIN dbo.syspublications p ON p.pubid = a.pubid WHERE p.name = @pub AND a.name = @art FOR XML RAW, BINARY BASE64)), N'')
             + ISNULL(CONVERT(nvarchar(20), (SELECT COUNT(*) FROM dbo.sysarticlecolumns c2 JOIN dbo.sysarticles a ON a.artid = c2.artid JOIN dbo.syspublications p ON p.pubid = a.pubid WHERE p.name = @pub AND a.name = @art)), N'');
        ROLLBACK;
        INSERT @res VALUES (@id, @k, 'ok', NULL, @ready, @st, CASE WHEN @fp0 <> @fp1 THEN 1 ELSE 0 END);
    END TRY
    BEGIN CATCH
        DECLARE @e int = ERROR_NUMBER(), @m nvarchar(400) = LEFT(ERROR_MESSAGE(), 400);
        IF @@TRANCOUNT > 0 ROLLBACK;
        INSERT @res VALUES (@id, @k, CONVERT(varchar(10), @e), CASE WHEN @e IN (20607, 20608) THEN NULL ELSE @m END, @ready, @st, NULL);
    END CATCH;
    IF @@TRANCOUNT > 0 ROLLBACK;
    FETCH c INTO @id, @stmt, @pub, @art, @k, @i, @r;
END;
CLOSE c; DEALLOCATE c;

DECLARE @out TABLE (rn int IDENTITY, line nvarchar(4000));
INSERT @out (line)
SELECT CAST(N'R|' + c.pfx + N'.' + c.grp + RIGHT(N'00' + CONVERT(nvarchar(10), ROW_NUMBER() OVER (PARTITION BY c.pfx, c.grp ORDER BY c.id)), 2) + N'|'
       + N'f00=' + ISNULL(MAX(CASE WHEN r.k = 0 THEN r.cell END), N'?')
       + N',f10=' + ISNULL(MAX(CASE WHEN r.k = 1 THEN r.cell END), N'?')
       + N',f01=' + ISNULL(MAX(CASE WHEN r.k = 2 THEN r.cell END), N'?')
       + N',f11=' + ISNULL(MAX(CASE WHEN r.k = 3 THEN r.cell END), N'?')
       + N'|' + REPLACE(c.label, N'|', N'/')
       + ISNULL(N'; ' + REPLACE(REPLACE(MAX(r.msg), N'|', N'/'), CHAR(10), N' '), N'')
       + N' (ready=' + CASE WHEN MIN(r.ready) = MAX(r.ready) THEN MIN(r.ready) ELSE MIN(r.ready) + N'/' + MAX(r.ready) END
       + N' status=' + CASE WHEN MIN(r.st) = MAX(r.st) THEN MIN(r.st) ELSE MIN(r.st) + N'/' + MAX(r.st) END
       + N' changed=' + CONVERT(nvarchar(2), ISNULL(SUM(r.chg), 0)) + N'/' + CONVERT(nvarchar(2), SUM(CASE WHEN r.cell = 'ok' THEN 1 ELSE 0 END)) + N')' AS nvarchar(4000))
FROM @cases AS c JOIN @res AS r ON r.id = c.id
GROUP BY c.id, c.pfx, c.grp, c.label
ORDER BY CASE c.pfx WHEN 'SNAP' THEN 1 WHEN 'SNAPI' THEN 2 ELSE 3 END, c.id;
SELECT line FROM @out ORDER BY rn;
SELECT 'R|TOTAL|' + CONVERT(varchar(10), COUNT(*)) FROM @out;
GO
