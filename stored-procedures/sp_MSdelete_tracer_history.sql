SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdelete_tracer_history]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdelete_tracer_history] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdelete_tracer_history]
	@tracer_id [int],
	@cutoff_date [datetime],
	@num_records_removed [int] OUTPUT,
	@publication [sysname],
	@publisher [sysname],
	@publisher_db [sysname]
WITH EXECUTE AS CALLER
AS
begin
	-- setting deadlock priority to low so we always lose
	set deadlock_priority low
	set nocount on
	
	declare @retcode			int,
			@del_error 			int,
			@publication_id		int,
			@distribution_db	sysname

	select @distribution_db = db_name()
	
	--
	-- security check.
	-- User must be member of 'replmonitor' role in distribution database
	--
	exec @retcode = sys.sp_MSrepl_DistributorReplMonitorAccess @distribution_db = @distribution_db
	if @retcode != 0 or @@error != 0
		return 1

	-- Has to be executed from distribution database
	if sys.fn_MSrepl_isdistdb (@distribution_db) != 1
	begin
		-- sp_MSispeertopeeragent can only be executed in the distribution database.
		raiserror (21482, 16, -1, 'sp_MShelptracertokens', 'distribution')
		return 1
	end

	-- parameter checks
	if @tracer_id is null and @cutoff_date is null
	begin
		-- The parameter @tracer_id and @cutoff_date cannot be NULL.
		raiserror (14043, 16, -1, '@tracer_id and @cutoff_date', 'sp_MSdelete_tracer_history')
		return 1
	end
	else if @tracer_id is not null and @cutoff_date is not null
	begin
		-- There must be one and only one of '@tracer_id' and '@cut_off' that is not NULL.
		raiserror(21314, 16, -1, '@tracer_id', '@cut_off')
		return 1
	end

	-- retrieve the publication id
	select @publication_id = msp.publication_id
		from dbo.MSpublications msp
			join MSreplservers ss
				on msp.publisher_id = ss.srvid
		where UPPER(ss.srvname) = UPPER(@publisher)
			and msp.publisher_db = @publisher_db
			and msp.publication = @publication
			
	-- if any publisher data is provided check to see if the publication exists
	if (@publisher is not NULL
			or @publisher_db is not NULL
			or @publication is not NULL)
		and @publication_id is NULL
	begin
		-- Publication 'publication' does not exist.
		raiserror(21200, 16, -1, @publication)
		return 1
	end
	
	begin tran tr_sp_MSdelete_tracer_history
	save tran tr_sp_MSdelete_tracer_history
	
	-- perform delete
	if @tracer_id is not null
	begin
		-- now if publisher info is provided then validate that the
		-- lsn provided falls under the given publishers list
		if (@publisher is not NULL
				or @publisher_db is not NULL
				or @publication is not NULL)
			and not exists(select *
						from MStracer_tokens
						where publication_id = @publication_id
							and tracer_id = @tracer_id)
		begin
			-- The tracer token id (%d) could not be found for publisher:%s, database:%s, publication:%s.
			raiserror(20688, 16, -1, @tracer_id, @publisher, @publisher_db, @publication)
			goto Err_Handler
		end
	
		-- ensure we delete the children for this tracer id as well
		delete MStracer_history
			where parent_tracer_id = @tracer_id
			option(MAXDOP 1)
		if @@error <> 0 goto Err_Handler
		
		
		-- delete parent rows
		delete MStracer_tokens
			where tracer_id = @tracer_id
			option(MAXDOP 1)
			
		select @del_error = @@error, @num_records_removed = @@rowcount
		if @del_error <> 0 goto Err_Handler
	end
	else 
	begin
		-- 
		-- remember here that if any of the publisher info is provided
		-- we can only delete those that match else do not delete it
		--
		
		-- delete children in range first
		delete MStracer_history
			where parent_tracer_id in (select tracer_id
										from MStracer_tokens
										where publisher_commit <= @cutoff_date
											and (publication_id = @publication_id
												or (@publisher is NULL
													and @publisher_db is NULL
													and @publication is NULL)))
			option(MAXDOP 1)
		if @@error <> 0 goto Err_Handler
		
		-- now delete the parent rows
		delete MStracer_tokens
			where publisher_commit <= @cutoff_date
				and (publication_id = @publication_id
					or (@publisher is NULL
						and @publisher_db is NULL
						and @publication is NULL))
			option(MAXDOP 1)
		select @del_error = @@error, @num_records_removed = @@rowcount
		if @del_error <> 0 goto Err_Handler
	end

	commit tran tr_sp_MSdelete_tracer_history
	
	return 0
	
Err_Handler:
	rollback tran tr_sp_MSdelete_tracer_history
	commit tran tr_sp_MSdelete_tracer_history
	
	return 1
end
GO
GRANT EXECUTE ON [sys].[sp_MSdelete_tracer_history] TO [public] AS [dbo]
GO
