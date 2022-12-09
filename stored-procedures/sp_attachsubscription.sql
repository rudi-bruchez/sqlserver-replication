SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_attachsubscription]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_attachsubscription] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_attachsubscription]
	@dbname [sysname],
	@filename [nvarchar](260),
	@subscriber_security_mode [int],
	@subscriber_login [sysname],
	@subscriber_password [sysname],
	@distributor_security_mode [int],
	@distributor_login [sysname],
	@distributor_password [sysname],
	@publisher_security_mode [int],
	@publisher_login [sysname],
	@publisher_password [sysname],
	@job_login [nvarchar](257),
	@job_password [sysname],
	@db_master_key_password [nvarchar](524)
WITH EXECUTE AS CALLER
AS
begin
    SET NOCOUNT ON
    -- Declarations.
    declare @cmd nvarchar(4000)
                ,@retcode int
                ,@copy_created bit
                ,@exists bit
                ,@sa_login sysname

    select @retcode = 0
            ,@copy_created = 0
            ,@exists = 0

    -- Warn about the parameters no longer being used
    IF @subscriber_login IS NOT NULL
        OR @subscriber_password IS NOT NULL
        OR (@subscriber_security_mode IS NOT NULL
        AND @subscriber_security_mode != 1)
    BEGIN
        -- The subscriber security parameter(s) have been deprecated and should no longer be used. See the 'sp_attachsubscription' documentation for more information.
        RAISERROR(21827, 10, -1, 'subscriber security', 'sp_attachsubscription')

        SELECT @subscriber_security_mode = NULL,
                @subscriber_login = NULL,
                @subscriber_password = NULL
    END

    -- Check to make sure the database does not exists.
    if exists (select * from master.dbo.sysdatabases where name = @dbname collate database_default)
    begin
        raiserror(20621, 16, -1, @dbname)
        return (1)
    end

    -- Only sysadmin can do this
    if (isnull(is_srvrolemember('sysadmin'),0) = 0)
    begin
        raiserror(21089,16,-1)
        return (1)        
    end 

    -- Check to see if users has permissions to create database
    -- permissions() have to be run in master to return create db permission.
    -- declare @pm int
    -- exec @retcode = master.sys.sp_executesql N'select @pm = permissions()', N'@pm int output', @pm output
    -- if @@error <> 0 or @retcode <> 0
    --     return 1
    -- if @pm & 1 = 0
    -- begin
    --     raiserror(20618, 16, -1)
    --     return 1
    -- end

    -- Decompress the file
    -- We have to copy the file to another location first. 
    -- (cannot use source as destination')
    declare @temp_copy nvarchar(260)
    declare @file_dir nvarchar(260)
    declare @file_name nvarchar(260)
    declare @dir_cmd nvarchar(260)
    declare @pathSeparator nvarchar(2)
    
    select @pathSeparator = CAST(SERVERPROPERTY('pathseparator') as nvarchar(2))

    -- Set @drive_cmd if needed 
    -- Set temp copy to be the file directory first
    -- Note @file_dir includes the path separator
    if (charindex(@pathSeparator, @filename, 1) = 0)
    begin
        select @file_dir = ''
        select @file_name = @filename
    end
    else
    begin
        select @file_dir = left(@filename,len(@filename) + 1 - 
            charindex(@pathSeparator, reverse(@filename), 1))
        select @file_name = right(@filename, len(@filename) - len(@file_dir))
    end
    -- Get guid name
    declare @guid_name nvarchar(36)
    select @guid_name =  convert (nvarchar(36), newid())
    select @temp_copy = @file_dir + @guid_name + '.tmp'


    -- copy file
    begin try
        EXEC xp_copy_file @filename, @temp_copy
    end try
    begin catch
        set @retcode = 1
    end catch
    if @retcode <> 0
    begin
        raiserror(21248, 16, -1, @filename)
        select @retcode = 1
        goto Cleanup
    end    

    exec @retcode = sys.sp_MSget_file_existence @temp_copy, @exists output
    if @@error <> 0 or @retcode <> 0
    begin
        select @retcode = 1
        goto Cleanup
    end
    if @exists = 0
    begin
        raiserror(21247, 16, -1, @temp_copy)        
        select @retcode = 1
        goto Cleanup
    end

    select @copy_created = 1

    -- decompress
    exec @retcode = sys.xp_unpackcab 
        @cabfilename = @temp_copy,
        @destination_folder = @file_dir,
        @verbose_level = 0,
        @destination_file = @file_name,
        @suppress_messages = 1
        
    if @@error <> 0 
    begin
        select @retcode = 1
        goto Cleanup
    end

    if @retcode in (1030,1029,2005)
    begin
        raiserror(20609, 16, -1, @filename)
        select @retcode = 1
        goto Cleanup
    end    
    else if @retcode <> 0
    -- re-issue the command to get errors
    begin
        exec @retcode = sys.xp_unpackcab 
            @cabfilename = @temp_copy,
            @destination_folder = @file_dir,
            @verbose_level = 0,
            @destination_file = @file_name,
            @suppress_messages = 0
        select @retcode = 1
        goto Cleanup
    end

    -- Attach
    exec @retcode = sys.sp_attach_single_file_db
        @dbname = @dbname,
        @physname = @filename
    if @retcode<>0 or @@error<>0
    begin
        raiserror(21248, 16, -1, @filename)
        select @retcode = 1
        goto Cleanup
    end

    if isnull(is_srvrolemember('sysadmin'), 0) <> 0
    begin
        select @sa_login = SUSER_SNAME(0x01)
        select @cmd = quotename(@dbname) + '.dbo.sp_changedbowner'
        exec @retcode = @cmd @sa_login
        if @retcode<>0 or @@error<>0
        begin
            select @retcode = 1
            goto Cleanup
        end
    end

    -- Prepare the database for detach. 2 things will be done
    -- 1. Set a flag to indicate that this is a prepare sub db for detach
    -- 2. For merge, create table to store dbo.sysservers info for later fixing up after attach
    select @cmd = quotename(@dbname) + '.sys.sp_MSrestore_sub'
    exec @retcode = @cmd
        @subscriber_security_mode = @subscriber_security_mode,    
        @subscriber_login = @subscriber_login,
        @subscriber_password = @subscriber_password,
        @distributor_security_mode = @distributor_security_mode,
		@distributor_login = @distributor_login,
		@distributor_password = @distributor_password,
		@publisher_security_mode = @publisher_security_mode,
		@publisher_login = @publisher_login,
		@publisher_password = @publisher_password,
		@job_login = @job_login,
		@job_password = @job_password,
		@db_master_key_password	= @db_master_key_password

    if @retcode<>0 or @@error<>0
    begin
        select @retcode = 1
        goto Cleanup
    end
	
Cleanup:
    if @retcode <> 0
    begin
        -- The files will be deleted if some thing failed. 
        if exists (select * from master.dbo.sysdatabases where name = @dbname collate database_default)
            begin
                select @cmd = 'drop database ' + quotename(@dbname)
                exec (@cmd)
            end
    end

    if @temp_copy is not null
    begin
        -- Restore the original file, ignore errors
        if @retcode <> 0 and @copy_created = 1
        begin
            EXEC xp_copy_file @temp_copy, @filename
        end

        -- Delete the temp file.
        EXEC xp_delete_files @temp_copy
    end

    return @retcode
end
GO
GRANT EXECUTE ON [sys].[sp_attachsubscription] TO [public] AS [dbo]
GO
