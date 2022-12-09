SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSagent_stethoscope]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSagent_stethoscope] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSagent_stethoscope]
	@heartbeat_interval [int]
WITH EXECUTE AS CALLER
AS
BEGIN
	declare @current_time datetime
			,@agent_name nvarchar(100)
			,@agent_id int
			,@job_id binary(16)
			,@start_time datetime
			,@duration int
			,@comments nvarchar(1024)
			,@publisher_id smallint
			,@publisher sysname
			,@publisher_db sysname
			,@heartbeat_failure bit
			,@snapshot_type int
			,@logreader_type int
			,@distribution_type int
			,@merge_type int
			,@qreader_type int
			,@histverboselevel tinyint
			,@merge_session_id int
			,@runstatus int
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
	-- initialize
	--
	set nocount on
	select @snapshot_type = 1
			,@logreader_type = 2
			,@distribution_type = 3
			,@merge_type = 4
			,@qreader_type = 9
			,@heartbeat_failure = 0
			,@current_time = getdate()
			,@comments = formatmessage(20554, @heartbeat_interval)

	-- If a running snapshot agent has not logged a history message within the specified
	-- heartbeat_interval then raise a agent suspect error
	declare hC_snapshot_suspect CURSOR LOCAL FAST_FORWARD for 
		select sh1.agent_id, sh1.start_time from MSsnapshot_history sh1 with (READPAST) where
			(sh1.runstatus = 1 or sh1.runstatus = 3 or sh1.runstatus = 4) and
			dateadd(minute, @heartbeat_interval, sh1.time) < @current_time and
			sh1.timestamp = (select max(timestamp) from MSsnapshot_history with (READPAST) where
				agent_id= sh1.agent_id)
		for read only

	open hC_snapshot_suspect
	fetch hC_snapshot_suspect into @agent_id, @start_time
	while (@@fetch_status <> -1)
	begin

		set @heartbeat_failure = 1

		-- Get the agent name
		select @agent_name = name, @job_id = job_id from MSsnapshot_agents where id = @agent_id

		-- Log a "No action" message on behalf of the agent
		exec sys.sp_MSadd_snapshot_history
			@agent_id = @agent_id,
			@runstatus = 6,     -- Failure status
			@comments = @comments,
			@do_raiserror = 0

		fetch hC_snapshot_suspect into @agent_id, @start_time
	end
	close hC_snapshot_suspect
	deallocate hC_snapshot_suspect


	-- If a running logreader agent has not logged a history message within the specified
	-- heartbeat_interval then raise a agent suspect error
	declare hC_logreader_suspect CURSOR LOCAL FAST_FORWARD for 
		select la.id, sh1.start_time from MSlogreader_agents la, MSlogreader_history sh1 where
			(sh1.runstatus = 1 or sh1.runstatus = 3 or sh1.runstatus = 4) and
			dateadd(minute, @heartbeat_interval, sh1.time) < @current_time and
			sh1.timestamp = (select max(timestamp) from MSlogreader_history where
				agent_id= sh1.agent_id) and
			la.id = sh1.agent_id
		for read only

	open hC_logreader_suspect
	fetch hC_logreader_suspect into @agent_id, @start_time
	while (@@fetch_status <> -1)
	begin
		set @heartbeat_failure = 1

		-- Get the agent name
		select @agent_name = name, @job_id = job_id from MSlogreader_agents where id = @agent_id

        -- Log a "No action" message on behalf of the agent
        select @publisher_id = publisher_id, @publisher_db = publisher_db from MSlogreader_agents where id = @agent_id
        select @publisher = srvname from MSreplservers where srvid = @publisher_id
        exec sys.sp_MSadd_logreader_history
            @agent_id = @agent_id,
            @runstatus = 6,     -- Failure status
            @comments = @comments,
			@do_raiserror = 0

		fetch hC_logreader_suspect into @agent_id, @start_time
	end
	close hC_logreader_suspect
	deallocate hC_logreader_suspect

	-- If a running distribution agent has not logged a history message within the specified
	-- heartbeat_interval then raise a agent suspect error
	declare #hC_distribution_suspect CURSOR LOCAL FAST_FORWARD for 
		select id from MSdistribution_agents
	   for read only

	open #hC_distribution_suspect
	fetch #hC_distribution_suspect into @agent_id
	while (@@fetch_status <> -1)
	begin
		select top 1 @start_time = time, @runstatus = runstatus
			from MSdistribution_history where
			agent_id = @agent_id 
			order by timestamp desc
		if (@@rowcount = 1 
			and (@runstatus = 1 or @runstatus = 3 or @runstatus = 4 )
		 	and (dateadd(minute, @heartbeat_interval, @start_time) < @current_time ))
		begin
			select @heartbeat_failure = 1

			-- Log a "No action" message on behalf of the agent
			exec sys.sp_MSadd_distribution_history
				@agent_id = @agent_id,
				@runstatus = 6,     -- Failure status
				@comments = @comments,
				@do_raiserror = 0
		end

	   fetch #hC_distribution_suspect into @agent_id
	end
	close #hC_distribution_suspect
	deallocate #hC_distribution_suspect
		
	-- If a running merge agent has not logged a history message within the specified
	-- heartbeat_interval then raise a agent suspect error
	declare hC_merge_suspect CURSOR LOCAL FAST_FORWARD for 
		select sh1.agent_id, sh1.start_time 
		from dbo.MSmerge_sessions sh1 
		where
			(sh1.runstatus = 1 or sh1.runstatus = 3 or sh1.runstatus = 4) and
			dateadd(minute, @heartbeat_interval, sh1.end_time) < @current_time and
			sh1.timestamp = (select max(sh2.timestamp) from dbo.MSmerge_sessions sh2 where
				sh2.agent_id= sh1.agent_id)
		for read only

	open hC_merge_suspect
	fetch hC_merge_suspect into @agent_id, @start_time
	while (@@fetch_status <> -1)
	begin
		
		
		set @heartbeat_failure = 1
		set @merge_session_id = NULL

		-- Get the agent name
		select @agent_name = name, @job_id = job_id from dbo.MSmerge_agents where id = @agent_id
									   
		select top 1 @merge_session_id = session_id from dbo.MSmerge_sessions 
		where agent_id = @agent_id 
		order by session_id desc

		-- Log a "No action" message on behalf of the agent
		exec sys.sp_MSadd_merge_history
			@agent_id = @agent_id,
			@runstatus = 6,     -- Failure status
			@comments = @comments,
			@do_raiserror = 0,
			@log_error = 1,
			@session_id_override = @merge_session_id

		fetch hC_merge_suspect into @agent_id, @start_time
	end
	close hC_merge_suspect
	deallocate hC_merge_suspect

	-- If a running queuereader agent has not logged a history message within the specified
	-- heartbeat_interval then raise a agent suspect error
	declare hC_qrdr_suspect CURSOR LOCAL FAST_FORWARD for 
		select sh1.agent_id, sh1.start_time from MSqreader_history sh1 where
			(sh1.runstatus = 1 or sh1.runstatus = 3 or sh1.runstatus = 4) and
			dateadd(minute, @heartbeat_interval, sh1.time) < @current_time and
			sh1.timestamp = (select max(timestamp) from MSqreader_history where
				agent_id= sh1.agent_id)
		for read only

	open hC_qrdr_suspect
	fetch hC_qrdr_suspect into @agent_id, @start_time
	while (@@fetch_status <> -1)
	begin
		set @heartbeat_failure = 1

		-- Get the agent name
		select @agent_name = name, @job_id = job_id from MSqreader_agents where id = @agent_id

		-- Log a "No action" message on behalf of the agent
		exec sys.sp_MSadd_qreader_history
			@agent_id = @agent_id,
			@runstatus = 6,     -- Failure status
			@comments = @comments,
			@do_raiserror = 0

		fetch hC_qrdr_suspect into @agent_id, @start_time
	end
	close hC_qrdr_suspect
	deallocate hC_qrdr_suspect

	-- Log all is fine message
	if @heartbeat_failure = 0
		-- "Detected heartbeat for all running Replication Agents"
		set @comments = formatmessage(20556)    
	else
		-- "Could not detected heartbeat for all running Replication Agents"
		set @comments = formatmessage(20580)    

	raiserror (20554, 10, -1, @heartbeat_interval)
END
GO
GRANT EXECUTE ON [sys].[sp_MSagent_stethoscope] TO [public] AS [dbo]
GO
