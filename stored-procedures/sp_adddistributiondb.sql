SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_adddistributiondb]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_adddistributiondb] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_adddistributiondb]
	@database [sysname],
	@data_folder [nvarchar](255),
	@data_file [nvarchar](255),
	@data_file_size [int],
	@log_folder [nvarchar](255),
	@log_file [nvarchar](255),
	@log_file_size [int],
	@min_distretention [int],
	@max_distretention [int],
	@history_retention [int],
	@security_mode [int],
	@login [sysname],
	@password [sysname],
	@createmode [int],
	@from_scripting [bit],
	@deletebatchsize_xact [int],
	@deletebatchsize_cmd [int]
WITH EXECUTE AS CALLER
AS
BEGIN
    SET NOCOUNT ON
    -- Declarations.
    DECLARE @data_path nvarchar(512)
                ,@log_path nvarchar(512)
                ,@data_path_quoted_for_copy nvarchar(600)
                ,@log_path_quoted_for_copy nvarchar(600)
                ,@logical_data_file nvarchar(255)
                ,@logical_log_file nvarchar(255)
                ,@canneddbdata_file nvarchar(255)
                ,@canneddblog_file nvarchar(255)
                ,@filecopy_cmd nvarchar(4000)
                ,@file_exists bit
                ,@data_file_preexists int
                ,@log_file_preexists int
                ,@devnum int
                ,@retcode int
                ,@retcode2 int
                ,@agentname nvarchar(100)
                ,@command nvarchar (4000)
                ,@distbit int
                ,@install_path nvarchar(255)
                ,@mssql_data_path nvarchar(255)
                ,@on_clause nvarchar(1700)
                ,@logon_clause nvarchar(1700)
                ,@distproc nvarchar(512)
                ,@major_version int
                ,@db_exists bit
                ,@trunc_log_bit int
                ,@description nvarchar(100)
                ,@category_name sysname
                ,@createmode_attach int
                ,@createmode_noattach int
                ,@createmode_fordetach int
                ,@data_file_size_str nvarchar(20)
                ,@log_file_size_str nvarchar(20)
                ,@platform_nt binary
                ,@distributor_login sysname
                ,@model_data_size int
                ,@model_log_size int
                ,@containment tinyint
                ,@pathSeparator nvarchar(2)
                ,@distdb_in_secondary bit

	-- Security Check: require sysadmin
	IF (ISNULL(IS_SRVROLEMEMBER('sysadmin'),0) = 0)
	BEGIN
		RAISERROR(21089,16,-1) 
		RETURN (1)
	END

	-- Check to ensure a login is provided if security mode is SQL Server authentication.
	select @login = rtrim(ltrim(isnull(@login, '')))
	if @security_mode = 0 and @login = ''
	begin
		-- '@login cannot be null or empty when @security_mode is set to 0 (SQL Server authentication).'
		raiserror(21694, 16, -1, '@login', '@security_mode')
		return 1
	end
	
	select @model_data_size = sum (size)*8/1024 from sys.master_files where database_id = db_id('model') and type_desc = 'ROWS'
	select @model_log_size = sum (size)*8/1024 from sys.master_files where database_id = db_id('model') and type_desc = 'LOG'


	select @password = case when (@password = N'') then NULL else @password end
			,@data_folder = case when (@data_folder = N'') then NULL else @data_folder end
			,@log_folder = case when (@log_folder = N'') then NULL else @log_folder end
			,@platform_nt = 0x1
			-- on error, delete the data and log files only if they didn't pre-exist.
			-- by default, assume they pre-exist.
			,@data_file_preexists = 1
			,@log_file_preexists = 1
			,@file_exists = 0
			,@data_file_size_str = case when (isnull(@data_file_size, 4) < 5 ) and (@model_data_size < 5) then N'5 MB' 
														when (@model_data_size < isnull(@data_file_size, 5)) then cast(@data_file_size as nvarchar(10)) + N' MB'
														else cast(@model_data_size + 5 as nvarchar(10)) + N' MB'
											 end
			,@log_file_size_str = case when (isnull(@log_file_size, 0) < 1) and (@model_log_size < 1) then N'1 MB'
														when (@model_log_size < isnull(@log_file_size, 1)) then cast(@log_file_size as nvarchar(10)) + N' MB'
														else cast(@model_log_size + 1 as nvarchar(10)) + N' MB'
													end
	if @createmode not in (0, 1, 2)
	begin
		select @description = cast(@createmode as nvarchar)

		-- '@description' is not a valid value for the '@createmode' parameter. The value must be 0, 1, or 2.
		RAISERROR (21117, 16, -1, @description, '@createmode')
		return 1
	end

	-- option 0 to use distmdl.mdf/ldf is no longer in use
	if (@createmode = 0) 
		select @createmode = 1

	select @createmode_attach = 0
			,@createmode_noattach = 1
			,@createmode_fordetach = 2
			,@trunc_log_bit = 8
			,@distbit = 16

	if (@createmode <> @createmode_fordetach)
	begin
		-- Check if replication components are installed on this server
		exec @retcode = sys.sp_MS_replication_installed
		if (@retcode <> 1)
		begin
			return (1)
		end
		-- Check for invalid security modes
		IF @security_mode < 0 OR @security_mode > 1
		BEGIN
			RAISERROR(14109, 16, -1)
			RETURN (1)
		END
		IF ( ( @platform_nt != platform() & @platform_nt ) and @security_mode = 1)
		BEGIN
			RAISERROR(21038, 16, -1)
			RETURN (1)
		END
		-- Check for invalid retention values 
		IF @min_distretention < 0 OR @max_distretention < 0 OR @history_retention < 0
		BEGIN
			RAISERROR(14106, 16, -1)
			RETURN (1)
		END
		IF @min_distretention > @max_distretention
		BEGIN
			RAISERROR(14107, 16, -1) 
			RETURN (1)
		END
		--Check for invalid delete batch size
		IF (@deletebatchsize_xact IS NULL OR @deletebatchsize_xact < 0
			OR @deletebatchsize_cmd IS NULL OR @deletebatchsize_cmd < 0)
		BEGIN
			raiserror(22120,16,-1)
			RETURN (1)
		END 
		-- Check to make sure this is a distributor
		IF NOT EXISTS (SELECT * FROM master.dbo.sysservers
			  WHERE UPPER(datasource collate database_default) = UPPER(@@SERVERNAME) collate database_default
				 AND srvstatus & 8 <> 0)
		BEGIN
			RAISERROR (14114, 16, -1, @@SERVERNAME)
			RETURN(1)
		END
		-- Check if database is already configured as a distributor database
		IF EXISTS (SELECT * FROM msdb..MSdistributiondbs WHERE name = @database collate database_default)
		BEGIN
			RAISERROR (14119, 16, -1, @database)
			RETURN(1)
		END    
	end

	select @pathSeparator = CAST(SERVERPROPERTY('pathseparator') as nvarchar(2))

    select @distdb_in_secondary = sys.fn_MSrepl_isdistdbsecondary(@database)
    -- Dont execute on secondary replica for dist db in AG
    if (@distdb_in_secondary = 0)
    begin 
		--
		-- check folder information
		--
		if (@data_folder is null or @log_folder is null)
		begin
			-- 
			-- Get path to version specific INSTALL directory
			--
			exec @retcode = sys.sp_MSget_setup_paths
				@sql_path = @install_path output,
				@data_path = @mssql_data_path output
			IF @retcode <> 0 or @install_path is NULL or @install_path='' or @mssql_data_path = ''
			BEGIN
	            GOTO UNDO       
		    END
			IF @data_folder IS NULL
				select @data_folder = @mssql_data_path + @pathSeparator + N'DATA'
			IF @log_folder IS NULL
				select @log_folder = @mssql_data_path + @pathSeparator + N'DATA'
		end

		IF @data_file IS NULL
			SELECT @data_file = sys.fn_replaceinvalidfilenamesymbols(@database) collate database_default + N'.MDF'
		IF @log_file IS NULL
			SELECT @log_file = sys.fn_replaceinvalidfilenamesymbols(@database) collate database_default + N'.LDF'

	    -- the file names can not be longer than 255 characters total
		IF len(@data_file) > 255
		begin
			raiserror(21746, 16, -1, N'@data_file', 255)
			return 1
		end
		IF len(@log_file) > 255
		begin
			raiserror(21746, 16, -1, N'@log_file', 255)
			return 1
		end

		if substring(@data_folder, len(@data_folder), 1) = @pathSeparator
		select @data_folder = substring (@data_folder, 1, len(@data_folder) -1)
		if substring(@log_folder, len(@log_folder), 1) = @pathSeparator
		select @log_folder = substring (@log_folder, 1, len(@log_folder) -1)

		-- nullify paths for CL environment to suppress DB files specification
		if sys.fn_MSrepl_editionid() = 32
		begin
			select @data_folder = NULL, @log_folder = NULL
		end

		-- data and log folder must exist to continue
		if @data_folder is not NULL
		begin
			exec sys.sp_MSget_file_existence @data_folder, @file_exists OUTPUT
			if @file_exists = 0
			begin
				raiserror(14430, 16, -1, @data_folder)
				return 1
			end
		end
		if @log_folder is not NULL
		begin
			exec sys.sp_MSget_file_existence @log_folder, @file_exists OUTPUT
			if @file_exists = 0
			begin
				raiserror(14430, 16, -1, @log_folder)
				return 1
			end
		end

		SELECT @data_path = @data_folder + @pathSeparator + @data_file
			        ,@log_path = @log_folder + @pathSeparator + @log_file
				    ,@data_path_quoted_for_copy = N'"' + sys.fn_escapecmdshellsymbolsremovequotes(@data_folder) collate database_default + @pathSeparator + sys.fn_escapecmdshellsymbolsremovequotes(@data_file) collate database_default + N'"'
					,@log_path_quoted_for_copy = N'"' + sys.fn_escapecmdshellsymbolsremovequotes(@log_folder) collate database_default + @pathSeparator + sys.fn_escapecmdshellsymbolsremovequotes(@log_file) collate database_default + N'"'
					,@logical_data_file = @database
					-- Truncate the logical log file name back to 128 characters
					-- long so the 'CREATE DATABASE' statement won't complain.
					,@logical_log_file = case when (LEN(@database) > 124)
						                        then SUBSTRING(@database, 1, 124) + N'_log'
							                    else @database + N'_log' end

		/*
		if (@createmode = @createmode_attach)
		begin
			select @canneddbdata_file = @mssql_data_path + N'\DATA\DISTMDL.MDF'
				    ,@canneddblog_file = @mssql_data_path + N'\DATA\DISTMDL.LDF'

			exec sys.sp_MSget_file_existence @canneddbdata_file, @file_exists OUTPUT
			if (@file_exists = 0)
			begin
				-- Fallback to mode where instdist.sql needs to be run
				select @createmode = @createmode_noattach
			end
			else
			begin
				exec sys.sp_MSget_file_existence @canneddblog_file, @file_exists OUTPUT
				if (@file_exists = 0)
				begin
					-- Fallback to mode where instdist.sql needs to be run
					select @createmode = @createmode_noattach
				end
			end
		end
		*/
    end
    --
    -- Create the distributor database if it does not exist and if we are not on secondary replica for dist db in AG
    --
    IF NOT EXISTS (SELECT * from master.dbo.sysdatabases WHERE name = @database collate database_default) AND (@distdb_in_secondary = 0) 
    BEGIN
        /*
        IF (@createmode = @createmode_attach)
        BEGIN
            -- DO THE CREATE DATABASE FOR ATTACH STUFF
            exec sys.sp_MSget_file_existence @data_path, @data_file_preexists OUTPUT
            if (@data_file_preexists = 1)
            begin
                raiserror(5170, 16, -1, @data_path)
                return 1
            end
            
            exec sys.sp_MSget_file_existence @log_path, @log_file_preexists OUTPUT
            if (@log_file_preexists = 1)
            begin
                raiserror(5170, 16, -1, @log_path)
                return 1
            end

			select @filecopy_cmd = N'copy "' + sys.fn_escapecmdshellsymbolsremovequotes(@canneddbdata_file) collate database_default + N'" ' + @data_path_quoted_for_copy
			EXEC @retcode = master.dbo.xp_cmdshell @filecopy_cmd, NO_OUTPUT
			IF @retcode <> 0 OR @@ERROR <> 0
			BEGIN
				RAISERROR (25017, 16, -1, @filecopy_cmd)
				return (1)
			END

			select @filecopy_cmd = N'copy "' + sys.fn_escapecmdshellsymbolsremovequotes(@canneddblog_file) collate database_default + N'" ' + @log_path_quoted_for_copy
			EXEC @retcode = master.dbo.xp_cmdshell @filecopy_cmd, NO_OUTPUT
			IF @retcode <> 0 OR @@ERROR <> 0
			BEGIN
				RAISERROR (25017, 16, -1, @filecopy_cmd)
				return (1)
			END
			--
			-- Create distributor database
			--
			SELECT @on_clause = N' ON (NAME = ''' + REPLACE(@logical_data_file, '''', '''''' ) + N''', FILENAME=''' + REPLACE( @data_path, '''', '''''' ) + N''')'
					,@logon_clause = N' LOG ON (NAME = ''' + REPLACE(@logical_log_file, '''', '''''' ) + N''', FILENAME=''' + REPLACE( @log_path, '''', '''''' ) + N''')'
			SELECT @command = N'USE master  CREATE DATABASE ' +  QUOTENAME(@database) + 
				+ @on_clause + @logon_clause + N' FOR ATTACH'

			EXEC (@command)
			IF @@ERROR <> 0
			begin
				RETURN (1)
			end
			dbcc dbreindexall(@database, 240) with no_infomsgs

			SELECT @db_exists = 0
		END
		ELSE
		*/
		--BEGIN
			-- DO THE CREATE DATABASE FOR NON ATTACH MODES
			-- Note: Use system's default file growth.
			IF @logical_data_file IS NOT NULL AND NOT EXISTS (SELECT * FROM master.dbo.sysaltfiles WHERE name = @logical_data_file collate database_default)
			BEGIN
				SELECT @on_clause = N' ON (NAME =''' + REPLACE( @logical_data_file, '''', '''''' ) + N''',FILENAME=''' + REPLACE( @data_path, '''', '''''' ) + 
					N''', SIZE=' + @data_file_size_str + N', MAXSIZE = UNLIMITED)'
			END

			IF @logical_log_file IS NOT NULL AND NOT EXISTS (SELECT * FROM master.dbo.sysaltfiles WHERE name = @logical_log_file collate database_default)
			BEGIN
				SELECT @logon_clause = N' LOG ON (NAME =''' + REPLACE( @logical_log_file, '''', '''''' ) + N''',FILENAME=''' + REPLACE( @log_path, '''', '''''' ) + 
					N''', SIZE=' + @log_file_size_str + N', MAXSIZE= UNLIMITED)'          
			END
			-- Create distributor database
			SELECT @command = N'USE master  CREATE DATABASE ' +  QUOTENAME(@database) + 
				+ isnull(@on_clause, N' ') + isnull(@logon_clause, N' ')
			EXEC (@command)
			IF @@ERROR <> 0
				RETURN (1)

			SELECT @db_exists = 0
		--END 
	END
	ELSE
	BEGIN
		-- distribution db exists - do nothing
		SELECT @db_exists = 1
	END

    /*
    ** Contained Database check (Replication is not yet supported on contained databases)
    ** If the specified database exists and is a contained database, then we error out.
    ** Note: 
    ** - If this check fires, then the attached database above won't be detached. I don't see any easy way of doing this while
    **   returning a meaningful error code. The main purpose of this check is to not let customers accidentally try to use 
    **   replication with contained databases, and that purpose is served here. They can delete the newly created database 
    **   manually, if they want to. (Also, the attach option seems to be not supported according to BOL)
    ** - This check needs to be after the database gets created above, since we might have attached or created a contained database above.
    */
    SELECT @containment=containment FROM sys.databases WHERE
        name = @database collate database_default
    if (@containment IS NOT NULL) AND (@containment != 0)
    BEGIN
        RAISERROR(12839, 16, -1, @database)
        RETURN(1)
    END
    -- Dont execute on secondary replica for dist db in AG
    if (@distdb_in_secondary = 0)
    BEGIN 
		--
		-- Must make the dist db owned by sa so that the sps in it can select from
		-- security cache tables in tempdb by owership chain rule.
		--
		select @retcode2 = 0
			    ,@distproc = QUOTENAME(@database) + N'.sys.sp_executesql'
				,@command = 
			-- If the db is created by sa or from attach, sa is dbo already.
			-- sp_changedbowner will fail if the new owner is an user in the db already.
			-- Addendum: we don't perform the check for existing rows in
			-- sysusers anymore as the server has implemented special logic 
			-- that handles such scenarios transparently.
			-- ' if not exists (select * from sys.database_principals where sid = 0x01) ' +
			N'  declare @login sysname
				select @login = suser_sname(0x01)
				exec @retcode2 = sys.sp_changedbowner @loginame= @login'
		EXEC @retcode = @distproc @command, N'@retcode2 int output', @retcode2 output
		IF @retcode <> 0 or @retcode2 <> 0 or @@ERROR <> 0
		BEGIN
	        GOTO UNDO
		END

		-- Consider: Lock database using EXEC %%CurrentDatabase().Lock()??

		IF NOT(sys.fn_MSrepl_editionid() = 32) -- Following options are not supported in CL
		BEGIN
			-- Set the database option truncate log on checkpoint & turn off autoclose which is default of win9x
			IF EXISTS (SELECT * FROM master.dbo.sysdatabases WHERE 
				name = @database collate database_default AND
				(status & @trunc_log_bit) = 0 )   -- if its not already marked
			BEGIN
				select @command = N'ALTER DATABASE ' + QUOTENAME(@database) + N' SET RECOVERY SIMPLE'
				exec(@command)
				IF @@ERROR <> 0
				BEGIN
					GOTO UNDO
				END
			END
			select @command = N'ALTER DATABASE ' + QUOTENAME(@database) + N' SET AUTO_CLOSE OFF'
			exec(@command)
			IF @@ERROR <> 0
			BEGIN
				GOTO UNDO
			END
		END
		--
		-- Update sysdatabase category bit
		-- This is to prevent user from dropping the database.
		--
		if (@createmode <> @createmode_fordetach)
			EXEC %%DatabaseEx(Name = @database).SetDistributor(Value = 1)
		--
		-- Install instdist.sql
		--
		if (@createmode <> @createmode_attach) OR (@db_exists = 1)
		begin
			select @command = quotename(@database) + N'.sys.sp_instdist'
			exec @retcode = @command
			IF @retcode <> 0 or @@error <> 0
			BEGIN
				GOTO UNDO
			END
			IF serverproperty('EngineEdition') = 8 BEGIN -- Defect 11550616: execute it outside of sp_instdist in CL only, to workaround known problem
				select @command = quotename(@database) + N'.dbo.sp_MS_marksystemobject'
				exec @retcode = @command N'dbo.sp_MSset_syncstate'
				IF @retcode <> 0 or @@error <> 0 GOTO UNDO
				exec @retcode = @command N'dbo.sp_MSadd_repl_commands27'
				IF @retcode <> 0 or @@error <> 0 GOTO UNDO
				exec @retcode = @command N'dbo.sp_MSadd_replcmds'
				IF @retcode <> 0 or @@error <> 0 GOTO UNDO
				exec @retcode = @command N'dbo.sp_MSremove_published_jobs'
				IF @retcode <> 0 or @@error <> 0 GOTO UNDO
				exec @retcode = @command N'dbo.sp_MSsubscription_cleanup'
				IF @retcode <> 0 or @@error <> 0 GOTO UNDO
				exec @retcode = @command N'dbo.sp_MSdelete_publisherdb_trans'
				IF @retcode <> 0 or @@error <> 0 GOTO UNDO
				exec @retcode = @command N'dbo.sp_MSmaximum_cleanup_seqno'
				IF @retcode <> 0 or @@error <> 0 GOTO UNDO
				exec @retcode = @command N'dbo.sp_MSdistribution_delete'
				IF @retcode <> 0 or @@error <> 0 GOTO UNDO
				exec @retcode = @command N'dbo.sp_MSdistribution_cleanup'
				IF @retcode <> 0 or @@error <> 0 GOTO UNDO
				exec @retcode = @command N'dbo.sp_MShistory_cleanup'
				IF @retcode <> 0 or @@error <> 0 GOTO UNDO
				exec @retcode = @command N'dbo.sp_MSget_repl_version'
				IF @retcode <> 0 or @@error <> 0 GOTO UNDO
				exec @retcode = @command N'dbo.MSdistribution_status'
				IF @retcode <> 0 or @@error <> 0 GOTO UNDO
				exec @retcode = @command N'dbo.sp_MSlog_agent_cancel'
				IF @retcode <> 0 or @@error <> 0 GOTO UNDO
				exec @retcode = @command N'dbo.sp_MSdelete_dodelete'
				IF @retcode <> 0 or @@error <> 0 GOTO UNDO
				exec @retcode = @command N'dbo.fn_MSmask_agent_type'
				IF @retcode <> 0 or @@error <> 0 GOTO UNDO
			END
		end
    END
	    
    if (@createmode <> @createmode_fordetach)
    begin
        -- Set db_existed bit in MSrepl_version
        IF @db_exists = 1 AND (@distdb_in_secondary = 0)
        BEGIN
            SELECT @command = N'UPDATE ' +
                QUOTENAME(@database) + N'.dbo.MSrepl_version SET db_existed = 0x1'
    
            EXEC(@command)
            IF @@ERROR <> 0
            BEGIN
                GOTO UNDO       
            END
        END

		DELETE msdb.dbo.MSdistributiondbs WHERE name = @database collate database_default
		IF @@ERROR <> 0
		BEGIN
			GOTO UNDO       
		END

		INSERT INTO msdb.dbo.MSdistributiondbs VALUES (
			@database, @min_distretention, @max_distretention, @history_retention, @deletebatchsize_xact, @deletebatchsize_cmd
			)
		IF @@ERROR <> 0
		BEGIN
			GOTO UNDO       
		END

        -- Dont execute on secondary replica for dist db in AG
        if (@distdb_in_secondary = 0)
        BEGIN
			-- This login need db_owner priviledge to call sps in distribution db
			select @distributor_login = N'distributor_admin'
					,@command = quotename(@database) + N'.sys.sp_MSrepl_dbrole'
			exec @retcode = @command N'db_owner', @distributor_login, N'add'
			IF @@error <> 0 OR @retcode <> 0
				GOTO UNDO
        END

		-- The following commented out code to drop guest user was fine for merge,
		-- but the tran BVT failed. It can be uncommented once tran fixes the issue
		-- with no guest user in dist db.
		-- The guest user needs to be dropped from the distribution db.
		--select @command = '
		--if exists (select * from ' + quotename(@database) + '.dbo.sysusers 
		--	where name = ''guest'' and hasdbaccess = 1)
		--begin
		--	exec ' + quotename(@database) + '.sys.sp_revokedbaccess @name_in_db = ''guest''
		--end'
		--exec (@command)
		--if (@@error != 0)
		--  goto UNDO

		if @from_scripting = 0
		begin
			--
			-- Create the history cleanup agent.
			--
			SELECT @agentname = formatmessage (20567, @database)
						,@command =  N'EXEC dbo.sp_MShistory_cleanup @history_retention = ' + 
							CONVERT(nvarchar(12), @history_retention)

			IF EXISTS (SELECT * FROM msdb.dbo.sysjobs_view WHERE name = @agentname collate database_default and
				UPPER(originating_server) = UPPER(CONVERT(sysname, SERVERPROPERTY('ServerName')))
				and master_server = 0)
			BEGIN
				EXEC @retcode = sys.sp_MSdrop_repl_job
					@job_name = @agentname
				IF @@ERROR <> 0 or @retcode <> 0
				BEGIN
					GOTO UNDO
				END
			END

			set @description = formatmessage(20535)

			-- Get History Cleanup category name (assumes category_id = 12)
			select @category_name = name FROM msdb.dbo.syscategories where category_id = 12

			EXECUTE @retcode = sys.sp_MSadd_repl_job @agentname,
				@subsystem = 'TSQL',
				@server = @@SERVERNAME,
				@databasename = @database,
				@description = @description,
				@freqtype = 4,    
				@freqsubtype = 4,         
				@freqsubinterval = 10,    -- Number of minutes between runs
				@command = @command,
				@enabled = 1,
				@retryattempts = 0,
				@loghistcompletionlevel = 0,
				@category_name = @category_name
	
			IF @@ERROR <> 0 or @retcode <> 0
			BEGIN
				GOTO UNDO
			END
			--
			-- Create the distribution cleanup agent.
			--
			SELECT @agentname = formatmessage (20568, @database)
						,@command =  N'EXEC dbo.sp_MSdistribution_cleanup @min_distretention = ' + 
							CONVERT(nvarchar(12), @min_distretention) + ', @max_distretention = ' +
							CONVERT(nvarchar(12), @max_distretention)

			IF EXISTS (SELECT * FROM msdb.dbo.sysjobs_view WHERE name = @agentname collate database_default and
				UPPER(originating_server) = UPPER(CONVERT(sysname, SERVERPROPERTY('ServerName')))
				and master_server = 0)
			BEGIN
				EXEC @retcode = sys.sp_MSdrop_repl_job 
					@job_name = @agentname
				IF @@ERROR <> 0 or @retcode <> 0
				BEGIN
					GOTO UNDO
				END
			END

			set @description = formatmessage(20541)
			-- Get Distribution Cleanup category name (assumes category_id = 11)
			select @category_name = name FROM msdb.dbo.syscategories where category_id = 11
	
			EXECUTE @retcode = msdb.sys.sp_MSadd_repl_job @agentname,
				@subsystem = 'TSQL',
				@server = @@SERVERNAME,
				@databasename = @database,
				@description = @description,
				@freqtype = 4,    
				@freqsubtype = 4,         
				@freqsubinterval = 10,    -- Number of minutes between runs
				@command = @command,
				@retryattempts = 0,
				@enabled = 0,
				@loghistcompletionlevel = 0,
				@category_name = @category_name,
				-- Start  and end time is 5 min off from the history cleanup, which use the default.
				@activestarttimeofday = 000500,
				@activeendtimeofday   = 000459

			IF @@ERROR <> 0 or @retcode <> 0
			BEGIN
				GOTO UNDO
			end
			--
			-- Add job for replication monitoring refresh
			--
			select @agentname = formatmessage (20811, @database)
			select @description = @agentname
					,@command =  N'exec dbo.sp_replmonitorrefreshjob  '
			if exists (select * from msdb.dbo.sysjobs_view where name = @agentname collate database_default and
				upper(originating_server collate database_default) = upper(convert(sysname, SERVERPROPERTY('ServerName')))
				and master_server = 0)
			BEGIN
				EXEC @retcode = sys.sp_MSdrop_repl_job
					@job_name = @agentname
				IF @@ERROR <> 0 or @retcode <> 0
				BEGIN
					GOTO UNDO
				END
			END
			select @category_name = name FROM msdb.dbo.syscategories where category_id = 18
	
			EXECUTE @retcode = msdb.sys.sp_MSadd_repl_job @agentname,
				@subsystem = 'TSQL',
				@server = @@SERVERNAME,
				@databasename = @database,
				@description = @description,
				@freqtype = 64,  -- continuous  
				@freqsubtype = 0,  -- unused
				@freqsubinterval = 0,    -- unused
				@command = @command,
				@retryattempts = 0,
				@enabled = 0,
				@loghistcompletionlevel = 0,
				@category_name = @category_name

            if @@ERROR <> 0 or @retcode <> 0
                GOTO UNDO
        end
        -- Dont execute on secondary replica for dist db in AG
        if (@distdb_in_secondary = 0)
        BEGIN
			--
			-- register default resolvers - this requires SQL installation
			--
			exec @retcode = sys.sp_MSrepl_register_default_resolvers @database

			if @@error <> 0 or @retcode <> 0
				goto UNDO
        END    
	end -- (@createmode <> @createmode_fordetach) block
    else
    begin
        -- detach
        dbcc detachdb(@database)
    end

	RETURN(0)

	-- Consider: Using transaction ??
UNDO:

    IF @db_exists = 0 AND (@distdb_in_secondary = 0)
        EXECUTE sys.sp_dropdistributiondb @database

    -- Need to do it since sp_dropdistributiondb will fail in some cases
    if (@distdb_in_secondary = 0)
    EXEC %%DatabaseEx(Name = @database).SetDistributor(Value = 0)
    
    DELETE msdb.dbo.MSdistributiondbs where name = @database collate database_default

    -- drop the database and ignore error
    IF @db_exists = 0 AND
        EXISTS (SELECT * from master.dbo.sysdatabases WHERE name = @database collate database_default) AND (@distdb_in_secondary = 0)
    BEGIN
        SELECT @command = N'USE master  DROP DATABASE ' +  QUOTENAME(@database) 
        EXEC (@command)
    END

	/*
	if (@createmode = @createmode_attach)
	begin
		if (@data_file_preexists = 0)
		begin
			select @command = N'del ' + @data_path_quoted_for_copy
			exec master.dbo.xp_cmdshell @command, NO_OUTPUT
			--ignore errors
		end
		if (@log_file_preexists = 0)
		begin
			select @command = N'del ' + @log_path_quoted_for_copy
			exec master.dbo.xp_cmdshell @command, NO_OUTPUT
			--ignore errors
		end
	end
	*/        
	RETURN(1)        
END
GO
GRANT EXECUTE ON [sys].[sp_adddistributiondb] TO [public] AS [dbo]
GO
