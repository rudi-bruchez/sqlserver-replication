SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_replmonitorhelpmergesessiondetail]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_replmonitorhelpmergesessiondetail] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_replmonitorhelpmergesessiondetail]
	@session_id [int]
WITH EXECUTE AS CALLER
AS
begin
	-- security check
	-- only replmonitor can execute this
	--
	if not (is_member(N'db_owner') = 1 or isnull(is_member(N'replmonitor'),0) = 1)
	begin
		raiserror(14260, 16, -1)
		return (1)
	end
	
	declare @upload_time int, @download_time int, @schema_change_time int, @prepare_snapshot_time int, @run_succeeded bit, 
			@start_time datetime,
			@session_duration int, @estimated_upload_changes int, @estimated_download_changes int,
			@init_time int, @upload_percent_cost int, @download_percent_cost int, 
			@schema_change_percent_cost int, 
			@prepare_snapshot_percent_cost int,
			@init_percent_cost int, @bulk_inserts int,
			@upload_percent_complete decimal(10,2), @download_percent_complete decimal(10,2),
			@upload_inserts int, @upload_updates int, @upload_deletes int, @upload_conflicts int, @upload_rows_retried int,
			@download_inserts int, @download_updates int, @download_deletes int, @download_conflicts int, @download_rows_retried int,
			@schema_changes int, @phase_description nvarchar(255)

	set @run_succeeded =0
	
	declare @resulttable TABLE 
		(
		PhaseID int NULL, -- 0 for summary line
		ArticleName sysname NULL, 
		PercentComplete decimal(5,2) NULL,  -- for running or failed session
		RelativeCost decimal(5,2) NULL,  -- for succeeded session
		Duration int NULL,
		Inserts int NULL, 
		Updates int NULL, 
		Deletes int NULL, 
		Conflicts int NULL,
		SchemaChanges int NULL,
		RowsRetried int NULL,
		ErrorID int NULL,
		SeqNo int IDENTITY(1,1),
		RowType int	-- 0 for init, 1 for upload, 2 for upload article, 3 for download, 4 for download article, 5 for schema changes/bcp, 6 for prepare snapshot
		)

	if exists (select * from dbo.MSmerge_sessions where session_id = @session_id)
	begin 

		select @run_succeeded= CASE runstatus WHEN 2 THEN 1 ELSE 0 END,
			@start_time=start_time,
			@session_duration = duration,
			@upload_time = upload_time,
			@download_time = download_time,
			@schema_change_time = schema_change_time,
			@prepare_snapshot_time = prepare_snapshot_time,
			@estimated_upload_changes = estimated_upload_changes,
			@estimated_download_changes = estimated_download_changes,
			
			@upload_inserts = upload_inserts,
			@upload_updates = upload_updates,
			@upload_deletes = upload_deletes,
			@upload_conflicts = upload_conflicts,
			@upload_rows_retried = upload_rows_retried,
			
			@download_inserts = download_inserts,
			@download_updates = download_updates,
			@download_deletes = download_deletes,
			@download_conflicts = download_conflicts,
			@download_rows_retried = download_rows_retried,
			
			@bulk_inserts = bulk_inserts, 
			@schema_changes = schema_changes,
			
			@upload_percent_complete = case when estimated_upload_changes > 0 then 
										(100.0 * cast((upload_deletes + upload_updates + upload_inserts) as float))/
										(cast(estimated_upload_changes as float))
										else 0.0 end,
										
			@download_percent_complete = case when estimated_download_changes > 0 then 
										(100.0 * cast((download_deletes + download_updates + download_inserts) as float))/
										(cast(estimated_download_changes as float))
										else 0.0 end,
										
			@upload_percent_cost = case when duration > 0 then 
										(100.0 * cast(upload_time as float))/(cast(duration as float))
										else 0.0 end,
										
			@download_percent_cost = case when duration > 0 then 
										(100.0 * cast(download_time as float))/(cast(duration as float))
										else 0.0 end,
										
			@schema_change_percent_cost = case when duration > 0 then 
										(100.0 * cast(schema_change_time as float))/(cast(duration as float))
										else 0.0 end,

			@prepare_snapshot_percent_cost = case when duration > 0 then 
										(100.0 * cast(prepare_snapshot_time as float))/(cast(duration as float))
										else 0.0 end,
										
			@init_time = duration - (upload_time + download_time + schema_change_time + prepare_snapshot_time)
			
		from dbo.MSmerge_sessions
		where session_id = @session_id
			
		if @upload_percent_complete < 0.0
			select @upload_percent_complete = 0.0
		else if @upload_percent_complete > 100.0
			select @upload_percent_complete = 100.0
			
		if @download_percent_complete < 0.0
			select @download_percent_complete = 0.0
		else if @download_percent_complete > 100.0
			select @download_percent_complete = 100.0
				
		if @upload_percent_cost < 0.0
			select @upload_percent_cost = 0.0
		else if @upload_percent_cost > 100.0
			select @upload_percent_cost = 100.0
			
		if @download_percent_cost < 0.0
			select @download_percent_cost = 0.0
		else if @download_percent_cost > 100.0
			select @download_percent_cost = 100.0
			
		if @schema_change_percent_cost < 0.0
			select @schema_change_percent_cost = 0.0
		else if @schema_change_percent_cost > 100.0
			select @schema_change_percent_cost = 100.0

		if @prepare_snapshot_percent_cost < 0.0
			select @prepare_snapshot_percent_cost = 0.0
		else if @prepare_snapshot_percent_cost > 100.0
			select @prepare_snapshot_percent_cost = 100.0
			
		if @init_time < 0
			select @init_time = 0
			
		select @init_percent_cost = 100.00 - (@upload_percent_cost + @download_percent_cost + @schema_change_percent_cost + @prepare_snapshot_percent_cost)
		
		select @phase_description = formatmessage(22531)
		--select @phase_description = formatmessage(21587)
		
		insert @resulttable 
			(PhaseID, ArticleName, PercentComplete, RelativeCost, Duration, Inserts, Updates, Deletes, 
				Conflicts, SchemaChanges, RowsRetried, ErrorID, RowType)
		values
			(0, @phase_description, NULL, @init_percent_cost, @init_time, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 0)

		-- Prepare dynamic snaphsot phase
		if (@prepare_snapshot_percent_cost > 0)
		begin
			select @phase_description = formatmessage(25016)            
			insert @resulttable 
				(PhaseID, ArticleName, PercentComplete, RelativeCost, Duration, Inserts, Updates, Deletes, 
					Conflicts, SchemaChanges, RowsRetried, ErrorID, RowType)
			values
				(0, @phase_description, NULL, @prepare_snapshot_percent_cost, @prepare_snapshot_time, NULL, NULL, 
					NULL, NULL, NULL, NULL, NULL, 6)
		end

		select @phase_description = formatmessage(25015)
		-- Schema Changes and Bulk Inserts
		insert @resulttable 
			(PhaseID, ArticleName, PercentComplete, RelativeCost, Duration, Inserts, Updates, Deletes, 
				Conflicts, SchemaChanges, RowsRetried, ErrorID, RowType)
		values
			(0, @phase_description, NULL, @schema_change_percent_cost, @schema_change_time, @bulk_inserts, NULL, 
				NULL, NULL, @schema_changes, NULL, NULL, 5)

		select @phase_description = formatmessage(22532)
		--select @phase_description = formatmessage(21588)
		-- upload summary line
		insert @resulttable 
			(PhaseID, ArticleName, PercentComplete, RelativeCost, Duration, Inserts, Updates, Deletes, 
				Conflicts, SchemaChanges, RowsRetried, ErrorID, RowType)
		values
			(0, @phase_description, @upload_percent_complete, @upload_percent_cost, @upload_time, @upload_inserts, @upload_updates, 
				@upload_deletes, @upload_conflicts, NULL, @upload_rows_retried, NULL, 1)

		-- upload details
		insert @resulttable
			(PhaseID, ArticleName, PercentComplete, RelativeCost, Duration, Inserts, Updates, Deletes, 
				Conflicts, SchemaChanges, RowsRetried, ErrorID, RowType)
		select phase_id, article_name, 
			CAST(percent_complete as int), 
			CASE when @run_succeeded = 1 and relative_cost <= 100.00
				then (relative_cost/100.0) * @upload_percent_cost
								ELSE NULL END, 
			CASE when @run_succeeded = 1 and relative_cost <= 100.00
				THEN (relative_cost/100.0) * @upload_time
								ELSE NULL END,			
			inserts, updates, deletes, conflicts, NULL, rows_retried, NULL, 2
			from dbo.MSmerge_articlehistory
			where session_id=@session_id and phase_id = 1
			order by start_time

		select @phase_description = formatmessage(22533)
		--select @phase_description = formatmessage(21589)
		
		-- download summary line
		insert @resulttable 
			(PhaseID, ArticleName, PercentComplete, RelativeCost, Duration, Inserts, Updates, Deletes, 
				Conflicts, SchemaChanges, RowsRetried, ErrorID, RowType)
		values (0, @phase_description, @download_percent_complete, @download_percent_cost, @download_time, @download_inserts, @download_updates, 
				@download_deletes, @download_conflicts, NULL, @download_rows_retried, NULL, 3)
		
		-- download details
		insert @resulttable
			(PhaseID, ArticleName, PercentComplete, RelativeCost, Duration, Inserts, Updates, Deletes, 
				Conflicts, SchemaChanges, RowsRetried, ErrorID, RowType)
		select phase_id, article_name, 
			CAST(percent_complete as int), 
			CASE when @run_succeeded = 1 and relative_cost <= 100.00
				then (relative_cost/100.0) * @download_percent_cost
								ELSE NULL END, 
			CASE when @run_succeeded = 1 and relative_cost <= 100.00
				then (relative_cost/100.0) * @download_time
								ELSE NULL END,
			inserts, updates, deletes, conflicts, NULL, rows_retried, NULL, 4
			from dbo.MSmerge_articlehistory
			where session_id=@session_id and phase_id = 2
			order by start_time
	end

	select PhaseID, ArticleName, 
		PercentComplete, RelativeCost, Duration, 
		Inserts, Updates, Deletes, Conflicts, ErrorID, SeqNo, RowType, SchemaChanges, RowsRetried
		from @resulttable order by SeqNo
end
GO
GRANT EXECUTE ON [sys].[sp_replmonitorhelpmergesessiondetail] TO [public] AS [dbo]
GO
