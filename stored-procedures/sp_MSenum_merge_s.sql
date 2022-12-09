SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenum_merge_s]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenum_merge_s] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenum_merge_s]
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
	/* 
	** Status const defined in sqlrepl.h 
	*/
	select @succeed = 2
	select @retry = 5
	select @failure = 6

	select @agent_id = id from dbo.MSmerge_agents where name = @name

	/* Get date starting point */
	IF @hours < 0
	BEGIN
		select top 100 ms.runstatus, 
			'start_time' = sys.fn_replformatdatetime(ms.start_time), 
			'time' = sys.fn_replformatdatetime(ms.end_time), 
			rh.comments, ms.duration, 
			-- Note: return average rate here !!! delivery_rate column is current rate
			ms.delivery_rate, 
			ms.download_inserts, ms.download_updates, ms.download_deletes, ms.download_conflicts,
			ms.upload_inserts, ms.upload_updates, ms.upload_deletes, ms.upload_conflicts,
			'action_count' = (select count(*) from dbo.MSmerge_history with (READPAST) where
				session_id = ms.session_id and agent_id = @agent_id),
			rh.error_id
			from dbo.MSmerge_history rh with (READPAST), dbo.MSmerge_sessions ms with (READPAST)
			where
			ms.agent_id = @agent_id and
			((@session_type = 1 and
			(ms.runstatus = @succeed or
			ms.runstatus = @retry or
			ms.timestamp = (select max(ms2.timestamp) from dbo.MSmerge_sessions ms2 with (READPAST) where
				ms2.agent_id = @agent_id))) or 
			ms.runstatus = @failure) and
			ms.session_id = rh.session_id and
			ms.agent_id = rh.agent_id and
			rh.timestamp = (select max(rh2.timestamp) from dbo.MSmerge_history rh2 with (READPAST) where
				rh2.agent_id = @agent_id and rh2.session_id=ms.session_id)
			order by ms.session_id desc
	END
	ELSE
	BEGIN
		IF @hours = 0
		BEGIN
			select @min_time = NULL
		END
		ELSE
		BEGIN
			select @min_time = dateadd(hour, -@hours, getdate())
		END
		select  ms.runstatus, 
			'start_time' = sys.fn_replformatdatetime(ms.start_time), 
			'time' = sys.fn_replformatdatetime(ms.end_time), 
			rh.comments, ms.duration, 
			-- Note: return average rate here !!! delivery_rate column is current rate
			ms.delivery_rate, 
			ms.download_inserts, ms.download_updates, ms.download_deletes, ms.download_conflicts,
			ms.upload_inserts, ms.upload_updates, ms.upload_deletes, ms.upload_conflicts,
			'action_count' = (select count(*) from dbo.MSmerge_history with (READPAST) where
				session_id = ms.session_id and agent_id = @agent_id),
			rh.error_id
			from dbo.MSmerge_history rh with (READPAST), dbo.MSmerge_sessions ms with (READPAST)
			where
			ms.agent_id = @agent_id and
			((@session_type = 1 and
			(ms.runstatus = @succeed or
			ms.runstatus = @retry or
			ms.timestamp = (select max(ms2.timestamp) from dbo.MSmerge_sessions ms2 with (READPAST) where
				ms2.agent_id = @agent_id))) or 
			ms.runstatus = @failure) and
			(ms.end_time >= @min_time or @min_time IS NULL) and
			   ms.session_id = rh.session_id and
			ms.agent_id = rh.agent_id and
			rh.timestamp = (select max(rh2.timestamp) from dbo.MSmerge_history rh2 with (READPAST) where
				rh2.agent_id = @agent_id and rh2.session_id=ms.session_id)        
			order by ms.session_id desc
	END
end
GO
GRANT EXECUTE ON [sys].[sp_MSenum_merge_s] TO [public] AS [dbo]
GO
