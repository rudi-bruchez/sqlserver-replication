SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MShelptracertokenhistory]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MShelptracertokenhistory] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MShelptracertokenhistory]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@tracer_id [int]
WITH EXECUTE AS CALLER
AS
begin
	declare @retcode 				int,
			@publication_id			int,
			@distributor_latency	bigint,
			@subscriber_latency		bigint,
			@overall_latency		bigint,
			@publisher_commit		datetime,
			@distributor_commit		datetime,
			@subscriber				sysname,
			@subscriber_db			sysname,
			@subscriber_commit		datetime,
			@distribution_db		sysname

	declare @tracer_history table(distributor_latency bigint, subscriber sysname, subscriber_db sysname, subscriber_latency bigint, overall_latency bigint)

	select @distribution_db = db_name()
	
	--
	-- security check.
	-- User must be member of 'replmonitor' role in distribution database.
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
	
	-- check to see if the publication exists
	select @publication_id = msp.publication_id
		from dbo.MSpublications msp
			join MSreplservers ss
				on msp.publisher_id = ss.srvid
		where UPPER(ss.srvname) = UPPER(@publisher)
			and msp.publisher_db = @publisher_db
			and msp.publication = @publication

	if @publication_id is NULL
	begin
		-- Publication 'publication' does not exist.
		raiserror(21200, 16, -1, @publication)
		return 1
	end
	
	select @publisher_commit = publisher_commit,
			@distributor_commit = distributor_commit
		from MStracer_tokens
		where publication_id = @publication_id
			and tracer_id = @tracer_id
	
	-- the publisher commit should never be null
	-- if we have a valid parent tracer LSN
	if @publisher_commit is NULL
	begin
		-- The tracer token id (%d) could not be found for publisher:%s, database:%s, publication:%s.
		raiserror(20688, 16, -1, @tracer_id, @publisher, @publisher_db, @publication)
		return 1
	end
	
	-- calculate the distributor latency
	select @distributor_latency = datediff(ss, @publisher_commit, @distributor_commit)

	-- gather remaining latency information
	declare tracer_history_cursor cursor fast_forward for
		select distinct syss.srvname,
				msda.subscriber_db,
				msth.subscriber_commit
			from MStracer_history msth
				join MSdistribution_agents msda
					on msth.agent_id = msda.id
				join MSreplservers syss
					on msda.subscriber_id = syss.srvid
			where msth.parent_tracer_id = @tracer_id
	
	open tracer_history_cursor

	fetch next from tracer_history_cursor into @subscriber, @subscriber_db, @subscriber_commit
	while (@@fetch_status <> -1)
	begin
		-- calculate the subscriber latency
		select @subscriber_latency = datediff(ss, @distributor_commit, @subscriber_commit)
		
		-- calculate the overall latency
		select @overall_latency = @distributor_latency + @subscriber_latency
		
		-- add history row to the temp table
		insert into @tracer_history 
		(
			distributor_latency, 
			subscriber, 
			subscriber_db, 
			subscriber_latency,
			overall_latency
		)
		values 
		(
			@distributor_latency, 
			@subscriber, 
			@subscriber_db, 
			@subscriber_latency,
			@overall_latency
		)

		fetch next from tracer_history_cursor into @subscriber, @subscriber_db, @subscriber_commit
	end

	close tracer_history_cursor
	deallocate tracer_history_cursor
	
	-- return the tracer history information
	select distributor_latency, 
			subscriber, 
			subscriber_db, 
			subscriber_latency,
			overall_latency
		from @tracer_history
		order by overall_latency desc, 
				subscriber_latency desc, 
				distributor_latency desc
	
	return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MShelptracertokenhistory] TO [public] AS [dbo]
GO
