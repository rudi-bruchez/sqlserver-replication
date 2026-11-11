-- Removes what pull-shared-setup.sql creates, subscriber first, each step in
-- its own TRY so that the rest runs; the errors are returned at the end. It
-- also runs before the setup, so every step is guarded.
SET NOCOUNT ON;
USE master;
DECLARE @errors nvarchar(max) = N'';
DECLARE @srv sysname = @@SERVERNAME;
-- One call for both publications: a reference to a table of m_pssub would
-- not compile once the database is gone.
BEGIN TRY
    IF OBJECT_ID(N'm_pssub.dbo.MSreplication_subscriptions', N'U') IS NOT NULL
        EXEC m_pssub.sys.sp_droppullsubscription @publisher = @srv, @publisher_db = N'Sales', @publication = N'all';
END TRY
BEGIN CATCH
    SET @errors += N'sp_droppullsubscription: ' + ERROR_MESSAGE() + NCHAR(10);
END CATCH;
-- sp_droppullsubscription leaves the shared agent's job behind: it has a
-- "non-standard name" (measured on the lab, SQL Server 2022 CU27). Its name
-- ends with the subscription database: -m_pssub-<guid>.
BEGIN TRY
    DECLARE @job uniqueidentifier;
    WHILE 1 = 1
    BEGIN
        SET @job = (SELECT TOP (1) job_id FROM msdb.dbo.sysjobs WHERE name LIKE N'%-m[_]pssub-%');
        IF @job IS NULL BREAK;
        EXEC msdb.dbo.sp_delete_job @job_id = @job;
    END;
END TRY
BEGIN CATCH
    SET @errors += N'sp_delete_job: ' + ERROR_MESSAGE() + NCHAR(10);
END CATCH;
BEGIN TRY
    IF EXISTS (SELECT 1 FROM Sales.dbo.syspublications WHERE name = N'm_ps1')
        EXEC Sales.sys.sp_dropsubscription @publication = N'm_ps1', @subscriber = @srv, @destination_db = N'm_pssub', @article = N'all';
END TRY
BEGIN CATCH
    SET @errors += N'sp_dropsubscription m_ps1: ' + ERROR_MESSAGE() + NCHAR(10);
END CATCH;
BEGIN TRY
    IF EXISTS (SELECT 1 FROM Sales.dbo.syspublications WHERE name = N'm_ps2')
        EXEC Sales.sys.sp_dropsubscription @publication = N'm_ps2', @subscriber = @srv, @destination_db = N'm_pssub', @article = N'all';
END TRY
BEGIN CATCH
    SET @errors += N'sp_dropsubscription m_ps2: ' + ERROR_MESSAGE() + NCHAR(10);
END CATCH;
BEGIN TRY
    IF EXISTS (SELECT 1 FROM Sales.dbo.syspublications WHERE name = N'm_ps1')
        EXEC Sales.sys.sp_droppublication @publication = N'm_ps1';
END TRY
BEGIN CATCH
    SET @errors += N'sp_droppublication m_ps1: ' + ERROR_MESSAGE() + NCHAR(10);
END CATCH;
BEGIN TRY
    IF EXISTS (SELECT 1 FROM Sales.dbo.syspublications WHERE name = N'm_ps2')
        EXEC Sales.sys.sp_droppublication @publication = N'm_ps2';
END TRY
BEGIN CATCH
    SET @errors += N'sp_droppublication m_ps2: ' + ERROR_MESSAGE() + NCHAR(10);
END CATCH;
BEGIN TRY
    IF DB_ID(N'm_pssub') IS NOT NULL
    BEGIN
        ALTER DATABASE m_pssub SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
        DROP DATABASE m_pssub;
    END;
END TRY
BEGIN CATCH
    SET @errors += N'DROP DATABASE m_pssub: ' + ERROR_MESSAGE() + NCHAR(10);
END CATCH;
BEGIN TRY
    IF OBJECT_ID(N'Sales.dbo.m_pst1') IS NOT NULL
        EXEC Sales.sys.sp_executesql N'DROP TABLE dbo.m_pst1';
    IF OBJECT_ID(N'Sales.dbo.m_pst2') IS NOT NULL
        EXEC Sales.sys.sp_executesql N'DROP TABLE dbo.m_pst2';
END TRY
BEGIN CATCH
    SET @errors += N'DROP TABLE: ' + ERROR_MESSAGE() + NCHAR(10);
END CATCH;
IF @errors <> N''
    THROW 50000, @errors, 1;
