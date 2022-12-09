SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSadd_distribution_agent]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSadd_distribution_agent] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSadd_distribution_agent]
	@name [sysname],
	@publisher_id [smallint],
	@publisher_db [sysname],
	@publication [sysname],
	@subscriber_id [smallint],
	@subscriber_db [sysname],
	@subscription_type [int],
	@local_job [bit],
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
	@retryattempts [int],
	@retrydelay [int],
	@command [nvarchar](4000),
	@agent_id [int] OUTPUT,
	@distribution_jobid [binary](16) OUTPUT,
	@update_mode [int],
	@offloadagent [bit],
	@offloadserver [sysname],
	@dts_package_name [sysname],
	@dts_package_password [nvarchar](524),
	@dts_package_location [int],
	@subscriber_security_mode [smallint],
	@subscriber_login [sysname],
	@subscriber_password [nvarchar](524),
	@job_login [nvarchar](257),
	@job_password [sysname],
	@internal [sysname],
	@subscriber_provider [sysname],
	@subscriber_datasrc [nvarchar](4000),
	@subscriber_location [nvarchar](4000),
	@subscriber_provider_string [nvarchar](4000),
	@subscriber_catalog [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
	
	SET NOCOUNT ON

	/*
	** Declarations.
	*/
	DECLARE	@retcode					int,
			@database					sysname,
			@profile_id					int,
			@distribution_type			int,
			@publisher					sysname,
			@publisher_type				sysname,
			@loc_publisher_db			sysname,
			@category_name				sysname,
			@subscriber					sysname,
			@publisher_database_id		int,
			@queue_server				sysname,
			@queue_id					sysname,
			@distrib_job_step_uid 		uniqueidentifier,
			@subscriber_type			int,
			@dsn_subscriber 			int, 
			@oledb_subscriber 			int,
			@dsn_dbname					sysname,
			@optional_cmdline			nvarchar(4000),
			@independent_agent			int,
			@job_existing 				bit,
			@comments					nvarchar(255),
			@listener					sysname = NULL,
			@distribution_db			sysname
				
	SELECT @dsn_subscriber = 1, 
			@oledb_subscriber = 3,
			@dsn_dbname = formatmessage(20586)

	-- Security Check: require sysadmin
	IF (ISNULL(IS_SRVROLEMEMBER('sysadmin'),0) = 0)
	BEGIN
		RAISERROR(21089,16,-1) 
		RETURN 1
	END

	IF (sys.fn_MSrepl_isdistdb (DB_NAME()) != 1)
	BEGIN
		-- "sp_MSadd_subscription can only be executed in the distribution database."
		RAISERROR(21482, 16, -1, 'sp_MSadd_subscription', 'distribution')
		RETURN 1
	END

	IF @offloadagent IS NOT NULL
		AND @offloadagent != 0
	BEGIN
		-- "Parameter '@offloadagent' is no longer supported."
		RAISERROR(21698, 16, -1, '@offloadagent')
		RETURN 1
	END

	IF ISNULL(@offloadserver, N'') != N''
	BEGIN
		-- "Parameter '@offloadserver' is no longer supported."
		RAISERROR(21698, 16, -1, '@offloadserver')
		RETURN 1
	END

	/*
	** Initializations
	*/
	select @database = DB_NAME()

	-- Adjust the optional_commandline
	SELECT @optional_cmdline = ISNULL(RTRIM(LTRIM(@command)), N'')
	SELECT @command = NULL

	-- ONLY ALLOW THIS IN 8.0 or less CASE
	IF @internal = N'PRE-YUKON'
	BEGIN
		-- if @name is not null, the proc is from DMO scripting
		-- check to see if the job is there or not, if not, reset @job_existing and
		-- @name values. This is for the case when the user generate the script at
		-- the publisher but did not re-create repl jobs at the distributor.
		if @local_job = 1 and @name is not null and 
		   @name <> N''
		begin
			if not exists (select * from msdb.dbo.sysjobs_view 
			where name = @name 
				and UPPER(originating_server) = UPPER(CONVERT(sysname, SERVERPROPERTY('ServerName')))
				and master_server = 0)
			begin
				set @name = null
			end
		end
	END
	
	BEGIN TRAN tran_sp_MSadd_distribution_agent
	SAVE TRAN tran_sp_MSadd_distribution_agent
	
	/* Code for distribution agent type in MSagent_profiles */
	SELECT @distribution_type = 3

	SELECT @profile_id = profile_id
	FROM msdb..MSagent_profiles
	WHERE agent_type = @distribution_type
		AND def_profile = 1

	IF @profile_id IS NULL
		GOTO UNDO

    SELECT	@publisher = srvname
    FROM	MSreplservers
    WHERE	srvid = @publisher_id

    SELECT	@subscriber = srvname
    FROM	MSreplservers
    WHERE	srvid = @subscriber_id

	SELECT	@publisher_database_id = id
	FROM	MSpublisher_databases
	WHERE	publisher_id = @publisher_id
	  AND	publisher_db = @publisher_db
	
	-- Get publisher type
	EXEC @retcode = sys.sp_MSrepl_getdistributorinfo	@publisher		= @publisher,
														@publisher_type	= @publisher_type OUTPUT

	IF @retcode != 0 OR @@ERROR != 0
	BEGIN
		GOTO UNDO
	END

   	-- For naming purposes, use @publisher instead of @publisher_db for HREPL
   	-- publishers that don't support publisher db notion
	IF @publisher_type LIKE N'ORACLE%'
	BEGIN
		SELECT @loc_publisher_db = @publisher
	END
	ELSE
	BEGIN
		SELECT @loc_publisher_db = @publisher_db
	END

	-- Encrypt the dts password before storing, but only do so if this 
	-- procedure is called from sp_addpushsubscription_agent
	IF @internal <> N'PRE-YUKON'
	BEGIN
		EXEC @retcode = sys.sp_MSreplencrypt @dts_package_password OUTPUT
		IF @@ERROR <> 0 OR  @retcode <> 0
			GOTO UNDO
	END
	
	IF @internal = N'PRE-YUKON'
		OR @internal = N'YUKON ADD AGENT'
	BEGIN
		-- if this is a pull or anon case and a value is not provided for the 
		-- security mode then we will default the value to be integrated. this 
		-- makes sense because the subsec mode for pull is only used in the queued 
		-- case and in that case we always want the sub to default to integrated
		IF @subscription_type != 0
			AND @subscriber_security_mode is NULL
		BEGIN
			SELECT @subscriber_security_mode = 1
		END

		-- if the subscriber sec info was not provided then default
		-- the vals to the values provided durring sp_addsubscriber...
		-- this is only possible when called by SYSADMIN or 8.0 pub.
		IF @subscriber_security_mode IS NULL
		BEGIN
			SELECT @subscriber_security_mode = security_mode,
					@subscriber_login = login,
					@subscriber_password = password
				FROM MSsubscriber_info 
				WHERE UPPER(publisher) = UPPER(@publisher) 
					AND UPPER(subscriber) = UPPER(@subscriber)

			IF @subscriber_security_mode IS NULL
			BEGIN
				SELECT @subscriber_security_mode = 1,
						@subscriber_login = '',
						@subscriber_password = newid()

				-- Encrypt the password before storing
				EXEC @retcode = sys.sp_MSreplencrypt @subscriber_password OUTPUT
				IF @@ERROR <> 0 OR  @retcode <> 0
					GOTO UNDO
			END
		END
		ELSE
		BEGIN
			-- if WINDOWS authentication then clear out the login/password
			IF @subscriber_security_mode = 1
			BEGIN
				select @subscriber_login = '',
						@subscriber_password = newid()
			END

			-- Encrypt the password before storing
			EXEC @retcode = sys.sp_MSreplencrypt @subscriber_password OUTPUT
			IF @@ERROR <> 0 OR  @retcode <> 0
				GOTO UNDO
		END

		-- Get default task parameter values from MSsubscriber_info 
		SELECT @subscriber_type = type
			FROM MSsubscriber_info 
			WHERE UPPER(publisher) = UPPER(@publisher) 
				AND UPPER(subscriber) = UPPER(@subscriber)

		-- Only SQL Server and OLEDB subscriber support dts
		IF @dts_package_name IS NOT NULL
			AND @subscriber_type NOT IN (0, 3)
		BEGIN
			-- Only sqlserver or oledb sub are allowed
			RAISERROR(21170, 16, -1)
			GOTO UNDO
		END	
	END
	
	-- Cloud Lifter edition (CL) uses values provided through @job_login and @job_password
	-- for SQL authentication (Windows authentication and proxies are not supported in CL)
	DECLARE @cl_login nvarchar(257), @cl_password nvarchar(524)
	IF sys.fn_MSrepl_editionid() = 32 AND @job_login IS NOT NULL AND @job_password IS NOT NULL
	BEGIN
		-- @job_login and @job_password should be nullified to avoid use of them for proxy configuration
		SELECT @cl_login = @job_login, @cl_password = @job_password, @job_login = NULL, @job_password = NULL
		-- Encrypt the password before storing
		EXEC @retcode = sys.sp_MSreplencrypt @cl_password OUTPUT
		IF @@ERROR <> 0 OR @retcode <> 0
			GOTO UNDO
	END

	IF @internal = N'PRE-YUKON'
		OR @internal = N'YUKON ADD SUB'
	BEGIN
		IF @internal = N'YUKON ADD SUB'
		BEGIN
			-- When calling it from internal = 'YUKON ADD SUB' we know 
			-- that the security information should not have been provided
			SELECT @subscriber_security_mode = 1,
					@subscriber_login = '',
					@subscriber_password = newid()

			-- Encrypt the password before storing
			EXEC @retcode = sys.sp_MSreplencrypt @subscriber_password OUTPUT
			IF @@ERROR <> 0 OR  @retcode <> 0
				GOTO UNDO
		END
		
		-- Try to drop it first
		EXEC @retcode = sys.sp_MSdrop_distribution_agent 
							@publisher_id = @publisher_id,
							@publisher_db = @publisher_db,
							@publication = @publication,
							@subscriber_id = @subscriber_id,
							@subscriber_db = @subscriber_db,
							@subscription_type = @subscription_type
		IF @@ERROR <> 0 or @retcode <> 0
			GOTO UNDO

		--
		-- If this is a queued subscription
		-- Process the queue creation
		--
		if (@update_mode in (2,3,7))
		begin
			--
			-- MSMQ Queue being used
			--
			exec @retcode = sys.sp_MSaddmqforsubscription @queue_server output, @queue_id output
			if (@retcode != 0 or @@error != 0)
				goto UNDO
		end
		else if (@update_mode in (4,5,6))
		begin
			--
			-- SQL Queue being used
			--
			select @queue_id = N'mssqlqueue'
		end
		
		/* 
		** Insert row
		*/
		INSERT INTO MSdistribution_agents (name, publisher_database_id, publisher_id, publisher_db, publication, 
				subscriber_id, subscriber_db, subscription_type, local_job, 
				subscription_guid, profile_id, queue_id, queue_server,
				dts_package_name, dts_package_password, dts_package_location,
				subscriber_security_mode, subscriber_login, subscriber_password,
				job_login, job_password)
			VALUES ('',@publisher_database_id, @publisher_id, @publisher_db, @publication, 
				@subscriber_id, @subscriber_db, @subscription_type, @local_job, 
				newid(), @profile_id, @queue_id, @queue_server,
				@dts_package_name, @dts_package_password, @dts_package_location,
				@subscriber_security_mode, @subscriber_login, @subscriber_password,
				@cl_login, @cl_password)
		IF @@ERROR <> 0
			GOTO UNDO
		
		SELECT @agent_id = @@IDENTITY
		
		--
		-- For independant agent - Add an entry to history to indicate the subscription is uninitialized (runstatus = 0)
		--
		if @publication is not null and (lower(@publication)<>'all')
		begin
			select @comments = isnull(formatmessage(21019), N'Message 21019')
			exec @retcode = sys.sp_MSadd_distribution_history 
								@agent_id = @agent_id
								,@runstatus = 0
								,@comments = @comments
								,@updateable_row = 0
								,@do_raiserror = 0
			IF @@ERROR <> 0 OR @retcode <> 0
				GOTO UNDO
		end
	END
	ELSE IF @internal = N'YUKON ADD AGENT'
	BEGIN		
		SELECT @agent_id = id
			FROM MSdistribution_agents
			WHERE publisher_id = @publisher_id 
				AND publisher_db = @publisher_db 
				AND publication = @publication 
				AND subscriber_id = @subscriber_id 
				AND subscriber_db = @subscriber_db 
				AND subscription_type = @subscription_type

		IF @agent_id IS NULL
		BEGIN
			-- "The subscription could not be found."
			RAISERROR (20021, 16, -1)
			GOTO UNDO
		END
			
		UPDATE MSdistribution_agents
			SET dts_package_name = @dts_package_name, 
				dts_package_password = @dts_package_password, 
				dts_package_location = @dts_package_location,
				subscriber_security_mode = @subscriber_security_mode, 
				subscriber_login = @subscriber_login, 
				subscriber_password = @subscriber_password,
				subscriber_provider = @subscriber_provider,
				subscriber_datasrc  = @subscriber_datasrc,
				subscriber_location = @subscriber_location,
				subscriber_provider_string = @subscriber_provider_string,
				subscriber_catalog = @subscriber_catalog,
				job_login = @cl_login,
				job_password = @cl_password
			WHERE id = @agent_id
	END

	-- Set agent name
	SELECT @subscriber = ISNULL(@subscriber, ''),
			@subscriber_db = ISNULL(@subscriber_db, '')

	IF @name IS NULL OR @name = N''
	BEGIN
		/*
		** Sacrifice 1-2 character from each of (@publisher,@publication,
		** @publisher_db,subscriber) to allow 4 more indentity digits in
		** the distribution agent name. This will hopefully provide better
		** guarantee of agent name uniqueness.
		*/
		IF @publication is NOT NULL and (LOWER(@publication)<>'all')
		BEGIN				
			SELECT  @name = LEFT(@publisher, 21) + '-' + 
							LEFT(@loc_publisher_db, 21) + '-' + 
							LEFT(@publication, 21) + '-' + 
							LEFT(@subscriber, 21) + '-' +
							CONVERT(nvarchar(21), @agent_id)
		END
		ELSE
		BEGIN
			SELECT  @name = LEFT(@publisher, 28) + '-' + 
							LEFT(@loc_publisher_db, 28) + '-' + 
							LEFT(@subscriber, 28) + '-' + 
							CONVERT(nvarchar(28), @agent_id)
		END

		-- If creating a new job and the generated name already 
		-- exists, re-generate the name with a guid appended
		IF EXISTS
		(
			SELECT  *
				FROM	 msdb.dbo.sysjobs_view 
				WHERE	 name = @name 
					AND	 UPPER(originating_server) = UPPER(CONVERT(sysname, SERVERPROPERTY('ServerName')))
					AND	 master_server = 0
		)
		BEGIN
			IF @publication is NOT NULL and (LOWER(@publication)<>'all')
			BEGIN
				SELECT  @name = fn_repluniquename(newid(), @publisher, @loc_publisher_db, @publication, @subscriber)
			END
			ELSE
			BEGIN
				SELECT  @name = fn_repluniquename(newid(), @publisher, @loc_publisher_db, @subscriber, null)
			END
		END

		SELECT @job_existing = 0
	END
	ELSE
	BEGIN
		SELECT @job_existing = 1
	END
	
	IF @internal = N'PRE-YUKON'
		OR @internal = N'YUKON ADD AGENT'
	BEGIN
		-- Reset @publication if shared agent
		SELECT @independent_agent = independent_agent
			FROM dbo.MSpublications 
			WHERE publisher_id = @publisher_id 
				AND publisher_db = @publisher_db
				AND publication = @publication

		IF @independent_agent = 0
			SELECT @publication = 'ALL'
		
		-- Check the existance of the package if it is at the distributor side.
		if @dts_package_name is not null 
			and @dts_package_location = 0
		begin
			exec @retcode = dbo.sp_MSrepl_validate_dts_package
				@name = @dts_package_name
			IF @@ERROR <> 0 or @retcode <> 0
				GOTO UNDO
		end
		
		-- Add Perfmon instance
		dbcc addinstance ("SQL Replication Distribution", @name)

		IF @local_job = 1
		BEGIN
			if @job_existing = 0
			begin
				-- Get subscriber port number
				declare @subscriber_with_port sysname
				exec sys.sp_MSget_server_portinfo 
					@name = @subscriber,
					@srvname_with_port = @subscriber_with_port OUTPUT

				-- Get publisher port number
				declare @publisher_with_port sysname
				exec sys.sp_MSget_server_portinfo 
					@name = @publisher,
					@srvname_with_port = @publisher_with_port OUTPUT

				-- Get servername port number
				declare @srvname_with_port sysname
				exec sys.sp_MSget_server_portinfo 
					@name = @@SERVERNAME,
					@srvname_with_port = @srvname_with_port OUTPUT
				-- Construct task command 
				SELECT @command = '-Subscriber ' + QUOTENAME(@subscriber_with_port)  + ' '

				-- DSN subscribers don't have a subscriber db name.
				-- 7.0 publisher still uses DSN. 8.0 publisher use localized '(default destination)'
				-- ActiveX may use unlocalized '(default destination)'
				IF @subscriber_db IS NOT NULL 
					AND @subscriber_db NOT IN( N'(default destination)', N'DSN', @dsn_dbname)
				BEGIN
					SELECT @command = @command  + '-SubscriberDB ' + QUOTENAME(@subscriber_db) + ' '
				END

				SELECT @command = @command + '-Publisher ' + QUOTENAME(@publisher_with_port) + ' '
				SELECT @distribution_db = distribution_db FROM msdb.dbo.MSdistpublishers WHERE name = @publisher
				
				IF (EXISTS (SELECT * FROM sys.dm_hadr_database_replica_states WHERE database_id = DB_ID(@distribution_db))) and serverproperty('EngineEdition') <> 8 -- Check AG DMV when its not Managed Instance
				BEGIN
					SELECT TOP 1 @listener = dns_name FROM sys.availability_group_listeners AGL
						INNER JOIN sys.dm_hadr_database_replica_states DBRepl ON AGL.group_id = DBRepl.group_id
						WHERE DBRepl.database_id = DB_ID(@distribution_db)
					IF @listener IS NULL
					BEGIN
						RAISERROR(25033, 16, -1)
						GOTO UNDO
					END
				END
				SELECT @command = @command + '-Distributor ' + QUOTENAME(ISNULL(@listener,@srvname_with_port)) + ' '


				-- Always use integrated security for the local connection
				SELECT @command = @command + '-DistributorSecurityMode 1 '

				IF @independent_agent = 1
					SELECT @command = @command + '-Publication ' + QUOTENAME(@publication) + ' '

				IF @publisher_db IS NOT NULL
					SELECT @command = @command + '-PublisherDB ' + QUOTENAME(@publisher_db) + ' '

				IF @subscriber_type = @dsn_subscriber 
					OR @subscriber_type = @oledb_subscriber
				BEGIN
					SELECT @command = @command + '-SubscriberType ' + convert (nvarchar(10), @subscriber_type) + ' '
				END

				IF @dts_package_name IS NOT NULL
					SELECT @command = @command + '-UseDTS '

				IF datalength(@command) + datalength(@optional_cmdline) > 8000
				BEGIN
					-- "The @optional_command_line is too long. Use an agent definition file."
					RAISERROR(20018, 16, -1)
					GOTO UNDO
				END

				SELECT @command = @command + N' ' +  @optional_cmdline + N' '
				
				DECLARE @nullchar nchar(20)
				SELECT @nullchar = NULL
				-- Get Distribution category name (assumes category_id = 10)
				select @category_name = name FROM msdb.dbo.syscategories where category_id = 10

				if @frequency_recurrence_factor is null
					select @frequency_recurrence_factor = 0
				 
				EXECUTE @retcode = dbo.sp_MSadd_repl_job
				@name = @name,
				@subsystem = 'Distribution',
				@server = @@SERVERNAME,
				@databasename = @database,
				@enabled = 1,
				@freqtype = @frequency_type,
				@freqinterval = @frequency_interval,
				@freqsubtype = @frequency_subday,
				@freqsubinterval = @frequency_subday_interval,
				@freqrelativeinterval = @frequency_relative_interval,
				@freqrecurrencefactor = @frequency_recurrence_factor,
				@activestartdate = @active_start_date,
				@activeenddate = @active_end_date,
				@activestarttimeofday = @active_start_time_of_day,
				@activeendtimeofday = @active_end_time_of_day,
				@nextrundate = 0,
				@nextruntime = 0,
				@runpriority = 0,
				@emailoperatorname = NULL,
				@retryattempts = @retryattempts,
				@retrydelay = @retrydelay,
				@command = @command,
				@loghistcompletionlevel = 0,
				@emailcompletionlevel = 0,
				@description = NULL,
				@category_name = @category_name,
				@failure_detection = 1,
				@agent_id = @agent_id,
				@job_login = @job_login,
				@job_password = @job_password,
				@job_id = @distribution_jobid OUTPUT,
				@job_step_uid = @distrib_job_step_uid OUTPUT

			   	IF @@ERROR <> 0 or @retcode <> 0
					GOTO UNDO

				-- note that we only raise the warning when called from 
				-- 'PRE-YUKON' code. when called from 'YUKON ADD AGENT' the 
				-- warning is not needed since it that case it was not implicit
				IF @internal = N'PRE-YUKON'
				BEGIN
					-- Warning: The distribution agent job has been implicitly created and will run under the SQL Server Agent Service Account.
					RAISERROR(21452, 10, -1, 'distribution')
				END
			end
			else
			begin
				-- retrieve the agent job step uid
				select @distribution_jobid = sjv.job_id,
						@distrib_job_step_uid = sjs.step_uid
				from msdb.dbo.sysjobs_view as sjv
					join msdb.dbo.sysjobsteps as sjs
						on sjv.job_id = sjs.job_id
				where sjv.name = @name
					and sjv.master_server = 0
					and UPPER(sjv.originating_server) = UPPER(CONVERT(sysname, SERVERPROPERTY('ServerName')))
					and sjv.category_id = 10
					and sjs.subsystem = N'Distribution'
					and sjs.database_name = db_name()
					
				if @distribution_jobid IS NULL
				begin
					-- Message from msdb.dbo.sp_verify_job_identifiers
					RAISERROR(14262, -1, -1, 'Distribution Job', @name)          
					GOTO UNDO
				end
			end
		END
		ELSE 
		BEGIN
			-- Generate a job GUID for remote agents. This will be used by the UI to uniquely
			-- identify rows returned by the enums
			set @distribution_jobid = newid();
			set @distrib_job_step_uid = NULL
		END
	END
	ELSE IF @internal = N'YUKON ADD SUB'
	BEGIN
		-- Generate a job GUID even when we haven't created the job agent. This 
		-- will be used by the UI to uniquely identify rows returned by the enums
		SELECT @distribution_jobid = newid(),
				@distrib_job_step_uid  = NULL
	END

	UPDATE MSdistribution_agents 
		SET name = ISNULL(@name, ''),
			job_id = @distribution_jobid,
			job_step_uid = @distrib_job_step_uid
		WHERE id = @agent_id

	IF @@ERROR <> 0
		GOTO UNDO

	--
	-- commit the transaction
	--
	COMMIT TRAN
	--
	-- all done
	--
	RETURN(0)
UNDO:
	IF @internal = N'PRE-YUKON'
		OR @internal = N'YUKON ADD SUB'
	BEGIN
		--
		-- delete the MSMQ queue if necessary
		--
		if (@update_mode in (2,3,7) and @queue_server IS NOT NULL and @queue_id IS NOT NULL)
		begin
			exec sys.sp_MSdropmqforsubscription @queue_server, @queue_id
		end
	END
	
	if @@TRANCOUNT > 0
	begin
		ROLLBACK TRAN tran_sp_MSadd_distribution_agent
		COMMIT TRAN
	end
	
	return(1)
END
GO
GRANT EXECUTE ON [sys].[sp_MSadd_distribution_agent] TO [public] AS [dbo]
GO
