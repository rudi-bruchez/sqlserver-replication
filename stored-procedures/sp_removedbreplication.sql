SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_removedbreplication]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_removedbreplication] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_removedbreplication]
	@dbname [sysname],
	@type [nvarchar](5)
WITH EXECUTE AS CALLER
AS
set nocount on
    declare @retcode int
    declare @proc  nvarchar(255)
    
    /*
    ** Security Check: require sysadmin
    */
    IF (ISNULL(IS_SRVROLEMEMBER('sysadmin'),0) = 0)
    BEGIN
        RAISERROR(21089,16,-1) 
        RETURN (1)
    END
    
    if @dbname is NULL
        select @dbname = db_name()

    IF LOWER(@type collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('merge', 'tran', 'both')
    BEGIN
    	RAISERROR(22551, 16, -1, @type)
    	RETURN (1)
    END
    
    if (convert(sysname,DATABASEPROPERTYEX(@dbname,'status'))  = 'ONLINE')
    begin
        exec @retcode = sys.sp_MSremovedbreplication_internal @dbname = @dbname,@type = @type,@ignore_distributor = 1

	    -- does brute force clean up for merge
	    IF LOWER(@type collate SQL_Latin1_General_CP1_CS_AS) IN ('merge', 'both')
	    begin
            SELECT @proc = quotename(@dbname) + N'.sys.sp_MSremovedb_merge_replication_brute_force'	
	   	    exec @retcode = @proc
	    end

		IF LOWER(@type collate SQL_Latin1_General_CP1_CS_AS) = 'both'
		BEGIN
			-- drop replication symetrickey
			-- note that since this is brute force we will not confirm 
			-- whether or not replication is still enabled in the db
			SELECT @proc = QUOTENAME(@dbname) + N'.sys.sp_dropreplsymmetrickey'
		    EXEC @retcode = @proc @check_replication = 0, @throw_error = 0
		END
		ELSE
		BEGIN
			-- drop replication symetrickey
			-- in this case since we are only dropping one merge/tran it's possibe
			-- that we still need the symetric key... so in this case we will check
			SELECT @proc = QUOTENAME(@dbname) + N'.sys.sp_dropreplsymmetrickey'
		    EXEC @retcode = @proc @check_replication = 1, @throw_error = 0
		END
    end
    else
    begin 
        exec @retcode  = sys.sp_MSrepl_clean_replication_bit @dbname=@dbname,@type=@type	     
    end
    

    if @@error <> 0 select @retcode = 1
    return @retcode

GO
GRANT EXECUTE ON [sys].[sp_removedbreplication] TO [public] AS [dbo]
GO
