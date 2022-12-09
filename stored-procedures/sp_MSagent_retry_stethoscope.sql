SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSagent_retry_stethoscope]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSagent_retry_stethoscope] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSagent_retry_stethoscope]
WITH EXECUTE AS CALLER
AS
BEGIN
	SET NOCOUNT ON
	
	DECLARE @retcode int,
			@LOGREADER_AGENT tinyint,
			@DISTRIB_AGENT tinyint,
			@REPL_SUCCEEDED tinyint,
			@REPL_FAILED tinyint,
			@REPL_RETRY tinyint,
			@REPL_INPROG tinyint,
			@KOMODO_SUCCEEDED tinyint,
			@KOMODO_FAILED tinyint,
			@KOMODO_RETRY tinyint,
			@KOMODO_CANCEL tinyint,
			@type int,
			@agent_id int, 
			@job_name sysname,
			@komodo_runstatus int, 
			@repl_runstatus int, 
			@retries_attempted int, 
			@message nvarchar(255)
										
	SELECT @LOGREADER_AGENT = 0,
			@DISTRIB_AGENT = 1,
			@REPL_SUCCEEDED = 2,
			@REPL_FAILED = 6, 
			@REPL_RETRY = 5,
			@REPL_INPROG = 3,
			@KOMODO_SUCCEEDED = 1,
			@KOMODO_FAILED = 0,
			@KOMODO_RETRY = 2,
			@KOMODO_CANCEL = 3

	-- security check
	IF IS_MEMBER('db_owner') != 1
	BEGIN
		-- You do not have sufficient permission to run this command. Contact your system administrator.
		RAISERROR(14260, 16, -1)
		RETURN 1
	END

	-- Has to be executed from distribution database
	IF sys.fn_MSrepl_isdistdb (db_name()) != 1
	BEGIN
		-- sp_MSagent_retry_stethoscope can only be executed in the "distribution" database.
		RAISERROR(21482, 16, -1, 'sp_MSagent_retry_stethoscope', 'distribution')
		RETURN 1
	END
		
	BEGIN TRANSACTION tr_retry_stethoscope
	SAVE TRANSACTION tr_retry_stethoscope

	-- here we use an applock to prevent more than one user 
	-- on any single server from executing this procedure at
	-- the same time... this also prevent calls from the UI
	-- to collide with calls from the checkup agent job...
	EXEC @retcode = sys.sp_getapplock @Resource = 'Repl_Refresh_Retry_Messages', 
									@LockMode = 'Exclusive', 
									@LockOwner = 'Transaction',
									@LockTimeout = 1,
									@DbPrincipal = N'db_owner'
	IF @@ERROR <> 0 or @retcode < 0
	BEGIN
		GOTO ROLLBACK_EXIT
	END
		
	DECLARE @agent_sessions table
			(	
				type tinyint, 
				agent_id int,
				job_id varbinary(16),
				time datetime
			) 

	--------------------------------------------------------
	-- Retrieve all sessions
	--------------------------------------------------------
	--
	-- Here we are attempting to retrieve the latest agent 
	-- sessions. Note that we discard information on any 
	-- agent that had a successful runstatus for it's last
	-- agent run. We should have 1 row for each agent that
	-- had a NON-successful run for it's most recent run...
	INSERT INTO @agent_sessions
		-- LOGREADER HISTORY
		SELECT @LOGREADER_AGENT,
				msla.id,
				msla.job_id,
				ISNULL(mslh.time, '1753-01-01 00:00:00')
			FROM MSlogreader_agents msla WITH (NOLOCK)
				JOIN msdb..sysjobs sysj WITH (NOLOCK)
					ON msla.job_id = sysj.job_id
				LEFT JOIN MSlogreader_history mslh WITH (NOLOCK)
					ON msla.id = mslh.agent_id
			WHERE (mslh.timestamp IN (SELECT max(mslh2.timestamp)
										FROM MSlogreader_history mslh2 WITH (NOLOCK)
										WHERE mslh2.agent_id = mslh.agent_id)
					AND mslh.runstatus NOT IN (@REPL_SUCCEEDED))
				OR
				(mslh.timestamp IS NULL
					AND mslh.runstatus IS NULL)

		UNION
		
		-- DISTRIBUTION HISTORY
		SELECT @DISTRIB_AGENT,
				msda.id,
				msda.job_id,
				ISNULL(msdh.time, '1753-01-01 00:00:00')
			FROM MSdistribution_agents msda WITH (NOLOCK)
				JOIN msdb..sysjobs sysj WITH (NOLOCK)
					ON msda.job_id = sysj.job_id
				LEFT JOIN MSdistribution_history msdh WITH (NOLOCK)
					ON msda.id = msdh.agent_id
			WHERE (msdh.timestamp IN (SELECT max(msdh2.timestamp)
										FROM MSdistribution_history msdh2 WITH (NOLOCK)
										WHERE msdh2.agent_id = msdh.agent_id)
					AND msdh.runstatus NOT IN (@REPL_SUCCEEDED))
				OR 
				(msdh.timestamp IS NULL
					AND msdh.runstatus IS NULL)

	------------------------------------------------------------
	-- Retrieve jobhistory information and log the information 
	-- to agent history
	------------------------------------------------------------
	--
	-- here we are attempting to retrieve the latest job
	-- history message for each agent that has an open
	-- agent session (entry in temp table). NOTE that in
	-- in the sub-query we take the max instance_id for
	-- all entrys in history that are within our time 
	-- contraints...
	DECLARE #cr_jobhistory cursor LOCAL FAST_FORWARD FOR
		SELECT agnts.type,
				agnts.agent_id,
				sysj.name,
				sysjh.run_status,
				sysjh.retries_attempted,
				CONVERT(nvarchar(255), sysjh.message)
			FROM msdb..sysjobhistory sysjh WITH (NOLOCK)
				JOIN msdb..sysjobs sysj WITH (NOLOCK)
					ON sysjh.job_id = sysj.job_id
				JOIN @agent_sessions agnts
					ON sysjh.job_id = agnts.job_id
						AND (sysjh.run_date > sys.fn_replsubtractkomododuration(agnts.time, sysjh.run_duration, 0)
								OR (sysjh.run_date = sys.fn_replsubtractkomododuration(agnts.time, sysjh.run_duration, 0)
									AND sysjh.run_time >= sys.fn_replsubtractkomododuration(agnts.time, sysjh.run_duration, 1)))
			WHERE sysjh.instance_id IN (SELECT MAX(instance_id)
										FROM msdb..sysjobhistory sysjh2 WITH (NOLOCK)
										WHERE sysjh2.job_id = agnts.job_id
											AND (sysjh2.run_date > sys.fn_replsubtractkomododuration(agnts.time, sysjh2.run_duration, 0)
												OR (sysjh2.run_date = sys.fn_replsubtractkomododuration(agnts.time, sysjh2.run_duration, 0)
													AND sysjh2.run_time >= sys.fn_replsubtractkomododuration(agnts.time, sysjh2.run_duration, 1)))
											AND sysjh2.run_status NOT IN (4)) -- In Progress

	OPEN #cr_jobhistory
	
	FETCH #cr_jobhistory INTO @type, @agent_id, @job_name, @komodo_runstatus, @retries_attempted, @message

	WHILE @@FETCH_STATUS <> -1
	BEGIN
		-- Map KOMODO runstatus to Replication RunStatus
		SELECT @repl_runstatus = CASE @komodo_runstatus
										WHEN @KOMODO_FAILED 	THEN @REPL_FAILED		-- Failed
										WHEN @KOMODO_SUCCEEDED 	THEN @REPL_SUCCEEDED	-- Succeeded
										WHEN @KOMODO_RETRY 		THEN @REPL_FAILED		-- Retry
										WHEN @KOMODO_CANCEL 	THEN @REPL_SUCCEEDED	-- Canceled
										ELSE @REPL_INPROG								-- In progress
									END
		
		-- In the retry case we must change the message so 
		-- the UI can display something meaningfull...
		IF @komodo_runstatus = @KOMODO_RETRY
		BEGIN
			-- Agent '%s' is retrying after an error. %d retries attempted. See agent job history in the Jobs folder for more details.
			SELECT @message = FORMATMESSAGE(18856, @job_name, @retries_attempted)
		END
		
		IF @type = @LOGREADER_AGENT
		BEGIN
			EXEC @retcode = sys.sp_MSadd_logreader_history @agent_id = @agent_id,
														@runstatus = @repl_runstatus,
														@comments = @message,
														@perfmon_increment = 0,
														@update_existing_row = 0,
														@do_raiserror = 0
			IF @@ERROR <> 0 AND @retcode <> 0
				GOTO FAILURE
		END
		ELSE IF @type = @DISTRIB_AGENT
		BEGIN
			EXEC @retcode = sys.sp_MSadd_distribution_history @agent_id = @agent_id,
													@runstatus = @repl_runstatus,
													@comments = @message,
													@perfmon_increment = 0,
													@update_existing_row = 0,
													@do_raiserror = 0
			IF @@ERROR <> 0 AND @retcode <> 0
				GOTO FAILURE
		END

		FETCH #cr_jobhistory INTO @type, @agent_id, @job_name, @komodo_runstatus, @retries_attempted, @message
	END

	CLOSE #cr_jobhistory
	DEALLOCATE #cr_jobhistory

	-- we release the applock at this point because 
	-- the remaining steps will not be affected by
	-- any type of name collisions etc...
	EXEC @retcode = sys.sp_releaseapplock @Resource = 'Repl_Refresh_Retry_Messages', 
												@LockOwner =  'Transaction',
												@DbPrincipal =  'db_owner'
	IF @@ERROR <> 0 or @retcode <> 0
		GOTO FAILURE
			
	COMMIT TRANSACTION tr_retry_stethoscope
	
	RETURN 0
ROLLBACK_EXIT:
	ROLLBACK TRANSACTION tr_retry_stethoscope
	COMMIT TRANSACTION 
	
	RETURN 0
FAILURE:
	ROLLBACK TRANSACTION tr_retry_stethoscope
	COMMIT TRANSACTION 

	RETURN 1
END
GO
GRANT EXECUTE ON [sys].[sp_MSagent_retry_stethoscope] TO [public] AS [dbo]
GO
