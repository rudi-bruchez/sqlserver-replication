SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_changereplicationserverpasswords]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_changereplicationserverpasswords] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_changereplicationserverpasswords]
	@login_type [tinyint],
	@login [nvarchar](257),
	@password [sysname],
	@server [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
	SET NOCOUNT ON

	DECLARE @FIsPublisher	bit,
			@FIsDistributor	bit
			
	DECLARE @retcode			int,
			@command			nvarchar(4000),
			@database			sysname,
			@credential 		sysname,
			@identity			sysname,
			@publisher			sysname,
			@publisher_type		sysname,
			@distribution_db	sysname

	SELECT @FIsPublisher = 0,
			@FIsDistributor	= 0
			
	SELECT	@publisher_type = N'MSSQLSERVER',
			@server         = ISNULL(@server, N'%'),
			@password       = ISNULL(@password, N'')

	-- Security Check
	IF IS_SRVROLEMEMBER('sysadmin') <> 1
	BEGIN
		-- "Only members of the sysadmin fixed server role can perform this operation."
		RAISERROR(21089, 16, -1)
		RETURN 1 
	END

	IF LOWER(DB_NAME()) != N'master'
	BEGIN
		-- "sp_changereplicationserverpasswords can only be executed in the master database."
		RAISERROR (21482, 16, -1, 'sp_changereplicationserverpasswords', 'master')
		RETURN 1
	END

	IF RTRIM(ISNULL(@login, N'')) = N''
	BEGIN
		-- Invalid value given for parameter @login.
		RAISERROR(21456, 16, -1, '@login')
		RETURN 1
	END

	IF RTRIM(ISNULL(@password, N'')) = N''
	BEGIN
		-- Invalid value given for parameter @password.
		RAISERROR(21456, 16, -1, '@password')
		RETURN 1
	END
	
	-- check for tran (category&1) and merge (category&4) published dbs
	IF EXISTS(SELECT name
				FROM master.sys.sysdatabases
				WHERE category & 1 = 1)
		OR 
		EXISTS(SELECT name
				FROM master.sys.sysdatabases
				WHERE category & 4 = 4)
	BEGIN
		SELECT @FIsPublisher = 1
	END

	-- check for dist server or distdb 
	IF EXISTS(SELECT * 
				FROM master.dbo.sysservers	
				WHERE srvstatus & 8 <> 0)
		OR 
		EXISTS (SELECT name
				FROM master.sys.sysdatabases
				WHERE category & 16 = 16)
	BEGIN
		SELECT @FIsDistributor = 1

		SELECT @distribution_db = name
			FROM master.sys.sysdatabases
			WHERE category & 16 = 16
	END

	/**********************************************************
	 *     CHANGES TO BE DONE OUTSIDE OF A TRANSACTION
	 **********************************************************/
	 
	-- these steps must be done outside of the transaction 
	-- block because they deal with linked server logins and 
	-- can NOT be done within any transaction boundaries...
	IF @login_type = 0
	BEGIN	
		-- if we are at a distributor srv or at a publisher and 
		-- if this is the dist admin link login name then
		-- we will attempt to update the dist link password
		IF (@FIsDistributor = 1
				OR @FIsPublisher = 1)
			AND @login = N'distributor_admin'
		BEGIN
			EXEC @retcode = sys.sp_changedistributor_password @password = @password
			IF @retcode <> 0 or @@ERROR <> 0
				RETURN 1

			RAISERROR(21451, 10, -1, 'distributor', 'admin', 'admin link', 'distributor_admin') WITH LOG
		END
		
		-- if we are at a distributor server then lets check to see if
		-- we have to update any hetero linked server logins in this run
		IF @FIsDistributor = 1
			AND OBJECT_ID('msdb..MSdistpublishers', 'U') IS NOT NULL
		BEGIN
			DECLARE cursorDistPublishers CURSOR LOCAL FAST_FORWARD FOR
				SELECT name 
					FROM msdb..MSdistpublishers 
					WHERE (UPPER(name) = UPPER(@server)
							OR @server = N'%')
						AND security_mode = 0
			OPEN cursorDistPublishers

			FETCH cursorDistPublishers INTO @publisher
			WHILE @@FETCH_STATUS <> -1
			BEGIN
				EXEC @retcode = sys.sp_MSrepl_getdistributorinfo	@publisher      = @publisher,
																	@publisher_type = @publisher_type OUTPUT
				IF @retcode <> 0
					RETURN 1

				-- if this is a hetero publisher then we should 
				-- attempt to update the remote login passwords
				IF @publisher_type != N'MSSQLSERVER'
				BEGIN
					EXEC @retcode = sys.sp_MSchangerepllinkedsrvrpassword	@server       = @publisher,
																			@remote_login = @login,
																			@new_password = @password,
																			@server_type  = @publisher_type
					IF @retcode <> 0 or @@ERROR <> 0
			        	RETURN 1
				END

				FETCH cursorDistPublishers INTO @publisher
			END

			CLOSE cursorDistPublishers
			DEALLOCATE cursorDistPublishers
		END	

		-- this is done for every database but, the current procedure
		-- sp_MSchangepublicationlinkpasswords being called performs a 
		-- no-op for dbs that are not replication subscription databases...
		DECLARE cursorDatabases CURSOR LOCAL FAST_FORWARD FOR
			SELECT DISTINCT name 
				FROM master..sysdatabases
			where databasepropertyex(name, 'Updateability') = 'READ_WRITE'
	       and has_dbaccess(name) = 1
		OPEN cursorDatabases

		FETCH cursorDatabases INTO @database
		WHILE @@FETCH_STATUS <> -1
		BEGIN
			-- set the database name in front of each sp call
			SELECT @command = QUOTENAME(@database) + N'.sys.sp_MSchangepublicationlinkpasswords'
			
			EXEC @retcode = @command @server = @server,
										@remote_login = @login,
										@new_password = @password
			IF @retcode <> 0 or @@ERROR <> 0
				GOTO UNDO
			
			FETCH cursorDatabases INTO @database
		END

		CLOSE cursorDatabases
		DEALLOCATE cursorDatabases
	END

	/**********************************************************
	 *       CHANGES TO BE DONE WITHIN A TRANSACTION
	 **********************************************************/
	 
	BEGIN TRANSACTION tr_change_repl_password
	SAVE TRANSACTION tr_change_repl_password
	
	-- SQL Authenticated login password change
	IF @login_type = 0
	BEGIN
		/*
		 * Perform all per database updates first
		 */
		DECLARE cursorDatabases CURSOR LOCAL FAST_FORWARD FOR
			SELECT DISTINCT name 
				FROM master..sysdatabases
			where databasepropertyex(name, 'Updateability') = 'READ_WRITE'
	       and has_dbaccess(name) = 1
		OPEN cursorDatabases

		FETCH cursorDatabases INTO @database
		WHILE @@FETCH_STATUS <> -1
		BEGIN
			-- set the database name in front of each sp call
			SELECT @command = QUOTENAME(@database) + N'.sys.sp_MSchangerepltablepasswords'
			
			EXEC @retcode = @command @server = @server,
										@login = @login,
										@password = @password,
										@distribution_db = @distribution_db
			IF @retcode <> 0 or @@ERROR <> 0
				GOTO UNDO
			
			FETCH cursorDatabases INTO @database
		END

		CLOSE cursorDatabases
		DEALLOCATE cursorDatabases
	END
	-- Windows Authenticated login password change
	ELSE IF @login_type = 1
	BEGIN
		IF @server IS NOT NULL
			AND @server != N'%'
		BEGIN
			-- Use of parameter(s) @server is invalid when parameter @login_type is set to 1.
			RAISERROR(22539, 16, -1, '@server', '@login_type', '1')
			GOTO UNDO
		END
		
		/*
		 * Perform all credential updates based on MSDB data
		 * 
		 * NOTE: We should ONLY allow the change of 
		 *		 REPLICATION credential passwords where
		 *		 the login matches the credential_identity
		 *			
		 *       Also, we upper the login and credential_identity
		 *       since windows accounts are case-insensitive...
		 */
		DECLARE cursorCredentials CURSOR LOCAL FAST_FORWARD FOR
			SELECT sc.name, 
					sc.credential_identity
				FROM msdb.dbo.sysjobs_view as sjv 
					JOIN msdb.dbo.sysjobsteps as sjs 
						ON sjv.job_id = sjs.job_id
					JOIN msdb.dbo.sysproxies sp
						ON sjs.proxy_id = sp.proxy_id
					JOIN sys.credentials sc
						ON sc.credential_id = sp.credential_id
				WHERE sjv.master_server = 0
					AND UPPER(sjv.originating_server) = UPPER(CONVERT(sysname, SERVERPROPERTY('ServerName')))
					AND ((sjv.category_id = 10
							AND sjs.subsystem = N'Distribution')
						OR (sjv.category_id = 14
							AND sjs.subsystem = N'Merge')
						OR (sjv.category_id = 13
							AND sjs.subsystem = N'LogReader')
						OR (sjv.category_id = 15
							AND sjs.subsystem =  N'Snapshot')
						OR (sjv.category_id = 19
							AND sjs.subsystem = N'QueueReader'))
					AND UPPER(sc.credential_identity) = UPPER(@login)
					
		OPEN cursorCredentials

		FETCH cursorCredentials INTO @credential, @identity
		WHILE @@FETCH_STATUS <> -1
		BEGIN
			-- change the credential password
			SELECT @command = 'ALTER CREDENTIAL ' + QUOTENAME(@credential) +
								' WITH IDENTITY = ' + QUOTENAME(@identity, '''') +
								', SECRET = ' + QUOTENAME(@password, '''')
			
			EXEC(@command)
			IF @retcode <> 0 or @@ERROR <> 0
				GOTO UNDO

			RAISERROR(21451, 10, -1, 'job', 'credential', @credential, @identity) WITH LOG
			
			FETCH cursorCredentials INTO  @credential, @identity
		END

		CLOSE cursorCredentials
		DEALLOCATE cursorCredentials
	END
	ELSE
	BEGIN
		-- Invalid value given for parameter @login_type.
		RAISERROR(21456, 16, -1, '@login_type')
		GOTO UNDO
	END
	
	COMMIT TRANSACTION tr_change_repl_password

	RETURN 0
UNDO:
	ROLLBACK TRANSACTION tr_change_repl_password
	COMMIT TRANSACTION 

	RETURN 1
END
GO
GRANT EXECUTE ON [sys].[sp_changereplicationserverpasswords] TO [public] AS [dbo]
GO
