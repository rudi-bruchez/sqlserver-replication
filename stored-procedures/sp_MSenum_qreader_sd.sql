SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenum_qreader_sd]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenum_qreader_sd] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenum_qreader_sd]
	@publication_id [int],
	@time [datetime]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	declare @time_up datetime
				,@agent_id int
				,@final_ts timestamp
				,@initial_ts timestamp
				,@session_start timestamp
				,@next_session_start timestamp
				,@session_end timestamp

	--
	-- security check
	-- only replmonitor can execute this
	--
	if not (is_member(N'db_owner') = 1 or isnull(is_member(N'replmonitor'),0) = 1)
	begin
		raiserror(14260, 16, -1)
		return (1)
	end

	if (@publication_id = 0)
		select @publication_id = NULL
		
	IF @time IS NULL
		select @time = GETDATE()

	/*
	** Minute-approximate @time can be used.
	** Note: The select only return datetime data with minute precision
	*/
	IF ( (DATEPART(second, @time) = 0) AND
			(DATEPART(millisecond, @time) = 0) )
	BEGIN
		SELECT @time_up = DATEADD(second, +59, @time)
		SELECT @time_up = DATEADD(millisecond, +999, @time)
	END
	ELSE
		SELECT @time_up = @time

	--
	-- Get the agent id
	--
	select TOP 1 @agent_id = agent_id from MSqreader_history with (READPAST)

	--
	-- Get the session start, next session start timestamps
	--
	select @initial_ts = min(timestamp), @final_ts = max(timestamp) from MSqreader_history with (READPAST)
	
	select @session_start = ISNULL(max(timestamp), @initial_ts) from MSqreader_history with (READPAST)
			where agent_id = @agent_id and time <= @time_up and runstatus = 1
			
	select @next_session_start = ISNULL(min(timestamp), @final_ts) from MSqreader_history
			where agent_id = @agent_id and timestamp > @session_start and runstatus = 1

	--
	-- find session end based on @next_session_start
	--
	if (@next_session_start = @final_ts)
		select @session_end = @final_ts
	else
	begin
		select @session_end = max(timestamp)
		from MSqreader_history
		where agent_id = @agent_id and
			timestamp > @session_start and 
			timestamp < @next_session_start
	end
	
	--
	-- Do the select now
	--
	select  runstatus, 
		'time' = sys.fn_replformatdatetime(time), 
		comments, 
		transaction_id, 
		transaction_status,
		commands_processed,
		subscriber,
		subscriberdb,
		'error_id' = ISNULL(error_id, 0)
	from MSqreader_history with (READPAST)
	where
		agent_id = @agent_id and
		timestamp >= @session_start and
		timestamp <= @session_end
 	and comments not like N'<stats state%'
 order by timestamp desc
end
GO
GRANT EXECUTE ON [sys].[sp_MSenum_qreader_sd] TO [public] AS [dbo]
GO
