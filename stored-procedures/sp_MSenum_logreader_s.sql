SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenum_logreader_s]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenum_logreader_s] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenum_logreader_s]
	@name [nvarchar](100),
	@hours [int],
	@session_type [int]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	declare @succeed int
	declare @agent_id int
	declare @retry int
	declare @failure int                                 
	declare @min_time datetime

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
	
	select @agent_id  = (select top 1 id from MSlogreader_agents where name = @name) 
	
	/* 
	** Status const defined in sqlrepl.h 
	*/
	select @succeed = 2
	select @retry = 5
	select @failure = 6
   	select @min_time = NULL
   	
	--
	-- Check @hours
	-- return top 100 rows if < 0
	-- return session later than if > 0
	--
	if @hours < 0
		set rowcount 100
	else if @hours > 0
		select @min_time = dateadd(hour, -@hours, getdate())
		
	/* Get date starting point */
	select rh.runstatus, 
			'start_time' = sys.fn_replformatdatetime(rh.start_time), 
			'time' = sys.fn_replformatdatetime(rh.time), 
			rh.comments, rh.duration, rh.delivery_rate, rh.delivery_latency,
			rh.delivery_time, rh.delivered_transactions, rh.delivered_commands, rh.average_commands, 
			hs.action_count,
			rh.error_id
		from MSlogreader_history rh with (READPAST)
			join (select agent_id, 
						start_time, 
						count(start_time) as action_count, 
						max(timestamp) as max_timestamp 
					from MSlogreader_history with (READPAST)
					where agent_id = @agent_id
						and comments not like N'<stats state%'
						and (@session_type = 1
							or runstatus = @failure)
					group by agent_id, start_time) as hs
			on rh.agent_id = hs.agent_id
				and rh.start_time = hs.start_time
				and rh.timestamp = hs.max_timestamp
		where time >= @min_time 
			or @min_time IS NULL
	   	order by timestamp desc
end
GO
GRANT EXECUTE ON [sys].[sp_MSenum_logreader_s] TO [public] AS [dbo]
GO
