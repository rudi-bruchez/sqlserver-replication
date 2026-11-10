-- Article storage measurements (lab/README.md rows 1 to 8), eight cases.
-- Builds the publication m_probe and the tables m_t1 to m_t5 in Sales, with no
-- subscription and no snapshot agent (case 1 measures exactly that), then drops
-- them. Run through lab/campaign.sh.
SET NOCOUNT ON;
USE Sales;
GO
DECLARE @r TABLE (id varchar(60), result nvarchar(200), detail nvarchar(1000));
DECLARE @e int, @m nvarchar(400);

BEGIN TRY
    CREATE TABLE dbo.m_t1 (id int PRIMARY KEY, a int, b int);
    CREATE TABLE dbo.m_t2 (id int PRIMARY KEY, a int, b int);
    CREATE TABLE dbo.m_t3 (id int PRIMARY KEY, a int, b int);
    CREATE TABLE dbo.m_t4 (id int PRIMARY KEY, a int, b int);
    CREATE TABLE dbo.m_t5 (id int PRIMARY KEY, a int, b int);
    EXEC sp_addpublication @publication = N'm_probe', @status = N'active',
         @independent_agent = N'true', @immediate_sync = N'true';
END TRY BEGIN CATCH
    INSERT @r VALUES ('SETUP', CONVERT(varchar(10), ERROR_NUMBER()), LEFT(ERROR_MESSAGE(), 400));
    IF @@TRANCOUNT > 0 ROLLBACK;
END CATCH;

-- 1. Without sp_addpublication_snapshot, MSsnapshot_agents still has a row,
--    with local_job = 0 and a job_id that does not exist in msdb.
BEGIN TRY
    INSERT @r
    SELECT 'A1.snapshot-agent-row', CONVERT(varchar(10), a.local_job),
           CASE WHEN j.job_id IS NULL THEN 'job missing' ELSE 'job exists' END
    FROM distribution.dbo.MSsnapshot_agents AS a
    LEFT JOIN msdb.dbo.sysjobs AS j ON j.job_id = CONVERT(uniqueidentifier, a.job_id)
    WHERE a.publication = N'm_probe';
    IF @@ROWCOUNT = 0 INSERT @r VALUES ('A1.snapshot-agent-row', 'no row', '');
END TRY BEGIN CATCH
    INSERT @r VALUES ('A1.snapshot-agent-row', CONVERT(varchar(10), ERROR_NUMBER()), LEFT(ERROR_MESSAGE(), 400));
END CATCH;

-- 2. Default schema_option of a table article: 0x30073, not Learn's 0x30F3.
BEGIN TRY
    EXEC sp_addarticle @publication = N'm_probe', @article = N'm_t1', @source_owner = N'dbo', @source_object = N'm_t1';
    INSERT @r SELECT 'A2.default-schema-option', CONVERT(varchar(18), schema_option, 1), 'status=' + CONVERT(varchar(10), status)
    FROM dbo.sysarticles WHERE name = N'm_t1';
END TRY BEGIN CATCH
    INSERT @r VALUES ('A2.default-schema-option', CONVERT(varchar(10), ERROR_NUMBER()), LEFT(ERROR_MESSAGE(), 400));
    IF @@TRANCOUNT > 0 ROLLBACK;
END CATCH;

-- 3. schema_option 0x8 (timestamp as timestamp) sets status 0x8 and 0x20.
BEGIN TRY
    EXEC sp_addarticle @publication = N'm_probe', @article = N'm_t2', @source_owner = N'dbo', @source_object = N'm_t2',
         @schema_option = 0x000000000003007B;
    INSERT @r SELECT 'A3.schema-option-0x8', 'status=' + CONVERT(varchar(10), status), 'schema_option=' + CONVERT(varchar(18), schema_option, 1)
    FROM dbo.sysarticles WHERE name = N'm_t2';
END TRY BEGIN CATCH
    INSERT @r VALUES ('A3.schema-option-0x8', CONVERT(varchar(10), ERROR_NUMBER()), LEFT(ERROR_MESSAGE(), 400));
    IF @@TRANCOUNT > 0 ROLLBACK;
END CATCH;

-- 4. A filter clause given to sp_addarticle is stored without a filter procedure.
BEGIN TRY
    EXEC sp_addarticle @publication = N'm_probe', @article = N'm_t3', @source_owner = N'dbo', @source_object = N'm_t3',
         @filter_clause = N'a > 0';
    INSERT @r SELECT 'A4.filter-clause-only', 'filter_proc=' + ISNULL(OBJECT_NAME(NULLIF(filter, 0)), 'none'),
           'filter_clause=' + CONVERT(nvarchar(200), filter_clause) + ' type=' + CONVERT(varchar(10), type)
    FROM dbo.sysarticles WHERE name = N'm_t3';
END TRY BEGIN CATCH
    INSERT @r VALUES ('A4.filter-clause-only', CONVERT(varchar(10), ERROR_NUMBER()), LEFT(ERROR_MESSAGE(), 400));
    IF @@TRANCOUNT > 0 ROLLBACK;
END CATCH;

-- 5. sp_articlefilter and sp_articleview with names keep type 1 (logbased).
BEGIN TRY
    EXEC sp_addarticle @publication = N'm_probe', @article = N'm_t4', @source_owner = N'dbo', @source_object = N'm_t4';
    EXEC sp_articlefilter @publication = N'm_probe', @article = N'm_t4', @filter_name = N'm_FLTR_t4', @filter_clause = N'a > 0';
    EXEC sp_articleview @publication = N'm_probe', @article = N'm_t4', @view_name = N'm_V_t4', @filter_clause = N'a > 0';
    INSERT @r SELECT 'A5.named-filter-and-view', 'type=' + CONVERT(varchar(10), type),
           'filter_proc=' + ISNULL(OBJECT_NAME(NULLIF(filter, 0)), 'none') + ' sync_object=' + ISNULL(OBJECT_NAME(sync_objid), 'none')
    FROM dbo.sysarticles WHERE name = N'm_t4';
END TRY BEGIN CATCH
    INSERT @r VALUES ('A5.named-filter-and-view', CONVERT(varchar(10), ERROR_NUMBER()), LEFT(ERROR_MESSAGE(), 400));
    IF @@TRANCOUNT > 0 ROLLBACK;
END CATCH;

-- 6. A column filter changes neither type nor status.
BEGIN TRY
    DECLARE @t0 int, @s0 int, @t1 int, @s1 int;
    EXEC sp_addarticle @publication = N'm_probe', @article = N'm_t5', @source_owner = N'dbo', @source_object = N'm_t5';
    SELECT @t0 = type, @s0 = status FROM dbo.sysarticles WHERE name = N'm_t5';
    EXEC sp_articlecolumn @publication = N'm_probe', @article = N'm_t5', @column = N'b', @operation = N'drop';
    SELECT @t1 = type, @s1 = status FROM dbo.sysarticles WHERE name = N'm_t5';
    INSERT @r VALUES ('A6.column-drop', CASE WHEN @t0 = @t1 AND @s0 = @s1 THEN 'unchanged' ELSE 'changed' END,
           'type ' + CONVERT(varchar(10), @t0) + ' to ' + CONVERT(varchar(10), @t1) + ', status ' + CONVERT(varchar(10), @s0) + ' to ' + CONVERT(varchar(10), @s1));
END TRY BEGIN CATCH
    INSERT @r VALUES ('A6.column-drop', CONVERT(varchar(10), ERROR_NUMBER()), LEFT(ERROR_MESSAGE(), 400));
    IF @@TRANCOUNT > 0 ROLLBACK;
END CATCH;

-- 7. Errors, expected: sp_articlefilter without @filter_name (14043), and an
--    update command without its procedure name (15251).
DECLARE @e1 int = 0, @e2 int = 0;
BEGIN TRY
    EXEC sp_articlefilter @publication = N'm_probe', @article = N'm_t1', @filter_clause = N'a > 0';
END TRY BEGIN CATCH SET @e1 = ERROR_NUMBER(); IF @@TRANCOUNT > 0 ROLLBACK; END CATCH;
BEGIN TRY
    EXEC sp_changearticle @publication = N'm_probe', @article = N'm_t1', @property = N'upd_cmd', @value = N'SCALL';
END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); IF @@TRANCOUNT > 0 ROLLBACK; END CATCH;
BEGIN TRY
    INSERT @r VALUES ('A7.expected-errors', CONVERT(varchar(10), @e1) + ',' + CONVERT(varchar(10), @e2),
           'sp_articlefilter without filter_name, then upd_cmd SCALL without a procedure');
END TRY BEGIN CATCH
    INSERT @r VALUES ('A7.expected-errors', CONVERT(varchar(10), ERROR_NUMBER()), LEFT(ERROR_MESSAGE(), 400));
END CATCH;

-- 8. sysschemaarticles.pre_creation_cmd for the default 'drop': 1, as in sysarticles
--    (read only, on the lab's own schema article).
BEGIN TRY
    INSERT @r SELECT 'A8.schema-article-drop', CONVERT(varchar(10), pre_creation_cmd), 'article ' + CONVERT(nvarchar(100), name)
    FROM dbo.sysschemaarticles WHERE name = N'vCustomerFR';
    IF @@ROWCOUNT = 0 INSERT @r VALUES ('A8.schema-article-drop', 'no row', '');
END TRY BEGIN CATCH
    INSERT @r VALUES ('A8.schema-article-drop', CONVERT(varchar(10), ERROR_NUMBER()), LEFT(ERROR_MESSAGE(), 400));
END CATCH;

SELECT CAST('R|' + id + '|' + result + '|' + detail AS nvarchar(4000)) FROM @r
UNION ALL SELECT 'R|TOTAL|' + CONVERT(varchar(10), COUNT(*)) FROM @r;
GO
-- Cleanup, in its own batch so that it runs even when the cases batch aborts.
USE Sales;
BEGIN TRY
    EXEC sp_droppublication @publication = N'm_probe';
END TRY BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
END CATCH;
DROP TABLE IF EXISTS dbo.m_t1, dbo.m_t2, dbo.m_t3, dbo.m_t4, dbo.m_t5;
GO
