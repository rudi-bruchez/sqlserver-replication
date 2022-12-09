SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenum_distribution_s]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenum_distribution_s] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenum_distribution_s]
	@name [nvarchar](100),
	@hours [int],
	@session_type [int]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	declare @notstarted int
		,@succeed int
		,@retry int
		,@failure int
		,@min_time datetime
		,@agent_id int

	--
	-- security check
	-- only replmonitor can execute this
	--
	if not (is_member(N'db_owner') = 1 or isnull(is_member(N'replmonitor'),0) = 1)
	begin
		raiserror(14260, 16, -1)
		return (1)
	end
	
	/* 
	** Status const defined in sqlrepl.h 
	*/
	select @notstarted = 0
			,@succeed = 2
			,@retry = 5
			,@failure = 6
			,@min_time = NULL

	select @agent_id = id 
		from MSdistribution_agents 
		where name = @name
	
	--
	-- Check @hours
	-- return top 100 rows if < 0
	-- return session later than if > 0
	--
	if @hours < 0
		set rowcount 100
	else if @hours > 0
		select @min_time = dateadd(hour, -@hours, getdate())
	--
	-- enumerate the sessions now
	--
	select rh.runstatus, 
			'start_time' = sys.fn_replformatdatetime(rh.start_time), 
			'time' = sys.fn_replformatdatetime(rh.time), 
			rh.comments, rh.duration, 
			rh.delivery_rate,
			rh.delivery_latency,
			0, /*delivery_time */   
			rh.delivered_transactions, rh.delivered_commands, rh.average_commands, 
			'action_count' = hs.action_count,
			rh.error_id
		from MSdistribution_history rh with (READPAST) 
			join (select agent_id, 
						start_time, 
						count(start_time) as action_count, 
						max(timestamp) as max_timestamp 
					from MSdistribution_history with (READPAST)
					where agent_id = @agent_id
						and runstatus != @notstarted
						and comments not like N'<stats state%'	
						and (@session_type = 1
							or runstatus = @failure)
					group by agent_id, start_time) as hs
			on rh.agent_id = hs.agent_id
				and rh.start_time = hs.start_time
				and rh.timestamp = hs.max_timestamp
		-- if min time is specified then return sessions after that 
		where @min_time IS NULL 
			or time >= @min_time
		order by timestamp desc
	--
	-- all done
	--
	return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSenum_distribution_s] TO [public] AS [dbo]
GO
