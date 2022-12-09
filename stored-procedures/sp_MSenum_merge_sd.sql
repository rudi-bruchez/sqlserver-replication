SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenum_merge_sd]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenum_merge_sd] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenum_merge_sd]
	@name [nvarchar](100),
	@time [datetime]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	declare @start_time datetime
	declare @agent_id int
	declare @time_up datetime

	--
	-- security check
	-- only replmonitor can execute this
	--
	if not (is_member(N'db_owner') = 1 or isnull(is_member(N'replmonitor'),0) = 1)
	begin
		raiserror(14260, 16, -1)
		return (1)
	end
	
	select @agent_id = id from dbo.MSmerge_agents where name=@name
	
	IF @time IS NULL
		select @time = GETDATE()

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

	declare @session_id int

	select top 1 @session_id=session_id
	from dbo.MSmerge_sessions with (READPAST) 
	where agent_id=@agent_id and
	end_time<= @time_up
	order by session_id DESC

	-- have to fake rate/time and count as we only have cumulative count number
	select  ms.runstatus, 
			'time' = sys.fn_replformatdatetime(ms.end_time),
			rh.comments, ms.duration, 
		-- Note: return average rate here !!! delivery_rate column is current rate
		ms.delivery_rate, 
		ms.download_inserts, ms.download_updates, ms.download_deletes, ms.download_conflicts,
		ms.upload_inserts, ms.upload_updates, ms.upload_deletes, ms.upload_conflicts,
		rh.error_id            
		from dbo.MSmerge_history rh with (READPAST), dbo.MSmerge_sessions ms with (READPAST)
		where
		rh.agent_id = @agent_id and
		rh.session_id = @session_id and 
		ms.agent_id = @agent_id and
		ms.session_id = @session_id
		order by rh.session_id desc, rh.timestamp desc
end
GO
GRANT EXECUTE ON [sys].[sp_MSenum_merge_sd] TO [public] AS [dbo]
GO
