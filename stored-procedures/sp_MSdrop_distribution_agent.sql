SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdrop_distribution_agent]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdrop_distribution_agent] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdrop_distribution_agent]
	@publisher_id [smallint],
	@publisher_db [sysname],
	@publication [sysname],
	@subscriber_id [smallint],
	@subscriber_db [sysname],
	@subscription_type [int],
	@keep_for_last_run [bit],
	@job_only [bit]
WITH EXECUTE AS CALLER
AS
BEGIN

	SET NOCOUNT ON

	/*
	** Declarations.
	*/
	DECLARE @stopcode       int
			,@retcode        int
			,@job_id         binary(16)
			,@job_step_uid	 uniqueidentifier
			,@is_continuous  bit
			,@local_job      bit
			,@publisher      sysname
			,@schedule_name  sysname
			,@job_command    nvarchar(512)
			,@name           nvarchar(100)
			,@agent_id       int
			,@queue_id      sysname
			,@qservicestatus int
			,@qservername   nvarchar(255)
			,@subscriber    sysname

	--
	-- security check
	-- only db_owner can execute this
	--
	if (is_member ('db_owner') != 1) 
	begin
		raiserror(14260, 16, -1)
		return (1)
	end
			
	select @stopcode = 1
			,@qservername = queue_server
			,@job_id = job_id, @local_job = local_job, @name = name, @agent_id = id,
			@job_step_uid = job_step_uid,
			@queue_id = queue_id
	FROM MSdistribution_agents WHERE
		publisher_id = @publisher_id AND
		publisher_db = @publisher_db AND
		publication = @publication and
		subscriber_id = @subscriber_id and
		subscriber_db = @subscriber_db and
		subscription_type = @subscription_type
	
	-- Delete Perfmon instance
	dbcc deleteinstance ("SQL Replication Distribution", @name)

    select @publisher = srvname from MSreplservers where srvid = @publisher_id

    select @subscriber = srvname from MSreplservers where srvid = @subscriber_id
    -- Return if not exists
    IF @local_job IS NULL
        RETURN(0)

	BEGIN TRAN

	if @queue_id is not null
		and @queue_id != N'mssqlqueue'
		and @job_only = 0
	begin
		--
		-- MQ specific processing
		--          
		exec @retcode = sys.sp_MSdropmqforsubscription @qservername, @queue_id
		IF @retcode != 0
			GOTO UNDO
	end

	IF @local_job = 1 and @keep_for_last_run = 0
	BEGIN
		IF EXISTS (SELECT * FROM msdb.dbo.sysjobs_view WHERE job_id = @job_id)
		BEGIN
			-- Checks if the job name matches one that is generated 
			-- by replication
			EXEC @retcode = sys.sp_MSisdistributionjobnamegenerated
								@publisher = @publisher,
								@publisher_db = @publisher_db,
								@publication = @publication,
								@subscriber = @subscriber,
								@job_id = @job_id
			IF @@ERROR <> 0
				GOTO UNDO
			
			-- Only drop the job if the name was generated
			IF @retcode = 0
			BEGIN
				EXEC @retcode = sys.sp_MSdrop_repl_job @job_id = @job_id,
														@job_step_uid = @job_step_uid
				IF @@ERROR <> 0 or @retcode <> 0
					GOTO UNDO
			END
		END
	END

	IF @local_job = 1 and @keep_for_last_run = 1
	BEGIN
			select @job_command=command from msdb.dbo.sysjobsteps where job_id=@job_id and step_id=2

			if PATINDEX('%-[Cc][Oo][Nn][Tt][Ii][Nn][Uu][Oo][Uu][Ss]%', @job_command) > 0
				begin
					select @is_continuous = 1
					create table #sqlstatus(status nvarchar(20))
					insert into #sqlstatus (status) exec master.dbo.xp_servicecontrol 'QUERYSTATE', 'SQLServerAgent'
					if exists (select * from #sqlstatus where status='Running.') 
							exec @stopcode = msdb.dbo.sp_stop_job @job_id = @job_id
								 if @@ERROR<>0 GOTO UNDO
					drop table #sqlstatus   
					if @stopcode=0 
						waitfor delay '00:00:30'
				end
			
			EXEC @retcode = msdb.dbo.sp_update_job @job_id=@job_id, @delete_level=3 -- NOTE: Run once, success or failure!
			IF @@ERROR <> 0 or @retcode <> 0
				GOTO UNDO
		
			EXEC @retcode = msdb.dbo.sp_delete_jobstep @job_id=@job_id, @step_id=3
			IF @@ERROR <> 0 or @retcode <> 0
				GOTO UNDO
			EXEC @retcode = msdb.dbo.sp_delete_jobstep @job_id=@job_id, @step_id=1
			IF @@ERROR <> 0 or @retcode <> 0
				GOTO UNDO

			select @job_command=command from msdb.dbo.sysjobsteps where job_id=@job_id and step_id=1        
			select @job_command = @job_command + ' -UnSubscribe 0 '  -- currently the value does not really matter
			
			EXEC @retcode = msdb.dbo.sp_update_jobstep @job_id=@job_id, @step_id=1, 
								@on_success_action=1, 
								@on_fail_action=2, 
								@command=@job_command
			IF @@ERROR <> 0 or @retcode <> 0
				GOTO UNDO

			
			select @schedule_name = formatmessage(20532)
			EXEC @retcode = msdb.dbo.sp_update_jobschedule @job_id=@job_id, @name=@schedule_name, @freq_subday_type = 2, @freq_subday_interval=30
			IF @@ERROR<>0 or @retcode<>0
				GOTO UNDO
			
			if (@is_continuous  = 1) and (@stopcode = 0)
				begin
					EXEC @retcode = msdb.dbo.sp_start_job @job_id=@job_id
					 if @@ERROR<>0 
						GOTO UNDO
				end
			/*
			** The last run of this job will be as scheduled
			*/
	END

   -- In case this was a PeerToPeer agent, delete all the cached PeerToPeer info
	DELETE FROM MScached_peer_lsns WHERE agent_id=@agent_id
   	IF @@ERROR <> 0 
		GOTO UNDO

	IF @job_only = 0
	BEGIN
		-- Remove agent entry
		DELETE MSdistribution_agents WHERE id = @agent_id
		IF @@ERROR <> 0 
			GOTO UNDO
	END
	
	-- Remove associated history 
	DELETE MSdistribution_history WHERE agent_id = @agent_id
	IF @@ERROR <> 0 
		GOTO UNDO
	
	COMMIT TRAN

	RETURN(0)

UNDO:
	if @@TRANCOUNT = 1
		ROLLBACK TRAN
	else
		COMMIT TRAN
	return(1)
END
GO
GRANT EXECUTE ON [sys].[sp_MSdrop_distribution_agent] TO [public] AS [dbo]
GO
