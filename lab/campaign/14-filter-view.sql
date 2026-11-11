-- What sp_articlefilter, sp_articleview and sp_articlecolumn do to sysarticles.filter_clause,
-- the filter procedure and the synchronization view (campaign item 11; spec section
-- "Filters and views"). Run through lab/campaign.sh, which feeds it to sqlcmd.
--
-- Committed state, built here and removed at the end: table Sales.dbo.m_t1 (id, a, b), the
-- publication m_fv (immediate_sync = 0, shared agent, native sync, snapshot agent that never
-- fires, no subscription), its article m_t1 with no filter, all columns, and the
-- synchronization view m_v created by sp_articleview without a clause.
-- Each case is one transaction rolled back, so that it starts from that state:
--   F1  sp_articlefilter @filter_name = m_f, @filter_clause = 'a > 0'
--   F2  F1, then sp_articlefilter with 'a > 1'
--   F3  F1, then sp_articlefilter with a NULL clause
--   F4  F1, then sp_articleview @view_name = m_v without @filter_clause
--   F5  F2, then sp_articleview @view_name = m_v, @filter_clause = 'a > 1'
--   F6  F1 and sp_articleview with 'a > 0', then sp_articlecolumn drop of b
--   F7  F6, then sp_articlecolumn add of b
--   F8  sp_articlecolumn drop of b, then sp_articleview with 'a > 0'
-- The last call of a case is the measured one; the state is read after it, inside the
-- transaction. One row per case:
--   R|F<n>|<ok, or the first error number>|calls=<proc:result,...>; filter_clause=<value>;
--     filter_proc=<exists|absent>; article_filter=<m_f|none|other>; proc_clause=<clause in the
--     procedure, none>; sync_view=<m_v|other name|none>; view_clause=<clause after the
--     HAS_PERMS_BY_NAME predicate, none>; view_columns=<list>; view_has_column_b=<yes|no>;
--     article_columns=<list>; last_call_recreated_view=<yes|no>; last_call_changed_view=<yes|no>
-- No object id is printed: only relations, which a rerun reproduces. The view and procedure
-- definitions are read whole (nvarchar(max)) and parsed server side; a definition longer than
-- 4000 characters fails the run, since nothing longer is ever printed.
--
-- Asserted (Step 3 of the brief), each failure raised as an uncaught error that the runner
-- rejects, after the rows are printed: 8 rows; F2 does not change the view (it stays on the
-- clause it had, none); F4 sets filter_clause to NULL; F6 leaves a view without column b.
SET NOCOUNT ON;
USE Sales;
GO
-- Leftovers of an earlier run are not absorbed: the run fails, and the cleanup batch at the
-- end removes them.
IF EXISTS (SELECT 1 FROM dbo.syspublications WHERE name = N'm_fv') OR OBJECT_ID(N'dbo.m_t1') IS NOT NULL
   OR OBJECT_ID(N'dbo.m_v') IS NOT NULL OR OBJECT_ID(N'dbo.m_f') IS NOT NULL
    RAISERROR (N'14-filter-view: leftovers of an earlier run (m_fv, m_t1, m_v or m_f); failing', 16, 1);
ELSE
BEGIN
    CREATE TABLE dbo.m_t1 (id int PRIMARY KEY, a int, b int);
    EXEC sp_addpublication @publication = N'm_fv', @status = N'active', @allow_push = N'true',
         @independent_agent = N'false', @immediate_sync = N'false', @repl_freq = N'continuous', @sync_method = N'native';
    EXEC sp_addpublication_snapshot @publication = N'm_fv', @frequency_type = 1, @active_start_date = 99991231,
         @job_login = NULL, @job_password = NULL, @publisher_security_mode = 1;
    EXEC sp_addarticle @publication = N'm_fv', @article = N'm_t1', @source_owner = N'dbo', @source_object = N'm_t1';
    EXEC sp_articleview @publication = N'm_fv', @article = N'm_t1', @view_name = N'm_v';
END
GO
DECLARE @AF0 nvarchar(400) = N'EXEC sp_articlefilter @publication = N''m_fv'', @article = N''m_t1'', @filter_name = N''m_f'', @filter_clause = N''a > 0''';
DECLARE @AF1 nvarchar(400) = N'EXEC sp_articlefilter @publication = N''m_fv'', @article = N''m_t1'', @filter_name = N''m_f'', @filter_clause = N''a > 1''';
DECLARE @AFN nvarchar(400) = N'EXEC sp_articlefilter @publication = N''m_fv'', @article = N''m_t1'', @filter_name = N''m_f'', @filter_clause = NULL';
DECLARE @AV  nvarchar(400) = N'EXEC sp_articleview @publication = N''m_fv'', @article = N''m_t1'', @view_name = N''m_v''';
DECLARE @AV0 nvarchar(400) = @AV + N', @filter_clause = N''a > 0''';
DECLARE @AV1 nvarchar(400) = @AV + N', @filter_clause = N''a > 1''';
DECLARE @CD  nvarchar(400) = N'EXEC sp_articlecolumn @publication = N''m_fv'', @article = N''m_t1'', @column = N''b'', @operation = N''drop''';
DECLARE @CA  nvarchar(400) = N'EXEC sp_articlecolumn @publication = N''m_fv'', @article = N''m_t1'', @column = N''b'', @operation = N''add''';

-- Steps of each case in order; the last one is the measured call.
DECLARE @steps TABLE (cid varchar(4), ord int, proc_name sysname, stmt nvarchar(400));
INSERT @steps VALUES
 ('F1', 1, N'sp_articlefilter', @AF0),
 ('F2', 1, N'sp_articlefilter', @AF0), ('F2', 2, N'sp_articlefilter', @AF1),
 ('F3', 1, N'sp_articlefilter', @AF0), ('F3', 2, N'sp_articlefilter', @AFN),
 ('F4', 1, N'sp_articlefilter', @AF0), ('F4', 2, N'sp_articleview', @AV),
 ('F5', 1, N'sp_articlefilter', @AF0), ('F5', 2, N'sp_articlefilter', @AF1), ('F5', 3, N'sp_articleview', @AV1),
 ('F6', 1, N'sp_articlefilter', @AF0), ('F6', 2, N'sp_articleview', @AV0), ('F6', 3, N'sp_articlecolumn', @CD),
 ('F7', 1, N'sp_articlefilter', @AF0), ('F7', 2, N'sp_articleview', @AV0), ('F7', 3, N'sp_articlecolumn', @CD), ('F7', 4, N'sp_articlecolumn', @CA),
 ('F8', 1, N'sp_articlecolumn', @CD), ('F8', 2, N'sp_articleview', @AV0);

DECLARE @res TABLE (cid varchar(4), result nvarchar(20), detail nvarchar(3000), view_clause nvarchar(400), filter_clause nvarchar(400),
                    has_b nvarchar(10), changed nvarchar(10), too_long int);

DECLARE @cid varchar(4), @ord int, @last int, @proc sysname, @stmt nvarchar(400);
DECLARE @calls nvarchar(1000), @first nvarchar(20), @e nvarchar(20), @readable bit;
DECLARE @vid0 int, @vdef0 nvarchar(max), @vid1 int, @vdef nvarchar(max), @pdef nvarchar(max);
DECLARE @fc nvarchar(400), @fproc nvarchar(10), @afilter nvarchar(10), @pclause nvarchar(400), @sview nvarchar(260),
        @vclause nvarchar(400), @vcols nvarchar(400), @hasb nvarchar(10), @acols nvarchar(400), @recreated nvarchar(10), @changed nvarchar(10),
        @too_long int, @p int, @q int, @rest nvarchar(max);
DECLARE @marker nvarchar(40) = N'''SELECT'')= 1';

DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT cid FROM @steps ORDER BY cid;
OPEN cc;
FETCH cc INTO @cid;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @calls = N'', @first = N'ok', @readable = 1, @too_long = 0, @vid0 = NULL, @vdef0 = NULL;
    SELECT @last = MAX(ord) FROM @steps WHERE cid = @cid;
    BEGIN TRAN;
    DECLARE cs CURSOR LOCAL FAST_FORWARD FOR SELECT ord, proc_name, stmt FROM @steps WHERE cid = @cid ORDER BY ord;
    OPEN cs;
    FETCH cs INTO @ord, @proc, @stmt;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @ord = @last
            SELECT @vid0 = OBJECT_ID(N'dbo.m_v'), @vdef0 = OBJECT_DEFINITION(OBJECT_ID(N'dbo.m_v'));
        SET @e = N'ok';
        BEGIN TRY
            EXEC (@stmt);
        END TRY
        BEGIN CATCH
            SET @e = CONVERT(nvarchar(20), ERROR_NUMBER());
        END CATCH;
        SET @calls += CASE WHEN @calls = N'' THEN N'' ELSE N',' END + @proc + N':' + @e;
        IF @e <> N'ok'
        BEGIN
            IF @first = N'ok' SET @first = @e;
            -- A refused replication procedure can leave its transaction open, or doomed: the
            -- state read below is then not the state of this case.
            IF XACT_STATE() <> 1 SET @readable = 0;
        END
        FETCH cs INTO @ord, @proc, @stmt;
    END;
    CLOSE cs; DEALLOCATE cs;

    IF @readable = 1 AND @@TRANCOUNT > 0
    BEGIN
        SELECT @fc = ISNULL(a.filter_clause, N'NULL'),
               @afilter = CASE WHEN a.filter = 0 THEN N'none' WHEN a.filter = OBJECT_ID(N'dbo.m_f') THEN N'm_f' ELSE N'other' END,
               @sview = ISNULL(CASE WHEN a.sync_objid = OBJECT_ID(N'dbo.m_v') THEN N'm_v'
                                    WHEN OBJECT_NAME(a.sync_objid) LIKE N'syncobj[_]0x%' THEN N'syncobj_0x<hex>'
                                    ELSE OBJECT_NAME(a.sync_objid) END, N'none'),
               @acols = ISNULL((SELECT STRING_AGG(CONVERT(nvarchar(400), c.name), N',') WITHIN GROUP (ORDER BY c.column_id)
                                FROM dbo.sysarticlecolumns ac JOIN sys.columns c ON c.object_id = a.objid AND c.column_id = ac.colid
                                WHERE ac.artid = a.artid), N'none')
        FROM dbo.syspublications pb JOIN dbo.sysarticles a ON a.pubid = pb.pubid
        WHERE pb.name = N'm_fv' AND a.name = N'm_t1';
        SET @fproc = CASE WHEN OBJECT_ID(N'dbo.m_f') IS NULL THEN N'absent' ELSE N'exists' END;

        -- The procedure: create procedure [dbo].[m_f] for replication as if exists (select *
        -- from [dbo].[m_t1] where <clause>) return 1 else return 0
        SET @pdef = REPLACE(REPLACE(OBJECT_DEFINITION(OBJECT_ID(N'dbo.m_f')), NCHAR(13), N' '), NCHAR(10), N' ');
        IF LEN(@pdef) > 4000 SET @too_long += 1;
        SET @p = CHARINDEX(N' where ', ISNULL(@pdef, N''));
        SET @q = CASE WHEN @p > 0 THEN CHARINDEX(N') return 1', @pdef, @p) ELSE 0 END;
        SET @pclause = CASE WHEN @pdef IS NULL THEN N'none'
                            WHEN @p = 0 OR @q = 0 THEN N'unparsed'
                            ELSE LTRIM(RTRIM(SUBSTRING(@pdef, @p + 7, @q - @p - 7))) END;

        -- The view: create view [dbo].[m_v]as select  [id],[a],[b]  from  [dbo].[m_t1]  where
        -- HAS_PERMS_BY_NAME('[dbo].[m_t1]', 'OBJECT', 'SELECT')= 1  [and (<clause>)]
        SELECT @vid1 = OBJECT_ID(N'dbo.m_v'), @vdef = OBJECT_DEFINITION(OBJECT_ID(N'dbo.m_v'));
        IF LEN(@vdef) > 4000 SET @too_long += 1;
        SET @vdef = REPLACE(REPLACE(@vdef, NCHAR(13), N' '), NCHAR(10), N' ');
        IF @vdef IS NULL
            SELECT @vcols = N'none', @vclause = N'none', @hasb = N'no';
        ELSE
        BEGIN
            SET @p = CHARINDEX(N'as select ', @vdef);
            SET @q = CASE WHEN @p > 0 THEN CHARINDEX(N' from ', @vdef, @p) ELSE 0 END;
            SET @vcols = CASE WHEN @p = 0 OR @q = 0 THEN N'unparsed'
                              ELSE REPLACE(REPLACE(REPLACE(SUBSTRING(@vdef, @p + 10, @q - @p - 10), N' ', N''), N'[', N''), N']', N'') END;
            SET @hasb = CASE WHEN N',' + @vcols + N',' LIKE N'%,b,%' THEN N'yes' ELSE N'no' END;
            SET @p = CHARINDEX(@marker, @vdef);
            SET @rest = CASE WHEN @p > 0 THEN LTRIM(RTRIM(SUBSTRING(@vdef, @p + LEN(@marker), LEN(@vdef)))) END;
            SET @vclause = CASE WHEN @p = 0 THEN N'unparsed'
                                WHEN @rest = N'' THEN N'none'
                                WHEN @rest LIKE N'and (%)' THEN SUBSTRING(@rest, 6, LEN(@rest) - 6)
                                ELSE N'unparsed' END;
        END;
        SET @recreated = CASE WHEN ISNULL(@vid0, -1) = ISNULL(@vid1, -1) THEN N'no' ELSE N'yes' END;
        SET @changed = CASE WHEN @vdef0 IS NULL AND @vdef IS NULL THEN N'no'
                            WHEN @vdef0 IS NULL OR OBJECT_DEFINITION(@vid1) IS NULL THEN N'yes'
                            WHEN @vdef0 = OBJECT_DEFINITION(@vid1) THEN N'no' ELSE N'yes' END;

        INSERT @res VALUES (@cid, @first,
            N'calls=' + @calls + N'; filter_clause=' + @fc + N'; filter_proc=' + @fproc + N'; article_filter=' + @afilter
            + N'; proc_clause=' + @pclause + N'; sync_view=' + @sview + N'; view_clause=' + @vclause
            + N'; view_columns=' + @vcols + N'; view_has_column_b=' + @hasb + N'; article_columns=' + @acols
            + N'; last_call_recreated_view=' + @recreated + N'; last_call_changed_view=' + @changed,
            @vclause, @fc, @hasb, @changed, @too_long);
    END
    ELSE
        INSERT @res VALUES (@cid, @first, N'calls=' + @calls + N'; state not readable (transaction doomed or closed by the refused call)',
                            NULL, NULL, NULL, NULL, 0);
    WHILE @@TRANCOUNT > 0 ROLLBACK;
    FETCH cc INTO @cid;
END;
CLOSE cc; DEALLOCATE cc;

SELECT CAST(N'R|' + cid + N'|' + result + N'|' + REPLACE(detail, N'|', N'/') AS nvarchar(4000)) FROM @res ORDER BY cid;
SELECT 'R|TOTAL|' + CONVERT(varchar(10), COUNT(*)) FROM @res;

-- Assertions: every failure is listed in one error, which the runner's uncaught guard rejects.
DECLARE @bad nvarchar(2000) = N'';
IF (SELECT COUNT(*) FROM @res) <> 8
    SET @bad += N' rows=' + CONVERT(nvarchar(10), (SELECT COUNT(*) FROM @res)) + N' (expected 8);';
IF EXISTS (SELECT 1 FROM @res WHERE too_long > 0)
    SET @bad += N' a view or filter procedure definition is longer than 4000 characters;';
IF NOT EXISTS (SELECT 1 FROM @res WHERE cid = 'F2' AND changed = N'no')
    SET @bad += N' F2 changed the view (expected: the view stays on its old clause);';
IF NOT EXISTS (SELECT 1 FROM @res WHERE cid = 'F4' AND filter_clause = N'NULL')
    SET @bad += N' F4 did not set filter_clause to NULL;';
IF NOT EXISTS (SELECT 1 FROM @res WHERE cid = 'F6' AND has_b = N'no')
    SET @bad += N' F6 left column b in the view (expected sp_articlecolumn to rebuild it without b);';
IF @bad <> N''
    RAISERROR (N'14-filter-view: assertion failed:%s', 16, 1, @bad);
GO
-- Cleanup: the publication (its article, filter procedure and view with it), then the table.
IF @@TRANCOUNT > 0 ROLLBACK;
BEGIN TRY
    IF EXISTS (SELECT 1 FROM dbo.syspublications WHERE name = N'm_fv') EXEC sp_droppublication @publication = N'm_fv';
END TRY
BEGIN CATCH
    DECLARE @m nvarchar(400) = ERROR_MESSAGE();
    RAISERROR (N'14-filter-view: cleanup failed: %s', 16, 1, @m);
END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK;
DROP VIEW IF EXISTS dbo.m_v;
DROP PROCEDURE IF EXISTS dbo.m_f;
DROP TABLE IF EXISTS dbo.m_t1;
GO
