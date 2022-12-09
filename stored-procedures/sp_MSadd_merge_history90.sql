SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSadd_merge_history90]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSadd_merge_history90] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSadd_merge_history90]
	@session_id [int] OUTPUT,
	@agent_id [int],
	@runstatus [int],
	@comments [nvarchar](1000),
	@update_existing_row [bit],
	@updateable_row [bit],
	@log_error [bit],
	@update_stats [bit],
	@phase_id [int],
	@article_name [sysname],
	@article_inserts [int],
	@article_updates [int],
	@article_deletes [int],
	@article_conflicts [int],
	@article_rows_retried [int],
	@article_percent_complete [decimal](5, 2),
	@article_estimated_changes [int],
	@article_relative_cost [decimal](12, 2),
	@session_duration [int],
	@delivery_time [int],
	@upload_time [int],
	@download_time [int],
	@schema_change_time [int],
	@prepare_snapshot_time [int],
	@delivery_rate [decimal](12, 2),
	@time_remaining [int],
	@session_percent_complete [decimal](5, 2),
	@session_upload_inserts [int],
	@session_upload_updates [int],
	@session_upload_deletes [int],
	@session_upload_conflicts [int],
	@session_upload_rows_retried [int],
	@session_download_inserts [int],
	@session_download_updates [int],
	@session_download_deletes [int],
	@session_download_conflicts [int],
	@session_download_rows_retried [int],
	@session_schema_changes [int],
	@session_bulk_inserts [int],
	@session_metadata_rows_cleanedup [int],
	@session_estimated_upload_changes [int],
	@session_estimated_download_changes [int],
	@connection_type [int],
	@subid [uniqueidentifier],
	@info_filter [int]
WITH EXECUTE AS CALLER
AS
begin

	declare @retcode int
			,@current_date datetime
			,@start_date datetime
			,@error_id int 
			,@idle int
			,@succeed int
			,@startup int
			,@retry int
			,@failure int
			,@inprogress int
			,@lastrow_timestamp timestamp
			,@existing_row_updateble bit
			,@this_row_updateable bit
			,@spid_login_time datetime
			,@agent_name nvarchar(100)
			,@agentclassname sysname
			
			
	select    @startup = 1, @succeed = 2, @inprogress = 3, @idle = 4, @retry = 5, @failure = 6
						
	-- Security Check
	exec @retcode = sys.sp_MScheck_pull_access @agent_id = @agent_id, @agent_type = 1 -- merge agent
	if @@error <> 0 or @retcode <> 0
			return (1)
			
	if @subid is not null
	begin
		if object_id('MSmerge_sessions', 'U') is NULL
			return 0
	end
	else
	begin
		--distributor side 
		select @agent_name = name from dbo.MSmerge_agents where id = @agent_id
	end
	
	select @current_date = getdate()
	--select @spid_login_time = login_time from sys.dm_exec_sessions where session_id = @@spid
	select @spid_login_time = NULL
	
	if @session_id is null or @session_id = 0
	begin
		select @start_date = dateadd(second, -@session_duration, @current_date)
		
		-- This has to be done whether or not @update_stats is set. This is because we need to get the session_id.
		insert into dbo.MSmerge_sessions(agent_id, start_time, end_time, duration, delivery_time, upload_time, 
			download_time, schema_change_time, prepare_snapshot_time, delivery_rate, 
			time_remaining, percent_complete, download_inserts, download_updates, download_deletes,
			download_conflicts, download_rows_retried, upload_inserts, upload_updates, upload_deletes,
			upload_conflicts, upload_rows_retried, runstatus, 
			schema_changes, bulk_inserts, metadata_rows_cleanedup, estimated_upload_changes, 
			estimated_download_changes, connection_type, current_phase_id, spid_login_time, spid)
		values(@agent_id, @start_date, @current_date, @session_duration, @delivery_time, @upload_time, @download_time, 
			@schema_change_time, @prepare_snapshot_time, @delivery_rate, @time_remaining, 
			@session_percent_complete, @session_download_inserts, @session_download_updates, @session_download_deletes,
			@session_download_conflicts, @session_download_rows_retried,
			@session_upload_inserts, @session_upload_updates, 
			@session_upload_deletes, @session_upload_conflicts, 
			@session_upload_rows_retried, @runstatus, 
			@session_schema_changes, @session_bulk_inserts, @session_metadata_rows_cleanedup, 
			@session_estimated_upload_changes, @session_estimated_download_changes, @connection_type,
			@phase_id, @spid_login_time, @@spid)
		
		select @session_id = @@identity
		
		if @session_id is null or @session_id = 0
		begin
			raiserror(14043, 16, -1, '@session_id', 'sp_MSadd_merge_history90')
			return 1
		end

		 -- increment agent counter on the distributor side (@subid is null)
		 if ( ( @subid is null )  and ( @runstatus = @startup ))
		 begin
			dbcc incrementinstance ("SQL Replication Agents", "Running", "Merge", 1)    
	  end

	end
	else if @update_stats = 1 
	begin
		if @info_filter = 0
		begin     
			update dbo.MSmerge_sessions set 
				end_time = @current_date, duration = datediff(second, start_time, @current_date), --@session_duration, 
				delivery_time = @delivery_time, upload_time = @upload_time, 
				download_time = @download_time, schema_change_time = @schema_change_time,
				prepare_snapshot_time = @prepare_snapshot_time,
				delivery_rate = @delivery_rate, 
				time_remaining = @time_remaining, percent_complete = @session_percent_complete,
				download_inserts = @session_download_inserts, download_updates = @session_download_updates, 
				download_deletes = @session_download_deletes, download_conflicts = @session_download_conflicts, 
				download_rows_retried = @session_download_rows_retried, 
				upload_inserts = @session_upload_inserts, upload_updates = @session_upload_updates, 
				upload_deletes = @session_upload_deletes, upload_conflicts = @session_upload_conflicts,
				upload_rows_retried = @session_upload_rows_retried,
				schema_changes = @session_schema_changes, bulk_inserts = @session_bulk_inserts,
				metadata_rows_cleanedup = @session_metadata_rows_cleanedup, 
				runstatus = case when runstatus in (@succeed, @retry, @failure) and @runstatus not in (@succeed, @retry, @failure) 
							and @phase_id <> 4 and spid is not null
							then runstatus 
							else @runstatus end, 
				estimated_upload_changes = @session_estimated_upload_changes, 
				estimated_download_changes = @session_estimated_download_changes, 
				connection_type = @connection_type,
				current_phase_id = @phase_id,
				spid_login_time = @spid_login_time,
				spid = @@spid
				where session_id = @session_id
		 end
		 if @info_filter = 1 --upload only stat
		 begin 
				update dbo.MSmerge_sessions set 
				end_time = @current_date, duration = datediff(second, start_time, @current_date), --@session_duration, 
				upload_time = @upload_time, 
				schema_change_time = @schema_change_time,
				time_remaining = @time_remaining, 
				percent_complete = @session_percent_complete,
				upload_inserts = @session_upload_inserts, 
				upload_updates = @session_upload_updates, 
				upload_deletes = @session_upload_deletes,
				upload_conflicts = @session_upload_conflicts,
				upload_rows_retried = @session_upload_rows_retried,
				schema_changes = @session_schema_changes, 
				runstatus = case when ((runstatus in (@succeed, @retry, @failure) and @runstatus not in (@succeed, @retry, @failure) 
							and @phase_id <> 4 and spid is not null)or (runstatus = @failure))
							then runstatus 
							else @runstatus end, 
				estimated_upload_changes = @session_estimated_upload_changes,
				current_phase_id = @phase_id
				where session_id = @session_id
		 end
		 if @info_filter = 2 --download only stat
		 begin 
				update dbo.MSmerge_sessions set 
				end_time = @current_date, 
				duration = datediff(second, start_time, @current_date), --@session_duration, 
				delivery_time = @delivery_time, 
				download_time = @download_time, 
				prepare_snapshot_time = @prepare_snapshot_time,
				delivery_rate = @delivery_rate, 
				time_remaining = @time_remaining, 
				percent_complete = @session_percent_complete,
				download_inserts = @session_download_inserts, 
				download_updates = @session_download_updates, 
				download_deletes = @session_download_deletes, 
				download_conflicts = @session_download_conflicts, 
				download_rows_retried = @session_download_rows_retried, 
				bulk_inserts = @session_bulk_inserts,
				metadata_rows_cleanedup = @session_metadata_rows_cleanedup, 
				runstatus = case when ((runstatus in (@succeed, @retry, @failure) and @runstatus not in (@succeed, @retry, @failure) 
							and @phase_id <> 4 and spid is not null)or (runstatus = @failure) )
							then runstatus 
							else @runstatus end, 
				estimated_download_changes = @session_estimated_download_changes, 
				connection_type = @connection_type,
				current_phase_id = @phase_id,
				spid_login_time = @spid_login_time,
				spid = @@spid
				where session_id = @session_id               
		 end


			-- perfmon counter

			declare @change_count int

			-- only log the counter change on the distributor side (@subid is null)
			if ( ( @subid is null )  and ( @runstatus = @idle or @runstatus = @inprogress ))
			begin
				dbcc addinstance ("SQL Replication Merge", @agent_name)

				select @change_count = @session_download_inserts + @session_download_updates + @session_download_deletes
				dbcc incrementinstance ("SQL Replication Merge", "Downloaded Changes/sec", @agent_name, @change_count)

				select @change_count = @session_upload_updates + @session_upload_inserts + @session_upload_deletes
				dbcc incrementinstance("SQL Replication Merge", "Uploaded Changes/sec", @agent_name, @change_count)

				select @change_count = @session_download_conflicts + @session_upload_conflicts
				dbcc incrementinstance("SQL Replication Merge", "Conflicts/sec", @agent_name, @change_count);
			end 
			
	end
	else
	begin
		if @info_filter = 0
		begin
		   update dbo.MSmerge_sessions set 
			end_time = @current_date, duration = datediff(second, start_time, @current_date), --@session_duration,
			runstatus = case when runstatus in (@succeed, @retry, @failure) and @runstatus not in (@succeed, @retry, @failure) 
						and @phase_id <> 4 and spid is not null
						then runstatus 
						else @runstatus end,
			current_phase_id = case when runstatus in (@succeed, @retry, @failure) then 0 else @phase_id end,
			spid_login_time = @spid_login_time,
			spid = @@spid
			where session_id = @session_id
		end
		
		if @info_filter = 1
		begin
			update dbo.MSmerge_sessions set 
			end_time = @current_date, 
			duration = datediff(second, start_time, @current_date), --@session_duration,
			runstatus = case when ((runstatus in (@succeed, @retry, @failure) and @runstatus not in (@succeed, @retry, @failure) 
						and @phase_id <> 4 and spid is not null) or (runstatus = @failure) )
						then runstatus 
						else @runstatus end,

			current_phase_id = case when runstatus in (@succeed, @retry, @failure) then 0 else @phase_id end

			where session_id = @session_id       
		end

		if @info_filter = 2
		begin
			update dbo.MSmerge_sessions set 
			end_time = @current_date, 
			duration = datediff(second, start_time, @current_date), --@session_duration,
			runstatus = case when ((runstatus in (@succeed, @retry, @failure) and @runstatus not in (@succeed, @retry, @failure) 
						and @phase_id <> 4 and spid is not null) or (runstatus = @failure) )
						then runstatus 
						else @runstatus end,
			current_phase_id = case when runstatus in (@succeed, @retry, @failure) then 0 else @phase_id end,
			spid_login_time = @spid_login_time,
			spid = @@spid
			where session_id = @session_id       
		end

	end
	
	if @subid is not null
	begin
		-- clean up all sessions and related rows past last 10 sessions for this subid and only keep the latest 5k rows for this subid for each session
			
		exec @retcode = sys.sp_MScleanup_subscriber_history @subid = @subid, @keep_sessions = 10
		if @retcode <> 0
			return 1
		
		-- not doing dynamic SQL can fail on distributor where the subid column does not exist
		-- in MSmerge_sessions.
		exec sys.sp_executesql N'update dbo.MSmerge_sessions set subid = @subid where session_id = @session_id',
							N'@subid uniqueidentifier, @session_id int', @subid=@subid, @session_id=@session_id
	end

	if @article_name is not null and @article_name <> '' and @update_stats = 1
	begin
		if exists (select * from dbo.MSmerge_articlehistory with (nolock)
					where session_id = @session_id and phase_id = @phase_id and article_name = @article_name)
			update dbo.MSmerge_articlehistory set 
				duration = datediff(second, start_time, @current_date), inserts    = @article_inserts, updates = @article_updates,
				deletes = @article_deletes, conflicts = @article_conflicts, 
				rows_retried = @article_rows_retried, percent_complete = @article_percent_complete,
				estimated_changes = @article_estimated_changes, relative_cost = @article_relative_cost
			where session_id = @session_id and phase_id = @phase_id and article_name = @article_name
		else
		begin
			select top 1 @current_date = start_time from dbo.MSmerge_articlehistory with (nolock)
					where session_id = @session_id and phase_id = @phase_id
					order by start_time desc -- if no row is found, @current_date will stay at its original value
												-- (set to getdate() earlier).
					
			insert into dbo.MSmerge_articlehistory (session_id, phase_id, article_name, start_time, duration, inserts,
				updates, deletes, conflicts, rows_retried, percent_complete, estimated_changes, relative_cost)
			values(@session_id, @phase_id, @article_name, @current_date, 0, @article_inserts, @article_updates, 
				@article_deletes, @article_conflicts, @article_rows_retried,
				@article_percent_complete, @article_estimated_changes, 
				@article_relative_cost)
		end
	end
	
	if @phase_id = 5 or @runstatus = @succeed or @log_error = 1
	begin
		declare @total_upload_article_cost decimal(12,2), @total_download_article_cost decimal(12,2)
		
		if @info_filter = 0
		begin
			update dbo.MSmerge_sessions set percent_complete = 100, time_remaining = 0,
				estimated_upload_changes = upload_inserts + upload_updates + upload_deletes,
				estimated_download_changes = download_inserts + download_updates + download_deletes,
				runstatus = case when runstatus in (@succeed, @retry, @failure) and @runstatus not in (@succeed, @retry, @failure) 
							and @phase_id <> 4 and spid is not null
							then runstatus 
							else @runstatus end,
				current_phase_id = 0
			where session_id = @session_id
		end
		if @info_filter = 1
		begin
			 update dbo.MSmerge_sessions set 
				percent_complete = 100, 
				time_remaining = 0,
				estimated_upload_changes = upload_inserts + upload_updates + upload_deletes,
				runstatus = case when ((runstatus in (@succeed, @retry, @failure) and @runstatus not in (@succeed, @retry, @failure) 
							and @phase_id <> 4 and spid is not null) or (runstatus = @failure) )
							then runstatus 
							else @runstatus end,
				current_phase_id = 0
			where session_id = @session_id         
		end
		if @info_filter = 2
		begin
			 update dbo.MSmerge_sessions set 
				percent_complete = 100, 
				time_remaining = 0,
				estimated_download_changes = download_inserts + download_updates + download_deletes,
				runstatus = case when ((runstatus in (@succeed, @retry, @failure) and @runstatus not in (@succeed, @retry, @failure) 
							and @phase_id <> 4 and spid is not null ) or (runstatus = @failure) )
							then runstatus 
							else @runstatus end,
				current_phase_id = 0
			where session_id = @session_id           
		end

		
		select @total_upload_article_cost = isnull(sum(relative_cost),0) from dbo.MSmerge_articlehistory
			where session_id = @session_id and phase_id = 1
												
		select @total_download_article_cost = isnull(sum(relative_cost),0) from dbo.MSmerge_articlehistory
			where session_id = @session_id and phase_id = 2
		
		update dbo.MSmerge_articlehistory set percent_complete = 100,
			estimated_changes = inserts + updates + deletes,
			relative_cost = 
				case 
					when phase_id = 1 and @total_upload_article_cost > 0 
						then (100*relative_cost)/@total_upload_article_cost
					when phase_id = 2 and @total_download_article_cost > 0
						then (100*relative_cost)/@total_download_article_cost 
					else
						0
				end
		where session_id = @session_id

		-- decrement the agent counter
		-- we only log the perfmon couter on the distributor side (@subit is null)
		if (( @subid is null ) and (@runstatus = @succeed or @runstatus=@retry or @runstatus = @failure ))
		begin
			dbcc incrementinstance ("SQL Replication Agents", "Running", "Merge", -1)
		end
		
	end
	
	if (@comments is not null and @comments <> '') or @log_error = 1
	begin
		select    @existing_row_updateble = 0, @this_row_updateable = 0

		if (@updateable_row = 1)
			select @this_row_updateable = 1

		select top 1 @lastrow_timestamp = timestamp, @existing_row_updateble = updateable_row
		from dbo.MSmerge_history with (rowlock)
		where agent_id = @agent_id order by timestamp desc
		
		select @error_id = 0
		if @log_error = 1
		begin        
			exec sys.sp_MSget_new_errorid @error_id output  -- Ignore errors here. @error_id will be set to 0 in case of errors  
		end

		-- Insert idle record or update if history record is already 'idle'
		IF (@existing_row_updateble = 1) and (@runstatus = @idle or @update_existing_row = 1)
		begin
			-- Attempt to update the last row if it is IDLE
			update dbo.MSmerge_history set comments = @comments, updateable_row = @this_row_updateable,
				error_id = case @error_id when 0 then error_id else @error_id end    
			where agent_id = @agent_id 
			and timestamp = @lastrow_timestamp

			-- Insert idle record if there is not one
			if @@rowcount = 0
				insert into dbo.MSmerge_history(agent_id, comments, error_id, updateable_row, session_id)
					values (@agent_id, @comments, @error_id, @this_row_updateable, @session_id)
		end
		else
			insert into dbo.MSmerge_history(agent_id, comments, error_id, updateable_row, session_id)
				values(@agent_id, @comments, @error_id, @this_row_updateable, @session_id)
	end

	if @subid is null --distributor side
	begin
		select @agentclassname = formatmessage(14554)
		exec sys.sp_MSrepl_raiserror @agentclassname, @agent_name, @runstatus, @comments
	end
	
	return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSadd_merge_history90] TO [public] AS [dbo]
GO
