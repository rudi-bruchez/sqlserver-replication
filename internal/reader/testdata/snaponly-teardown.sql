-- Removes what snaponly-setup.sql creates; idempotent.
SET NOCOUNT ON;
USE master;
DECLARE @errors nvarchar(max) = N'';
BEGIN TRY
    IF DB_ID(N'm_snaponly') IS NOT NULL
       AND EXISTS (SELECT 1 FROM sys.databases WHERE name = N'm_snaponly' AND is_published = 1)
    BEGIN
        -- Dynamic: the batch must compile when the database does not exist.
        EXEC (N'USE m_snaponly;
IF EXISTS (SELECT 1 FROM dbo.syspublications WHERE name = N''m_so'')
    EXEC sp_droppublication @publication = N''m_so'';');
        EXEC sp_replicationdboption @dbname = N'm_snaponly', @optname = N'publish', @value = N'false';
    END;
END TRY
BEGIN CATCH
    SET @errors += N'unpublishing m_snaponly: ' + ERROR_MESSAGE() + NCHAR(10);
END CATCH;
BEGIN TRY
    IF DB_ID(N'm_snaponly') IS NOT NULL
    BEGIN
        ALTER DATABASE m_snaponly SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
        DROP DATABASE m_snaponly;
    END;
END TRY
BEGIN CATCH
    SET @errors += N'DROP DATABASE m_snaponly: ' + ERROR_MESSAGE() + NCHAR(10);
END CATCH;
IF @errors <> N''
    THROW 50000, @errors, 1;
