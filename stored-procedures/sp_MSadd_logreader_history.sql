SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSadd_logreader_history]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSadd_logreader_history] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSadd_logreader_history]
	@agent_id [int],
	@runstatus [int],
	@comments [nvarchar](4000),
	@xact_seqno [varbinary](16),
	@delivery_time [int],
	@delivered_transactions [int],
	@delivered_commands [int],
	@delivery_latency [int],
	@log_error [bit],
	@perfmon_increment [bit],
	@update_existing_row [bit],
	@do_raiserror [bit],
	@updateable_row [bit]
WITH EXECUTE AS CALLER
AS
BEGIN
	set nocount on 
	DECLARE @current_time datetime
			,@start_time datetime
			,@duration int
			,@average_commands int
			,@delivery_rate float
			,@error_id int
			,@retcode int
			,@idle int
			,@succeed int
			,@startup int
			,@retry int
			,@inprogress int
			,@failure int
			,@lastrow_timestamp timestamp
			,@publisher sysname
			,@publisher_db sysname
			,@publication sysname
			,@agent_name nvarchar(100)
			,@last_delivered_commands int
			,@last_delivered_transactions int
			,@latest_delivered_commands int
			,@latest_delivered_transactions int
			,@latest_delivery_rate float
			,@last_delivery_rate float             -- was declare as int for perfmon,but never used in perfmon, change back to float to eb consistant with other rates
			,@last_delivery_latency int
			,@last_delivery_time int
			,@avg_delivery_rate float
			,@avg_delivery_latency int
			,@total_delivery_time int
			,@agentclassname sysname
			,@last_xact_seqno varbinary(16)
			,@prev_runstatus int
			,@prev_start_time datetime
			,@existing_row_updateble bit
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

	--
	-- security check
	-- Has to be executed from distribution database
	--
	if (sys.fn_MSrepl_isdistdb (db_name()) != 1)
	begin
		raiserror(21482, 16, -1, 'sp_MSadd_logreader_history', 'distribution')
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

	-- Update Perfmon counter
	if @perfmon_increment = 1
	begin
		if @runstatus = @startup
			dbcc incrementinstance ("SQL Replication Agents", "Running", "Logreader", 1)
		else if (@runstatus = @succeed or @runstatus = @retry or @runstatus = @failure)
			dbcc incrementinstance ("SQL Replication Agents", "Running", "Logreader", -1)
	end

	-- The initial values provided below are needed for the first entry for the agent that
	-- appears in MSlogreader_history.  Normally, this occurs when the initialization message
	-- is logged (@runstatus = 1).  It can also occur when an error message is logged before
	-- the startup message is written. For message subsequent to the first message, these
	-- values are overwritten.

	SELECT @start_time = @current_time
	SET @last_delivered_commands = 0
	SET @last_delivered_transactions = 0
	SET @last_delivery_latency = 0
	SET @last_delivery_time = 0
	SET @last_delivery_rate = 0
	SET @last_delivery_latency = 0

		if(@update_existing_row = 1 and substring(@comments, 1, 7) = N'<stats ')
		set @update_existing_row = 0


	/* Get start_time for latest agent run */
	select @agent_name = N'DEFAULTAGENT'
	select @agent_name = isnull(name, N'DEFAULTAGENT') from MSlogreader_agents where id = @agent_id
	IF @runstatus <> 1  -- Startup status
	BEGIN
		SELECT TOP 1 @start_time = start_time, 
			@lastrow_timestamp = timestamp, 
			@last_delivered_commands = isnull(delivered_commands, 0),
			@last_delivered_transactions = isnull(delivered_transactions, 0),
			@last_delivery_latency = isnull(delivery_latency, 0),
			@last_delivery_time = isnull(delivery_time, 0),
			@last_delivery_rate = isnull(delivery_rate, 0),
			@last_xact_seqno = xact_seqno
			,@existing_row_updateble = updateable_row
		FROM MSlogreader_history with (rowlock)
			WHERE agent_id = @agent_id
				and comments not like N'<stats state%'
				ORDER BY timestamp DESC
	END
	ELSE
	BEGIN
		SELECT TOP 1 
			@prev_runstatus = runstatus,
			@prev_start_time = start_time,
			@last_xact_seqno = xact_seqno,
			@last_delivery_latency = isnull(delivery_latency, 0)
		   ,@existing_row_updateble = updateable_row
		FROM MSlogreader_history with (rowlock)
			WHERE agent_id = @agent_id
			ORDER BY timestamp  DESC

		IF @prev_runstatus IN (@startup, @retry)
		BEGIN
			SELECT @start_time = @prev_start_time
		END

		-- New logreader message "Validating publisher" has runstatus = 1
		-- and precedes message "Initializing". Only the first of these startup
		-- messages should set startup for Perfmon counters.
		IF @prev_runstatus != @startup
		BEGIN
			-- Set Startup Perfmon counters
			dbcc addinstance ("SQL Replication Logreader", @agent_name)
			dbcc setinstance ("SQL Replication Logreader", "Logreader:Delivery Latency", @agent_name, @last_delivery_latency )
		END
	END

	/* Use the current time if no corresponding start_up message logged */
	IF @start_time is NULL
	   SELECT @start_time = @current_time

	-- Calculate number of transactions in this history
	set @latest_delivered_commands = @delivered_commands - @last_delivered_commands

	-- Calculate number of commands in this history
	set @latest_delivered_transactions = @delivered_transactions - @last_delivered_transactions

	/* Calculate agent run duration */
	SELECT @duration = DATEDIFF(second, @start_time, @current_time) 

	-- Calculate total delivery_time 
	if @latest_delivered_commands <> 0      -- Work around for Logreader passing in @delivery_time on shutdown.
		SELECT @total_delivery_time = @delivery_time + @last_delivery_time
	else
		SELECT @total_delivery_time = @last_delivery_time

	-- Calculate average delivery_rate of the session
	IF @latest_delivered_commands <> 0 and @total_delivery_time <> 0
	BEGIN
		SELECT @avg_delivery_rate = (@delivered_commands * 1.0)/(@total_delivery_time/1000.0)

		-- Current history delivery rate
		if @delivery_time <> 0
			SELECT @latest_delivery_rate = (@latest_delivered_commands * 1.0)/(@delivery_time/1000.0)
		else 
			SELECT @latest_delivery_rate = 0
	END
	ELSE
	BEGIN
		SELECT @avg_delivery_rate = @last_delivery_rate
		SELECT @latest_delivery_rate = 0
	END

	-- Calculate the average delivery_latency of the session
	if @latest_delivered_commands <> 0      -- Work around for Logreader passing in @delivery_latency on shutdown.
	BEGIN
		IF @delivery_latency <> 0
			IF @last_delivery_latency <> 0
				SELECT @avg_delivery_latency = (@delivery_latency + @last_delivery_latency)/2
			ElSE
				SELECT @avg_delivery_latency = @delivery_latency
		ELSE
			SELECT @avg_delivery_latency = 0
	END
	ELSE
	BEGIN
		SELECT @avg_delivery_latency = @last_delivery_latency

		-- Ignore latency value if no commands
		SELECT @delivery_latency = 0    
	END

	/*
	** Calculate average number of commands per transaction
	*/
	IF @delivered_commands <> 0
	   SELECT @average_commands = @delivered_commands/@delivered_transactions
	ELSE

	   SELECT @average_commands = 0

	-- set xact_seqno to last value if not already set
	if (@xact_seqno = 0x or @xact_seqno is NULL) and @last_xact_seqno is not null
	begin
		select @xact_seqno = @last_xact_seqno
	end
	
	-- Set Perfmon counters
	-- Note that Startup perfmon counters are set above
	if @runstatus = @idle or @runstatus = @inprogress
	begin
		dbcc addinstance ("SQL Replication Logreader", @agent_name)
		dbcc incrementinstance ("SQL Replication Logreader", "Logreader:Delivered Trans/sec", @agent_name, @latest_delivered_transactions)
		dbcc incrementinstance ("SQL Replication Logreader", "Logreader:Delivered Cmds/sec", @agent_name, @latest_delivered_commands)
		dbcc setinstance ("SQL Replication Logreader", "Logreader:Delivery Latency", @agent_name, @delivery_latency)
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
	IF ((@existing_row_updateble = 1 ) and (@runstatus = @idle or @update_existing_row = 1))
	begin
		-- Attempt to update the last row if it is IDLE
		if (@runstatus = @idle)
		begin
			UPDATE MSlogreader_history SET runstatus = @runstatus, time = @current_time,
			duration = @duration,comments = @comments,
			error_id = case @error_id when 0 then error_id else @error_id end
			,updateable_row = @updateable_row
			WHERE
			agent_id = @agent_id and
			timestamp = @lastrow_timestamp and
			( runstatus = @runstatus or 
			(@update_existing_row = 1 and runstatus in (@idle, @inprogress) and @runstatus in (@idle, @inprogress)) )
		end
		else
		begin
			UPDATE MSlogreader_history SET runstatus = @runstatus, start_time = @start_time, 
			time = @current_time,
			duration = @duration, comments = @comments,
			xact_seqno = @xact_seqno,
			delivery_time = @total_delivery_time,
			delivered_transactions = @delivered_transactions,
			delivered_commands = @delivered_commands,
			average_commands = @average_commands,
			delivery_rate = @avg_delivery_rate,
			delivery_latency = @avg_delivery_latency,
			error_id = case @error_id when 0 then error_id else @error_id end
			,updateable_row = @updateable_row
			WHERE
			agent_id = @agent_id and
			timestamp = @lastrow_timestamp and
			( runstatus = @runstatus or 
			(@update_existing_row = 1 and runstatus in (@idle, @inprogress) and @runstatus in (@idle, @inprogress)) )
		end

		-- Insert idle record if there is not one
		if @@ROWCOUNT = 0
		begin
			-- Use last values because nothing was done
			INSERT INTO MSlogreader_history VALUES (@agent_id, @runstatus, @start_time, @current_time, 
				@duration, @comments,  
				@xact_seqno, @total_delivery_time, @delivered_transactions, @delivered_commands,
				@average_commands, @avg_delivery_rate, @avg_delivery_latency, @error_id, NULL, @updateable_row)
		end
	end
	else
	begin
		INSERT INTO MSlogreader_history VALUES (@agent_id, @runstatus, @start_time, @current_time, 
			@duration, @comments, 
			@xact_seqno, @total_delivery_time, @delivered_transactions, @delivered_commands,
			@average_commands, @avg_delivery_rate, @avg_delivery_latency, @error_id, NULL, @updateable_row)
	end

	-- Get named information 
	select @publisher = srvname, @publisher_db = publisher_db, @publication = publication, @publisher_id = publisher_id,
		@agent_name = isnull(name, N'DEFAULTAGENT') from MSreplservers, MSlogreader_agents where
		id = @agent_id and
		publisher_id = srvid

	select @db_id = db_id(), @publication_id = publication_id
		from dbo.MSpublications where publication = @publication and publisher_id = @publisher_id and publisher_db = @publisher_db

	exec sys.sp_repl_generate_agent_status_event
		@event = N'repl_logreader_status',
		@agent_id = @agent_id,
		@publication_id = @publication_id,
		@db_id = @db_id,
		@runstatus = @runstatus,
		@start_time = @start_time,
		@time = @current_time,
		@duration = @duration,
		@delivered_transactions = @delivered_transactions,
		@delivered_commands = @delivered_commands,
		@average_commands = @average_commands,
		@delivery_rate = @avg_delivery_rate,
		@delivery_time = @total_delivery_time,
		@delivery_latency = @avg_delivery_latency,
		@error_id = @error_id,
		@comments = @comments

 	-- Raise the appropriate error
	if @do_raiserror = 1
	begin
		select @agentclassname = formatmessage(14552)

		-- Only use the first 255 characters of the comment
		select @comments = left(@comments, 255)

		exec sys.sp_MSrepl_raiserror @agentclassname, @agent_name, @runstatus, @comments
	end

	IF @@ERROR <> 0
	BEGIN
	   RETURN (1)
	END
END
GO
GRANT EXECUTE ON [sys].[sp_MSadd_logreader_history] TO [public] AS [dbo]
GO
