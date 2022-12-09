SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_vupgrade_replsecurity_metadata]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_vupgrade_replsecurity_metadata] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_vupgrade_replsecurity_metadata]
WITH EXECUTE AS CALLER
AS
BEGIN
	SET NOCOUNT ON
	
	DECLARE @retcode			int,
			@statement			nvarchar(4000),
			@database 			nvarchar(512),
			@has_dbaccess		bit, 
			@is_distributiondb	bit,
			@is_subscriberdb	bit,
			@is_upgraded		bit
			,@agentname nvarchar(100)
			,@description nvarchar(100)
			,@category_name sysname
			,@dbname sysname

	-- Security Check
	IF ISNULL(IS_SRVROLEMEMBER('sysadmin'), 0) = 0
	BEGIN
		-- "Only members of the sysadmin fixed server role can perform this operation."
		RAISERROR(21089,16,-1) 
		RETURN 1
	END

	IF LOWER(DB_NAME()) != N'master'
	BEGIN
		-- "sp_vupgrade_replsecurity_metadata can only be executed in the master database."
		RAISERROR (21482, 16, -1, 'sp_vupgrade_replsecurity_metadata', 'master')
		RETURN 1
	END

	-- make sure user has already upgraded msdb
	IF NOT EXISTS(SELECT * 
				FROM msdb.sys.columns 
				WHERE object_id = OBJECT_ID(N'msdb.dbo.sysjobsteps') 
					AND name = N'step_uid')
	BEGIN
		-- "The replication %s could not be upgraded for %s database(s). Please ensure that %s is upgraded and re-execute %s."
		RAISERROR(21450, 16, -1, 'security meta-data', 'all',  'msdb database', 'sp_vupgrade_replsecurity_metadata')
		RETURN 1
	END
	
	BEGIN TRANSACTION
	SAVE TRANSACTION tr_upgrade_security_meta

    DECLARE cursorDatabases CURSOR LOCAL FAST_FORWARD FOR 
    	SELECT DISTINCT HAS_DBACCESS(name),
            	sys.fn_MSrepl_isdistdb(name),
            	N'[' + replace(name, N']', N']]') + N']',
            	name
    		FROM master.sys.databases 
    		WHERE name NOT IN ( N'master' COLLATE DATABASE_DEFAULT,
			                    N'tempdb' COLLATE DATABASE_DEFAULT,
			                    N'msdb'   COLLATE DATABASE_DEFAULT,
			                    N'model'  COLLATE DATABASE_DEFAULT
			                    ) and source_database_id is null  -- exclude DB snapshots
    	FOR READ ONLY

	OPEN cursorDatabases

	FETCH cursorDatabases INTO @has_dbaccess, @is_distributiondb, @database, @dbname
	
    WHILE @@FETCH_STATUS != -1
    BEGIN
		IF @has_dbaccess = 1
		BEGIN
			-- if this is a distribution db then upgrade dist meta-data
			IF @is_distributiondb = 1
			BEGIN
				SELECT @statement = N'SELECT @is_upgraded = 0 ' +
									N'IF EXISTS(SELECT * '+
									N'			FROM ' + @database + N'.sys.columns ' +
									N'			WHERE name = N''job_step_uid'') ' +
									N'BEGIN ' +
									N'	SELECT @is_upgraded = 1 ' +
									N'END'

				EXEC @retcode = sys.sp_executesql @statement = @statement, 
													@params = N'@is_upgraded bit OUTPUT', 
													@is_upgraded = @is_upgraded OUTPUT
				IF @@ERROR <> 0 OR @retcode <> 0
						GOTO UNDO

				IF @is_upgraded = 1
				BEGIN
					SELECT @statement = @database + N'.[sys].[sp_MSupgrade_distdb_security_metadata]'

					EXEC @retcode = @statement
					IF @@ERROR <> 0 OR @retcode <> 0
						GOTO UNDO
				END
				ELSE
				BEGIN
					-- "The replication %s could not be upgraded for %s database(s). Please ensure that %s is upgraded and re-execute %s."
					RAISERROR(21450, 10, -1, 'distributor security meta-data', @database,  @database, 'sp_vupgrade_replsecurity_metadata') WITH NOWAIT
				END
				--
				-- Add replmonitor refresh job for this distribution database
				--
				select @agentname = formatmessage (20811, @dbname)
				select @description = @agentname
					,@statement =  N'exec dbo.sp_replmonitorrefreshjob  '
				if not exists (select * from msdb.dbo.sysjobs_view where name = @agentname collate database_default and
							upper(originating_server collate database_default) = upper(convert(sysname, SERVERPROPERTY('ServerName')))
							and master_server = 0)
				BEGIN
					select @category_name = name FROM msdb.dbo.syscategories where category_id = 18
					EXECUTE @retcode = msdb.sys.sp_MSadd_repl_job @agentname,
											@subsystem = 'TSQL',
											@server = @@SERVERNAME,
											@databasename = @dbname,
											@description = @description,
											@freqtype = 64,  -- continuous  
											@freqsubtype = 0,  -- unused
											@freqsubinterval = 0,    -- unused
											@command = @statement,
											@retryattempts = 0,
											@enabled = 0,
											@loghistcompletionlevel = 0,
											@category_name = @category_name
					if @@ERROR <> 0 or @retcode <> 0
					GOTO UNDO
				END
			END

			SELECT @statement = N'SELECT @is_subscriberdb = 0 ' +
									N'IF EXISTS(SELECT * ' +
									N'			FROM ' + @database + N'.sys.objects ' +
									N' 			WHERE name = N''MSsubscription_properties'') ' +
									N'BEGIN ' + 
									N' 	SELECT @is_subscriberdb = 1 ' +
									N'END ' +
									N'SELECT @is_upgraded = 0 ' +
									N'IF EXISTS(SELECT * ' +
									N'			FROM ' + @database + N'.sys.columns ' +
									N'			WHERE name = N''job_step_uid'') ' +
									N'BEGIN ' +
									N'	SELECT @is_upgraded = 1 ' +
									N'END'

			EXEC @retcode = sys.sp_executesql @statement = @statement, 
												@params = N'@is_subscriberdb bit OUTPUT, @is_upgraded bit OUTPUT', 
												@is_subscriberdb = @is_subscriberdb OUTPUT,
												@is_upgraded = @is_upgraded OUTPUT
			IF @@ERROR <> 0 OR @retcode <> 0
					GOTO UNDO

			IF @is_subscriberdb = 1
			BEGIN
				IF @is_upgraded = 1
				BEGIN
					-- always assume this is subscriber db and attempt upgrade sub meta-data
					SELECT @statement = @database + N'.[sys].[sp_MSupgrade_subdb_security_metadata]'
					
					EXEC @retcode = @statement
					IF @@ERROR <> 0 OR @retcode <> 0
						GOTO UNDO
				END
				ELSE
				BEGIN
					-- "The replication %s could not be upgraded for %s database(s). Please ensure that %s is upgraded and re-execute %s."
					RAISERROR(21450, 10, -1, 'subscriber security meta-data', @database,  @database, 'sp_vupgrade_replsecurity_metadata') WITH NOWAIT
				END
			END
		END
		ELSE
		BEGIN
			-- "Could not open database %s. Upgrade of replication %s could not be performed. Please rerun %s from %s database once the %s is accessible."
			RAISERROR(21733, 10, -1, @database, 'security meta-data', 'sp_vupgrade_replsecurity_metadata', '[master]', @database) WITH NOWAIT
		END

		FETCH cursorDatabases INTO @has_dbaccess, @is_distributiondb, @database, @dbname
	END

	CLOSE cursorDatabases
	DEALLOCATE cursorDatabases

	COMMIT TRANSACTION tr_upgrade_security_meta

	RETURN 0
UNDO:
	ROLLBACK TRANSACTION tr_upgrade_security_meta
	COMMIT TRANSACTION 

	RETURN 1
END
GO
GRANT EXECUTE ON [sys].[sp_vupgrade_replsecurity_metadata] TO [public] AS [dbo]
GO
