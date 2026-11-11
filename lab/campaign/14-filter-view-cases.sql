-- The cases of lab/campaign/14-filter-view.sh, fed to sqlcmd on standard input by it, after
-- it has built the committed state (see the header of the .sh). Two sets of the same eight
-- cases:
--   F1..F8    publication m_fv, article m_t1, view m_v, filter m_f: no subscription
--   F1s..F8s  publication m_fvs, article m_t2, view m_vs, filter m_fs: a push subscription
--             to m_fvsub, status 2, snapshot delivered; every call passes
--             @force_invalidate_snapshot = immediate_sync_ready (read here) and
--             @force_reinit_subscription = 1 (measured: each of the three procedures is
--             refused with 20608 without it on this subscribed article)
-- Each case is one transaction rolled back, so that it starts from the committed state:
--   F1  sp_articlefilter @filter_name, @filter_clause = 'a > 0'
--   F2  F1, then sp_articlefilter with 'a > 1'
--   F3  F1, then sp_articlefilter with a NULL clause
--   F4  F1, then sp_articleview @view_name without @filter_clause
--   F5  F2, then sp_articleview @view_name, @filter_clause = 'a > 1'
--   F6  F1 and sp_articleview with 'a > 0', then sp_articlecolumn drop of b
--   F7  F6, then sp_articlecolumn add of b
--   F8  sp_articlecolumn drop of b, then sp_articleview with 'a > 0'
-- The last call of a case is the measured one; the state is read after it, inside the
-- transaction. One row per case:
--   R|<case>|<ok, or the first error number>|subscribed=<yes|no>; flags=<none|inv=i,reinit=1>;
--     calls=<proc:result,...>; filter_clause=<value>; filter_proc=<exists|absent>;
--     article_filter=<filter name|none|other>; proc_clause=<clause in the procedure, none>;
--     sync_view=<view name|other name|none>; view_clause=<clause after the HAS_PERMS_BY_NAME
--     predicate, none>; view_columns=<list>; view_has_column_b=<yes|no>;
--     article_columns=<list>; last_call_recreated_view=<yes|no>; last_call_changed_view=<yes|no>
-- subscribed is read inside the transaction, before the first call (syssubscriptions rows
-- of the article with srvid >= 0). No object id is printed: only relations, which a rerun
-- reproduces. The view and procedure definitions are read whole (nvarchar(max)) and parsed
-- server side; a definition longer than 4000 characters fails the run.
--
-- Asserted, each failure raised as one uncaught error that the runner rejects, after the
-- rows are printed: 16 rows; the subscribed flag of every row is the one of its set; F2 and
-- F2s do not change the view (it stays on the clause it had, none); F4 and F4s set
-- filter_clause to NULL; F6 leaves column b in the view (measured on 2022: without a
-- subscription sp_articlecolumn does not rebuild the view; the brief expected the
-- opposite, the coordinator ruled to assert the measurement); F6s leaves a view without b
-- (with a subscription sp_articlecolumn rebuilds it, measured in the Task 11 probe).
SET NOCOUNT ON;
USE Sales;
GO
DECLARE @inv nvarchar(10) = ISNULL((SELECT CONVERT(nvarchar(10), immediate_sync_ready) FROM dbo.syspublications WHERE name = N'm_fvs'), N'none');

DECLARE @sets TABLE (sfx varchar(2), pub sysname, art sysname, vw sysname, flt sysname, fl nvarchar(200), subscribed nvarchar(3), flags nvarchar(40));
INSERT @sets VALUES
 ('',  N'm_fv',  N'm_t1', N'm_v',  N'm_f',  N'', N'no', N'none'),
 ('s', N'm_fvs', N'm_t2', N'm_vs', N'm_fs', N', @force_invalidate_snapshot = ' + @inv + N', @force_reinit_subscription = 1', N'yes', N'inv=' + @inv + N',reinit=1');

DECLARE @AF0 nvarchar(400) = N'EXEC sp_articlefilter @publication = N''{pub}'', @article = N''{art}'', @filter_name = N''{flt}'', @filter_clause = N''a > 0''{fl}';
DECLARE @AF1 nvarchar(400) = N'EXEC sp_articlefilter @publication = N''{pub}'', @article = N''{art}'', @filter_name = N''{flt}'', @filter_clause = N''a > 1''{fl}';
DECLARE @AFN nvarchar(400) = N'EXEC sp_articlefilter @publication = N''{pub}'', @article = N''{art}'', @filter_name = N''{flt}'', @filter_clause = NULL{fl}';
DECLARE @AV  nvarchar(400) = N'EXEC sp_articleview @publication = N''{pub}'', @article = N''{art}'', @view_name = N''{vw}''{fl}';
DECLARE @AV0 nvarchar(400) = N'EXEC sp_articleview @publication = N''{pub}'', @article = N''{art}'', @view_name = N''{vw}'', @filter_clause = N''a > 0''{fl}';
DECLARE @AV1 nvarchar(400) = N'EXEC sp_articleview @publication = N''{pub}'', @article = N''{art}'', @view_name = N''{vw}'', @filter_clause = N''a > 1''{fl}';
DECLARE @CD  nvarchar(400) = N'EXEC sp_articlecolumn @publication = N''{pub}'', @article = N''{art}'', @column = N''b'', @operation = N''drop''{fl}';
DECLARE @CA  nvarchar(400) = N'EXEC sp_articlecolumn @publication = N''{pub}'', @article = N''{art}'', @column = N''b'', @operation = N''add''{fl}';

-- Steps of each case in order; the last one is the measured call.
DECLARE @tpl TABLE (cid varchar(4), ord int, proc_name sysname, stmt nvarchar(400));
INSERT @tpl VALUES
 ('F1', 1, N'sp_articlefilter', @AF0),
 ('F2', 1, N'sp_articlefilter', @AF0), ('F2', 2, N'sp_articlefilter', @AF1),
 ('F3', 1, N'sp_articlefilter', @AF0), ('F3', 2, N'sp_articlefilter', @AFN),
 ('F4', 1, N'sp_articlefilter', @AF0), ('F4', 2, N'sp_articleview', @AV),
 ('F5', 1, N'sp_articlefilter', @AF0), ('F5', 2, N'sp_articlefilter', @AF1), ('F5', 3, N'sp_articleview', @AV1),
 ('F6', 1, N'sp_articlefilter', @AF0), ('F6', 2, N'sp_articleview', @AV0), ('F6', 3, N'sp_articlecolumn', @CD),
 ('F7', 1, N'sp_articlefilter', @AF0), ('F7', 2, N'sp_articleview', @AV0), ('F7', 3, N'sp_articlecolumn', @CD), ('F7', 4, N'sp_articlecolumn', @CA),
 ('F8', 1, N'sp_articlecolumn', @CD), ('F8', 2, N'sp_articleview', @AV0);

DECLARE @steps TABLE (cid varchar(4), ord int, proc_name sysname, stmt nvarchar(800));
INSERT @steps
SELECT t.cid + s.sfx, t.ord, t.proc_name,
       REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(t.stmt, N'{pub}', s.pub), N'{art}', s.art), N'{vw}', s.vw), N'{flt}', s.flt), N'{fl}', s.fl)
FROM @tpl t CROSS JOIN @sets s;

DECLARE @res TABLE (cid varchar(4), result nvarchar(20), detail nvarchar(3000), subscribed nvarchar(3), view_clause nvarchar(400),
                    filter_clause nvarchar(400), has_b nvarchar(10), changed nvarchar(10), too_long int);

DECLARE @cid varchar(4), @ord int, @last int, @proc sysname, @stmt nvarchar(800);
DECLARE @pub sysname, @art sysname, @vw sysname, @flt sysname, @flags nvarchar(40), @subs nvarchar(3);
DECLARE @calls nvarchar(1000), @first nvarchar(20), @e nvarchar(20), @readable bit;
DECLARE @vid0 int, @vdef0 nvarchar(max), @vid1 int, @vdef nvarchar(max), @pdef nvarchar(max);
DECLARE @fc nvarchar(400), @fproc nvarchar(10), @afilter sysname, @pclause nvarchar(400), @sview nvarchar(260),
        @vclause nvarchar(400), @vcols nvarchar(400), @hasb nvarchar(10), @acols nvarchar(400), @recreated nvarchar(10), @changed nvarchar(10),
        @too_long int, @p int, @q int, @rest nvarchar(max);
DECLARE @marker nvarchar(40) = N'''SELECT'')= 1';

DECLARE cc CURSOR LOCAL FAST_FORWARD FOR
    SELECT DISTINCT st.cid, se.pub, se.art, se.vw, se.flt, se.flags
    FROM @steps st JOIN @sets se ON se.sfx = CASE WHEN st.cid LIKE '%s' THEN 's' ELSE '' END
    ORDER BY st.cid;
OPEN cc;
FETCH cc INTO @cid, @pub, @art, @vw, @flt, @flags;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @calls = N'', @first = N'ok', @readable = 1, @too_long = 0, @vid0 = NULL, @vdef0 = NULL;
    SELECT @last = MAX(ord) FROM @steps WHERE cid = @cid;
    BEGIN TRAN;
    SET @subs = CASE WHEN EXISTS (SELECT 1 FROM dbo.syssubscriptions s JOIN dbo.sysarticles a ON a.artid = s.artid
                                  JOIN dbo.syspublications pb ON pb.pubid = a.pubid
                                  WHERE pb.name = @pub AND a.name = @art AND s.srvid >= 0) THEN N'yes' ELSE N'no' END;
    DECLARE cs CURSOR LOCAL FAST_FORWARD FOR SELECT ord, proc_name, stmt FROM @steps WHERE cid = @cid ORDER BY ord;
    OPEN cs;
    FETCH cs INTO @ord, @proc, @stmt;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @ord = @last
            SELECT @vid0 = OBJECT_ID(N'dbo.' + @vw), @vdef0 = OBJECT_DEFINITION(OBJECT_ID(N'dbo.' + @vw));
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
               @afilter = CASE WHEN a.filter = 0 THEN N'none' WHEN a.filter = OBJECT_ID(N'dbo.' + @flt) THEN @flt ELSE N'other' END,
               @sview = ISNULL(CASE WHEN a.sync_objid = OBJECT_ID(N'dbo.' + @vw) THEN @vw
                                    WHEN OBJECT_NAME(a.sync_objid) LIKE N'syncobj[_]0x%' THEN N'syncobj_0x<hex>'
                                    ELSE OBJECT_NAME(a.sync_objid) END, N'none'),
               @acols = ISNULL((SELECT STRING_AGG(CONVERT(nvarchar(400), c.name), N',') WITHIN GROUP (ORDER BY c.column_id)
                                FROM dbo.sysarticlecolumns ac JOIN sys.columns c ON c.object_id = a.objid AND c.column_id = ac.colid
                                WHERE ac.artid = a.artid), N'none')
        FROM dbo.syspublications pb JOIN dbo.sysarticles a ON a.pubid = pb.pubid
        WHERE pb.name = @pub AND a.name = @art;
        SET @fproc = CASE WHEN OBJECT_ID(N'dbo.' + @flt) IS NULL THEN N'absent' ELSE N'exists' END;

        -- The procedure: create procedure [dbo].[<flt>] for replication as if exists (select *
        -- from [dbo].[<art>] where <clause>) return 1 else return 0
        SET @pdef = REPLACE(REPLACE(OBJECT_DEFINITION(OBJECT_ID(N'dbo.' + @flt)), NCHAR(13), N' '), NCHAR(10), N' ');
        IF LEN(@pdef) > 4000 SET @too_long += 1;
        SET @p = CHARINDEX(N' where ', ISNULL(@pdef, N''));
        SET @q = CASE WHEN @p > 0 THEN CHARINDEX(N') return 1', @pdef, @p) ELSE 0 END;
        SET @pclause = CASE WHEN @pdef IS NULL THEN N'none'
                            WHEN @p = 0 OR @q = 0 THEN N'unparsed'
                            ELSE LTRIM(RTRIM(SUBSTRING(@pdef, @p + 7, @q - @p - 7))) END;

        -- The view: create view [dbo].[<vw>]as select  [id],[a],[b]  from  [dbo].[<art>]  where
        -- HAS_PERMS_BY_NAME('[dbo].[<art>]', 'OBJECT', 'SELECT')= 1  [and (<clause>)]
        SELECT @vid1 = OBJECT_ID(N'dbo.' + @vw), @vdef = OBJECT_DEFINITION(OBJECT_ID(N'dbo.' + @vw));
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
            N'subscribed=' + @subs + N'; flags=' + @flags
            + N'; calls=' + @calls + N'; filter_clause=' + @fc + N'; filter_proc=' + @fproc + N'; article_filter=' + @afilter
            + N'; proc_clause=' + @pclause + N'; sync_view=' + @sview + N'; view_clause=' + @vclause
            + N'; view_columns=' + @vcols + N'; view_has_column_b=' + @hasb + N'; article_columns=' + @acols
            + N'; last_call_recreated_view=' + @recreated + N'; last_call_changed_view=' + @changed,
            @subs, @vclause, @fc, @hasb, @changed, @too_long);
    END
    ELSE
        INSERT @res VALUES (@cid, @first, N'subscribed=' + @subs + N'; flags=' + @flags + N'; calls=' + @calls
                            + N'; state not readable (transaction doomed or closed by the refused call)',
                            @subs, NULL, NULL, NULL, NULL, 0);
    WHILE @@TRANCOUNT > 0 ROLLBACK;
    FETCH cc INTO @cid, @pub, @art, @vw, @flt, @flags;
END;
CLOSE cc; DEALLOCATE cc;

SELECT CAST(N'R|' + cid + N'|' + result + N'|' + REPLACE(detail, N'|', N'/') AS nvarchar(4000)) FROM @res
ORDER BY CASE WHEN cid LIKE '%s' THEN 1 ELSE 0 END, cid;
SELECT 'R|TOTAL|' + CONVERT(varchar(10), COUNT(*)) FROM @res;

-- Assertions: every failure is listed in one error, which the runner's uncaught guard rejects.
DECLARE @bad nvarchar(2000) = N'';
IF (SELECT COUNT(*) FROM @res) <> 16
    SET @bad += N' rows=' + CONVERT(nvarchar(10), (SELECT COUNT(*) FROM @res)) + N' (expected 16);';
IF EXISTS (SELECT 1 FROM @res WHERE too_long > 0)
    SET @bad += N' a view or filter procedure definition is longer than 4000 characters;';
IF EXISTS (SELECT 1 FROM @res WHERE subscribed <> CASE WHEN cid LIKE '%s' THEN N'yes' ELSE N'no' END)
    SET @bad += N' a row of one set has the subscription state of the other;';
IF NOT EXISTS (SELECT 1 FROM @res WHERE cid = 'F2' AND changed = N'no')
    SET @bad += N' F2 changed the view (expected: the view stays on its old clause);';
IF NOT EXISTS (SELECT 1 FROM @res WHERE cid = 'F2s' AND changed = N'no')
    SET @bad += N' F2s changed the view (expected: the view stays on its old clause);';
IF NOT EXISTS (SELECT 1 FROM @res WHERE cid = 'F4' AND filter_clause = N'NULL')
    SET @bad += N' F4 did not set filter_clause to NULL;';
IF NOT EXISTS (SELECT 1 FROM @res WHERE cid = 'F4s' AND filter_clause = N'NULL')
    SET @bad += N' F4s did not set filter_clause to NULL;';
IF NOT EXISTS (SELECT 1 FROM @res WHERE cid = 'F6' AND has_b = N'yes')
    SET @bad += N' F6 removed column b from the view (measured before: without a subscription sp_articlecolumn does not rebuild it);';
IF NOT EXISTS (SELECT 1 FROM @res WHERE cid = 'F6s' AND has_b = N'no')
    SET @bad += N' F6s left column b in the view (measured before: with a subscription sp_articlecolumn rebuilds it);';
IF @bad <> N''
    RAISERROR (N'14-filter-view: assertion failed:%s', 16, 1, @bad);
GO
