SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenum_qreader]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenum_qreader] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenum_qreader]
	@name [nvarchar](100),
	@show_distdb [bit]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	declare @agent_name nvarchar(100)
				,@status int
				,@session_status int
				,@start_time nvarchar(24)
				,@time nvarchar(24)
				,@duration int
				,@comments nvarchar(255)
				,@transactions_processed int
				,@commands_processed int
				,@average_commands int
				,@delivery_rate int
				,@delivery_latency int
				,@error_id int
				,@session_error_id int
				,@job_id binary(16)
				,@agent_id int
				,@profile_id int
				,@last_timestamp binary(8)
				,@first_timestamp binary(8)

	--
	-- security check
	-- only replmonitor can execute this
	--
	if not (is_member(N'db_owner') = 1 or isnull(is_member(N'replmonitor'),0) = 1)
	begin
		raiserror(14260, 16, -1)
		return (1)
	end
	
	create table #qreader_agent (name nvarchar(100) NOT NULL, status int NOT NULL,
		start_time nvarchar(24) NULL, time nvarchar(24) NULL, duration int NULL,
		comments nvarchar(255) NULL, 
		transactions_processed int NULL, commands_processed int NULL, 
		average_commands int NULL, delivery_rate int NULL, delivery_latency int NULL,
		error_id INT NULL, job_id binary(16) NULL, 
		profile_id int NULL, agent_id int NOT NULL, local_timestamp binary(8) NOT NULL)

	declare #hC CURSOR LOCAL FAST_FORWARD FOR
		select id, name, job_id, profile_id
		from MSqreader_agents with (READPAST)
		where name = case when ((@name = '%') or (@name is NULL)) then name else @name end
		for read only

	OPEN #hC
	FETCH #hC INTO @agent_id, @agent_name, @job_id, @profile_id
	WHILE (@@fetch_status <> -1)
	begin       
		--
		-- Initialize
		--
		select @status = 0 
				,@session_status = 0
				,@session_error_id = 0
				,@delivery_latency = 0
		--
		-- select the last timestamp
		--
		select @last_timestamp = max(timestamp) from MSqreader_history with (READPAST) 
		where agent_id = @agent_id
		--
		-- select the last time the agent was started
		--
		select @first_timestamp = max(timestamp) from MSqreader_history with (READPAST)
		where agent_id = @agent_id and runstatus = 1
		--
		-- Get start time, duration
		--
		select @start_time = sys.fn_replformatdatetime(start_time)
		from MSqreader_history with (READPAST)
		where agent_id = @agent_id and timestamp = @first_timestamp
		--
		-- Get the session status and error - get the highest ones
		--
		select @session_status = isnull(max(runstatus),0)
				,@session_error_id = isnull(max(error_id),0)
		from MSqreader_history with (READPAST)
		where agent_id = @agent_id 
			and timestamp >= @first_timestamp and timestamp <= @last_timestamp
		--
		-- Compute the transaction processed, commands processed,
		-- avg commands, delivery rate
		--
		select @transactions_processed = sum(ISNULL(transactions_processed, 0)) 
			,@commands_processed = sum(ISNULL(commands_processed, 0))
			,@average_commands =  avg(ISNULL(commands_processed, 0))
			,@delivery_rate = cast(avg(ISNULL(delivery_rate, 0.0)) as int)
		from MSqreader_history with (READPAST)
		where agent_id = @agent_id 
			and timestamp >= @first_timestamp and timestamp <= @last_timestamp
			and transactions_processed > 0
		--
		-- Get the duration, time, status, comments, error from last log
		--
		select 
			@duration = duration,
			@time = sys.fn_replformatdatetime(time),
			@status = isnull(runstatus, 0),
			@comments = comments,
			@error_id = error_id
		from MSqreader_history with (READPAST)
		where agent_id = @agent_id and timestamp = @last_timestamp
		--
		-- if we have errors in the session - choose the highest status
		--
		if (@session_status > 4)
		begin
			select @status = @session_status
					,@error_id = @session_error_id
		end
		--
		-- store the session information
		--
		insert into #qreader_agent values(@agent_name, @status, @start_time, 
			@time, @duration, @comments, @transactions_processed, @commands_processed, 
			@average_commands, @delivery_rate, @delivery_latency,
			@error_id, @job_id, @profile_id, @agent_id, isnull(@last_timestamp,0x00))            
		--
		-- fetch next agent to process
		--
		FETCH #hC INTO @agent_id, @agent_name, @job_id, @profile_id
	end
	--
	-- return resultset
	--
	if @show_distdb = 0
		select * from #qreader_agent 
	else 
		select 'dbname' = DB_NAME(), * from #qreader_agent
	--
	-- all done
	--
	return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSenum_qreader] TO [public] AS [dbo]
GO
