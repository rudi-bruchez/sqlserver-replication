SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MShelp_merge_agentid]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MShelp_merge_agentid] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MShelp_merge_agentid]
	@publisher_id [smallint],
	@publisher_db [sysname],
	@publication [sysname],
	@subscriber_id [smallint],
	@subscriber_db [sysname],
	@subscriber_version [int],
	@subscriber [sysname]
WITH EXECUTE AS CALLER
AS
begin
	declare @publisher		sysname
	declare @expired		int
	declare @agent_id 		int
	declare @name 			sysname
	declare @retention 		int
	declare @retention_period_unit	tinyint
	declare @last_status	int
	declare @last_history	datetime
	declare @min_valid_day 	datetime
	declare @reinited 		int
	declare @status 		int
	declare @success		int
	declare @publication_id	int
	declare @subscriber_datasource_type int
	declare @sql_subscriber	int
	declare @sub_version int

	select @expired = 0
	select @reinited = 4
	select @success = 2

    select @subscriber_datasource_type = 0
    select @sql_subscriber = 0
	-- @publisher_id is always from master..sysservers, so we need to fetch from MSreplservers
	select @publisher_id = sys.fn_MSrepl_getsrvidfromdistdb(@publisher_id)

	if not EXISTS (select * from dbo.MSpublications 
		where publisher_id=@publisher_id 
		and publisher_db = @publisher_db
		and publication = @publication
		and publication_type = 2) -- merge publication is gone
	begin
		select 1, @publication, 1, 0 --third column = 1 means publication is gone, making the other values meanningless.
		return (1)
	end

   	select @publication_id = publication_id 
		from dbo.MSpublications
		where publisher_id = @publisher_id and
			  publisher_db = @publisher_db and
			  publication = @publication

	-- Get subscriber info
	if @subscriber IS NULL
		begin
		    select @subscriber = srvname from MSreplservers where srvid = @subscriber_id
		end
	--Get subscriber server name only.
	exec sys.sp_MSget_server_portinfo 
		@name = @subscriber, 
		@srvname = @subscriber OUTPUT

	select @publisher = srvname from MSreplservers where srvid = @publisher_id

	select @subscriber_datasource_type = type
		from MSsubscriber_info 
		where UPPER(publisher) = UPPER(@publisher) and UPPER(subscriber) = UPPER(@subscriber)

	if (@subscriber_datasource_type = @sql_subscriber)
	begin
		select @status = status, @sub_version = subscriber_version from dbo.MSmerge_subscriptions where
			publisher_id = @publisher_id and 
			publisher_db = @publisher_db and 
			publication_id = @publication_id and
			UPPER(subscriber) = UPPER(@subscriber) and
			subscriber_db = @subscriber_db

		select @agent_id = id, @name = name from dbo.MSmerge_agents 
			where publisher_id = @publisher_id 
			and publisher_db = @publisher_db
			and publication = @publication
			and UPPER(subscriber_name) = UPPER(@subscriber)
			and subscriber_db = @subscriber_db
	end
	else
	begin
		select @status = status, @sub_version = subscriber_version from dbo.MSmerge_subscriptions where
			publisher_id = @publisher_id and 
			publisher_db = @publisher_db and 
			publication_id = @publication_id and
			UPPER(subscriber) = UPPER(@subscriber)

		select @agent_id = id, @name = name from dbo.MSmerge_agents 
			where publisher_id = @publisher_id 
			and publisher_db = @publisher_db
			and publication = @publication
			and UPPER(subscriber_name) = UPPER(@subscriber)
	end

	-- Security check. Do it here to let the agent fail at the beginning
	if @agent_id is not null
	begin
		exec sys.sp_MScheck_pull_access @agent_id = @agent_id, @agent_type = 1 -- merge agent

		if @sub_version is NULL
			select @sub_version = @subscriber_version
			
		if @sub_version < 90
		begin
			select @retention = retention, @retention_period_unit = retention_period_unit
				from dbo.MSpublications 
				where publisher_id=@publisher_id and publisher_db=@publisher_db and publication=@publication 

			if @retention is not NULL and @retention > 0
			begin
				select @min_valid_day = sys.fn_add_units_to_date(@retention * (-1), @retention_period_unit, getdate()) 
				-- only do history based expiration if there is a valid successful run information available.    	
				-- If we do not find the history for the last successful run we will not cleanup.
				-- however a seperate cleanup happens that uses the last_sync_time on the publisher. So
				-- even if we do not cleanup here sp_MSdrop_expired_mergesubscription will take care of it
				select Top 1 @last_status = runstatus, @last_history = end_time 
					from dbo.MSmerge_sessions where agent_id = @agent_id and runstatus=2 order by session_id DESC

				/*
				commeting out since we do not want to use the failed history information
				if @last_status = 6 and EXISTS (select * from dbo.MSmerge_history where  agent_id = @agent_id and runstatus = 2) 
					select Top 1 @last_history = time from dbo.MSmerge_history where agent_id = @agent_id and runstatus = 2
									order by time DESC
				*/
				if @last_history is not NULL
				begin
					if @last_history < @min_valid_day --and @status <> @reinited //We no longer consider marked-for-reinit subscriptions as exempt for expiry
						select @expired = 1
				end
			end
		end
	end

	select @agent_id, @name, 0, @expired where @agent_id is not NULL
end
GO
GRANT EXECUTE ON [sys].[sp_MShelp_merge_agentid] TO [public] AS [dbo]
GO
