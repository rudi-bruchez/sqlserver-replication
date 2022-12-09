SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_replicationdboption]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_replicationdboption] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_replicationdboption]
	@dbname [sysname],
	@optname [sysname],
	@value [sysname],
	@ignore_distributor [bit],
	@from_scripting [bit]
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON

    /*
    ** Declarations.
    */
    DECLARE @retcode      int,
                @optbit       int,
                @optbit_value int,				-- Desired value with the optbit mask
                @proc         nvarchar(512),
                @category     int,
                @value_bit    bit,
                @command  nvarchar(4000),
                @backup_proc nvarchar(1000),
                @testStr nvarchar(300),
                @num_mergedb int,
                @flush_proc nvarchar(300),
                @done_proc  nvarchar(300),
                @clearcache_proc  nvarchar(300),
                @containment tinyint


    select @optname = LOWER(@optname)
            ,@value   = LOWER(@value)
            ,@num_mergedb = null

    /*
    ** Security Check: require sysadmin
    */
    IF (ISNULL(IS_SRVROLEMEMBER(N'sysadmin'),0) = 0)
    BEGIN
        RAISERROR(21089,16,-1) 
        RETURN (1)
    END

    /*
    ** Parameter check
    ** @dbname
    */
    SELECT @category = category FROM master.dbo.sysdatabases WHERE
        name = @dbname collate database_default
    if @category is null
    BEGIN
        RAISERROR(15010, 16, -1, @dbname)
        RETURN(1)
    END

    SELECT @containment=containment FROM sys.databases WHERE
        name = @dbname collate database_default
    if @containment is null
    BEGIN
        RAISERROR(15010, 16, -1, @dbname)
        RETURN(1)
    END

    /*
    ** Parameter check
    ** @type
    */
    IF @optname is null or @optname NOT IN (N'publish',N'merge publish',N'subscribe',N'sync with backup'
        )
    BEGIN
        RAISERROR(14138,16,-1,@optname)
        RETURN(1)
    END

    -- Verify that this SKU is allowed to be a publisher
    if @optname in (N'publish',N'merge publish') and @value = N'true'
    begin
        exec @retcode = sys.sp_MSsku_allows_replication
        if @@error <> 0 return 1
        if @retcode <> 0
        begin
            raiserror(21106, 16, -1)
            return (1)
        end
    end

    /*
    ** Contained Database check (Replication is not yet supported on contained databases)
    ** If the specified database exists and is a contained database, then we error out.
    **
    */
    if @containment != 0
    BEGIN
        RAISERROR(12839, 16, -1, @dbname)
        RETURN(1)
    END

    /*
    ** Parameter check
    ** @value
    */
    IF @value NOT IN (N'true',N'false')
    BEGIN
      RAISERROR(14137,16,-1)
      RETURN(1)
    END
    
    /*
    **    If we're in a transaction, disallow this since it might make recovery
    **    impossible.
    **
    */
    IF @@trancount > 0 
    BEGIN
        RAISERROR(15002,16,-1,'sp_replicationdboption')
        RETURN(1)
    END
    
    IF @optname = N'publish'
    BEGIN
        SELECT @optbit = 1
        SELECT @proc = QUOTENAME(@dbname) + N'.sys.sp_MSpublishdb'
    END
    ELSE IF @optname = N'merge publish'
    BEGIN
        SELECT @optbit = 4
        SELECT @proc = QUOTENAME(@dbname) + N'.sys.sp_MSmergepublishdb'
    END
    ELSE IF @optname = N'subscribe'
    BEGIN
        SELECT @optbit = 2
    END
    ELSE IF @optname = N'sync with backup'
    BEGIN
        SELECT @optbit = 32
    END

    IF @value = N'true'
    begin
        SELECT @optbit_value = @optbit
        select @value_bit = 1
    end
    ELSE
    begin
        select @value_bit = 0
        SELECT @optbit_value = 0
    end

    /*
    ** Check if the option is set as required already
    */
    if (@category & @optbit) = @optbit_value
    BEGIN
        if @value = N'true'
            RAISERROR (14035, 10, -1, @optname, @dbname)        
        else
            RAISERROR (14037, 10, -1, @optname, @dbname)
        RETURN (1)
    END

    -- If turning on 'sync with backup', make sure 'publish' or 'dist' is turned on already.
    if  @optbit_value = 32 and (@category & 1 = 0 and @category & 16 = 0)
    begin
        raiserror(20019, 16, -1, 'sync with backup')
        return (1)
    end

    -- We do not allow turning on sync with backup mode at publishing db if the db is
    -- in simple recovery mode
    if  @optbit_value = 32 and @category & 1 <> 0 and 
        databasepropertyex(@dbname, 'recovery') = N'SIMPLE'
    begin
        raiserror(20622, 16, -1, 'sync with backup')
        return (1)
    end

    -- If turning off 'publish', turn off 'sync with backup' as well if the database
    -- is not a distribution database.
    if @optbit = 1 and @optbit_value = 0 and @category & 32 <> 0 and @category & 16 = 0
    begin
        EXEC @retcode =  sys.sp_replicationdboption   
            @dbname = @dbname,
            @optname = N'sync with backup',
            @value = N'false',
            @ignore_distributor = @ignore_distributor,
            @from_scripting = @from_scripting
        IF @@ERROR <> 0 or @retcode <> 0
        BEGIN
            GOTO UNDO
        END
    end

    -- if turning on 'sync with backup' a distribution database, initialize the backup lsns 
    -- to nulls, this should be done before the category bit is set.
    if @optbit_value = 32 and @category & 16 <> 0
    begin
        SELECT @backup_proc = QUOTENAME(@dbname) + N'.dbo.sp_MSrepl_init_backup_lsns'
        exec @retcode = @backup_proc
        if @@error <> 0 or @retcode <> 0
            goto UNDO
    end

    /*
    ** Prepare the required option
    */
    if @proc is not null
    begin
        if (@optname IN (N'publish',N'merge publish' ) and (@value = N'false'))
        begin
            --
            --check db state in try block, if failed, goto IGNORE so db can be unmarked (and dropped later)
            --avoid putting try block on sp_MSpublishdb as it may fail with other error within nested tran
            --
            BEGIN TRY
                SELECT @testStr = N'use '  + QUOTENAME(@dbname) + ' begin tran save tran test_read_write commit tran'
                exec (@testStr)
            END TRY
            BEGIN CATCH
                declare @number int
                        ,@sev int
                        ,@state int
                        ,@msg nvarchar(max)
                select @number = ERROR_NUMBER(), @sev = ERROR_SEVERITY(), @state = ERROR_STATE(), @msg = ERROR_MESSAGE()
                raiserror(14166, 11, 1, @number, @sev, @state, @msg)
                goto IGNORE
            END CATCH
        end
        EXEC @retcode = @proc @value = @value,
                                @ignore_distributor = @ignore_distributor
        IF @@ERROR <> 0 or @retcode <> 0
        BEGIN
            GOTO UNDO
        END
    end

IGNORE:
    -- Consider: Lock database using EXEC %%CurrentDatabase().Lock()??
    -- rmak: Doesn't seem necessary nor is the right thing to do as
    -- %%CurrentDatabase().Lock locks only the current database (master)
    /*
    ** Preparation succeeded. 
    ** Toggle the category bit in master.dbo.sysdatabases
    */
    IF @optname = N'publish'
    BEGIN
        -- clear dbtable fields
        -- no check for IsPublished here, as it is taken care of above
        if @value_bit = 0
			AND CONVERT(sysname,DATABASEPROPERTYEX(@dbname,'status'))  = N'READ_WRITE'
			AND HAS_DBACCESS(@dbname) = 1
			--if cdc is still enabled, don't call sp_repldone
			AND not exists(select * from sys.databases where db_id(@dbname) = database_id and is_cdc_enabled = 1)
        BEGIN
            SELECT @flush_proc = QUOTENAME(@dbname) + N'.sys.sp_replflush'
            SELECT @done_proc  = QUOTENAME(@dbname) + N'.sys.sp_repldone'
        
            exec @flush_proc
            exec @done_proc NULL, NULL, 0, 0, 1
            exec @flush_proc
        END
        EXEC %%DatabaseEx(Name = @dbname).SetPublished(Value = @value_bit)
    END    
    ELSE IF @optname = N'merge publish'
        EXEC %%DatabaseEx(Name = @dbname).SetMergePublished(Value = @value_bit)
    ELSE IF @optname = N'subscribe'
        EXEC %%DatabaseEx(Name = @dbname).SetSubscribed(Value = @value_bit)
    ELSE IF @optname = N'sync with backup'
        EXEC %%DatabaseEx(Name = @dbname).SetSyncWithBackup(Value = @value_bit)

    IF ((@optname = N'merge publish') or (@optname = N'publish')) 
    begin
        if (convert(sysname,DATABASEPROPERTYEX(@dbname,'status'))  = N'ONLINE')
        begin 
			-- sysreplservers needs to be refreshed when:
			-- 1. 'publish' or 'merge publish' is being set to true
			-- 2. 'publish' or 'merge publish' is being set to false and db is no longer published for either
			if(@value_bit = 1 
			or (@value_bit = 0 
					and(DatabasePropertyEx(@dbname, 'IsPublished') = 0)
					and (DatabasePropertyEx(@dbname, 'IsMergePublished') = 0)))
			begin
				SELECT @proc = QUOTENAME(@dbname) + N'.sys.sp_refreshreplsysservers'
				EXEC @retcode = @proc 
				IF @@ERROR <> 0 or @retcode <> 0
				    GOTO UNDO
			end
        end
    end

    if @optname = N'merge publish'
    begin
        if @value = N'true'
        begin            
            -- Set the 'startup' option for sp_MScleanupmergepublisher if the
            -- database is enabled for merge replication.  
            exec (N'use master
                    exec sys.sp_procoption N''sp_MScleanupmergepublisher'', N''startup'', N''true''')
        end
        else
        begin
            -- Reset the 'startup' option for sp_MScleanupmergepublisher if
            -- this is the last database that has its 'merge publish' option 
            -- disabled
            select @num_mergedb = count(*) from master.dbo.sysdatabases 
             where (category & 4) <> 0
            if @num_mergedb = 0
            begin
                exec (N'use master
                    exec sys.sp_procoption N''sp_MScleanupmergepublisher'', N''startup'', N''false''')
            end
        end
    end

    IF ((@optname = N'merge publish') or (@optname = N'publish')) and (@value = N'true')
    BEGIN
        -- Add expired subscription cleanup job and alerts
        EXEC @retcode = sys.sp_MSrepl_add_expired_sub_cleanup_job

        IF @@ERROR <> 0 or @retcode <> 0
            GOTO UNDO
    END

    IF ((@optname = N'merge publish') or (@optname = N'publish')) and (@value = N'false')
    BEGIN
        -- Drop expired subscription cleanup job and alerts
        EXEC @retcode = sys.sp_MSrepl_drop_expired_sub_cleanup_job
        IF (@@ERROR != 0 OR @retcode != 0)
        	RETURN (1)
    END

	-- drop symetric keys if the database is online
	-- note that here on a failure we will throw an error
    IF CONVERT(sysname, DATABASEPROPERTYEX(@dbname,'status')) = N'ONLINE'
	BEGIN
	  	SELECT @proc = QUOTENAME(@dbname) + N'.sys.sp_dropreplsymmetrickey'
	  	
		EXEC @retcode = @proc @check_replication = 1, @throw_error = 1
		IF (@@ERROR != 0 OR @retcode != 0)
        	RETURN (1)
	END
	
    /*
    **    ??? 
    ** CHECKPOINT the database that was changed. Make the change
    ** effective immediatly
    */
    CHECKPOINT
    IF @@ERROR <> 0 
    BEGIN
        RETURN(1)
    END

     IF @optname = N'publish' and @value_bit = 0 and not exists(select * from sys.databases where db_id(@dbname) = database_id and is_cdc_enabled = 1)
     BEGIN
	SELECT @clearcache_proc = QUOTENAME(@dbname) + N'.sys.sp_replhelp'
	EXEC @clearcache_proc N'ClearDbArticleCache' --clear article cache for this database
	EXEC @clearcache_proc N'DisablePerDbHistoryCache' --clear DMV cache for this database
     END 

    
    RETURN(0)

UNDO:
    -- Create system table is not allowed in a multi-statement transactions.
    -- Drop the tables here
    IF @value = N'true'
        EXEC sys.sp_replicationdboption 
          @dbname     = @dbname,
          @optname     = @optname,
          @value     = N'false',
          @ignore_distributor = @ignore_distributor

    return(1)    
GO
GRANT EXECUTE ON [sys].[sp_replicationdboption] TO [public] AS [dbo]
GO
