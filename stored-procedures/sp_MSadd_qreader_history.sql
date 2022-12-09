SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSadd_qreader_history]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSadd_qreader_history] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSadd_qreader_history]
	@agent_id [int],
	@pubid [int],
	@runstatus [int],
	@comments [nvarchar](1000),
	@transaction_id [nvarchar](40),
	@transaction_status [int],
	@transactions_processed [int],
	@commands_processed [int],
	@seconds_elapsed [int],
	@subscriber [sysname],
	@subscriberdb [sysname],
	@perfmon_increment [bit],
	@log_error [bit],
	@update_existing_row [bit],
	@do_raiserror [bit]
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @current_time datetime
			,@start_time datetime
			,@duration int
			,@agent_name nvarchar(100)
			,@publisher sysname
			,@publisher_db sysname
			,@publication sysname
			,@lastrow_timestamp timestamp
			,@retcode int
			,@cmdprocessed_rate float
			,@transaction_rate float
			,@error_id int
			,@idle int
			,@succeed int
			,@startup int
			,@retry int
			,@failure int
			,@inprogress int
			,@database sysname
			,@statobjid int
			,@agentclassname sysname
			,@prev_runstatus int


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
	-- Status const defined in sqlrepl.h 
	--
	select @startup = 1
			,@succeed = 2
			,@inprogress = 3
			,@idle = 4
			,@retry = 5
			,@failure = 6

	-- intializations
	if (@pubid = 0)
		select @pubid = NULL
	if (@comments = '')
		select @comments = NULL
	if (@transaction_id = '')
		select @transaction_id = NULL
	if (@commands_processed is NULL)
		select @commands_processed = 0
	if (@subscriber = '')
		select @subscriber = NULL
	if (@subscriberdb = '')
		select @subscriberdb = NULL		

	SELECT @database = db_name()
			,@current_time = GETDATE()

	-- Get named information
	select @agent_name = name from MSqreader_agents where id = @agent_id
	if (@agent_name IS NULL)
	begin
		--
		-- When Queue reader is shutting down due to the last queued subscription
		-- being dropped it may happen that before the Queue reader logs the shutdown 
		-- message, the subscription drop process deletes the agent entry from MSqreader_agents
		--
		select @agent_name = quotename(@@servername) + '.' + cast(db_id() as nvarchar)
	end
	if (@pubid is NULL)
	begin
		select @publisher = NULL
				,@publisher_db = NULL
				,@publication = NULL
	end
	else
	begin
		select @publisher = a.srvname, @publisher_db = b.publisher_db, @publication = b.publication
		from MSreplservers a, dbo.MSpublications b
		where
			b.publisher_id= @pubid and
			b.publisher_id = a.srvid
	end

	-- Update Perfmon counter
	if @perfmon_increment = 1
	begin
		if @runstatus = @startup
			dbcc incrementinstance ("SQL Replication Agents", "Running", "QueueReader", 1)
		else if (@runstatus = @succeed or @runstatus = @retry or @runstatus = @failure)
			dbcc incrementinstance ("SQL Replication Agents", "Running", "QueueReader", -1)
	end

	-- Get start_time for latest agent run

	SELECT TOP 1 
		@prev_runstatus = runstatus,
		@start_time = start_time, 
		@lastrow_timestamp = timestamp
	FROM MSqreader_history with (rowlock)
	WHERE 
	agent_id = @agent_id
	ORDER BY timestamp DESC

	-- If we are starting through SQL Agent - there might already be
	-- a startup logged in history
	IF (@runstatus = @startup)
	begin
		IF @prev_runstatus not IN (@startup, @retry)
		BEGIN
			SELECT @start_time = @current_time
		END
	end
	
	if (@start_time is NULL)
	begin
		select @runstatus = @startup,
			@start_time = @current_time
	end

	-- Calculate agent run duration
	SELECT @duration = DATEDIFF(second, @start_time, @current_time) 

	-- Calculate rate of processing
	IF (@seconds_elapsed IS NOT NULL and @seconds_elapsed > 0)
	BEGIN
		SELECT @cmdprocessed_rate = (@commands_processed * 1.0)/@seconds_elapsed
				,@transaction_rate = (@transactions_processed * 1.0)/@seconds_elapsed
	END
	ELSE
	BEGIN
		SELECT @cmdprocessed_rate = 0.0
				,@transaction_rate = 0.0
	END

	-- Set Perfmon counters
	if @runstatus = @idle or @runstatus = @inprogress
	begin
		dbcc addinstance ("SQL Replication QueueReader", @agent_name)
--		dbcc incrementinstance ("SQL Replication QueueReader", "QueueReader:Delivered Cmds/sec", @agent_name, @cmdprocessed_rate)
--		dbcc incrementinstance ("SQL Replication QueueReader", "QueueReader:Delivered Trans/sec", @agent_name, @transaction_rate)
	end

	--
	-- Set error id to 0 unless the user want to log errors associate with this 
	-- history message.
	--
	IF (@log_error = 1)
	begin
		select @runstatus = @failure
		EXEC sys.sp_MSget_new_errorid @error_id OUTPUT
	end
	ELSE
		SELECT @error_id = 0	
	--
	-- @comments should contain message at all times
	--
	if (@comments is null)
		select @comments = isnull(formatmessage(21020), N'Message 21020')
	-- Insert idle record or update if history record is already 'idle'
	IF (@runstatus = @idle or @update_existing_row = 1)
	begin
		-- Attempt to update the last row if it is IDLE
		UPDATE MSqreader_history 
		SET 	publication_id = @pubid,
				runstatus = @runstatus, 
				time = @current_time, 
				duration = @duration,
				comments = @comments,
				transaction_id = @transaction_id,
				transaction_status = @transaction_status,
				transactions_processed = @transactions_processed,
				commands_processed = @commands_processed,
				delivery_rate = @cmdprocessed_rate,
				transaction_rate = @transaction_rate,
				subscriber = @subscriber,
				subscriberdb = @subscriberdb,
				error_id = case @error_id when 0 then error_id else @error_id end
				WHERE
				agent_id = @agent_id and
				timestamp = @lastrow_timestamp and
				runstatus = @runstatus

		-- Insert idle record if there is not one
		if (@@ROWCOUNT = 0)
		begin
			INSERT INTO MSqreader_history(agent_id, publication_id, runstatus, start_time, time, 
					duration, comments, transaction_id, transaction_status, 
					transactions_processed, commands_processed, delivery_rate, 
					transaction_rate, subscriber, subscriberdb, error_id)
			VALUES(@agent_id, @pubid, @runstatus, @start_time, @current_time, 
					@duration, @comments, @transaction_id, @transaction_status,
					@transactions_processed, @commands_processed, @cmdprocessed_rate, 
					@transaction_rate, @subscriber, @subscriberdb, @error_id)
		end
	end
	else
	begin
		INSERT INTO MSqreader_history(agent_id, publication_id, runstatus, start_time, time, 
				duration, comments, transaction_id, transaction_status, 
				transactions_processed, commands_processed, delivery_rate,
				transaction_rate, subscriber, subscriberdb, error_id)
		VALUES(@agent_id, @pubid, @runstatus, @start_time, @current_time, 
				@duration, @comments, @transaction_id, @transaction_status, 
				@transactions_processed, @commands_processed, @cmdprocessed_rate, 
				@transaction_rate, @subscriber, @subscriberdb, @error_id)
	end

	-- Raise the appropriate error
	if (@do_raiserror = 1)
	begin
		select @agentclassname = formatmessage(14581)
		exec sys.sp_MSrepl_raiserror @agentclassname, @agent_name, @runstatus, @comments
	end

	IF (@@ERROR != 0)
		RETURN (1)
END
GO
GRANT EXECUTE ON [sys].[sp_MSadd_qreader_history] TO [public] AS [dbo]
GO
