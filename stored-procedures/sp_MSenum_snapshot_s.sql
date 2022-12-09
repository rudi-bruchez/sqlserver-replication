SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenum_snapshot_s]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenum_snapshot_s] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenum_snapshot_s]
	@name [nvarchar](100),
	@hours [int],
	@session_type [int]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	declare @agent_id int
	declare @succeed int
	declare @retry int
	declare @failure int
	declare @min_time datetime
	declare @independent_agent bit
	declare @publisher_id smallint
	declare @publisher_db sysname
	declare @publication sysname
	declare @start_agent_comment nvarchar(100)
	declare @initializing int
	declare @latest_session_timestamps table (timestamp binary(8) primary key, action_count int)

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
	select @initializing = 1
	select @start_agent_comment = formatmessage(20529)


	SELECT @publisher_id = publisher_id, @publisher_db = publisher_db, 
		@publication = publication, @agent_id = id
		from
		MSsnapshot_agents
		where 
		name = @name 

	insert into @latest_session_timestamps 
		select max(timestamp), count(*)
		  from MSsnapshot_history
		 where (runstatus <> @initializing or
				comments <> @start_agent_comment) 
	  group by agent_id, start_time
		having agent_id = @agent_id

	/* Get date starting point */
	IF @hours < 0
	BEGIN
		select top 100 sh1.runstatus, 
			'start_time' = sys.fn_replformatdatetime(sh1.start_time), 
			'time' = sys.fn_replformatdatetime(sh1.time), 
			sh1.comments, sh1.duration,
			sh1.delivery_rate, sh1.delivered_commands,
			'action_count' = lst.action_count,
			sh1.error_id
			from MSsnapshot_history sh1
			inner join @latest_session_timestamps lst
			on sh1.timestamp = lst.timestamp
			where
			sh1.agent_id = @agent_id and
			((@session_type = 1)  or
			sh1.runstatus = @failure) 
			order by sh1.timestamp desc
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
		select sh1.runstatus, 
			'start_time' = sys.fn_replformatdatetime(sh1.start_time), 
			'time' = sys.fn_replformatdatetime(sh1.time), 
			sh1.comments, sh1.duration,
			sh1.delivery_rate, sh1.delivered_commands,
			'action_count' = lst.action_count,
			sh1.error_id
			from MSsnapshot_history sh1
			inner join @latest_session_timestamps lst
			on sh1.timestamp = lst.timestamp
			where
			sh1.agent_id = @agent_id and
			((@session_type = 1)  or
			sh1.runstatus = @failure) and
			(sh1.time >= @min_time OR @min_time IS NULL)
			order by sh1.timestamp desc
	END
end
GO
GRANT EXECUTE ON [sys].[sp_MSenum_snapshot_s] TO [public] AS [dbo]
GO
