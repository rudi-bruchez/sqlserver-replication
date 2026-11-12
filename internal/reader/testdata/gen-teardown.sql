-- Removes what gen-setup.sql creates. Each step is in its own TRY so that the
-- rest runs when one fails; the errors are returned at the end.
SET NOCOUNT ON;
USE master;
DECLARE @errors nvarchar(max) = N'';
DECLARE @srv sysname = @@SERVERNAME;
BEGIN TRY
    IF EXISTS (SELECT 1 FROM Sales.dbo.syspublications WHERE name = N'm_gen')
        EXEC Sales.sys.sp_dropsubscription @publication = N'm_gen', @subscriber = @srv, @destination_db = N'm_gsub', @article = N'all';
END TRY
BEGIN CATCH
    SET @errors += N'sp_dropsubscription: ' + ERROR_MESSAGE() + NCHAR(10);
END CATCH;
BEGIN TRY
    IF EXISTS (SELECT 1 FROM Sales.dbo.syspublications WHERE name = N'm_gen')
        EXEC Sales.sys.sp_droppublication @publication = N'm_gen';
END TRY
BEGIN CATCH
    SET @errors += N'sp_droppublication: ' + ERROR_MESSAGE() + NCHAR(10);
END CATCH;
BEGIN TRY
    IF DB_ID(N'm_gsub') IS NOT NULL
    BEGIN
        ALTER DATABASE m_gsub SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
        DROP DATABASE m_gsub;
    END;
END TRY
BEGIN CATCH
    SET @errors += N'DROP DATABASE m_gsub: ' + ERROR_MESSAGE() + NCHAR(10);
END CATCH;
BEGIN TRY
    IF OBJECT_ID(N'Sales.dbo.m_gt1') IS NOT NULL
        EXEC Sales.sys.sp_executesql N'DROP TABLE dbo.m_gt1';
END TRY
BEGIN CATCH
    SET @errors += N'DROP TABLE dbo.m_gt1: ' + ERROR_MESSAGE() + NCHAR(10);
END CATCH;
IF @errors <> N''
    THROW 50000, @errors, 1;
