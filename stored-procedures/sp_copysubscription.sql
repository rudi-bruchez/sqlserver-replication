SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_copysubscription]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_copysubscription] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_copysubscription]
	@filename [nvarchar](260),
	@temp_dir [nvarchar](260),
	@overwrite_existing_file [bit]
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON

    /*
    ** Declarations.
    */
    declare @cmd nvarchar(4000)
    declare @retcode int
    declare @data_path nvarchar(260)
    declare @subscriber_server sysname
    declare @subscriber_db        sysname
    declare @backup_path nvarchar(260)
    declare @temp_data_path nvarchar(260)
    declare @temp_log_path nvarchar(260)
    declare @retention            int
    declare @retention_period_unit tinyint
    declare @retention_date       datetime
    declare @pubid                 uniqueidentifier
    declare @has_hws            bit
    declare @has_lws            bit
    declare @METADATA_TYPE_InsertLightweight tinyint
    declare @METADATA_TYPE_UpdateLightweight tinyint
    declare @METADATA_TYPE_DeleteLightweight tinyint
    declare @REPLICA_STATUS_BeforeRestore tinyint
    declare @lightweight_subscription tinyint
    declare @pathSeparator nvarchar(2)

    /*
    * Initializations
    */
    select @retcode = 0
    select @subscriber_server = @@SERVERNAME
    select @subscriber_db = db_name()
    set @has_hws= 0
    set @has_lws= 0
    set @METADATA_TYPE_InsertLightweight= 7
    set @METADATA_TYPE_UpdateLightweight= 8
    set @METADATA_TYPE_DeleteLightweight= 10
    set @REPLICA_STATUS_BeforeRestore= 7
    set @lightweight_subscription = 3

    -- Security check
    -- Only sysadmin can do this
    if (isnull(is_srvrolemember('sysadmin'),0) = 0)
    begin
        raiserror(21089,16,-1)
        return (1)
    end

    -- We only support single file attach. Check to make sure
    -- there are only 2 files, one data file and one log file
    if (select count(*) from sysfiles) > 2
    begin
        raiserror(21212,16, -1)
        return 1
    end

    /* Make sure all tran sub allows attach */
    declare @publication                 sysname
    declare @publisher                    sysname
    declare @tran_found                    bit
    declare @merge_found                bit
    select @tran_found = 0
    select @merge_found = 0

    if object_id('MSsubscription_agents') is not NULL
    begin
        set @publisher = NULL
        -- Not using @publication because share agent case.
        select top 1 @publisher = publisher from MSsubscription_agents where
            allow_subscription_copy = 0
        IF @publisher is not null
        BEGIN
            RAISERROR(21236, 16, -1, @publisher)
            RETURN (1)
        END

        set @publisher = null
        select top 1 @publisher = publisher from MSreplication_subscriptions where
            subscription_type = 0
        IF @publisher is not null
        BEGIN
            RAISERROR(21237, 16, -1, @publisher)            
            RETURN (1)
        END
        if exists (select * from MSsubscription_agents)
            select @tran_found = 1
    end

    set @publication= NULL

    /* 
    ** Make sure all merge subscriptions in the current database 
    ** have allow_subscription_copy set to TRUE
    ** and there are no push subscriptions. 
    */
    if object_id('sysmergepublications') is not NULL
    begin
        -- Make sure all subscriptions allow to be copied
        select top 1 @publication = p.name from dbo.sysmergepublications p, dbo.sysmergesubscriptions s
            where p.allow_subscription_copy = 0 and p.pubid = s.pubid and s.db_name = @subscriber_db and
                  UPPER(s.subscriber_server) = UPPER(@subscriber_server)
        IF @publication is not null
        BEGIN
            RAISERROR (21204, 16, -1, @publication)    
            RETURN (1)
        END

        -- Make sure there are no push subscriptions
        select top 1 @publication = p.name from dbo.sysmergepublications p, 
            dbo.sysmergesubscriptions s where
            p.pubid = s.pubid and
            db_name = db_name() collate database_default and 
            subscriber_server = convert(nvarchar(4000), SERVERPROPERTY('ServerName')) collate database_default  and
            s.subscription_type = 0
        IF @publication is not null
        BEGIN
            RAISERROR(21238, 16, -1, @publication)            
            RETURN (1)
        END

        -- Make sure no merge heavy-weight subscription has expired.
        declare PC_hws CURSOR LOCAL FAST_FORWARD for
            select DISTINCT p.name, p.pubid, p.retention, p.retention_period_unit
                from dbo.sysmergepublications p, dbo.sysmergesubscriptions s
                where s.subid <> s.pubid and s.pubid=p.pubid and 
                      s.subscription_type <> @lightweight_subscription
                for read only
        open PC_hws
        fetch PC_hws into @publication, @pubid, @retention, @retention_period_unit

        WHILE (@@fetch_status <> -1)
        BEGIN
            /* Compute the retention period cutoff dates per publication */
            if @retention is not NULL and @retention > 0
            begin
                set @retention_date= sys.fn_add_units_to_date(-@retention, @retention_period_unit, getdate())

                if not exists (select h.coldate from dbo.sysmergearticles a, dbo.MSmerge_genhistory h
                                    where (a.nickname = h.art_nick or h.art_nick=0)
                                          and h.coldate > @retention_date 
                                          and a.pubid = @pubid)
                begin
                    RAISERROR (21306, 16, -1, @publication)
                    return (1)
                end                                
            end
            
            fetch PC_hws into @publication, @pubid, @retention, @retention_period_unit
        END

        close PC_hws
        deallocate PC_hws

        -- Make sure no merge lightweight subscription has expired.
        declare PC_lws CURSOR LOCAL FAST_FORWARD for
            select DISTINCT p.name, p.pubid, p.retention, p.retention_period_unit
                from dbo.sysmergesubscriptions s, dbo.sysmergepublications p
                where s.status <> @REPLICA_STATUS_BeforeRestore and
                      s.subscription_type = @lightweight_subscription and
                      s.subid <> s.pubid and s.pubid=p.pubid
                for read only
        open PC_lws
        fetch PC_lws into @publication, @pubid, @retention, @retention_period_unit

        while (@@fetch_status <> -1)
        begin
            if @retention is not NULL and @retention > 0
            begin
                -- Check whether there are rows whose most recent local change was before the
                -- retention_date, but the change was not uploaded to the publisher yet.
                if exists (select * from dbo.MSmerge_rowtrack
                                where tablenick in (select nickname from dbo.sysmergearticles
                                                        where pubid=@pubid and
                                                              lightweight=1)
                                      and
                                      changetype in (@METADATA_TYPE_InsertLightweight,
                                                       @METADATA_TYPE_UpdateLightweight,
                                                       @METADATA_TYPE_DeleteLightweight)
                                      and
                                      1=sys.fn_MSrowispastretention(tablenick, changed, getdate())
                          )
                begin
                    RAISERROR (21306, 16, -1, @publication)
                    return (1)
                end                                
            end
            
            fetch PC_lws into @publication, @pubid, @retention, @retention_period_unit
        end
        close PC_lws
        deallocate PC_lws

        -- Does db contains subscriptions?
        if exists (select * from dbo.sysmergesubscriptions where subid <> pubid and 
            db_name = db_name() collate database_default and 
            subscriber_server = convert(nvarchar(4000), SERVERPROPERTY('ServerName')) collate database_default and
            status <> 7) -- REPLICA_STATUS_BeforeRestore
        begin
            select @merge_found = 1
        end
    end

    -- Error out if there is no subscription at all
    if @tran_found = 0 and @merge_found = 0
    begin
        raiserror(21239, 16 , -1)
        return (1)
    end


    if @overwrite_existing_file is null
        set @overwrite_existing_file = 0

    -- Check to see if the file already exists
    declare @exists bit

    if @overwrite_existing_file = 0
    begin
        exec @retcode = sys.sp_MSget_file_existence @filename, @exists output
        if @@error <> 0 or @retcode <> 0
            return 1
        if @exists <> 0 
        begin
            raiserror(21214, 16, -1, @filename)
            return 1
        end
    end

    -- Check to see if have write permissions to the file location.
    -- Try create the file
    -- Echo text can be anything.
    select @cmd = 'echo Subscription copy failed. > "' + sys.fn_escapecmdshellsymbolsremovequotes(@filename) collate database_default + '"'
    exec @retcode = master.dbo.xp_cmdshell @cmd, NO_OUTPUT
    if @@error <> 0 or @retcode <> 0
    begin
        raiserror(21247, 16, -1, @filename)
        select @retcode = 1
        goto Cleanup
    end    
    -- File should be created.
    exec @retcode = sys.sp_MSget_file_existence @filename, @exists output
    if @@error <> 0 or @retcode <> 0
    begin
        select @retcode = 1
        goto Cleanup
    end
    if @exists = 0
    begin
        raiserror(21247,16, -1, @filename)
        select @retcode = 1
        goto Cleanup
    end

    /*
    ** Get the MSSQL DATA path. Note that users can have a SQLDataRoot directory different from SQLPath
    */
    select @pathSeparator = CAST(SERVERPROPERTY('pathseparator') as nvarchar(2))
    if @temp_dir is null
    begin
        exec @retcode = sys.sp_MSget_setup_paths
            @data_path = @temp_dir output
        IF @retcode <> 0 or @@error <> 0
            return 1
        select @temp_dir = concat(@temp_dir, @pathSeparator, N'DATA', @pathSeparator)
    end
    else
    begin
        -- Check to make sure working dir is valid.
        exec @retcode = sys.sp_MSget_file_existence @temp_dir, @exists output
        if @@error <> 0 or @retcode <> 0
        begin
            select @retcode = 1
            goto Cleanup
        end
        if @exists = 0
        begin
            raiserror (21037, 16, -1, @temp_dir)        
            select @retcode = 1
            goto Cleanup
        end
        if substring(@temp_dir, len(@temp_dir), 1) <> @pathSeparator
            select @temp_dir = @temp_dir + @pathSeparator
    end

    -- Get temp db name
    -- Use a guid to avoid name colision.
    declare @dbname sysname
    select @dbname = db_name()
    declare @temp_db_name sysname
    declare @guid_name nvarchar(36)
    select @guid_name =  convert (nvarchar(36), newid())

    select @temp_db_name = 'repl_sub_restore_' + @guid_name

    select @backup_path = @temp_dir + @temp_db_name + '.bak'

    -- Create table used to signal attach or restored process to do different things
    if not exists (select * from sys.objects where name = 'MSreplication_restore_stage')
    begin 
        CREATE TABLE dbo.MSreplication_restore_stage
        (
            stage_id int -- not used for now
        )
        IF @@ERROR <> 0    return 1
        
        exec dbo.sp_MS_marksystemobject 'dbo.MSreplication_restore_stage'

    end

    -- First backup the database to the file given
    -- Overwrite the existing file with INIT option.
    BACKUP DATABASE @dbname TO DISK = @backup_path WITH INIT
    if @@error<> 0
    begin
        select @retcode = 1
        goto Cleanup
    end


    -- Restore it to a temporary working database
    -- Get phy data and log file name for the temp db
    select @temp_data_path = @temp_dir + @temp_db_name + '.mdf'
    select @temp_log_path = @temp_dir + @temp_db_name + '.ldf'

    -- Get the command
    select @cmd = 'restore database ' + quotename(@temp_db_name) + ' from disk = ' 
        + quotename(@backup_path,'''') + ' with replace, move '

    -- Get the logical file name for data file.
    select @cmd = @cmd + quotename(rtrim(name),'''') from sysfiles where
        (status & 0x40) = 0

    -- Use passed in filename as phy data file name for the temp db

    -- Use the passed in file as phy data file for the temp db
    select @cmd = @cmd + ' to ' + quotename(@temp_data_path,'''') + ', move '

    -- Get the logical file name for the log file
    select @cmd = @cmd + quotename(rtrim(name),'''') from sysfiles where
        (status & 0x40) <> 0

    -- Use the passed in file as phy file for the temp db
    select @cmd = @cmd + ' to ' + quotename(@temp_log_path,'''') + ' '
    exec (@cmd)
    if @@error<> 0
    begin
        select @retcode = 1
        goto Cleanup
    end

    -- Once we successfully restored, we delete to back up file to save disk space.
    if @backup_path is not null
    begin
        begin try
            EXEC xp_delete_file 0, @backup_path
        end try
        -- Ignore any failure to delete the file
        begin catch
        end catch
        set @backup_path = null
    end

    -- Prepare the database for detach. 2 things will be done
    -- 1. Set a flag to indicate that this is a prepare sub db for detach
    -- 2. For merge, create table to store dbo.sysservers info for later fixing up after attach
    select @cmd = quotename(@temp_db_name) + '.sys.sp_MSprepare_sub_for_detach'

    exec @retcode = @cmd @subscriber_server = @subscriber_server, @subscriber_db = @subscriber_db
    if @retcode<>0 or @@error<>0
    begin
        select @retcode = 1
        goto Cleanup
    end

    -- Shink the size of the temp db before detach
    DBCC SHRINKDATABASE (@temp_db_name, 10)
    if @@error <> 0
        goto Cleanup

    -- detach the database
    -- Wait for the db to be closed
    WAITFOR DELAY '00:00:00.500'
    exec @retcode = sys.sp_detach_db @temp_db_name
    if @retcode<>0 or @@error<>0
    begin
        select @retcode = 1
        goto Cleanup
    end

    -- Delete the log file to save disk space
    if @temp_log_path is not null
    begin
        EXEC xp_delete_files @temp_log_path
        set @temp_log_path = null
    end

    -- Compress the file
    exec @retcode = sys.xp_makecab
        @cabfilename = @filename,
        @compression_mode ='mszip',
        @verbose_level = 0,
        @filename1 = @temp_data_path
    if @retcode<>0 or @@error<>0
    begin
        select @retcode = 1
        goto Cleanup
    end


Cleanup:
    if exists (select * from sys.objects where name = 'MSreplication_restore_stage')
        drop table dbo.MSreplication_restore_stage

    if exists (select * from master.dbo.sysdatabases where name = @temp_db_name collate database_default)
    begin
        select @cmd = 'drop database ' + quotename(@temp_db_name)
        exec (@cmd)
    end

    -- No need to check the strings as xp_delete_files handles null/empty strings
    begin try
        EXEC xp_delete_files @backup_path, @temp_data_path, @temp_log_path

        if @retcode <> 0
        begin
            EXEC xp_delete_files @filename
        end
    end try
    -- Ignore any failures to clean up
    begin catch
    end catch

    return @retcode
GO
GRANT EXECUTE ON [sys].[sp_copysubscription] TO [public] AS [dbo]
GO
