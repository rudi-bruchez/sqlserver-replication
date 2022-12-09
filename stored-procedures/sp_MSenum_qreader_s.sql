SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenum_qreader_s]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenum_qreader_s] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenum_qreader_s]
	@publication_id [int],
	@hours [int],
	@session_type [int]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	declare @succeed int
				,@retry int
				,@failure int
				,@min_time datetime
				,@agent_id int
				,@maxtimestamp timestamp
				,@session_start timestamp
				,@next_session_start timestamp
				,@session_end timestamp
				,@final_ts timestamp

				,@status int
				,@session_status int
				,@error_id int
				,@session_error_id int,
				@start_time nvarchar(24), 
				@time nvarchar(24), 
				@comments nvarchar(255), 
				@duration int, 
				@delivery_rate int, 
				@delivery_latency int,
				@transactions_processed int, 
				@commands_processed int, 
				@average_commands int, 
				@action_count int, 
				@start_datetime datetime,
				@end_datetime datetime
	
	--
	-- security check
	-- only replmonitor can execute this
	--
	if not (is_member(N'db_owner') = 1 or isnull(is_member(N'replmonitor'),0) = 1)
	begin
		raiserror(14260, 16, -1)
		return (1)
	end

	if @session_type  not in (1,2)
	begin
		return(1)
	end
	
	/* 
	** Status const defined in sqlrepl.h 
	*/
	select @succeed = 2
	select @retry = 5
	select @failure = 6

	-- create the table to store sessions
	create table #qreader_session (status int NOT NULL,
		start_time nvarchar(24) NOT NULL, time nvarchar(24) NOT NULL, comments nvarchar(255) NULL, 
		duration int NULL, delivery_rate int NULL, delivery_latency int NULL,
		publication_id int NULL, transactions_processed int NULL, commands_processed int NULL, 
		average_commands int NULL, action_count int NULL, error_id INT NULL, local_timestamp binary(8) NOT NULL)
		
	-- get the agent id
	select TOP 1 @agent_id = agent_id from MSqreader_history with (READPAST)

	--
	-- If Min time specified, initilialize it
	--
	IF (@hours < 1)
		select @min_time = NULL
	ELSE
		select @min_time = dateadd(hour, -@hours, getdate())

	-- initialize
	select @delivery_latency = 0
			,@next_session_start = NULL
			,@session_end = NULL
			,@final_ts = max(timestamp) 
	from MSqreader_history
	
	-- Get the session details
	while (@session_end != @final_ts)
	begin
		--
		-- Mark the beginning of a new session
		--
		if (@next_session_start is NULL)
		begin
			select @session_start = min(timestamp) from MSqreader_history with (READPAST)
				where agent_id = @agent_id and runstatus = 1
		end
		else
		begin
			select @session_start = @next_session_start 
		end

		--
		-- update @next_session_start
		--
		select @next_session_start = ISNULL(min(timestamp), @final_ts) 
		from MSqreader_history
		where agent_id = @agent_id and timestamp > @session_start and runstatus = 1

		--
		-- find session end based on @next_session_start
		--
		if (@next_session_start = @final_ts)
			select @session_end = @final_ts
		else
		begin
			select @session_end = isnull(max(timestamp), @next_session_start)
			from MSqreader_history with (READPAST)
			where agent_id = @agent_id and
				timestamp > @session_start and 
				timestamp < @next_session_start
		end
		   
		--
		-- get start time for this session
		--
		select @start_datetime = start_time, 
			@start_time = sys.fn_replformatdatetime(start_time)
		from MSqreader_history with (READPAST)
		where agent_id = @agent_id and timestamp = @session_start			

		--
		-- do we need to process this session 
		--
		if (@start_time IS NULL)
		begin
			--
			-- Check if we are done with all sessions
			--
			if (@session_end = @final_ts)
				break
			else
				continue
		end

		--
		-- get status, end time, comments, error id for this session
		--
		select @status = runstatus,
			@end_datetime = time,
			@time = sys.fn_replformatdatetime(time), 
			@comments = comments, 
			@error_id = ISNULL(error_id, 0) 
		from MSqreader_history with (READPAST)
		where agent_id = @agent_id and timestamp = @session_end

		--
		-- do we need to continue this session - min time check
		--
		if ((@min_time is NOT NULL) and (@min_time > @end_datetime))
		begin
			--
			-- Check if we are done with all sessions
			--
			if (@session_end = @final_ts)
				break
			else
				continue
		end

		--
		-- get duration, action count, tran processed, cmds processed, avg cmds, etc
		-- for this session
		--
		select @duration = DATEDIFF(second, @start_datetime, @end_datetime)
		select @action_count = ISNULL(count(*), 0)
				,@session_status = max(runstatus)
				,@session_error_id = isnull(max(error_id),0)
			from MSqreader_history with (READPAST)
			where agent_id = @agent_id 
				and timestamp >= @session_start and timestamp <= @session_end

		select @transactions_processed = sum(ISNULL(transactions_processed, 0)) 
				,@commands_processed = sum(ISNULL(commands_processed, 0))
				,@average_commands =  avg(ISNULL(commands_processed, 0))
				,@delivery_rate = cast(avg(ISNULL(delivery_rate, 0.0)) as int)
			from MSqreader_history with (READPAST)
			where agent_id = @agent_id 
				and timestamp >= @session_start and timestamp <= @session_end
				and transactions_processed > 0
		--
		-- if we have errors in the session - choose the highest status
		--
		if (@session_status > 4)
		begin
			select @status = @session_status
				,@error_id = @session_error_id
		end
		--
		-- insert into #qreader_session
		--
		insert into #qreader_session values(@status, @start_time, @time, @comments, 
			@duration, @delivery_rate, @delivery_latency, NULL, @transactions_processed, 
			@commands_processed, @average_commands, @action_count, @error_id, @session_end)

		--
		-- Check if we are done with all sessions
		--
		if (@session_end = @final_ts)
			break
	end

	-- return results
	
	if (@hours < 0)
		set rowcount 100
	select 
		status,
		start_time,
		time, 
		comments, 
		duration,
		delivery_rate,
		delivery_latency,
		publication_id,
		transactions_processed, 
		commands_processed, 
		average_commands, 
		action_count, 
		error_id
	from #qreader_session		
	where (@session_type = 2 and (status = @failure)) or 
			(@session_type = 1)
	order by local_timestamp desc
	--
	-- all done
	--
	return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSenum_qreader_s] TO [public] AS [dbo]
GO
