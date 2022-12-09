SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSadd_merge_history]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSadd_merge_history] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSadd_merge_history]
	@agent_id [int],
	@runstatus [int],
	@comments [nvarchar](1000),
	@delivery_time [int],
	@download_inserts [int],
	@download_updates [int],
	@download_deletes [int],
	@download_conflicts [int],
	@upload_inserts [int],
	@upload_updates [int],
	@upload_deletes [int],
	@upload_conflicts [int],
	@log_error [bit],
	@perfmon_increment [bit],
	@update_existing_row [bit],
	@updateable_row [bit],
	@do_raiserror [bit],
	@called_by_nonlogged_shutdown_detection_agent [bit],
	@session_id_override [int]
WITH EXECUTE AS CALLER
AS
BEGIN
	declare @start_time datetime
	declare @end_time datetime
	declare @inserts int
	declare @updates int
	declare @deletes int
	declare @conflicts int
	declare @total int
	declare @percentage decimal(10,2)
	DECLARE @current_time datetime
			,@duration int
			,@delivery_rate float
			,@perfmon_delivery_rate int
			,@perfmon_conflict_count int
			,@delivered_rows int
			,@changes int
			,@delivery_time_old  int
			,@delivered_rows_old int
			,@download_inserts_old  int 
			,@download_updates_old  int 
			,@download_deletes_old  int 
			,@download_conflicts_old int 
			,@upload_inserts_old int 
			,@upload_updates_old int 
			,@upload_deletes_old int 
			,@upload_conflicts_old int 
			,@publisher_id smallint
			,@subscriber_id smallint
			,@error_id int 
			,@startup int
			,@succeed int
			,@retry int
			,@inprogress int
			,@failure int
			,@idle int
			,@lastrow_timestamp timestamp
			,@lastssrow_timestamp timestamp
			,@agent_name nvarchar(100)
			,@publisher sysname
			,@publisher_db sysname
			,@publication sysname
			,@retcode int
			,@existing_row_updateble bit
			,@this_row_updateable bit
			,@agentclassname sysname
			,@lastrunstatus int
			,@spid_login_time datetime
			
	-- Security Check
	exec @retcode = sys.sp_MScheck_pull_access
			@agent_id = @agent_id,
			@agent_type = 1 -- merge agent
	if @@error <> 0 or @retcode <> 0
			return (1)

	select @start_time = getdate()		
	select @percentage= NULL
	--select @spid_login_time = login_time from sys.dm_exec_sessions where session_id = @@spid
	select @spid_login_time = NULL

	if @session_id_override is null
	begin
		-- The only time session_id is fetched
		declare @binctx binary(128)
		declare @current_session_id int, @session_id int
		SELECT @binctx = isnull(context_info(),0x00)
		set @current_session_id=CAST( @binctx AS int )
		if @current_session_id=0
		begin
		declare @logintime1 datetime
		select @logintime1 = @start_time
		
		insert into dbo.MSmerge_sessions(agent_id, start_time, runstatus, spid_login_time, spid) 
				values(@agent_id, @logintime1, 1, @spid_login_time, @@spid)
		select @current_session_id = @@IDENTITY
		if @@ERROR<>0
			return (0)
			SET @binctx = CAST( @current_session_id AS binary(128) )
			SET CONTEXT_INFO @binctx	 
		end
		set @session_id=@current_session_id
	end
	else
		set @session_id = @session_id_override
	
	select @start_time = start_time from dbo.MSmerge_sessions
			where session_id = @session_id	-- no need for top 1 because of unique clustered index on session_id
	
	-- calculate duration for summary
	set @end_time = getdate()
	select @duration=DATEDIFF(second, @start_time, @end_time)

	-- This section is added during Yukon. >>
		
	/* 
	** Status const defined in sqlrepl.h 
	*/
	select @startup = 1
			,@succeed = 2
			,@inprogress = 3
			,@idle = 4
			,@retry = 5
			,@failure = 6
			,@delivery_time_old  = 0
			,@download_inserts_old   = 0
			,@download_updates_old   = 0
			,@download_deletes_old   = 0
			,@download_conflicts_old  = 0
			,@upload_inserts_old  = 0
			,@upload_updates_old  = 0
			,@upload_deletes_old  = 0
			,@upload_conflicts_old  = 0
			,@existing_row_updateble = 0
			,@this_row_updateable = 0

	if (@updateable_row = 1)
	begin
		select @this_row_updateable = 1
	end

	SELECT @current_time = GETDATE()

	-- Update Perfmon counter
	if @perfmon_increment = 1
	begin
		if @runstatus = @startup
			dbcc incrementinstance ("SQL Replication Agents", "Running", "Merge", 1)
		else if (@runstatus = @succeed or @runstatus = @retry or @runstatus = @failure)
			dbcc incrementinstance ("SQL Replication Agents", "Running", "Merge", -1)
	end

    SELECT @agent_name = name, @publisher_id = publisher_id, @publisher_db = publisher_db, 
        @publication = publication from dbo.MSmerge_agents where id = @agent_id
    SELECT @publisher = srvname from MSreplservers where srvid = @publisher_id

	IF @runstatus = @inprogress or @runstatus = @idle
		BEGIN
			SELECT TOP 1 @lastrow_timestamp = timestamp,
					@existing_row_updateble = updateable_row
			FROM dbo.MSmerge_history with (rowlock)
			WHERE  agent_id = @agent_id ORDER BY timestamp DESC

			SELECT TOP 1 @lastssrow_timestamp = timestamp,
							@start_time = start_time, 
					@download_inserts_old = download_inserts ,
					@download_updates_old = download_updates, 
					@download_deletes_old = download_deletes,
					@download_conflicts_old = download_conflicts,
					@upload_inserts_old = upload_inserts, 
					@upload_updates_old = upload_updates,
					@upload_deletes_old = upload_deletes,
					@upload_conflicts_old = upload_conflicts,
					@delivery_time_old = delivery_time
			FROM dbo.MSmerge_sessions with (rowlock)
			WHERE  session_id=@session_id
		
			select @delivered_rows_old = @download_inserts_old + 
							 @download_updates_old +
							 @download_deletes_old +
							 @upload_updates_old +
							 @upload_inserts_old +
							 @upload_deletes_old 
		END
	ELSE IF @runstatus <> 1 --1 is the Start status
		BEGIN
			SELECT TOP 1 @lastrow_timestamp = timestamp
			FROM dbo.MSmerge_history with (rowlock)
			WHERE  agent_id = @agent_id ORDER BY timestamp DESC

			SELECT TOP 1 @lastssrow_timestamp = timestamp,
						@start_time = start_time,
						@lastrunstatus = runstatus
			FROM dbo.MSmerge_sessions with (rowlock)
			WHERE session_id=@session_id

			if (@lastrunstatus = @succeed or @lastrunstatus = @failure or @lastrunstatus = @retry)
			begin
				select @start_time = @current_time
			end
		END
	ELSE
		BEGIN
			SELECT @start_time = @current_time
		END

	/* Use the current time if no corresponding start_up message logged */
	IF @start_time IS NULL
	   SELECT @start_time = @current_time

	/* Calculate agent run duration */
	SELECT @duration = DATEDIFF(second, @start_time, @current_time)

	if (@start_time = @current_time and (@runstatus = @succeed or @runstatus = @failure or @runstatus = @retry))
	begin
		declare @logintime datetime
		select @logintime = NULL
		select @logintime = (select start_time from dbo.MSmerge_sessions with (NOLOCK) where session_id=@session_id)
		set @start_time = @logintime
		if (@logintime is not null)
		begin
			select @duration = DATEDIFF(second, @logintime, @current_time) 
		end
	end
							 
	select @delivered_rows = @download_inserts + 
							 @download_updates +
							 @download_deletes +
							 @upload_updates +
							 @upload_inserts +
							 @upload_deletes 

	-- Set Perfmon counters
	if @runstatus = @idle or @runstatus = @inprogress
	begin
		dbcc addinstance ("SQL Replication Merge", @agent_name)

		set @changes = @download_inserts + @download_updates + @download_deletes                             
		dbcc incrementinstance ("SQL Replication Merge", "Downloaded Changes", @agent_name, @changes)

		set @changes = @upload_updates + @upload_inserts + @upload_deletes 
		dbcc incrementinstance ("SQL Replication Merge", "Uploaded Changes", @agent_name, @changes)

		set @perfmon_conflict_count = @download_conflicts + @upload_conflicts
		dbcc incrementinstance ("SQL Replication Merge", "Conflicts", @agent_name, @perfmon_conflict_count)
	end

	if @runstatus = @inprogress  or @runstatus = @idle			-- if it is in progress, then do incremental change
	begin
		select @download_inserts = @download_inserts_old + @download_inserts
		select      @download_updates = @download_updates_old + @download_updates
		select      @download_deletes = @download_deletes_old + @download_deletes
		select      @download_conflicts = @download_conflicts_old + @download_conflicts
		select      @upload_inserts = @upload_inserts_old + @upload_inserts
		select     @upload_updates = @upload_updates_old + @upload_updates
		select     @upload_deletes = @upload_deletes_old + @upload_deletes
		select     @upload_conflicts = @upload_conflicts_old + @upload_conflicts

		select  @delivery_time = @delivery_time_old + @delivery_time
		select @delivered_rows = @delivered_rows + @delivered_rows_old
	end
	
	IF @duration <> 0 and @duration is not null
	   SELECT @delivery_rate = (@delivered_rows * 1.0) / @duration
	ELSE
	   SELECT @delivery_rate = 0.0

	/* 
	** Set error id to 0 unless the user want to log errors associate with this 
	** history message.
	*/
	SELECT @error_id = 0
	IF @log_error = 1 or (@runstatus = @failure and (@called_by_nonlogged_shutdown_detection_agent = 1 or @session_id_override is not null))
	BEGIN
		-- Ignore errors here. @error_id will be set to 0 in case of errors  
		EXEC sys.sp_MSget_new_errorid @error_id OUTPUT
		
		if (@runstatus = @failure and (@called_by_nonlogged_shutdown_detection_agent = 1 or @session_id_override is not null))
		begin
			exec sys.sp_MSadd_repl_error 
				@id = @error_id,
				@error_type_id = 0,
				@source_type_id = 0,
				@source_name = NULL,
				@error_code = 0,
				@error_text = @comments,
				@session_id = @session_id
		end
	END

	-- Insert idle record or update if history record is already 'idle'
	IF (@existing_row_updateble = 1) and (@runstatus = @idle or @update_existing_row = 1)
	begin
		-- Attempt to update the last row if it is IDLE
		UPDATE dbo.MSmerge_history SET 
					comments = @comments,
			updateable_row = @this_row_updateable,
			error_id = case @error_id when 0 then error_id else @error_id end    
			WHERE
			agent_id = @agent_id and
			timestamp = @lastrow_timestamp

		-- Insert idle record if there is not one
		if @@ROWCOUNT = 0
			INSERT INTO dbo.MSmerge_history
			(
			agent_id, comments, error_id, timestamp, updateable_row, session_id
			)
			VALUES 
			(
			@agent_id, @comments, @error_id, NULL,@this_row_updateable, @session_id
			)
	end
	else
	begin
		INSERT INTO dbo.MSmerge_history 
		(
			agent_id, comments, error_id, timestamp, updateable_row, session_id
		)
		VALUES 
		(
			@agent_id, @comments, @error_id, NULL, @this_row_updateable, @session_id
		)
	end
	
	if @session_id_override is null
	begin
		UPDATE dbo.MSmerge_sessions SET 
			runstatus = case when runstatus in (@succeed, @retry, @failure) and @runstatus not in (@succeed, @retry, @failure) 
						and spid is not null
						then runstatus 
						else @runstatus end, 
			end_time = @current_time, duration = @duration,
			delivery_time = @delivery_time, 
			delivery_rate = ISNULL(@delivery_rate, 0.0), 
			download_inserts = @download_inserts,
			download_updates = @download_updates,
			download_deletes = @download_deletes,
			download_conflicts = @download_conflicts,
			upload_inserts = @upload_inserts,
			upload_updates = @upload_updates,
			upload_deletes = @upload_deletes,
			upload_conflicts = @upload_conflicts,
			spid_login_time = @spid_login_time,
			spid = @@spid
			WHERE session_id=@session_id
	end
	else
	begin
		UPDATE dbo.MSmerge_sessions SET 
			runstatus = case when runstatus in (@succeed, @retry, @failure) and @runstatus not in (@succeed, @retry, @failure) 
						and spid is not null
						then runstatus 
						else @runstatus end, 
			end_time = @current_time, duration = @duration,
			spid_login_time = NULL,		-- when NULL then a subsequent progress message from agent will be allowed to change failed status back to running.
			spid = NULL					-- when NULL then a subsequent progress message from agent will be allowed to change failed status back to running.
			WHERE session_id=@session_id
	end

	-- Raise the appropriate error
	if @do_raiserror = 1
	begin
		select @agentclassname = formatmessage(14554)
		exec sys.sp_MSrepl_raiserror agentclassname, @agent_name, @runstatus, @comments
	end

	IF @@ERROR <> 0
		RETURN (1)

	RETURN (0)
END
GO
GRANT EXECUTE ON [sys].[sp_MSadd_merge_history] TO [public] AS [dbo]
GO
