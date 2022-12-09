SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSadd_merge_anonymous_agent]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSadd_merge_anonymous_agent] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSadd_merge_anonymous_agent]
	@publisher_id [smallint],
	@publisher_db [sysname],
	@publication [sysname],
	@subscriber_db [sysname],
	@subscriber_name [sysname],
	@subid [uniqueidentifier],
	@first_anonymous [int],
	@subscriber_version [int],
	@publisher_engine_edition [int]
WITH EXECUTE AS CALLER
AS
begin
	declare @min_valid_day  datetime
	declare @merge_type     int
	declare @profile_id     int
	declare @subscriber_id  smallint
	declare @agent_name     sysname
	declare @agent_id       int
	declare @retcode        int
	declare @publication_id int
	declare @not_exist      bit
	declare @last_status	int
	declare @last_history	datetime
	declare @merge_jobid	uniqueidentifier
	declare @by_pass		bit
	declare @retention		int
	declare @retention_period_unit tinyint
	declare @success		int
	declare @expired		int
	declare @dropped		int
	declare @allow_anonymous bit
	declare @publisher		sysname
	declare @subscriber_name_current sysname

	--
	-- security check
	-- Has to be executed from distribution database
	-- PAL check is done after getting publication metadata
	--
	if (sys.fn_MSrepl_isdistdb (db_name()) != 1)
	begin
		raiserror(21482, 16, -1, 'sp_MSadd_merge_anonymous_agent', 'distribution')
		return (1)
	end
	
	select @dropped = 0
	select @expired = 0
	select @success = 2
	select @by_pass = 0

    /*
    ** This stored procedure does not really add a job at distribution database;
    ** if add a row in dbo.MSmerge_agent table for anonymous subscription for the 
    ** purpose of history logging
    */
	-- @publisher_id is always from master..sysservers, so we need to fetch from MSreplservers
	select @publisher_id = sys.fn_MSrepl_getsrvidfromdistdb(@publisher_id)

	-- Check to see if the publication is valid and allows anonymous subscribers
	select @publication_id = publication_id, @allow_anonymous = allow_anonymous, @retention = retention,
			@retention_period_unit = retention_period_unit
	from dbo.MSpublications where
		publisher_id = @publisher_id and
		publisher_db = @publisher_db and
		publication = @publication

    if @publication_id is null
    begin
        RAISERROR (21040, 16, -1, @publication)
        return 1
    end
    
    select @publisher = srvname from MSreplservers where srvid = @publisher_id

	if @allow_anonymous = 0
	begin
		RAISERROR (21084, 16, -1, @publication)
		return 1
	end

	if @subscriber_name is null
		select @subscriber_name = N''

	if @retention is NULL or @retention =0
		select @by_pass = 1

	--
	-- PAL Security check
	--
	exec @retcode = sys.sp_MScheck_pull_access
		@publication_id = @publication_id, @agent_type = 1
	if @retcode <> 0 or @@error <> 0
		return (1)

	select @not_exist = 0
	SELECT @merge_type = 4
	select @subscriber_id = 0  -- For anonymous subscribers, ID is always 0 

	SELECT @profile_id = profile_id
	FROM msdb..MSagent_profiles
	WHERE agent_type = @merge_type
		AND def_profile = 1

	IF @profile_id IS NULL
		RETURN (1)

	/*
	** This is to handle Jet only
	*/
	IF @subid = '00000000-0000-0000-0000-000000000000'
	begin
		select @subid = anonymous_subid from dbo.MSmerge_agents 
				where publisher_id=@publisher_id and 
					  publisher_db = @publisher_db and 
					  publication = @publication and 
					  subscriber_name = @subscriber_name 
					  and subscriber_db = @subscriber_db
		if @subid = '00000000-0000-0000-0000-000000000000'
			select @subid = newid()
		else
			select @first_anonymous = 1   -- for Jet, schemaversion should not be 0 in this path.
	end
		 
	IF NOT EXISTS (select * from dbo.MSmerge_agents where anonymous_subid=@subid)
	begin

		if @first_anonymous <= 0   --only add agent entry for initial subscription only. 
		begin
			select @not_exist = 1
			
			begin tran 
			
			exec @retcode = sys.sp_MScheck_subscription_count_internal @mode = 1, @publisher = @publisher, @publisher_engine_edition = @publisher_engine_edition,	
							@about_to_insert_new_subscription=1
			if @@error <> 0 or @retcode <> 0
			begin
				if @@trancount > 0
					commit tran
				return 1
			end
				
			-- Generate a job GUID for remote agents. This will be used by the UI to uniquely
			-- identify rows returned by the enums
			set @merge_jobid = newid();

			insert into dbo.MSmerge_agents (name, publisher_id, publisher_db, publication, 
						subscriber_id, subscriber_db, anonymous_subid, job_id, profile_id, subscriber_name)
					VALUES (convert(nvarchar(40), @subid), @publisher_id, @publisher_db, @publication, 
							@subscriber_id, @subscriber_db, @subid, @merge_jobid, @profile_id, @subscriber_name)
						 
			commit tran
		end
		else
			select @dropped  =1
	end

	select @agent_id = id, @agent_name = name, @subscriber_name_current = subscriber_name from dbo.MSmerge_agents 
		where anonymous_subid=@subid  -- subid guarantees uniqueness

	if @subscriber_name <> @subscriber_name_current and  @subscriber_name is not null and @subscriber_name <> N''
	begin
		-- Due to a bug in the upgrade code in yukon RTM that has been fixed in SP2 the subscriber_name column of MSmerge_agents may not be correct for anonymous 
		-- subscribers if the database has been upgraded from shiloh to pre yukon SP2 build. Running the following query to do the fixup.
		update dbo.MSmerge_agents set subscriber_name = @subscriber_name
			where anonymous_subid=@subid  -- subid guarantees uniqueness
	end


	if @by_pass = 0 and @subscriber_version < 90 --by pass the checking if retention is NULL or 0 or if yukon
	begin
		select @min_valid_day = sys.fn_add_units_to_date(-@retention, @retention_period_unit, getdate())

		-- only do history based expiration if there is a valid successful run information available.    	
		-- If we do not find the history for the last successful run we will not cleanup.
		-- however a seperate cleanup happens that uses the last_sync_time on the publisher. So
		-- even if we do not cleanup here sp_MSdrop_expired_mergesubscription will take care of it
		select Top 1 @last_status = runstatus, @last_history = end_time from dbo.MSmerge_sessions where agent_id = @agent_id and runstatus=2
					order by session_id DESC
	   
		/*
		** This anonymous subscription is gone for too long to be efficiently reconciled. Either reinitialization or
		** re-deployment of this subscription is needed. Merge agent will fail.
		*/
		if @last_history is not NULL
		begin
			if @last_history < @min_valid_day and @first_anonymous <> 0	--do not check for re-initialized replicas.
				select @expired = 1
		end
   end

	select @agent_id, @agent_name, @expired where @dropped = 0 --return empty result set 
end
GO
GRANT EXECUTE ON [sys].[sp_MSadd_merge_anonymous_agent] TO [public] AS [dbo]
GO
