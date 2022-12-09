SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSadd_distribution_history]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSadd_distribution_history] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSadd_distribution_history]
	@agent_id [int],
	@runstatus [int],
	@comments [nvarchar](max),
	@xact_seqno [binary](16),
	@delivered_transactions [int],
	@delivered_commands [int],
	@delivery_rate [float],
	@log_error [bit],
	@perfmon_increment [bit],
	@xactseq [varbinary](16),
	@command_id [int],
	@update_existing_row [bit],
	@updateable_row [bit],
	@do_raiserror [bit]
WITH EXECUTE AS CALLER
AS
BEGIN

	set nocount on

	DECLARE @current_time datetime
			,@start_time datetime
			,@entry_time datetime
			,@duration int                   -- milliseconds
			,@delivery_latency int
			,@average_commands int
			,@total_cmds bigint
			,@publisher_id smallint
			,@publisher_db sysname
			,@publication sysname
			,@publisher sysname
			,@subscriber_id smallint
			,@subscriber sysname
			,@subscriber_db sysname
			,@article sysname
			,@article_id int
			,@publication_id int
			,@publisher_database_id int

			,@agent_name nvarchar(100)
			,@error_id int 
			,@startup int
			,@succeed int
			,@inprogress int
			,@retry int
			,@failure int
			,@validation_failure int
			,@validation_success int, @error_skipped int
			,@requested_shutdown int
			,@raiserror_status int
			,@idle int
			,@lastrow_timestamp timestamp
			,@lastrow_xact_seqno binary(16)
			,@new_delivered_commands int
			,@new_delivered_transactions int
			,@retcode int
			,@last_delivery_rate float
			,@last_delivery_latency int
			,@avg_delivery_rate float
			,@avg_delivery_latency int
			,@perfmon_delivery_rate int
			,@existing_row_updateble bit
			,@this_row_updateable bit
			,@agentclassname sysname
			,@MAXINT bigint
			,@prev_runstatus int
			,@prev_start_time datetime

			,@db_id int
			
	--
	-- PAL Security Check
	--
	exec @retcode = sys.sp_MScheck_pull_access
		@agent_id = @agent_id,
		@agent_type = 0 -- distribution agent
	if @@error <> 0 or @retcode <> 0
		return (1)
	/* 
	** Status const defined in sqlrepl.h 
	*/
	select @startup = 1
			,@succeed = 2
			,@inprogress = 3
			,@idle = 4
			,@retry = 5
			,@failure = 6
			,@validation_failure = 7
			,@validation_success = 8
			,@requested_shutdown = 9
			,@error_skipped = 10
			,@MAXINT = 9223372036854775807

	-- To prevent cleanup up being messed up by invalid history message, only log
	-- valid history message. 
	if @runstatus > 10 or @runstatus < 0
	begin
		--Invalid history message logged
		RAISERROR (21079, 16, -1, @runstatus)
		return (1)
	end

	if(@update_existing_row = 1 and substring(@comments, 1, 7) = N'<stats ')
		set @update_existing_row = 0

	select @existing_row_updateble = 1
	select @this_row_updateable = 1

	select @raiserror_status = @runstatus
	if (@runstatus = @validation_failure or @runstatus = @validation_success 
		or @runstatus = @requested_shutdown or @runstatus = @error_skipped)
	begin
		select @runstatus = @inprogress
		select @this_row_updateable = 0
	end

	if (@updateable_row = 0)
	begin
		select @this_row_updateable = 0
	end
	
	SELECT @current_time = GETDATE()

	-- Update Perfmon counter
	if @perfmon_increment = 1
	begin
		if @runstatus = @startup
			dbcc incrementinstance ("SQL Replication Agents", "Running", "Distribution", 1)
		else if (@runstatus = @succeed or @runstatus = @retry or @runstatus = @failure)
			dbcc incrementinstance ("SQL Replication Agents", "Running", "Distribution", -1)
	end

    -- Get agent name, publisher id and publisher_db
    select @agent_name = name, 
        @publisher_database_id = publisher_database_id,
        @publisher_id = publisher_id, @publisher_db = publisher_db,
        @publication =  publication, @subscriber_id = subscriber_id, @subscriber_db = subscriber_db
        from MSdistribution_agents
        where id = @agent_id
    select @publisher = srvname from MSreplservers where srvid = @publisher_id
    select @subscriber = srvname from MSreplservers where srvid = @subscriber_id

	/* Get start_time and xact_seqno for latest agent run */
	IF @runstatus <> 1   
	BEGIN
		  
		SELECT TOP 1 
			@lastrow_xact_seqno = xact_seqno,
			@start_time = start_time, 
			@total_cmds = total_delivered_commands,
			@lastrow_timestamp = timestamp, 
			@new_delivered_transactions = @delivered_transactions - delivered_transactions,
			@new_delivered_commands = @delivered_commands - delivered_commands,
			@last_delivery_rate = delivery_rate,
			@last_delivery_latency = delivery_latency,
			@existing_row_updateble = updateable_row
		FROM MSdistribution_history with (rowlock)
			WHERE agent_id = @agent_id 
				and comments not like N'<stats state%'
			ORDER BY timestamp  DESC
			
		/* 
		** Check the case where the user did not pass in the proper values
		** for delivered commands and transactions (this leads to negative
		** new command/tran counts).
		*/
		if ( @new_delivered_commands < 0 )
			SELECT @new_delivered_commands = 0

		if ( @new_delivered_transactions < 0 )
			SELECT @new_delivered_transactions = 0
	END
	ELSE
	BEGIN
		-- At least get running total of commands over all sessions.
		SELECT TOP 1 
			@prev_runstatus = runstatus,
			@prev_start_time = start_time,
			@lastrow_xact_seqno = xact_seqno,
			@total_cmds = total_delivered_commands,
			@last_delivery_latency = delivery_latency
			FROM MSdistribution_history with (rowlock)
			WHERE agent_id = @agent_id
			ORDER BY timestamp  DESC

		set @last_delivery_latency = isnull(@last_delivery_latency, 0)
		-- Set Startup Perfmon counters
		dbcc addinstance ("SQL Replication Distribution", @agent_name)
		dbcc setinstance ("SQL Replication Distribution", "Dist:Delivery Latency", @agent_name, @last_delivery_latency)

		IF @prev_runstatus IN (@startup, @retry)
		BEGIN
			SELECT @start_time = @prev_start_time
		END
		ELSE
		BEGIN
			SELECT @start_time = @current_time
		END
		SELECT @new_delivered_commands = @delivered_commands
		SELECT @new_delivered_transactions = @delivered_transactions
		SELECT @last_delivery_rate = 0
		SELECT @last_delivery_latency = 0
	END

	IF @total_cmds IS NULL
		SELECT @total_cmds = 0

	if @new_delivered_commands IS NULL
		SELECT @new_delivered_commands = 0

	if @new_delivered_transactions IS NULL
		SELECT @new_delivered_transactions = 0

	/* Use the current time if no corresponding start_up message logged */
	IF @start_time is NULL
	   SELECT @start_time = @current_time

	/* Calculate agent run duration */
	SELECT @duration = DATEDIFF(second, @start_time, @current_time) 
	
   IF @delivered_commands <> 0 and @delivered_transactions <> 0
	   SELECT @average_commands = @delivered_commands/@delivered_transactions
	ELSE
	   SELECT @average_commands = 0

	-- Get the entry time of the last distributed transaction
	if @xact_seqno <> 0x00 and @new_delivered_commands <> 0
		-- SELECT @entry_time = entry_time FROM MSrepl_transactions with (READPAST)
		SELECT @entry_time = entry_time FROM MSrepl_transactions with (nolock)
		   WHERE xact_seqno = @xact_seqno and
				publisher_database_id = @publisher_database_id

	-- Calculate the latency of the last distributed transaction
	IF @entry_time IS NOT NULL
	begin
	   -- Calculte diff in minutes.
	   declare @diff_min int
	   select @diff_min = DATEDIFF(minute, @entry_time, @current_time)
	   if @diff_min > 16666
			select @delivery_latency = 999999999
	   else 
			select @delivery_latency = DATEDIFF(millisecond, @entry_time, @current_time)
	end
	ELSE
	   SELECT @delivery_latency = 0

	-- Calculate the average delivery latency of the session
	IF @last_delivery_latency = 0 or @last_delivery_latency is null
		SET @avg_delivery_latency = @delivery_latency
	ELSE IF @delivery_latency = 0
		SET @avg_delivery_latency = @last_delivery_latency
	ELSE
		SET @avg_delivery_latency = (@delivery_latency + @last_delivery_latency)/2

	--at the end of snapshot, set delivery_latency to 0 so that monitor does not raise false alarm
	if @runstatus = @succeed
	begin 
		if substring(@comments, 1, 20) = N'Applied the snapshot'
		begin
		   SELECT @delivery_latency = 0, @avg_delivery_latency = 0
		end 
	end    

	-- Calculate average delivery rate of the session
	IF @last_delivery_rate = 0 or @last_delivery_rate is null
		SET @avg_delivery_rate = @delivery_rate
	ELSE IF @delivery_rate = 0 or @new_delivered_commands = 0
		SET @avg_delivery_rate = @last_delivery_rate
	ELSE
		SET @avg_delivery_rate = (@delivery_rate + @last_delivery_rate)/2.0     

	/* Calculate grand total of delivered trans across sessions, check
	** to make sure the result does not overflow integer column  
	*/
	if (@total_cmds > @MAXINT  - @new_delivered_commands)
		SET @total_cmds = @MAXINT
	else
		SET @total_cmds = @total_cmds + @new_delivered_commands

	-- Set Perfmon counters
	-- Note that Startup perfmon counters are set above
	--now that we may write in-prograss msg with 0 cmds 0 trans for informational purpose
	--, no need to write those to perfmon
	if @runstatus = @idle or (@runstatus = @inprogress and @new_delivered_transactions > 0 and @new_delivered_commands > 0)
	begin
		dbcc addinstance ("SQL Replication Distribution", @agent_name)
		dbcc incrementinstance ("SQL Replication Distribution", "Dist:Delivered Trans/sec", @agent_name, @new_delivered_transactions)
		dbcc incrementinstance ("SQL Replication Distribution", "Dist:Delivered Cmds/sec", @agent_name, @new_delivered_commands)
		dbcc setinstance ("SQL Replication Distribution", "Dist:Delivery Latency", @agent_name, @delivery_latency)
	end

	/* 
	** Set error id to 0 unless the user want to log errors associate with this 
	** history message.
	*/
	SELECT @error_id = 0
	IF @log_error = 1
		-- Ignore errors here. @error_id will be set to 0 in case of errors  
		EXEC sys.sp_MSget_new_errorid @error_id OUTPUT, @xactseq, @command_id
	
	-- @xact_seqno may be uninitialized for the first several messages after
	-- the start-up of the distribtion agent. Get the correct value in that case. 
	-- We must do this because distribution cleanup will use the lastest xact_seqno
	-- as cleanup boundary.
	-- Note: @last_xact_seqno might be NULL
	-- Only do this if @xact_seqno is 0, since a smaller xact_seqno might be logged due
	-- to reinited sub for immediate_sync pub.
	-- This will prevent history being messed up by one gabage history entry.
	if @xact_seqno = 0x00 and @lastrow_xact_seqno is not null
		select @xact_seqno = @lastrow_xact_seqno 

	-- Insert idle record or update if history record is already 'idle'
	IF (@existing_row_updateble = 1) and (@runstatus = @idle or @update_existing_row = 1)
	begin

		-- Attempt to update the last row if it is IDLE
		if (@runstatus = @idle)
		begin
			UPDATE MSdistribution_history SET runstatus = @runstatus, time = @current_time,
			duration = @duration, comments = @comments,
			xact_seqno = @xact_seqno, updateable_row = @this_row_updateable,
			error_id = case @error_id when 0 then error_id else @error_id end
			WHERE
			agent_id = @agent_id and
			timestamp = @lastrow_timestamp and
			( runstatus = @runstatus or 
			(@update_existing_row = 1 and runstatus in (@idle, @inprogress) and @runstatus in (@idle, @inprogress)) )
		end
		else
		begin
			-- Attempt to update the last row if it is IDLE
			UPDATE MSdistribution_history SET runstatus = @runstatus, start_time = @start_time,
				time = @current_time,
				duration = @duration,
				xact_seqno = @xact_seqno,
				comments = @comments,
				delivered_transactions = @delivered_transactions,
				delivered_commands = @delivered_commands,
				average_commands = @average_commands,
				delivery_rate = @avg_delivery_rate,
				delivery_latency = @avg_delivery_latency,
				total_delivered_commands = @total_cmds,
				current_delivery_rate = @delivery_rate,
				current_delivery_latency = @delivery_latency,
				updateable_row = @this_row_updateable,
				error_id = case @error_id when 0 then error_id else @error_id end
				WHERE
				agent_id = @agent_id and
				timestamp = @lastrow_timestamp and
				( runstatus = @runstatus or 
				(@update_existing_row = 1 and runstatus in (@idle, @inprogress) and @runstatus in (@idle, @inprogress)) )
		end
	
		-- Insert idle record if there is not one
		if @@ROWCOUNT = 0
		begin
			INSERT INTO MSdistribution_history (agent_id, runstatus, start_time, time, duration, comments, xact_seqno,
				delivered_transactions, delivered_commands, average_commands, delivery_rate, delivery_latency,
				total_delivered_commands, error_id, timestamp, current_delivery_rate, current_delivery_latency, updateable_row)
			VALUES (@agent_id, @runstatus, @start_time, @current_time, 
				@duration, @comments, @xact_seqno, @delivered_transactions, 
				@delivered_commands, @average_commands, @avg_delivery_rate,
				@avg_delivery_latency, @total_cmds, @error_id, NULL, @delivery_rate, @delivery_latency, @this_row_updateable)
		end
	end
	else
	begin
		INSERT INTO MSdistribution_history (agent_id, runstatus, start_time, time, duration, comments, xact_seqno,
				delivered_transactions, delivered_commands, average_commands, delivery_rate, delivery_latency,
				total_delivered_commands, error_id, timestamp, current_delivery_rate, current_delivery_latency, updateable_row)
		VALUES (@agent_id, @runstatus, @start_time, @current_time, 
			@duration, @comments, @xact_seqno, @delivered_transactions, 
			@delivered_commands, @average_commands, @avg_delivery_rate,
			@avg_delivery_latency, @total_cmds, @error_id, NULL, @delivery_rate, @delivery_latency, @this_row_updateable)
	end

	if (@raiserror_status = @validation_failure or @raiserror_status = @validation_success or
		@raiserror_status = @error_skipped)
	begin
		-- Get the "real" publication name (as opposed to 'ALL') and article name
		select @article_id = article_id from MSrepl_commands with (nolock)
		where publisher_database_id = @publisher_database_id
		and xact_seqno = @xactseq
		and command_id = @command_id
	
		select @publication = mp.publication, @publication_id = mp.publication_id
		from dbo.MSpublications as mp, dbo.MSsubscriptions as ms
		where mp.publisher_id = ms.publisher_id
		and mp.publisher_db = ms.publisher_db
		and mp.publication_id = ms.publication_id
		and ms.publisher_id = @publisher_id
		and ms.publisher_db = @publisher_db
		and ms.subscriber_id = @subscriber_id
		and ms.subscriber_db = @subscriber_db
		and ms.article_id = @article_id

		select @article = article
		from MSarticles
		where article_id = @article_id
		and publisher_id = @publisher_id
		and publisher_db = @publisher_db
		and publication_id = @publication_id
	end
	else
	begin
		-- populate required details for event generation
		select @publication_id = publication_id
			from dbo.MSpublications where publication = @publication and publisher_id = @publisher_id and publisher_db = @publisher_db
	end

	select @db_id = db_id()

	exec sys.sp_repl_generate_agent_status_event
		@event = N'repl_distribution_status',
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
		@delivery_rate = @delivery_rate,
		@delivery_latency = @delivery_latency,
		@average_delivery_rate = @avg_delivery_rate,
		@average_delivery_latency = @avg_delivery_latency,
		@total_delivered_commands = @total_cmds,
		@error_id = @error_id,
		@comments = @comments

	-- Raise the appropriate error
	if @do_raiserror = 1
	begin
		select @agentclassname = formatmessage(14553)

		-- only use the first 255 chars
		select @comments = left(@comments, 255)
		
		exec sys.sp_MSrepl_raiserror @agentclassname, @agent_name, @raiserror_status, @comments, @subscriber=@subscriber, @publication=@publication, @article=@article
	end
	
	IF @@ERROR <> 0
	   RETURN (1)
END
GO
GRANT EXECUTE ON [sys].[sp_MSadd_distribution_history] TO [public] AS [dbo]
GO
