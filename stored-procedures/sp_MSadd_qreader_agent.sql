SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSadd_qreader_agent]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSadd_qreader_agent] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSadd_qreader_agent]
	@name [nvarchar](100),
	@agent_id [int] OUTPUT,
	@agent_jobid [binary](16) OUTPUT,
	@job_login [nvarchar](257),
	@job_password [sysname],
	@internal [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
	SET NOCOUNT ON

	DECLARE @retcode				int
			,@profile_id			int
			,@category_name			sysname
			,@database				sysname

	-- these are defaults used for sp_MSadd_repl_job
			,@frequency_type int,
			@frequency_interval int,
			@frequency_relative_interval int,
			@frequency_recurrence_factor int,
			@frequency_subday int,
			@frequency_subday_interval int,
			@active_start_time_of_day int,
			@active_end_time_of_day int,
			@active_start_date int,
			@active_end_date int,
			@retryattempts int,
			@retrydelay int,
			@command nvarchar(4000)
			,@jobname sysname
			,@agent_name nvarchar(100)
			,@agent_job_step_uid uniqueidentifier

	SELECT
		@frequency_type = 64,
		@frequency_interval = 1,
		@frequency_relative_interval = 1,
		@frequency_recurrence_factor  = 0,
		@frequency_subday = 4,
		@frequency_subday_interval = 5,
		@active_start_time_of_day = 0,
		@active_end_time_of_day = 235959,
		@active_start_date = 0,
		@active_end_date = 99991231,
		@retryattempts = 10,
		@retrydelay = 1

	--
	-- security check
	-- only db_owner can execute this
	--
	if (is_member ('db_owner') != 1) 
	begin
		raiserror(14260, 16, -1)
		return (1)
	end
	--
	-- security check
	-- Has to be executed from distribution database
	--
	if (sys.fn_MSrepl_isdistdb (db_name()) != 1)
	begin
		raiserror(21482, 16, -1, 'sp_MSadd_qreader_agent', 'distribution')
		return (1)
	end
	
	--
	-- initialize
	--
	select @database = db_name()
			,@agent_id = NULL
			,@agent_jobid = NULL
			,@agent_job_step_uid = NULL

	--
	-- Check for Agent entry
	--
	select top 1 @agent_id = id, @agent_name = name
	from dbo.MSqreader_agents

	--
	-- Check if we have any queue reader jobs for this database
	--
	select @agent_jobid = job.job_id
			,@jobname = job.name 
			,@agent_job_step_uid = step.step_uid
	from msdb.dbo.sysjobs_view as job join msdb.dbo.sysjobsteps as step 
		on job.job_id = step.job_id 
			and job.master_server = 0
			and job.category_id = 19
			and UPPER(job.originating_server) = UPPER(CONVERT(sysname, SERVERPROPERTY('ServerName')))
			and step.subsystem = N'QueueReader' 
			and step.database_name = @database
			and (job.name = @name
				or @name is NULL
				or @internal = N'PRE-YUKON')

	-- ONLY CHECK THIS IN 9.0 or more CASES
	IF @internal = N'YUKON'
	BEGIN
		IF @name IS NOT NULL
			AND @jobname IS NULL
		BEGIN
			-- Message from msdb.dbo.sp_verify_job_identifiers
			RAISERROR(14262, -1, -1, 'Job', @name)   	
			RETURN 1
		END
	END

	--
	-- begin tran
	--
	BEGIN TRAN sp_MSadd_qreader_agent
	SAVE TRAN sp_MSadd_qreader_agent
	
	--
	-- Check if we need to proceed
	-- add agent entry and job entry as required
	--
	if ((@agent_id IS NOT NULL) and (@agent_jobid IS NOT NULL))
	begin
		--
		-- we have an entry in MSqreader_agents and an entry in 
		-- msdb.dbo.sysjobs_view, make sure the names and jobid match
		--
		if (@agent_name != @jobname)
		begin
			--
			-- Update the agent name to be same as the job name
			--
			UPDATE MSqreader_agents SET name = @jobname WHERE id = @agent_id
			IF (@@ERROR != 0)
				GOTO UNDO
		end

		if not exists (select * 
						from MSqreader_agents
						where id = @agent_id 
							and job_id = @agent_jobid
							and job_step_uid = @agent_job_step_uid)
		begin
			--
			-- Update the agent job_id if necessary
			--
			UPDATE MSqreader_agents 
				SET job_id = @agent_jobid,
					job_step_uid = @agent_job_step_uid
				WHERE id = @agent_id
			IF (@@ERROR != 0)
				GOTO UNDO
		end

		if @job_login is not NULL
			or @job_password is not NULL
		begin
			-- 
			-- Always update the Proxy Account if one is provided
			-- 	
			exec @retcode = sys.sp_MSchange_repl_job @id = @agent_jobid,
													@step_uid = @agent_job_step_uid,
													@login = @job_login,
													@password = @job_password
			IF (@@ERROR != 0 or @retcode != 0)
				GOTO UNDO
		end 
		
		COMMIT TRAN sp_MSadd_qreader_agent
		RETURN(0)
	end

	-- Get server port number
	 declare @srvname_with_port sysname
	 exec sys.sp_MSget_server_portinfo 
		@name = @@servername,
		@srvname_with_port = @srvname_with_port OUTPUT
	--
	-- prepare the command
	-- Since this will always run on NT, use integrated security
	--
	select @command = N'-Distributor ' + quotename(@srvname_with_port) 
					+ N' -DistributionDB ' + quotename(@database) 
					+ N' -DistributorSecurityMode 1 '
	
	SELECT @profile_id = profile_id
	FROM msdb..MSagent_profiles
	WHERE agent_type = 9
	AND def_profile = 1

	IF @profile_id IS NULL
		GOTO UNDO

	--
	-- Set the name
	--
	if (@name is NULL)
	begin
		select @name = case 
			when (@agent_name IS NULL and @jobname IS NULL) 
				then quotename(@@servername) + '.' + cast(db_id() as nvarchar)
			when (@jobname IS NOT NULL)
				then cast(@jobname as nvarchar(100))
				else @agent_name
			end
	end
	else
	begin
		--
		-- we will override the user specified name if
		-- a job already exists
		--
		if (@jobname IS NOT NULL and @jobname != @name)
			select @name = cast(@jobname as nvarchar(100))
	end
	
	--
	-- Insert row and Add Perfmoon instance only if needed
	--
	if (@agent_id IS NULL)
	begin
		INSERT INTO MSqreader_agents (name, profile_id) VALUES (@name, @profile_id)
		IF (@@ERROR != 0)
			GOTO UNDO
		SELECT @agent_id = @@IDENTITY
		dbcc addinstance ('SQL Replication QueueReader', @name)
	end
	else
	begin
		--
		-- update Agent name if necessary
		--
		if not exists (select * from MSqreader_agents 
			where id = @agent_id and name = @name) 
		begin
			UPDATE MSqreader_agents SET name = @name WHERE id = @agent_id
			IF (@@ERROR != 0)
				GOTO UNDO
		end
	end

	--
	-- add the job if necessary
	-- For DMO scripting
	-- if the corresponding job for this agent does not exist we will 
	-- proceed and create the job (This is for the case when the user 
	-- generated the script at the publisher but did not re-create 
	-- repl jobs at the distributor.)
	--
	if (@agent_jobid IS NULL)
	begin
		-- Get Qreader category name (assumes category_id = 19)
		select @category_name = name FROM msdb.dbo.syscategories where category_id = 19

		EXECUTE @retcode = dbo.sp_MSadd_repl_job
			@name = @name,
			@subsystem = 'QueueReader',
			@server = @@SERVERNAME,
			@databasename = @database,
			@enabled = 1,
			@freqtype = @frequency_type,
			@freqinterval = @frequency_interval,
			@freqsubtype = @frequency_subday,
			@freqsubinterval = @frequency_subday_interval,
			@freqrelativeinterval = @frequency_relative_interval,
			@freqrecurrencefactor = 0,
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
			@description = 'Reads queues for Queued updating subscriptions',
			@category_name = @category_name,
			@failure_detection = 1,
			@agent_id = @agent_id,
			@job_login = @job_login,
			@job_password = @job_password,
			@job_id = @agent_jobid OUTPUT,
			@job_step_uid = @agent_job_step_uid OUTPUT

		IF (@@ERROR != 0 or @retcode != 0)
			GOTO UNDO
	end
	
	-- update agents table with the job id
	UPDATE MSqreader_agents 
		SET job_id = @agent_jobid,
			job_step_uid = @agent_job_step_uid
		WHERE id = @agent_id
	IF (@@ERROR != 0)
		GOTO UNDO

	COMMIT TRAN sp_MSadd_qreader_agent
	RETURN(0)

UNDO:
	--
	-- Since this proc is called from other SPs, doing
	-- a ROLLBACK can roll all the way to the top 
	-- so check for that and commit and return error code.
	-- the top level calling SP should do proper rollback
	-- based on returned error code
	--
	ROLLBACK TRAN sp_MSadd_qreader_agent
  	COMMIT TRAN sp_MSadd_qreader_agent
  	
	return(1)
END
GO
GRANT EXECUTE ON [sys].[sp_MSadd_qreader_agent] TO [public] AS [dbo]
GO
