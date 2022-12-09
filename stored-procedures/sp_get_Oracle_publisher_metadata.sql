SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_get_Oracle_publisher_metadata]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_get_Oracle_publisher_metadata] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_get_Oracle_publisher_metadata]
	@database_name [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
    set nocount on
    
    DECLARE @cmd			nvarchar(4000)
    DECLARE @retcode		int
    DECLARE @distbit		int
    DECLARE @publisher_type	sysname
    DECLARE @publisher		sysname
    DECLARE @quoteddb		sysname
    DECLARE @database		sysname
    DECLARE @nologgingtable int
    
    CREATE TABLE #MetadataCaptureLog
    (
		ID int IDENTITY,
		MsgType nvarchar(100),
		MsgTypeID int,        
		Time DateTime,
		Message nvarchar(max)
	)
    
    -- Error if not sysadmin
    IF NOT (is_srvrolemember('sysadmin') = 1)
    BEGIN
        RAISERROR('The stored procedure sp_get_Oracle_publisher_metadata may only be run by members of the fixed server role ''sysadmin''.',10,-1)
        RETURN(1)
    END

    SELECT @nologgingtable = 0
    SELECT @distbit = 16
    SELECT @database = sys.fn_replquotename(@database_name, '''') collate database_default
    SELECT @quoteddb = sys.fn_replquotename(@database_name, default) collate database_default
    
    -- Verify that database to be used as repository exists 
    IF NOT EXISTS (SELECT * FROM master.dbo.sysdatabases WHERE name = @database_name)
    BEGIN
        RAISERROR('The database %s to be used as a repository for Oracle publishing meta data does not exist.',10,-1, @database)
        RETURN(1)
    END
    
    -- Verify that the database to be used as a repository is not a distribution database.
    -- This is required to prevent the possibility of overwriting meta data on the running
    -- system.
    IF EXISTS (SELECT * FROM master.dbo.sysdatabases WHERE name = @database_name AND (category & @distbit) = @distbit )
    BEGIN
        RAISERROR('The database %s to be used as a repository for Oracle publishing meta data is a distribution database. This is not allowed. Choose another database as the repository.',10,-1, @database)
        RETURN(1)
    END
    
    SELECT @cmd = N'SELECT * FROM ' + @quoteddb + N'.dbo.MetadataCapture_Log WHERE 0 = 1'
    
    BEGIN TRY
		EXEC @retcode = sys.sp_executesql @cmd
    END TRY
    BEGIN CATCH
    	-- If table doesn't exist, set nologgingtable flag
    	SELECT @nologgingtable = 1
    END CATCH
    
    IF (@nologgingtable = 1)
    BEGIN
    	SELECT @cmd = N'SELECT * INTO ' + @quoteddb + N'.dbo.MetadataCapture_Log FROM #MetadataCaptureLog'
    	
   	    EXEC @retcode = sys.sp_executesql @cmd
   	    
   	    IF @retcode != 0 OR @@error != 0
   	    BEGIN
		    RETURN(1)
		END    
    	    	
    	EXEC sys.sp_log_repository_message N'Success', @cmd, @database_name
    END
    
    DROP TABLE #MetadataCaptureLog

    DECLARE hC  CURSOR LOCAL FAST_FORWARD FOR 
        SELECT srvname from master.dbo.sysservers sys, msdb.dbo.MSdistpublishers pub
        WHERE (sys.srvproduct = 'Oracle Gateway Replication' OR srvproduct = 'Oracle Replication')
          AND pub.publisher_type LIKE 'ORACLE%'
          AND UPPER(sys.srvname collate database_default) = UPPER(pub.name collate database_default)
    
    OPEN hC
    FETCH hC INTO @publisher
    WHILE (@@fetch_status <> -1)
    BEGIN
    
        SET @retcode = 0

        EXEC @retcode = sys.sp_MSrepl_getpublisherinfo
            @publisher = @publisher,
            @publisher_type = @publisher_type OUTPUT,
            @rpcheader = @cmd OUTPUT,
            @skipSecurityCheck	= 1

        IF @retcode = 0
        BEGIN

            SET @publisher = UPPER(@publisher) COLLATE DATABASE_DEFAULT
            SET @cmd = @cmd + N'sys.sp_MSrepl_get_Oracle_publisher_metadata'
            EXEC @retcode = @cmd
                @publisher,
                @database_name
        END
        
        FETCH hC INTO @publisher
    END
    CLOSE hC
    DEALLOCATE hC
    
    RETURN 
END
GO
GRANT EXECUTE ON [sys].[sp_get_Oracle_publisher_metadata] TO [public] AS [dbo]
GO
