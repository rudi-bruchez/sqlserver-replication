SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenum_distribution_sd]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenum_distribution_sd] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenum_distribution_sd]
	@name [nvarchar](100),
	@time [datetime]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	declare @start_time datetime
	declare @time_up datetime
	declare @agent_id int

	--
	-- security check
	-- only replmonitor can execute this
	--
	if not (is_member(N'db_owner') = 1 or isnull(is_member(N'replmonitor'),0) = 1)
	begin
		raiserror(14260, 16, -1)
		return (1)
	end

	IF @time IS NULL
		select @time = GETDATE()
	
	select @agent_id = id from MSdistribution_agents where
		name = @name

	/*
	** Minute-approximate @time can be used.
	** Note: The select only return datetime data with minute precision
	*/
	IF  DATEPART(second, @time) = 0 AND
		DATEPART(millisecond, @time) = 0
	BEGIN
		SELECT @time_up = DATEADD(second, +59, @time)
		SELECT @time_up = DATEADD(millisecond, +999, @time)
	END
	ELSE
		SELECT @time_up = @time
		

	select top 1 @start_time = start_time           
		 from MSdistribution_history rh with (READPAST) 
		where
		rh.agent_id = @agent_id and
		time <= @time_up
	and comments not like N'<stats state%'	
		order by timestamp DESC

	select  runstatus, 
		'time' = sys.fn_replformatdatetime(time), 
		comments, duration, 
		delivery_rate,
		delivery_latency,
		/* delivery_time */ 0,  
		delivered_transactions, delivered_commands, average_commands, 
		error_id            
		from MSdistribution_history rh with (READPAST) 
		where
		rh.agent_id = @agent_id and
		start_time = @start_time
	and comments not like N'<stats state%'	
	order by timestamp desc
end
GO
GRANT EXECUTE ON [sys].[sp_MSenum_distribution_sd] TO [public] AS [dbo]
GO
