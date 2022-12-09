SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSadd_merge_agent]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSadd_merge_agent] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSadd_merge_agent]
	@name [sysname],
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname],
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
	@optional_command_line [nvarchar](255),
	@merge_jobid [binary](16) OUTPUT,
	@offloadagent [bit],
	@offloadserver [sysname],
	@subscription_type [int],
	@hostname [sysname],
	@subscriber_security_mode [smallint],
	@subscriber_login [sysname],
	@subscriber_password [nvarchar](524),
	@publisher_security_mode [smallint],
	@publisher_login [sysname],
	@publisher_password [nvarchar](524),
	@job_login [nvarchar](257),
	@job_password [sysname],
	@internal [sysname],
	@publisher_engine_edition [int]
WITH EXECUTE AS CALLER
AS
begin
	SET NOCOUNT ON

	/*
	** Declarations.
	*/
	declare @retcode        int
	DECLARE @publisher_id   smallint
	DECLARE @subscriber_id  smallint
	DECLARE @profile_id     int
	DECLARE @merge_type     int
	DECLARE @command        nvarchar(4000)

	DECLARE @subscriber_datasource_type     int     /* 0 SQL Server, 1 ODBC, 2 Jet, 3 OLEDB */
	DECLARE @distributor                    sysname 
	DECLARE @database                       sysname
	DECLARE @agent_id                       int
	DECLARE @category_name                  sysname
	DECLARE @dsn_subscriber                 tinyint
	DECLARE @jet_subscriber                 tinyint
	DECLARE @oledb_subscriber               tinyint
	DECLARE @exchange_subscriber            tinyint
	DECLARE @oracle_subscriber              tinyint
	DECLARE @db2universal_subscriber        tinyint
	DECLARE @platform_nt                    binary
	DECLARE @provider_name					sysname
	DECLARE @merge_job_step_uid				uniqueidentifier
	DECLARE @subscriber_encrypted_password 	nvarchar(524)
	DECLARE @publisher_encrypted_password 	nvarchar(524)
	
	set @distributor = @@SERVERNAME

	set @dsn_subscriber = 1    /* Const: subscriber type 'dsn' */ 
	set @jet_subscriber = 2   
	set @oledb_subscriber = 3 
	set @exchange_subscriber = 4
	set @oracle_subscriber = 5 
	set @db2universal_subscriber = 6

	set @platform_nt = 0x1  

	set @merge_job_step_uid = NULL

	-- Security Check: require sysadmin
	IF (ISNULL(IS_SRVROLEMEMBER('sysadmin'),0) = 0)
	BEGIN
		RAISERROR(21089,16,-1) 
		RETURN 1
	END

	IF (sys.fn_MSrepl_isdistdb (DB_NAME()) != 1)
	BEGIN
	   	-- "sp_MSadd_merge_agent can only be executed in the distribution database."
		RAISERROR(21482, 16, -1, 'sp_MSadd_merge_agent', 'distribution')
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
	
    -- Set null @optional_command_line to empty string to avoid string concat problem
    SELECT @optional_command_line = ISNULL(N' ' + LTRIM( RTRIM(@optional_command_line) ) + N' ', N'')
    
    /*
    ** Initializations
    */
    -- Get subscriber info
    select @subscriber_id = srvid from MSreplservers where UPPER(srvname) = UPPER(@subscriber)
    select @publisher_id = srvid from MSreplservers where UPPER(srvname) = UPPER(@publisher)

	select @subscriber_datasource_type = type
		from MSsubscriber_info 
		where UPPER(publisher) = UPPER(@publisher) and UPPER(subscriber) = UPPER(@subscriber)

	/*
	** Jet and Oracle subscribers are actually added to MSsubscriber_info as OLE DB subscribers,
	** since they can be used in transactional replication also.
	** Map the type to Jet or Oracle based on OLE DB provider name.
	*/
	if (@subscriber_datasource_type = @oledb_subscriber) 
	BEGIN
		select @provider_name = providername from master.dbo.sysservers where UPPER(srvname) = UPPER(@subscriber)
		if (upper(@provider_name) = 'MICROSOFT.JET.OLEDB.4.0')
			select @subscriber_datasource_type = @jet_subscriber
		else if (upper(@provider_name) = 'MSDAORA')
			select @subscriber_datasource_type = @oracle_subscriber
		else if (upper(@provider_name) = 'DB2OLEDB')
			select @subscriber_datasource_type = @db2universal_subscriber
	END
	
	if (@subscriber_datasource_type IS NULL)
		select @subscriber_datasource_type = 0

	-- ONLY ALLOW THIS IN 8.0 or less CASE
	IF @internal = N'PRE-YUKON'
	BEGIN
		-- if @name is not null, the proc is from DMO scripting
		-- check to see if the job is there are not, if not, reset @job_existing and
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
	
	BEGIN TRANSACTION tr_add_merge_agent
	SAVE TRANSACTION tr_add_merge_agent

	/* Code for merge agent type in MSagent_profiles */
	SELECT @merge_type = 4

	SELECT @profile_id = profile_id
	FROM msdb..MSagent_profiles
	WHERE agent_type = @merge_type
		AND def_profile = 1

	IF @profile_id IS NULL
		RETURN (1)

	IF @internal = N'PRE-YUKON'
		OR @internal = N'YUKON ADD AGENT'
	BEGIN
		-- if the subscriber sec info was not provided then default
		-- the vals to the values provided durring sp_addsubscriber...
		-- this is only possible when called by SYSADMIN or 8.0 pub.
		IF @subscriber_security_mode is NULL
		BEGIN
			--Get default task parameter values from MSsubscriber_info 
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
			IF @subscriber_security_mode = 1
			BEGIN
				SELECT @subscriber_login = N'',
						@subscriber_password = newid()
			END

			EXEC @retcode = sys.sp_MSreplencrypt @subscriber_password OUTPUT
			IF @@error <> 0 or @retcode <> 0
				GOTO UNDO
		END

		-- if the publisher sec info was not provided then default
		-- the vals to the values provided durring sp_adddistpublisher...
		-- this is only possible when called by SYSADMIN or 8.0 pub.
		IF @publisher_security_mode is NULL
		BEGIN
			-- if the publisher security mode was not provided then 
			-- we will fall back to the backcmpt form which is the 
			-- value found in the msdb..MSdistpublishers table...
			select @publisher_security_mode = security_mode,
					@publisher_login = login,
					@publisher_password = password
				from msdb..MSdistpublishers
				where upper(name) = upper(@publisher)
					and distribution_db = db_name()
		END
		ELSE 
		BEGIN
			IF @publisher_security_mode = 1
			BEGIN
				SELECT @publisher_login = N'',
						@publisher_password = newid()
			END

			EXEC @retcode = sys.sp_MSreplencrypt @publisher_password OUTPUT
			IF @@error <> 0 or @retcode <> 0
				GOTO UNDO
		END
	END
	
	IF @internal = N'PRE-YUKON'
		OR @internal = N'YUKON ADD SUB'
	BEGIN
		-- Try to drop it first
		EXEC sys.sp_MSdrop_merge_agent 
			@publisher = @publisher,
			@publisher_db = @publisher_db,
			@publication = @publication,
			@subscriber = @subscriber,
			@subscriber_db = @subscriber_db
		IF @@ERROR <> 0
			GOTO UNDO

		IF @internal = N'YUKON ADD SUB'
		BEGIN
			-- When calling it from internal = 0 we know that this is 
			-- a dummy row until the actual value is set on addpushagent
			SELECT @subscriber_security_mode = 1,
					@subscriber_login = N'',
					@subscriber_password = newid(),
					@publisher_security_mode = 1,
					@publisher_login = N'',
					@publisher_password = newid()

			EXEC @retcode = sys.sp_MSreplencrypt @subscriber_password OUTPUT
			IF @@error <> 0 or @retcode <> 0
				GOTO UNDO

			EXEC @retcode = sys.sp_MSreplencrypt @publisher_password OUTPUT
			IF @@error <> 0 or @retcode <> 0
				GOTO UNDO
		END
		
		exec @retcode = sys.sp_MScheck_subscription_count_internal @mode = 1, @publisher = @publisher, @publisher_engine_edition = @publisher_engine_edition,
						@about_to_insert_new_subscription=1
		if @@error <> 0 or @retcode <> 0
			goto UNDO
		
		/* 
		** Insert row
		*/
		INSERT INTO dbo.MSmerge_agents (name, publisher_id, publisher_db, publication, 
			 subscriber_id, subscriber_db, local_job, profile_id,
			 subscriber_security_mode, subscriber_login, subscriber_password, subscriber_name, 
			 publisher_security_mode, publisher_login, publisher_password)
			 VALUES ('',@publisher_id, @publisher_db, @publication, 
			 @subscriber_id, @subscriber_db, @local_job, @profile_id,
			 @subscriber_security_mode, @subscriber_login, @subscriber_password, @subscriber,
			 @publisher_security_mode, @publisher_login, @publisher_password)
		IF @@ERROR <> 0
			GOTO UNDO

		SELECT @agent_id = @@IDENTITY
	END
	ELSE IF @internal = N'YUKON ADD AGENT'
	BEGIN
		SELECT @agent_id = id
			FROM MSmerge_agents
			WHERE publisher_id = @publisher_id
				AND publisher_db = @publisher_db
				AND publication = @publication
				AND upper(subscriber_name) = upper(@subscriber)
				AND subscriber_db = @subscriber_db

		UPDATE MSmerge_agents
			SET subscriber_security_mode = @subscriber_security_mode,
				subscriber_login = @subscriber_login,
				subscriber_password = @subscriber_password,
				publisher_security_mode = @publisher_security_mode,
				publisher_login = @publisher_login,
				publisher_password = @publisher_password
			WHERE @agent_id = id
	END

	declare @job_existing bit
	IF @name IS NULL OR @name = N''
	begin
		SELECT @name = CONVERT(nvarchar(21),@publisher ) + '-' + CONVERT(nvarchar(21),@publisher_db) + '-' + 
						CONVERT(nvarchar(21),@publication) + '-' + CONVERT(nvarchar(21),@subscriber) + '-' +
						CONVERT(nvarchar, @agent_id)
		select @job_existing = 0
	end
	else
		select @job_existing = 1

	-- If creating a new job and the generated name already exists, re-generate the name with a 
	-- guid appended
	IF  @job_existing = 0
	BEGIN
		IF EXISTS (SELECT * FROM msdb.dbo.sysjobs_view 
						WHERE name = @name 
							AND UPPER(originating_server) = UPPER(CONVERT(sysname, SERVERPROPERTY('ServerName')))
							and master_server = 0)
		BEGIN
			SELECT @name = fn_repluniquename(newid(), @publisher, @publisher_db, 
						@publication, @subscriber)
		END			
	END
	
	IF @internal = N'PRE-YUKON'
		OR @internal = N'YUKON ADD AGENT'
	BEGIN
		if @frequency_type is NULL
			set @frequency_type = 4     /* Daily */
		if @frequency_interval is NULL
			set @frequency_interval = 1
		if @frequency_relative_interval is NULL
			set @frequency_relative_interval = 1
		if @frequency_recurrence_factor is NULL
			set @frequency_recurrence_factor = 0
		if @frequency_subday is NULL
			set @frequency_subday = 8   /* Hour */
		if @frequency_subday_interval is NULL
			set @frequency_subday_interval = 1
		if @active_start_time_of_day is NULL
			set @active_start_time_of_day = 0
		if @active_end_time_of_day is NULL
			set @active_end_time_of_day = 235959
		if @active_start_date is NULL
			set @active_start_date = 0
		if @active_end_date is NULL
			set @active_end_date = 99991231

		-- Add Perfmoon instance
		dbcc addinstance ("SQL Replication Merge", @name)
		 
	   	IF @local_job = 1
		BEGIN
			if @job_existing = 0
			begin
				-- Get subscriber port number
				declare @subscriber_with_port sysname
				exec sys.sp_MSget_server_portinfo 
					@name = @subscriber,
					@srvname_with_port = @subscriber_with_port OUTPUT

					-- Get distributor port number
				declare @distributor_with_port sysname
				exec sys.sp_MSget_server_portinfo 
					@name = @distributor,
					@srvname_with_port = @distributor_with_port OUTPUT

				-- Get publisher port number
				declare @publisher_with_port sysname
				exec sys.sp_MSget_server_portinfo 
					@name = @publisher,
					@srvname_with_port = @publisher_with_port OUTPUT

				/* Construct task command */

				select @command = '-Publisher ' + QUOTENAME(@publisher_with_port) + ' -PublisherDB ' + QUOTENAME(@publisher_db) + ' '
				select @command = @command + '-Publication ' + QUOTENAME(@publication) + ' '
				select @command = @command + '-Subscriber ' + QUOTENAME(@subscriber_with_port)  + ' '

				if (@subscriber_datasource_type = 0)
					select @command = @command + '-SubscriberDB ' + QUOTENAME(@subscriber_db) + ' '
			
				if (@subscriber_datasource_type <> 0)
					select @command = @command + '-SubscriberType ' + convert(nvarchar(10),@subscriber_datasource_type) + ' '
		
				select @command = @command + @optional_command_line
				select @command = @command + '-Distributor ' + QUOTENAME(@distributor_with_port) + ' '

				-- Always use integrated for local connection
				select @command = @command + '-DistributorSecurityMode 1 '
				
				if @hostname is not null and rtrim(ltrim(@hostname)) <> ''
					select @command = @command + '-HostName ' + quotename(@hostname) + ' '

				select @database = db_name()

				-- Get Merge category name (assumes category_id = 14)
				select @category_name = name FROM msdb.dbo.syscategories where category_id = 14

				EXEC @retcode = dbo.sp_MSadd_repl_job
						@name = @name,
						@subsystem = 'Merge',
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
						@command = @command,
						@category_name = @category_name,
						@failure_detection = 1,
						@agent_id = @agent_id,
						@retryattempts = 10,
						@retrydelay = 1,
						@job_login = @job_login,
						@job_password = @job_password,
						@job_id = @merge_jobid OUTPUT,
						@job_step_uid = @merge_job_step_uid OUTPUT
				
				if @@ERROR <> 0 or @retcode <> 0
					goto UNDO

				-- note that we only raise the warning when called from 
				-- 'PRE-YUKON' code. when called from 'YUKON ADD AGENT' the 
				-- warning is not needed since it that case it was not implicit
				IF @internal = N'PRE-YUKON'
				BEGIN
					-- Warning: The merge agent job has been implicitly created and will run under the SQL Server Agent Service Account.
					RAISERROR(21452, 10, -1, 'merge')
				END
			end
			else
			begin
				select @merge_jobid = sjv.job_id,
						@merge_job_step_uid = sjs.step_uid
				from msdb.dbo.sysjobs_view as sjv
					join msdb.dbo.sysjobsteps as sjs
						on sjv.job_id = sjs.job_id
				where sjv.name = @name
					and sjv.master_server = 0
					and UPPER(sjv.originating_server) = UPPER(CONVERT(sysname, SERVERPROPERTY('ServerName')))
					and sjv.category_id = 14
					and sjs.subsystem = N'Merge'
					and sjs.database_name = db_name()
				
				if @merge_jobid IS NULL
				begin
					-- Message from msdb.dbo.sp_verify_job_identifiers
					RAISERROR(14262, -1, -1, 'Merge Job', @name)          
					GOTO UNDO
				end
			end
		END
		ELSE 
		BEGIN
			-- Generate a job GUID for remote agents. This will be used by the UI to uniquely
			-- identify rows returned by the enums
			set @merge_jobid = newid();
			set @merge_job_step_uid = NULL
		END
	END
	ELSE 
	BEGIN
		-- Generate a job GUID even when we haven't created the job agent. This 
		-- will be used by the UI to uniquely identify rows returned by the enums
		SELECT @merge_jobid = newid(),
					@merge_job_step_uid = NULL
	END
			
	UPDATE dbo.MSmerge_agents 
		SET name = ISNULL(@name, N''),
			job_id = @merge_jobid,
			job_step_uid = @merge_job_step_uid
		WHERE id = @agent_id
	IF @@ERROR <> 0
		GOTO UNDO
	
	COMMIT TRANSACTION tr_add_merge_agent

	RETURN(0)

UNDO:

	if @@trancount > 0
	begin
		ROLLBACK TRANSACTION tr_add_merge_agent
		COMMIT TRANSACTION
	end
	
	RETURN(1)
end
GO
GRANT EXECUTE ON [sys].[sp_MSadd_merge_agent] TO [public] AS [dbo]
GO
