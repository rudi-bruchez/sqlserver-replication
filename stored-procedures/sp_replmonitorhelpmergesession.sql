SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_replmonitorhelpmergesession]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_replmonitorhelpmergesession] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_replmonitorhelpmergesession]
	@agent_name [nvarchar](100),
	@hours [int],
	@session_type [int],
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on
	
	declare @min_time datetime
	declare @retcode int
	declare @succeed int    
	declare @running int    
	declare @retry int
	declare @failure int
	declare @isdistdb bit
	declare @agent_id int
	declare @max_session_id int
	declare @max_running_session_id int
		
	select @succeed = 2
	select @retry = 5
	select @failure = 6
	select @running = 3
		
	--
	-- security check : replmonitor
	--
	if not (is_member(N'db_owner') = 1 or isnull(is_member(N'replmonitor'),0) = 1)
	begin
		raiserror(14260, 16, -1)
		return (1)
	end

	select @isdistdb = sys.fn_MSrepl_isdistdb(DB_NAME())
	
	if @isdistdb = 1 and @agent_name is null
	begin
		raiserror(14043, 16, -1, '@agent_name', 'sp_replmonitorhelpmergesession')
		return 1
	end
	else if @isdistdb = 0 and (@publisher is null or @publisher_db is null or @publication is null)
	begin
		-- subscriber-side monitoring
		if @publisher is null
			raiserror(14043, 16, -1, '@publisher', 'sp_replmonitorhelpmergesession')
		if @publisher_db is null
			raiserror(14043, 16, -1, '@publisher_db', 'sp_replmonitorhelpmergesession')
		if @publication is null
			raiserror(14043, 16, -1, '@publication', 'sp_replmonitorhelpmergesession')
		return 1
	end

	if @isdistdb = 1
	begin
	
		select @agent_id = id from dbo.MSmerge_agents where name = @agent_name
		
		select top 1 @max_session_id = session_id from dbo.MSmerge_sessions with (NOLOCK) 
		where agent_id = @agent_id
		order by session_id desc

		select @max_running_session_id = @max_session_id

		select top 1 @max_running_session_id = session_id from dbo.MSmerge_sessions with (NOLOCK) 
		where agent_id = @agent_id and runstatus = @running
		order by session_id desc
	
		IF @hours < 0
		BEGIN
			select top 100
			sessions.session_id as Session_id,
			case when sessions.runstatus = 3 and sessions.session_id <> @max_running_session_id  and sys.fn_replmerge_get_errormsgcounts(sessions.session_id) <> 0 then @failure
				   when sessions.runstatus = 3 and sessions.session_id <> @max_running_session_id  and sys.fn_replmerge_get_errormsgcounts(sessions.session_id) = 0 then @succeed
				when sessions.runstatus is null then 0 else sessions.runstatus end as Status,
			sessions.start_time as StartTime,
			sessions.end_time as EndTime,
			sessions.duration as Duration,
			sys.fn_replmerge_get_cmdcounts(sessions.session_id, 1) as UploadedCommands,
			sys.fn_replmerge_get_cmdcounts(sessions.session_id, 2) as DownloadedCommands,
			sys.fn_replmerge_get_errormsgcounts(sessions.session_id) as ErrorMessages,
			(
				select top 1 re.id from dbo.MSrepl_errors re
				where re.session_id = sessions.session_id
				order by re.id desc
			) as ErrorID,
			sessions.percent_complete as PercentageDone,
			sessions.time_remaining as TimeRemaining,
			sessions.current_phase_id as CurrentPhase,
			(
				select top 1 rh.comments from dbo.MSmerge_history rh 
				where rh.session_id = sessions.session_id
				order by rh.session_id desc, rh.timestamp desc
			) as LastMessage,
			--IsSpidActive = case when exists (select * from sys.dm_exec_sessions sp where sp.login_time = sessions.spid_login_time
			--									and sp.session_id = sessions.spid) then 1 else 0 end
			IsSpidActive = 1
			from dbo.MSmerge_sessions sessions
			where sessions.agent_id = @agent_id
			and sessions.session_id <= @max_session_id
			and             
			(
				(
					@session_type = 1 and
		  			(
		  				sessions.runstatus = @succeed 
		  				or sessions.runstatus = @retry 
		  				or sessions.runstatus = @running
						or sessions.session_id = @max_session_id
					)
				) 
				or sessions.runstatus = @failure
			)
			order by sessions.start_time desc   	
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
			-- phase is ReconcilerMsg.lPhase: UPLOAD_PHASE as 2 and DOWNLOAD_PHASE as 3
			-- dbo.MSmerge_articlehistory.phase_id
			select 
			sessions.session_id as Session_id,
			case when sessions.runstatus = 3 and sessions.session_id <> @max_running_session_id  and sys.fn_replmerge_get_errormsgcounts(sessions.session_id) <> 0 then @failure
				   when sessions.runstatus = 3 and sessions.session_id <> @max_running_session_id  and sys.fn_replmerge_get_errormsgcounts(sessions.session_id) = 0 then @succeed
				when sessions.runstatus is null then 0 else sessions.runstatus end as Status,
			sessions.start_time as StartTime,
			sessions.end_time as EndTime,
			sessions.duration as Duration,
			sys.fn_replmerge_get_cmdcounts(sessions.session_id, 1) as UploadedCommands,
			sys.fn_replmerge_get_cmdcounts(sessions.session_id, 2) as DownloadedCommands,
			sys.fn_replmerge_get_errormsgcounts(sessions.session_id) as ErrorMessages,
			(
				select top 1 re.id from dbo.MSrepl_errors re
				where re.session_id = sessions.session_id
				order by re.id desc
			) as ErrorID,
			sessions.percent_complete as PercentageDone,
			sessions.time_remaining as TimeRemaining,
			sessions.current_phase_id as CurrentPhase,
			(
				select top 1 rh.comments from dbo.MSmerge_history rh 
				where rh.session_id = sessions.session_id
				order by rh.session_id desc, rh.timestamp desc
			) as LastMessage,
			--IsSpidActive = case when exists (select * from sys.dm_exec_sessions sp where sp.login_time = sessions.spid_login_time
			--									and sp.session_id = sessions.spid) then 1 else 0 end
			IsSpidActive = 1
			from dbo.MSmerge_sessions sessions
			where sessions.agent_id = @agent_id
			and sessions.session_id <= @max_session_id
			and             
			(
				(
					@session_type = 1 and
		  			(
		  				sessions.runstatus = @succeed 
		  				or sessions.runstatus = @retry 
		  				or sessions.runstatus = @running
						or sessions.session_id = @max_session_id
					)
				) 
				or sessions.runstatus = @failure
			)
			and (sessions.end_time >= @min_time or @min_time IS NULL)
			order by sessions.start_time desc
		END
	end
	else
	begin
		exec @retcode = sys.sp_MShelp_subscriberside_history 
							@hours=@hours, @session_type=@session_type, @publisher = @publisher, @publisher_db = @publisher_db, @publication = @publication
		if @@error <> 0 or @retcode <> 0
			return 1
	end
	
	return 0
end
GO
GRANT EXECUTE ON [sys].[sp_replmonitorhelpmergesession] TO [public] AS [dbo]
GO
