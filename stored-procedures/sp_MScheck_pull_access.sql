SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MScheck_pull_access]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MScheck_pull_access] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MScheck_pull_access]
	@agent_id [int],
	@agent_type [int],
	@publication_id [int],
	@raise_fatal_error [bit]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on
	
    declare @retcode int,
			@login_time datetime,
			@isntname bit,
    		@offensive_pub_id int,
			@login sysname,
			@publication sysname,
			@spid smallint

    -- sysadmin or db_owner have access
    if is_srvrolemember('sysadmin') = 1 or is_member('db_owner') = 1
        return 0

    -- Defect 11687782: current version of CL(MI) blocks sp_procoption and thus there is no startup/fallback callback set for sp_MSrepl_startup, but it can be called directly here when required
    IF sys.fn_MSrepl_editionid() = 32 AND object_id('tempdb.dbo.MSdistributor_access', 'U') is NULL BEGIN
        exec @retcode = sys.sp_MSrepl_startup_internal_dbo
        if @@error <> 0 or @retcode <> 0
            return (1)
    END

	-- if this table does not exist then restrict access. This most likely means the proc 
	-- is being call on a non-distributor or the distributor is not fully installed
    if object_id('tempdb.dbo.MSdistributor_access', 'U') is NULL
    begin
		raiserror (14126, 11, -1)
        return (1)
    end

	-- Check if database is configured as a distributor database.
	if not exists (select * 
    				from msdb..MSdistributiondbs 
    				WHERE name = db_name() collate database_default)
    begin
		raiserror (14126, 11, -1)
        return (1)
    end

	select @spid = @@spid
    -- Need login_time to uniquely identify a connection.
    select @login_time = login_time from sys.dm_exec_sessions where session_id = @spid

    if @agent_id <> 0
    begin
    	if @agent_type = 1 -- merge
    	begin
	    	-- For merge change to use publication_id
	        select @publication_id = p.publication_id 
				from dbo.MSmerge_agents a, 
					MSpublications p 
				where a.id = @agent_id and
	                a.publisher_id = p.publisher_id and
	                a.publisher_db = p.publisher_db and
	                a.publication = p.publication

	        select @agent_id = 0
	    end
       	else if @agent_type = 0 -- tran
		begin
			-- retrieve the anonymous agent id if we find one
	    	-- if we don't then just use the original agent_id
	    	-- we do this because some of the calls to this procedure
	    	-- pass in the id from MSdistribution_agents instead
	    	-- of the agent_id from MSsubscription. anonymous_agent_id
	    	-- is the value from MSsubscription which is needed
	    	select @agent_id = isnull(anonymous_agent_id, @agent_id) 
	    		from MSdistribution_agents 
	    		where id = @agent_id 
	    			and anonymous_agent_id is not null
	    end 
    end

    -- if we are in cache, return success
    if exists (select * 
				from tempdb.dbo.MSdistributor_access 
				where spid = @spid 
        			and login_time = @login_time 
        			and db_id = db_id()         			
        			and (
        					(publication_id = @publication_id 
	       						and agent_id = @agent_id 
	        					and agent_type = @agent_type)
	        				or
				        	-- All 0s is used by sp_MSadd_repl_error, which just require the 
				        	-- login to be in cache regardless of the publication id and agent_id.
				        	-- This means that once a agent get into the distribution db, it
				        	-- can add any error.
				        	(@publication_id = 0 
				        		and @agent_id = 0 
				        		and @agent_type = 0)
				        ))
        return (0)

    -- Cover sp_MSadd_repl_error case
    if @publication_id = 0 and @agent_id = 0 and @agent_type = 0
    begin
        raiserror (14126, 11, -1)
        return (1)
    end

    -- Check to see if the login is NT login
    select @isntname = isntname from master.dbo.syslogins where sid = suser_sid()

    -- If the login does not exists, check to see if the login is a NT login that
    -- has access to the server.
    if @isntname is null
    begin
        -- If it is an NT login
        if suser_sid() is not null
            select @isntname = 1
        -- If it is not an NT login
        else
            select @isntname = 0
    end

    if @agent_id <> 0 
    begin
        select top 1 @offensive_pub_id = s.publication_id 
			from MSsubscriptions s 
			where s.agent_id = @agent_id 
				and not exists (select * 
									from MSpublication_access l 
									where l.publication_id = s.publication_id 
										-- Current login has no access
										and (l.sid = suser_sid() 
												or (@isntname = 1 
														and exists (select * 
																		from master.dbo.syslogins 
																		where sid = l.sid 
																			and isntgroup = 1 
																			and is_member(l.login) = 1))))

        -- check if we found a publication we do not have access to
        if @offensive_pub_id is not null
			goto NO_ACCESS
		
		-- now check that we actually had a valid agent id before allowing user to continue
		if not exists(select * from MSsubscriptions where agent_id = @agent_id)
			goto NO_ACCESS
    end
    -- Check security based on publication_id
    else
    begin   
        if not exists (select * 
							from MSpublication_access l 
							where l.publication_id = @publication_id 
								and (l.sid = suser_sid() 
									or (@isntname = 1 
										and exists (select * 
														from master.dbo.syslogins 
														where sid = l.sid
															and isntgroup = 1 
															and is_member(l.login) = 1))))
        begin
            select @offensive_pub_id = @publication_id
            goto NO_ACCESS
        end
	end

    -- If we are here, we know that the connection has access and is not in the cache
    -- add it in to the cache.
        
    -- Clear the cache to keep it small.
    exec @retcode = dbo.sp_MSflush_access_cache
    if @retcode <> 0 or @@error <> 0
        return (1)
        
	if @spid is not null and @login_time is not null
	begin
		insert tempdb.dbo.MSdistributor_access (spid, db_id, agent_id, agent_type, publication_id, login_time) 
	        values (@spid, db_id(), @agent_id, @agent_type, @publication_id, @login_time)
	    if @@error <> 0
			return (1)
	end

    return (0)

NO_ACCESS:
	-- We don't have access if we reach here, return error
    select @login = suser_sname(suser_sid()),
    		@publication = publication 
		from MSpublications 
		where publication_id = @offensive_pub_id

	if @offensive_pub_id is null or @publication is null
	begin
		-- You do not have the required permissions to complete the operation.
		if @raise_fatal_error = 1
			raiserror(14126, 16, -1)
		else
			raiserror(14126, 10, -1)
	end
	else
	begin
		-- The login '@login' does not have access permission on publication 
		-- '@publication' because it is not in the publication access list.
		if @raise_fatal_error = 1
	        raiserror(21049, 16, -1, @login, @publication)
	    else
         	raiserror(21049, 10, -1, @login, @publication)
	end
	
    return(1)
end
GO
GRANT EXECUTE ON [sys].[sp_MScheck_pull_access] TO [public] AS [dbo]
GO
