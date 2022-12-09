SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_dbmmonitorresults]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_dbmmonitorresults] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_dbmmonitorresults]
	@database_name [sysname],
	@mode [int],
	@update_table [int]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on
	if (is_srvrolemember(N'sysadmin') <> 1 and isnull(is_member(N'dbm_monitor'), 0) <>  1 )
    begin
		raiserror(32046, 16, 1)
		return 1
	end
	if ( db_name() != N'msdb' )
	begin
		raiserror(32045, 16, 1, N'sys.sp_dbmmonitorresults')
		return 1
	end

	if( @mode < 0 or @mode > 9 or @update_table < 0 or @update_table > 1 )
	begin
		raiserror( 32036, 16, 1 )
		return 1
	end
	--
	-- Check if the database specified exists
	--
	if not exists (select * from master.sys.databases where name = @database_name)
	begin
		raiserror(15010, 16, 1, @database_name)
		return 1
	end

	declare
		@database_id			smallint,
		@role					bit,
		@status					tinyint,
		@witness_status			tinyint,
		@log_flush_rate			bigint ,
		@send_queue_size		bigint ,
		@send_rate				bigint ,
		@redo_queue_size		bigint ,
		@redo_rate				bigint ,
		@transaction_delay		bigint ,
		@transactions_per_sec	bigint ,
		@time					datetime ,
		@end_of_log_lsn			numeric(25,0),
		@failover_lsn			numeric(25,0),
		@average_delay			int,
		@local_time				datetime

	declare
		@role2					bit,
		@status2				tinyint,
		@witness_status2		tinyint,
		@log_flush_rate2		bigint ,
		@send_queue_size2		bigint ,
		@send_rate2				bigint ,
		@redo_queue_size2		bigint ,
		@redo_rate2				bigint ,
		@transaction_delay2		bigint ,
		@transactions_per_sec2	bigint ,
		@time2					datetime ,
		@end_of_log_lsn2		numeric(25,0),
		@failover_lsn2			numeric(25,0),
		@diff_time				bigint,
		@local_time2			datetime,
		@time_update_window		datetime

	declare
		@time_behind			datetime,
		@temp_lsn				numeric(25,0),
		@time_cutoff			datetime,
		@rows_to_return			int

	declare @results table(
		database_name			sysname,	-- Name of database
		role					tinyint,	-- 1 = Principal, 2 = Mirror
		mirroring_state			tinyint,	-- 0 = Suspended, 1 = Disconnected, 2 = Synchronizing, 3 = Pending Failover, 4 = Synchronized
		witness_status			tinyint,	-- 1 = Connected, 2 = Disconnected
		log_generation_rate		int null,	-- in kb / sec
		unsent_log				int,		-- in kb
		send_rate				int null,	-- in kb / sec
		unrestored_log			int,		-- in kb
		recovery_rate			int null,	-- in kb / sec
		transaction_delay		int null,	-- in ms
		transactions_per_sec	int null,	-- in trans / sec
		average_delay			int,		-- in ms
		time_recorded			datetime,
		time_behind				datetime,
		local_time				datetime	-- Added for UI
	)

	set @database_id = DB_ID( @database_name )
	-- if we update the table anyway, the table will be created
	if (@update_table = 1)
	begin
		if( is_srvrolemember(N'sysadmin') = 1 )
		begin
			-- Check if the base table is there
			if object_id ( N'msdb.dbo.dbm_monitor_data', N'U' ) is null
			begin
				exec sys.sp_dbmmonitorupdate @database_name
			end
			else
			begin -- UI wants us to update base table, but don't do it if less than 15 seconds since last update.
				select top(1) @time_update_window = time from msdb.dbo.dbm_monitor_data
					where database_id = @database_id order by time desc
				if ( datediff( second, @time_update_window, getutcdate() ) > 15 or @time_update_window is null)
				begin
					exec sys.sp_dbmmonitorupdate @database_name		--replace(@database_name, N'''',N'''''')
				end
			end
		end
		else
		begin
			raiserror(32051, 10, 1)  -- Inform user that although asked to update the table, the user does not have rights to do it.
		end
	end

	-- Here's what we do
	-- 1. create a cursor to loop over the rows in the data table
	-- 2. get one row of data
	-- 3. while (we should loop is true)
	-- 4.	get the next row of data	might break out of the loop here.
	-- 5.	calculate differences between rates
	-- 6.	calculate the difference in "time" between the failover LSN (what the mirror has) and the end of log LSN (the latest value on the principal)
	-- 7.   insert the data into the table
	-- 8.	copy older values of data into newer values (basically we are doing step 2 here.  or putting step 4's data into the original
	--			variables since we are done with that information anyway.
	-- 9. loop to 3.

	declare mirroring_cursor cursor local
			for select
				role, status, witness_status, log_flush_rate, send_queue_size, send_rate, redo_queue_size, redo_rate, transaction_delay, transactions_per_sec, time, end_of_log_lsn, failover_lsn, local_time
			from msdb.dbo.dbm_monitor_data
			where database_id = @database_id order by time desc

		open mirroring_cursor

		fetch next from mirroring_cursor
			into @role, @status, @witness_status, @log_flush_rate, @send_queue_size, @send_rate, @redo_queue_size,
			@redo_rate,	@transaction_delay, @transactions_per_sec, @time, @end_of_log_lsn, @failover_lsn, @local_time

		set @rows_to_return = 0
		set @time_cutoff = getutcdate()
		if @mode = 0
		begin
			set @rows_to_return = 1
		end
		else if @mode = 1
		begin
			set @time_cutoff = getutcdate() - ( 2.  / 24.)
		end
		else if @mode = 2
		begin
			set @time_cutoff = getutcdate() - ( 4.  / 24.)
		end
		else if @mode = 3
		begin
			set @time_cutoff = getutcdate() - ( 8.  / 24.)
		end
		else if @mode = 4
		begin
			set @time_cutoff = getutcdate() - ( 1.)
		end
		else if @mode = 5
		begin
			set @time_cutoff = getutcdate() - ( 2.)
		end
		else if @mode = 6
		begin
			set @rows_to_return = 100
		end
		else if @mode = 7
		begin
			set @rows_to_return = 500
		end
		else if @mode = 8
		begin
			set @rows_to_return = 1000
		end
		else if @mode = 9
		begin
			set @rows_to_return = 1000000
		end

		while (@time > @time_cutoff or @rows_to_return > 0)
		begin
			if @rows_to_return > 0
				set @rows_to_return = @rows_to_return - 1

			fetch next from mirroring_cursor
				into @role2, @status2, @witness_status2, @log_flush_rate2, @send_queue_size2, @send_rate2, @redo_queue_size2,
				@redo_rate2, @transaction_delay2, @transactions_per_sec2, @time2, @end_of_log_lsn2, @failover_lsn2, @local_time2

			if( @@fetch_status <> 0 )	-- this is the fetch_status that we want to break out of the loop
				break

			set @diff_time = datediff( second, @time2, @time )
			if (@diff_time = 0)
			begin
				set @log_flush_rate = 0
				set @send_rate =      0
				set @redo_rate =      0
				set @transactions_per_sec = 0
				set @transaction_delay = 0
			end
			else if (@role != @role2)	-- if the role has changed then the rate counters are meaningless
			begin
				set @log_flush_rate = null
				set @send_rate =      null
				set @redo_rate =      null
				set @transactions_per_sec = null
				set @transaction_delay = null
			end
			else
			begin
				if (@log_flush_rate < @log_flush_rate2 )
				begin
					set @log_flush_rate = null
				end
				else
				begin
					set @log_flush_rate = (@log_flush_rate - @log_flush_rate2 ) / ( @diff_time * 1024)	-- This is in kilobytes
				end

				if (@send_rate < @send_rate2)
				begin
					set @send_rate = null
				end
				else
				begin
					set @send_rate =      (@send_rate - @send_rate2)/ ( @diff_time * 1024 )
				end

				if (@redo_rate < @redo_rate2)
				begin
					set @redo_rate = null
				end
				else
				begin
					set @redo_rate =      (@redo_rate - @redo_rate2)/ ( @diff_time * 1024 )
				end

				if (@transactions_per_sec < @transactions_per_sec2 )
				begin
					set @transactions_per_sec = null
				end
				else
				begin
					set @transactions_per_sec = (@transactions_per_sec - @transactions_per_sec2 ) / @diff_time
				end

				if (@transaction_delay < @transaction_delay2)
				begin
					set @transaction_delay = null
				end
				else
				begin
					set @transaction_delay = (@transaction_delay - @transaction_delay2 ) / @diff_time
				end
			end

			if (@transactions_per_sec = 0)
			begin
				set @average_delay = 0
			end
			else
			begin
				set @average_delay = @transaction_delay / @transactions_per_sec
			end
			-- Here we are going to match the failover lsn to time
			if ((@failover_lsn > @end_of_log_lsn) and (@end_of_log_lsn <> 0) )		-- this should never happen
			begin
				return 1
			end
			else
			begin
				if ( (@failover_lsn = @end_of_log_lsn) or (@end_of_log_lsn = 0) )	-- I've seen cases after a failover or the system just start up
				begin										-- where the failover_lsn does not catch up to the end_of_log_lsn
					set @time_behind = @time				-- until some log is generated.  we'll see how this works.
				end
				else
				begin
					select top(1) @time_behind = time from msdb.dbo.dbm_monitor_data
						where end_of_log_lsn <= @failover_lsn and database_id = @database_id order by time desc
				end
			end

			insert @results
				values (
					@database_name,
					@role + 1,
					@status,
					@witness_status,
					@log_flush_rate,
					@send_queue_size,
					@send_rate,
					@redo_queue_size,
					@redo_rate,
					@transaction_delay,
					@transactions_per_sec,
					@average_delay,
					@time,
					@time_behind,
					@local_time
				)

			set @role					= @role2
			set @status					= @status2
			set @witness_status			= @witness_status2
			set @send_queue_size		= @send_queue_size2
			set @redo_queue_size		= @redo_queue_size2
			set @end_of_log_lsn			= @end_of_log_lsn2
			set @failover_lsn			= @failover_lsn2
			set @log_flush_rate			= @log_flush_rate2
			set @send_rate				= @send_rate2
			set @redo_rate				= @redo_rate2
			set @transactions_per_sec	= @transactions_per_sec2
			set @transaction_delay		= @transaction_delay2
			set @time					= @time2
			set @local_time				= @local_time2
		end

	close mirroring_cursor
	deallocate mirroring_cursor

	select * from @results
	return 0
end
GO
GRANT EXECUTE ON [sys].[sp_dbmmonitorresults] TO [public] AS [dbo]
GO
