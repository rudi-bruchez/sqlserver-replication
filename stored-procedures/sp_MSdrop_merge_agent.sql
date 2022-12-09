SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdrop_merge_agent]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdrop_merge_agent] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdrop_merge_agent]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname],
	@keep_for_last_run [bit],
	@job_only [bit]
WITH EXECUTE AS CALLER
AS
begin

	SET NOCOUNT ON

	/*
	** Declarations.
	*/
	DECLARE @retcode    int
	DECLARE @job_id     binary(16)
	DECLARE @job_step_uid uniqueidentifier
	DECLARE @local_job  bit
	DECLARE @publisher_id smallint
	DECLARE @job_command nvarchar(512)
	DECLARE @name nvarchar(100)
	DECLARE @agent_id   int

	-- Security Check: require sysadmin
	IF (ISNULL(IS_SRVROLEMEMBER('sysadmin'),0) = 0)
	BEGIN
		RAISERROR(21089,16,-1) 
		RETURN 1
	END

	IF (sys.fn_MSrepl_isdistdb (DB_NAME()) != 1)
	BEGIN
		-- "sp_MSdrop_merge_agent can only be executed in the distribution database."
		RAISERROR(21482, 16, -1, 'sp_MSdrop_merge_agent', 'distribution')
		RETURN 1
	END
	/*
	** Initializations
	*/
	exec sys.sp_MSget_server_portinfo 
		@name = @publisher, 
		@srvname = @publisher OUTPUT

	exec sys.sp_MSget_server_portinfo 
		@name = @subscriber, 
		@srvname = @subscriber OUTPUT

	-- Get subscriber info
    select @publisher_id = srvid from MSreplservers where UPPER(srvname) = UPPER(@publisher)


	SELECT @job_id = job_id, @job_step_uid = job_step_uid, @local_job = local_job, @name = name, @agent_id = id FROM dbo.MSmerge_agents with (updlock holdlock) 
	WHERE
		publisher_id = @publisher_id AND
		publisher_db = @publisher_db AND
		publication = @publication and
		UPPER(subscriber_name) = UPPER(@subscriber) and
		subscriber_db = @subscriber_db 

	-- Delete Perfmon instance
	dbcc deleteinstance ("SQL Replication Merge", @name)

	BEGIN TRAN

	-- If the job does not exist, still go ahead and cleanup the MSmerge_agent entry and associated errors, session info, article stats
	IF @local_job IS NULL
		goto NONJOBCLEANUP


	IF @keep_for_last_run = 0
	BEGIN
		if @local_job=1
		begin
			IF EXISTS (SELECT * FROM msdb.dbo.sysjobs_view WHERE job_id = @job_id)
			begin
				-- Checks if the job name matches one that is generated
				-- by replication
				EXEC @retcode = sys.sp_MSismergejobnamegenerated
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
			end
		end
	END

	IF @local_job = 1 and @keep_for_last_run = 1
	BEGIN
		IF EXISTS (SELECT * FROM msdb.dbo.sysjobs_view WHERE job_id = @job_id)
		BEGIN
			EXEC @retcode = msdb.dbo.sp_update_job @job_id=@job_id, @delete_level=3 -- NOTE: Only once, success or failure!
			IF @@ERROR <> 0 or @retcode <> 0
				GOTO UNDO
			EXEC @retcode = msdb.dbo.sp_delete_jobstep @job_id=@job_id, @step_id=3
			IF @@ERROR <> 0 or @retcode <> 0
				GOTO UNDO
			EXEC @retcode = msdb.dbo.sp_delete_jobstep @job_id=@job_id, @step_id=1
			IF @@ERROR <> 0 or @retcode <> 0
				GOTO UNDO

			select @job_command=command from msdb.dbo.sysjobsteps where job_id=@job_id and step_id=1        
			select @job_command = @job_command + ' -AgentType 4 '
			
			EXEC @retcode = msdb.dbo.sp_update_jobstep @job_id=@job_id, @step_id=1, 
				@on_success_action = 1,
				@on_fail_action = 2,
				@command=@job_command
			IF @@ERROR <> 0 or @retcode <> 0
				GOTO UNDO
		END
	END

NONJOBCLEANUP:
	-- we need to clean up added article history before session table
	delete dbo.MSmerge_articlehistory
		from dbo.MSmerge_articlehistory arthist join dbo.MSmerge_sessions sess
		on arthist.session_id=sess.session_id
		where sess.agent_id=@agent_id
	IF @@ERROR <> 0 
		GOTO UNDO
		
	delete dbo.MSmerge_history
		from dbo.MSmerge_history hist join dbo.MSmerge_sessions sess
		on hist.session_id=sess.session_id
		where sess.agent_id=@agent_id
	IF @@ERROR <> 0 
		GOTO UNDO
		
	delete dbo.MSrepl_errors
		from dbo.MSrepl_errors errs join dbo.MSmerge_sessions sess
		on errs.session_id=sess.session_id
		where sess.agent_id=@agent_id
	IF @@ERROR <> 0 
		GOTO UNDO

	-- delete sessions associated with the agent that is to be deleted
	DELETE dbo.MSmerge_sessions where agent_id = @agent_id
	IF @@ERROR <> 0 
		GOTO UNDO

	IF @job_only = 0
	BEGIN
		DELETE dbo.MSmerge_agents WHERE id = @agent_id
		IF @@ERROR <> 0 
			GOTO UNDO
	END
	
	-- Remove history       
	DELETE dbo.MSmerge_history WHERE agent_id = @agent_id 
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
end
GO
GRANT EXECUTE ON [sys].[sp_MSdrop_merge_agent] TO [public] AS [dbo]
GO
