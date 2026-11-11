-- Removes what pull-setup.sql creates, subscriber first
-- (lab/campaign/08-pull.sh, P3.subscriber-first). Each step is in its own TRY
-- so that the rest runs when one fails; the errors are returned at the end.
SET NOCOUNT ON;
-- The setup leaves the session in m_psub, which could not be dropped.
USE master;
DECLARE @errors nvarchar(max) = N'';
DECLARE @srv sysname = @@SERVERNAME;
BEGIN TRY
    IF OBJECT_ID(N'm_psub.dbo.MSreplication_subscriptions', N'U') IS NOT NULL
        EXEC m_psub.sys.sp_droppullsubscription @publisher = @srv, @publisher_db = N'Sales', @publication = N'm_pp';
END TRY
BEGIN CATCH
    SET @errors += N'sp_droppullsubscription: ' + ERROR_MESSAGE() + NCHAR(10);
END CATCH;
BEGIN TRY
    IF EXISTS (SELECT 1 FROM Sales.dbo.syspublications WHERE name = N'm_pp')
        EXEC Sales.sys.sp_dropsubscription @publication = N'm_pp', @subscriber = @srv, @destination_db = N'm_psub', @article = N'all';
END TRY
BEGIN CATCH
    SET @errors += N'sp_dropsubscription: ' + ERROR_MESSAGE() + NCHAR(10);
END CATCH;
BEGIN TRY
    IF EXISTS (SELECT 1 FROM Sales.dbo.syspublications WHERE name = N'm_pp')
        EXEC Sales.sys.sp_droppublication @publication = N'm_pp';
END TRY
BEGIN CATCH
    SET @errors += N'sp_droppublication: ' + ERROR_MESSAGE() + NCHAR(10);
END CATCH;
BEGIN TRY
    IF DB_ID(N'm_psub') IS NOT NULL
    BEGIN
        ALTER DATABASE m_psub SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
        DROP DATABASE m_psub;
    END;
END TRY
BEGIN CATCH
    SET @errors += N'DROP DATABASE m_psub: ' + ERROR_MESSAGE() + NCHAR(10);
END CATCH;
BEGIN TRY
    IF OBJECT_ID(N'Sales.dbo.m_pt1') IS NOT NULL
        EXEC Sales.sys.sp_executesql N'DROP TABLE dbo.m_pt1';
END TRY
BEGIN CATCH
    SET @errors += N'DROP TABLE dbo.m_pt1: ' + ERROR_MESSAGE() + NCHAR(10);
END CATCH;
IF @errors <> N''
    THROW 50000, @errors, 1;
