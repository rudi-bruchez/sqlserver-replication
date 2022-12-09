SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_addmergepushsubscription_agent]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_addmergepushsubscription_agent] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_addmergepushsubscription_agent]
	@publication [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname],
	@subscriber_security_mode [smallint],
	@subscriber_login [sysname],
	@subscriber_password [sysname],
	@publisher_security_mode [smallint],
	@publisher_login [sysname],
	@publisher_password [sysname],
	@job_login [nvarchar](257),
	@job_password [sysname],
	@job_name [sysname],
	@frequency_type [int],
	@frequency_interval [int],
	@frequency_relative_interval [int],
	@frequency_recurrence_factor [int],
	@frequency_subday [int],
	@frequency_subday_interval [int],
	@active_start_time_of_day [int],
	@active_end_time_of_day [int],
	@active_start_date [int],
	@active_end_date [int],
	@enabled_for_syncmgr [nvarchar](5)
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @retcode			int,
			@procedure			nvarchar(4000),
			@distributor_rpc	sysname,
			@distributor		sysname,
			@distribution_db	sysname,
			@publisher			sysname,
			@publisher_db		sysname,
			@distrib_pwd		nvarchar(527),
			@pubid				uniqueidentifier,
			@subid				uniqueidentifier,
			@use_ir 			bit,
			@hostname			sysname,
			@exists 			int,
			@merge_job_name		sysname,
			@merge_jobid		binary(16),
			@proxy_id			int
	
	-- Security Check
	EXEC @retcode = sys.sp_MSreplcheck_publish
	IF @@ERROR <> 0 or @retcode <> 0
		RETURN 1
	
	-- Make sure current database is enabled for merge replication
	EXEC @retcode=sys.sp_MSCheckmergereplication
	IF @@ERROR <> 0 or @retcode <> 0
		RETURN 1
	
	SELECT @publisher = publishingservername(),
			@publisher_db = DB_NAME()
	
	-- Parameter Check: @subscriber 
	IF @subscriber IS NULL
	BEGIN
		-- "The parameter @subscriber cannot be NULL."
		RAISERROR (14043, 16, -1, '@subscriber', 'sp_addmergepushsubscription_agent')
		RETURN 1
	END

	IF @subscriber = 'all'
	BEGIN
		-- "The keyword 'all' is reserved by replication stored procedures."
		RAISERROR (14136, 16, -1)
		RETURN 1
	END

	EXEC @retcode = sys.sp_validname @subscriber
	IF @@ERROR <> 0 OR @retcode <> 0
	   RETURN 1

    declare @subscriber_with_port sysname
    exec sys.sp_MSget_server_portinfo 
        @name = @subscriber, 
        @srvname = @subscriber OUTPUT,
        @srvname_with_port = @subscriber_with_port OUTPUT

	-- Parameter Check: @subscriber_db
	IF @subscriber_db IS NULL
	BEGIN
		-- "The parameter @subscriber_db cannot be NULL."
		RAISERROR (14043, 16, -1, '@subscriber_db', 'sp_addmergepushsubscription_agent')
		RETURN 1
	END

	IF @subscriber_db = 'all'
	BEGIN
		-- "The keyword 'all' is reserved by replication stored procedures."
		RAISERROR (14136, 16, -1)
		RETURN 1
	END

	-- @subscriber_db cannot be master
	if LOWER(@subscriber_db) = 'master'
	BEGIN
		-- Cannot create replication subscription(s) in the master database. Choose another database for creating subscriptions.
		RAISERROR (21481, 16, 1)
		RETURN 1
	END

	SELECT @pubid = pubid 
		FROM dbo.sysmergepublications 
		WHERE UPPER(publisher)=UPPER(publishingservername()) 
			AND publisher_db=db_name()
			AND name = @publication 
	IF @pubid IS NULL
	BEGIN
		-- The publication '@publication' does not exist.
		RAISERROR (20026, 16, -1, @publication)
		RETURN 1
	END

	SELECT @subid = subid 
		FROM dbo.sysmergesubscriptions 
		WHERE UPPER(subscriber_server) = UPPER(@subscriber)
			AND db_name = @subscriber_db
			AND pubid = @pubid 
			AND subscription_type = 0
	IF @subid IS NULL
	BEGIN
		-- "The subscription could not be found."
		RAISERROR (20021, 16, -1)
		RETURN 1
	END

	SELECT @use_ir = use_interactive_resolver,
			@hostname = hostname
		FROM dbo.MSmerge_replinfo
		WHERE repid = @subid

	-- Check Subscriber Security information
	SELECT @subscriber_security_mode = ISNULL(@subscriber_security_mode, 1)

	IF @subscriber_security_mode NOT IN (0, 1)
	BEGIN
		-- The specified '@subscriber_security_mode' is invalid (valid values are: 0, 1).
		RAISERROR(14266, 16, -1, '@subscriber_security_mode', '0, 1')
		RETURN 1
	END

	-- make sure that the login is valid
	SELECT @subscriber_login = RTRIM(LTRIM(ISNULL(@subscriber_login, '')))
	IF @subscriber_security_mode = 0 AND @subscriber_login = ''
	BEGIN
		-- '@subscriber_login cannot be null or empty when @subscriber_security_mode is set to 0 (SQL Server authentication).'
		RAISERROR(21694, 16, -1, '@subscriber_login', '@subscriber_security_mode')
		RETURN 1
	END

	-- Check Publisher Security information
	SELECT @publisher_security_mode = ISNULL(@publisher_security_mode, 1)

	IF @publisher_security_mode NOT IN (0, 1)
	BEGIN
		-- The specified '@publisher_security_mode' is invalid (valid values are: 0, 1).
		RAISERROR(14266, 16, -1, '@publisher_security_mode', '0, 1')
		RETURN 1
	END

	-- make sure that the login is valid
	SELECT @publisher_login = RTRIM(LTRIM(ISNULL(@publisher_login, '')))
	IF @publisher_security_mode = 0 AND @publisher_login = ''
	BEGIN
		-- '@publisher_login cannot be null or empty when @publisher_security_mode is set to 0 (SQL Server authentication).'
		RAISERROR(21694, 16, -1, '@publisher_login', '@publisher_security_mode')
		RETURN 1
	END
	
	-- if we do not require yukon security then check paramters.
	IF sys.fn_yukonsecuritymodelrequired(NULL) = 0
	BEGIN
		IF @job_login IS NULL
		BEGIN
			IF @job_password IS NOT NULL
			BEGIN
				-- Parameter '@job_login' can be set to 'NULL' only when '@job_password' is set to 'NULL'.
				RAISERROR(21678, 16, -1, '@job_login', 'NULL', '@job_password', 'NULL')
				RETURN 1
			END
		END
		ELSE
		BEGIN
			IF @job_password IS NULL
			BEGIN
				-- Parameter '@job_password' can be set to 'NULL' only when '@job_login' is set to 'NULL'.
				RAISERROR(21678, 16, -1, '@job_password', 'NULL', '@job_login', 'NULL')
				RETURN 1
			END

			IF sys.fn_replisvalidwindowsloginformat(@job_login) != 1
			BEGIN
				-- '@job_login' must be a valid Windows Login in the form : 'MACHINE\Login' or 'DOMAIN\Login'. Please see the documentation for 'sp_addmergepushsubscription_agent'.
				RAISERROR(21797, 16, -1, '@job_login', 'sp_addmergepushsubscription_agent')
				RETURN 1
			END
		END
	END
	-- if yukon sec required then a valid windows login/password is required
	ELSE
	BEGIN
		IF @job_login IS NULL
			OR @job_password IS NULL
		BEGIN
			-- Only members of the sysadmin fixed server role can perform this operation without specifying @job_login or @job_password.
			RAISERROR(21832, 16, -1, '@job_login or @job_password')
			RETURN 1
		END

		IF sys.fn_replisvalidwindowsloginformat(@job_login) != 1
		BEGIN
			-- '@job_login' must be a valid Windows Login in the form : 'MACHINE\Login' or 'DOMAIN\Login'. Please see the documentation for 'sp_addmergepushsubscription_agent'.
			RAISERROR(21797, 16, -1, '@job_login', 'sp_addmergepushsubscription_agent')
			RETURN 1
		END
	END

	-- retrieve the distribution database name			
	EXEC @retcode = sys.sp_helpdistributor @rpcsrvname = @distributor_rpc OUTPUT, @distribdb = @distribution_db OUTPUT
	IF @@error <> 0 or @retcode <> 0 or @distribution_db is NULL
	BEGIN
		-- "The Distributor has not been installed correctly."
		RAISERROR(20036, 16, -1)
		RETURN 1
	END

	SELECT @procedure = QUOTENAME(RTRIM(@distributor_rpc)) + '.' + QUOTENAME(RTRIM(@distribution_db)) + '.sys.sp_MSreplagentjobexists'
	EXEC  @procedure @type = 1,
						@exists = @exists OUTPUT,
						@job_name = @merge_job_name output,
						@proxy_id = @proxy_id output,
						@publisher = @publisher,
						@publisher_db = @publisher_db,
						@publication = @publication,
						@subscriber =  @subscriber_with_port,
						@subscriber_db = @subscriber_db
	IF @@ERROR <> 0 OR @retcode <> 0
		RETURN 1

	IF @exists = 1
	BEGIN
		-- We have 2 cases here:
		--
		-- 1) if we require the yukon security model then fail since  
		-- the add was expected and the subscription already exists
		--
		-- 2) We are here then this is a sysadmin call and if a 
		-- proxy account already exists on the job then they can
		-- not call the add proc again they need to call change
		IF sys.fn_yukonsecuritymodelrequired(NULL) = 1
			OR @proxy_id IS NOT NULL
		BEGIN
			-- "A replication agent job (%s) for this subscription already exists."
			RAISERROR (21837, 11, -1, @merge_job_name)
			RETURN 1	
		END
		
		SELECT @procedure =  QUOTENAME(RTRIM(@distributor_rpc)) + '.' + QUOTENAME(RTRIM(@distribution_db)) + '.sys.sp_MSdrop_merge_agent'
		EXEC @retcode = @procedure @publisher = @publisher,
									@publisher_db = @publisher_db,
									@publication = @publication,
									@subscriber =  @subscriber_with_port,
									@subscriber_db = @subscriber_db,
									@job_only = 1    
		IF @retcode <> 0 OR @@ERROR <> 0
			RETURN 1
	END
	
	declare @publisher_engine_edition int
	
	select @publisher_engine_edition = sys.fn_MSrepl_editionid()
	
	SELECT @procedure = QUOTENAME(RTRIM(@distributor_rpc)) + '.' + QUOTENAME(RTRIM(@distribution_db)) + '.sys.sp_MSadd_merge_agent'
	EXEC  @procedure  @name = @job_name,
						@publisher = @publisher,
						@publisher_db = @publisher_db,
						@publication = @publication,
						@subscriber = @subscriber_with_port,
						@subscriber_db = @subscriber_db,
						@local_job = 1,
						@frequency_type = @frequency_type,
						@frequency_interval = @frequency_interval,
						@frequency_relative_interval = @frequency_relative_interval, 
						@frequency_recurrence_factor = @frequency_recurrence_factor,
						@frequency_subday = @frequency_subday,
						@frequency_subday_interval = @frequency_subday_interval,
						@active_start_time_of_day = @active_start_time_of_day,
						@active_end_time_of_day = @active_end_time_of_day,
						@active_start_date = @active_start_date,
						@active_end_date = @active_end_date,
						@merge_jobid = @merge_jobid OUTPUT,
						@subscription_type = 0,
						@hostname = @hostname,
						@subscriber_security_mode = @subscriber_security_mode,
						@subscriber_login = @subscriber_login,
						@subscriber_password = @subscriber_password,
						@publisher_security_mode = @publisher_security_mode,
						@publisher_login = @publisher_login,
						@publisher_password = @publisher_password,
						@job_login = @job_login,
						@job_password = @job_password,
						@internal = N'YUKON ADD AGENT',
						@publisher_engine_edition = @publisher_engine_edition
	IF @@ERROR <> 0 OR @retcode <> 0
		RETURN 1

	UPDATE MSmerge_replinfo
		SET  merge_jobid = @merge_jobid
		WHERE repid = @subid
		
	-- Conditional support for MobileSync
	IF LOWER(@enabled_for_syncmgr collate SQL_Latin1_General_CP1_CS_AS) = 'true'
	BEGIN
		EXEC @retcode = sys.sp_helpdistributor @distributor = @distributor OUTPUT
		IF @@ERROR <> 0 OR @retcode <> 0
			RETURN 1

		-- Always use integrated security on winNT
		SELECT @distrib_pwd = newid()

		EXEC @retcode = sys.sp_MSreplencrypt @distrib_pwd output
		IF @@ERROR <> 0 OR @retcode <> 0
			RETURN 1

		-- Call sp_MSregistersubscription so that the subscription can be synchronized via Onestop etc.
		EXEC @retcode = sys.sp_MSregistersubscription @replication_type = 2,
														@publisher = @publisher,
														@publisher_db = @publisher_db,
														@publication = @publication,
														@subscriber =  @subscriber_with_port,
														@subscriber_db = @subscriber_db,
														@distributor = @distributor,
														@distributor_security_mode = 1,
														@distributor_login = N'',
														@distributor_password = @distrib_pwd,
														@subscription_id = @subid,
														@subscription_type = 0,
														@use_interactive_resolver = @use_ir,
														@hostname = @hostname
		IF @@ERROR <> 0 OR @retcode <> 0
			RETURN 1
	END

	-- If we didn't need to create the job but 
	-- we were given the job_login and job_password
	-- then we will attempt to change them or add
	-- NOTE:
	-- We do this at the very end because the actual
	-- agent must be added prior to setting the login
	-- and passwords...
	IF @job_name IS NOT NULL
	BEGIN
		IF @job_login IS NOT NULL
		BEGIN
			EXEC @retcode = sys.sp_changemergesubscription @publication = @publication,
															@subscriber =  @subscriber_with_port,
															@subscriber_db = @subscriber_db,
														    @property = 'merge_job_login',
															@value = @job_login
			IF @retcode <> 0 OR @@ERROR <> 0
	            RETURN 1


	        IF @job_password IS NOT NULL
	        BEGIN
				EXEC @retcode = sys.sp_changemergesubscription @publication = @publication,
																@subscriber =  @subscriber_with_port,
																@subscriber_db = @subscriber_db,
															    @property = 'merge_job_password',
																@value = @job_password
				IF @retcode <> 0 OR @@ERROR <> 0
		            RETURN 1
	        END
		END
	END

	RETURN 0
END
GO
GRANT EXECUTE ON [sys].[sp_addmergepushsubscription_agent] TO [public] AS [dbo]
GO
