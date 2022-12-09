SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdetect_nonlogged_shutdown]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdetect_nonlogged_shutdown] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdetect_nonlogged_shutdown]
	@subsystem [nvarchar](60),
	@agent_id [int]
WITH EXECUTE AS CALLER
AS
begin
	declare @job_id binary(16)
	declare @agent_name sysname
	declare @message nvarchar(2048)
	declare @retcode int
	declare @runstatus int
	declare @run_date int
	declare @run_time int
	declare @run_date_orig int
	declare @run_time_orig int
	declare @merge_session_id int
	
	--
	-- security check
	-- only db_owner can execute this
	--
	if (is_member ('db_owner') != 1) 
	begin
		raiserror(14260, 16, -1)
		return (1)
	end

	-- Detect if the agent was shutdown without a logged reason
	if UPPER(@subsystem collate SQL_Latin1_General_CP1_CS_AS) = 'SNAPSHOT'
	begin
		if exists (select runstatus from MSsnapshot_history where 
			agent_id = @agent_id and
			runstatus <> 2 and 
--CAC       runstatus <> 5 and 
			runstatus <> 6 and
			timestamp = (select max(timestamp) from MSsnapshot_history where agent_id = @agent_id))
			begin
				select @job_id = job_id, @agent_name = name from MSsnapshot_agents where id = @agent_id
			end
	end
	else if UPPER(@subsystem collate SQL_Latin1_General_CP1_CS_AS) = 'LOGREADER'
	begin
		if exists (select runstatus from MSlogreader_history where 
			agent_id = @agent_id and
			runstatus <> 2 and 
--CAC           runstatus <> 5 and 
			runstatus <> 6 and
			timestamp = (select max(timestamp) from MSlogreader_history where agent_id = @agent_id))
			begin
				select @job_id = job_id, @agent_name = name from MSlogreader_agents where id = @agent_id
			end
	end
	else if UPPER(@subsystem collate SQL_Latin1_General_CP1_CS_AS) = 'DISTRIBUTION'
	begin
		if exists (select runstatus from MSdistribution_history where 
			agent_id = @agent_id and
			runstatus <> 2 and 
--CAC           runstatus <> 5 and 
			runstatus <> 6 and
			timestamp = (select max(timestamp) from MSdistribution_history where agent_id = @agent_id))
			begin
				select @job_id = job_id, @agent_name = name from MSdistribution_agents where id = @agent_id
			end
	end
	else if UPPER(@subsystem collate SQL_Latin1_General_CP1_CS_AS) = 'MERGE'
	begin
		if exists (select runstatus from dbo.MSmerge_sessions where 
			agent_id = @agent_id and
			runstatus <> 2 and 
--CAC           runstatus <> 5 and 
			runstatus <> 6 and
			session_id = (select top 1 session_id from dbo.MSmerge_sessions where agent_id = @agent_id order by session_id desc))
			begin
				select @job_id = job_id, @agent_name = name from dbo.MSmerge_agents where id = @agent_id
				
				select top 1 @merge_session_id = session_id from dbo.MSmerge_sessions 
				where agent_id = @agent_id 
				order by session_id desc
			end
	end
	else if UPPER(@subsystem collate SQL_Latin1_General_CP1_CS_AS) = 'QUEUEREADER'
	begin
		if exists (select runstatus from MSqreader_history where 
			agent_id = @agent_id and
			runstatus <> 2 and 
--CAC       runstatus <> 5 and 
			runstatus <> 6 and
			timestamp = (select max(timestamp) from MSqreader_history where agent_id = @agent_id))
			begin
				select @job_id = job_id, @agent_name = name from MSqreader_agents where id = @agent_id
			end
	end

	-- If no job_id assume shutdown was logged properly
	if @job_id is null
		return 0

	-- Get last message from SQL Agent History table
	create table #JobHistory (
		instance_id int NOT NULL, 
		job_id uniqueidentifier NOT NULL,
		job_name sysname NOT NULL,
		step_id int NOT NULL,
		step_name nvarchar(100) NOT NULL, 
		sql_message_id int NOT NULL,
		sql_severity int NOT NULL,
		message nvarchar(1024) NOT NULL,
		run_status int NOT NULL,
		run_date int NOT NULL,
		run_time int NOT NULL,
		run_duration int NOT NULL,
		operator_emailed sysname NULL,
		operator_netsent sysname NULL,
		operator_paged sysname NULL,
		retries_attempted int NOT NULL,
		server sysname NOT NULL
	)
	if @@error <> 0
		return 1

	-- Insert last history for step_id 2 (Agent running)
	insert TOP(2) into #JobHistory exec sys.sp_MSreplhelp_jobhistory @job_id = @job_id, @step_id = 2, 
		@mode = 'FULL'          


	declare cursorHistory cursor local fast_forward for
		select message, 
				run_status,
				run_date,
				run_time
			from #JobHistory
			order by run_date desc, 
					run_time desc, 
					instance_id asc
	
	open cursorHistory

	fetch cursorHistory into @message, @runstatus, @run_date, @run_time

	select @run_date_orig = @run_date, 
 			@run_time_orig = @run_time
 				
	while @@fetch_status <> -1
	begin  	
		-- as long as we are looking at the history for the same run 
		-- date and time then we should log all rows. there should 
		-- be 2 rows since we perform a TOP on exec sp_help_jobhistory
		if @run_date_orig = @run_date
 			and @run_time_orig = @run_time
		begin
			-- Map SQL Agent runstatus to Replication runstatus
			set @runstatus = 
			case @runstatus
				when 0 then 6   -- Fail mapping
				when 1 then 2   -- Success mapping
				when 2 then 5   -- Retry mapping
				when 3 then 2   -- Shutdown mapping
				when 4 then 3   -- Inprogress mapping
				when 5 then 0   -- Unknown is mapped to never run
			end

			-- If no message, provide a default message
			-- Also overwrite all inprogress messages to be "See SQL Agent history log".
			-- This is to prevent "Agent running. See monitor" to be logged into repl monitor.
			-- In this case (the last job history message is InProgress), we know that
			-- there have been failures of SQL Server Agent history logging.
			-- In fact, the only possible "in progress" msg in SQL Agent job step
			-- history for push jobs is "Agent running. See monitor". It is confusing that those
			-- messages showed up in repl monitor.
			if @message is null or @runstatus = 3
			begin
				raiserror(20557, 10, -1, @agent_name)
				select @message = formatmessage(20557, @agent_name)
			end

			if UPPER(@subsystem collate SQL_Latin1_General_CP1_CS_AS) = 'SNAPSHOT'
				exec @retcode = sys.sp_MSadd_snapshot_history @agent_id = @agent_id, @runstatus = @runstatus,
						@comments = @message
			else if UPPER(@subsystem collate SQL_Latin1_General_CP1_CS_AS) = 'LOGREADER'
				exec @retcode = sys.sp_MSadd_logreader_history @agent_id = @agent_id, @runstatus = @runstatus,
						@comments = @message
			else if UPPER(@subsystem collate SQL_Latin1_General_CP1_CS_AS) = 'DISTRIBUTION'
				exec @retcode = sys.sp_MSadd_distribution_history @agent_id = @agent_id, @runstatus = @runstatus,
						@comments = @message
			else if UPPER(@subsystem collate SQL_Latin1_General_CP1_CS_AS) = 'MERGE'
				exec @retcode = sys.sp_MSadd_merge_history @agent_id = @agent_id, @runstatus = @runstatus,
						@comments = @message, @called_by_nonlogged_shutdown_detection_agent = 1, @session_id_override = @merge_session_id
			else if UPPER(@subsystem collate SQL_Latin1_General_CP1_CS_AS) = 'QUEUEREADER'
				exec @retcode = sys.sp_MSadd_qreader_history @agent_id = @agent_id, @runstatus = @runstatus,
						@comments = @message

			if @@error <> 0 or @retcode <> 0
				return 1
		end

		fetch cursorHistory into @message, @runstatus, @run_date, @run_time
	end

	close cursorHistory
	deallocate cursorHistory

	drop table #JobHistory
end
GO
GRANT EXECUTE ON [sys].[sp_MSdetect_nonlogged_shutdown] TO [public] AS [dbo]
GO
