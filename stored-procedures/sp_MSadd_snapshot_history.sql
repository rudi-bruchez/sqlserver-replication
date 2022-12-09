SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSadd_snapshot_history]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSadd_snapshot_history] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSadd_snapshot_history]
	@agent_id [int],
	@runstatus [int],
	@comments [nvarchar](1000),
	@delivered_transactions [int],
	@delivered_commands [int],
	@log_error [bit],
	@perfmon_increment [bit],
	@update_existing_row [bit],
	@do_raiserror [bit],
	@start_time_string [nvarchar](25),
	@duration [int]
WITH EXECUTE AS CALLER
AS
BEGIN

	DECLARE @current_time datetime
			,@start_time datetime
			,@delivery_rate float
			,@error_id int
			,@retcode int
			,@idle int
			,@succeed int
			,@startup int
			,@retry int
			,@failure int
			,@inprogress int
			,@lastrow_timestamp timestamp
			,@publisher sysname
			,@publisher_db sysname
			,@publication sysname
			,@agent_name nvarchar(100)
			,@perfmon_delivery_rate int
			,@agentclassname sysname
			,@publisher_id int
			,@publication_id int
			,@db_id int

	--
	-- security check
	-- only db_owner can execute this
	--
	if (is_member ('db_owner') != 1) 
	begin
		raiserror(14260, 16, -1)
		return (1)
	end
	/* 
	** Status const defined in sqlrepl.h 
	*/
	select @startup = 1
			,@succeed = 2
			,@inprogress = 3
			,@idle = 4
			,@retry = 5
			,@failure = 6
			,@current_time = GETDATE()

	-- Get named information 
	select @publisher = srvname, @publisher_db = publisher_db, @publication = publication, @publisher_id = publisher_id,
		@agent_name = name from MSreplservers, MSsnapshot_agents where
		id = @agent_id and
		publisher_id = srvid

	-- Update Perfmon counter
	if @perfmon_increment = 1
	begin
		if @runstatus = @startup
			dbcc incrementinstance ("SQL Replication Agents", "Running", "Snapshot", 1)
		else if (@runstatus = @succeed or @runstatus = @retry or @runstatus = @failure)
			dbcc incrementinstance ("SQL Replication Agents", "Running", "Snapshot", -1)
	end

	/* Get start_time for latest agent run */
	IF @runstatus <> 1  -- Start status
	BEGIN
		IF @start_time_string IS NULL OR @start_time_string = N''
		BEGIN
			SELECT TOP 1 @start_time = start_time, 
					@lastrow_timestamp = timestamp
				FROM MSsnapshot_history with (rowlock)
				WHERE agent_id = @agent_id
				ORDER BY timestamp DESC
		END
		ELSE
		BEGIN
			SELECT @start_time = @start_time_string
			SELECT TOP 1 @lastrow_timestamp = timestamp
			  FROM MSsnapshot_history with (rowlock)
			 WHERE agent_id = @agent_id
			ORDER BY timestamp DESC
		END
	END
	ELSE
	BEGIN
		WAITFOR DELAY '000:00:01'
		SELECT @current_time = DATEADD(ms, CONVERT(INT, 1000.0 * (RAND(@@spid) + RAND() + RAND())/3.0), @current_time)
		SELECT @start_time = @current_time
	END
	/* Calculate agent run duration if an explicit duration is not specified 
	   by the snapshot agent */

	IF @start_time is NULL or @start_time = N''
	BEGIN
		select @start_time = getdate()
	END
	
	IF @duration IS NULL
	BEGIN
		SELECT @duration = DATEDIFF(second, @start_time, @current_time) 
	END

	/* Calculate delivery_rate */
	IF @duration <> 0 
	   SELECT @delivery_rate = (@delivered_commands * 1.0)/@duration 
	ELSE
	   SELECT @delivery_rate = 0

	-- Set Perfmon counters
	if @runstatus = @idle or @runstatus = @inprogress
	begin
		dbcc addinstance ("SQL Replication Snapshot", @agent_name)
		dbcc incrementinstance ("SQL Replication Snapshot", "Snapshot:Delivered Cmds/sec", @agent_name, @delivered_commands)
		dbcc incrementinstance ("SQL Replication Snapshot", "Snapshot:Delivered Trans/sec", @agent_name, @delivered_transactions)
	end

	/* 
	** Set error id to 0 unless the user want to log errors associate with this 
	** history message.
	*/
	SELECT @error_id = 0
	IF @log_error = 1
		-- Ignore errors here. @error_id will be set to 0 in case of errors  
		EXEC sys.sp_MSget_new_errorid @error_id OUTPUT

	-- Insert idle record or update if history record is already 'idle'
	IF @runstatus = @idle or @update_existing_row = 1
	begin
		-- Attempt to update the last row if it is IDLE
		UPDATE MSsnapshot_history SET runstatus = @runstatus, time = @current_time, duration = @duration,
			comments = @comments,
			delivered_transactions = @delivered_transactions,
			delivered_commands = @delivered_commands,
			delivery_rate = @delivery_rate,
			error_id = case @error_id when 0 then error_id else @error_id end    
			WHERE
			agent_id = @agent_id and
			timestamp = @lastrow_timestamp and
			runstatus = @runstatus

		-- Insert idle record if there is not one
		if @@ROWCOUNT = 0
		begin
			INSERT INTO MSsnapshot_history VALUES (@agent_id, @runstatus, @start_time, 
			@current_time, @duration, @comments, @delivered_transactions, @delivered_commands, 
			@delivery_rate, @error_id, NULL)
		end
	end
	else
	begin
		INSERT INTO MSsnapshot_history VALUES (@agent_id, @runstatus, @start_time, 
			@current_time, @duration, @comments, @delivered_transactions, @delivered_commands, 
			@delivery_rate, @error_id, NULL)
	end
   
	select @db_id = db_id(), @publication_id = publication_id
		from dbo.MSpublications where publication = @publication and publisher_id = @publisher_id and publisher_db = @publisher_db

	exec sys.sp_repl_generate_agent_status_event
		@event = N'repl_snapshot_status',
		@agent_id = @agent_id,
		@publication_id = @publication_id,
		@db_id = @db_id,
		@runstatus = @runstatus,
		@start_time = @start_time,
		@time = @current_time,
		@duration = @duration,
		@delivered_transactions = @delivered_transactions,
		@delivered_commands = @delivered_commands,
		@delivery_rate = @delivery_rate,
		@error_id = @error_id,
		@comments = @comments

	-- Raise the appropriate error
	if @do_raiserror = 1
	begin
		select @agentclassname = formatmessage(14551)
		exec sys.sp_MSrepl_raiserror @agentclassname, @agent_name, @runstatus, @comments
	end

	IF @@ERROR <> 0
	   RETURN (1)

	if @runstatus = 1
	begin
		select 'start_time' = sys.fn_replformatdatetime(@start_time)
	end
END
GO
GRANT EXECUTE ON [sys].[sp_MSadd_snapshot_history] TO [public] AS [dbo]
GO
