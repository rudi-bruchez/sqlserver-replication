-- Article storage measurements (lab/README.md, "Measured"). Run after setup.sql.
-- Creates the publication Probe in Sales, with no subscription, then drops it.
SET NOCOUNT ON;
USE Sales;
GO
CREATE TABLE dbo.M1 (id int PRIMARY KEY, a int, b int);
CREATE TABLE dbo.M2 (id int PRIMARY KEY, a int, b int);
CREATE TABLE dbo.M3 (id int PRIMARY KEY, a int, b int);
CREATE TABLE dbo.M4 (id int PRIMARY KEY, a int, b int);
CREATE TABLE dbo.M5 (id int PRIMARY KEY, a int, b int);
GO
EXEC sp_addpublication @publication = N'Probe', @status = N'active',
     @independent_agent = N'true', @immediate_sync = N'true';
GO
-- 1. Without sp_addpublication_snapshot, MSsnapshot_agents still has a row,
--    with local_job = 0 and a job_id that does not exist in msdb.
SELECT 'snapshot agent row' AS measure, a.local_job,
       CASE WHEN j.job_id IS NULL THEN 'missing' ELSE 'exists' END AS job
FROM distribution.dbo.MSsnapshot_agents AS a
LEFT JOIN msdb.dbo.sysjobs AS j ON j.job_id = CONVERT(uniqueidentifier, a.job_id)
WHERE a.publication = N'Probe';
GO
-- 2. Default schema_option of a table article: 0x30073, not Learn's 0x30F3.
EXEC sp_addarticle @publication = N'Probe', @article = N'M1', @source_owner = N'dbo', @source_object = N'M1';
-- 3. schema_option 0x8 (timestamp as timestamp) sets status 0x8 and 0x20.
EXEC sp_addarticle @publication = N'Probe', @article = N'M2', @source_owner = N'dbo', @source_object = N'M2',
     @schema_option = 0x000000000003007B;
-- 4. A filter clause given to sp_addarticle is stored without a filter procedure.
EXEC sp_addarticle @publication = N'Probe', @article = N'M3', @source_owner = N'dbo', @source_object = N'M3',
     @filter_clause = N'a > 0';
-- 5. sp_articlefilter and sp_articleview with names keep type 1 (logbased).
EXEC sp_addarticle @publication = N'Probe', @article = N'M4', @source_owner = N'dbo', @source_object = N'M4';
EXEC sp_articlefilter @publication = N'Probe', @article = N'M4', @filter_name = N'FLTR_M4', @filter_clause = N'a > 0';
EXEC sp_articleview @publication = N'Probe', @article = N'M4', @view_name = N'V_M4', @filter_clause = N'a > 0';
-- 6. A column filter changes neither type nor status.
EXEC sp_addarticle @publication = N'Probe', @article = N'M5', @source_owner = N'dbo', @source_object = N'M5';
EXEC sp_articlecolumn @publication = N'Probe', @article = N'M5', @column = N'b', @operation = N'drop';
GO
SELECT a.name, a.type, a.status, a.schema_option, a.filter_clause,
       OBJECT_NAME(NULLIF(a.filter, 0)) AS filter_proc, OBJECT_NAME(a.sync_objid) AS sync_object,
       a.ins_cmd, a.upd_cmd, a.del_cmd
FROM dbo.sysarticles AS a JOIN dbo.syspublications AS p ON p.pubid = a.pubid
WHERE p.name = N'Probe' ORDER BY a.name;
GO
-- 7. Errors, expected: sp_articlefilter without @filter_name (14043), and an
--    update command without its procedure name (15251).
BEGIN TRY
    EXEC sp_articlefilter @publication = N'Probe', @article = N'M1', @filter_clause = N'a > 0';
END TRY BEGIN CATCH SELECT 'articlefilter without name' AS measure, ERROR_NUMBER() AS error; END CATCH;
BEGIN TRY
    EXEC sp_changearticle @publication = N'Probe', @article = N'M1', @property = N'upd_cmd', @value = N'SCALL';
END TRY BEGIN CATCH SELECT 'upd_cmd SCALL without procedure' AS measure, ERROR_NUMBER() AS error; END CATCH;
GO
-- 8. sysschemaarticles.pre_creation_cmd for the default 'drop': 1, as in sysarticles.
SELECT 'schema article drop' AS measure, name, pre_creation_cmd FROM dbo.sysschemaarticles WHERE name = N'vCustomerFR';
GO
EXEC sp_droppublication @publication = N'Probe';
DROP TABLE dbo.M1, dbo.M2, dbo.M3, dbo.M4, dbo.M5;
GO
