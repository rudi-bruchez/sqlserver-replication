SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MShelp_distribution_agentid]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MShelp_distribution_agentid] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MShelp_distribution_agentid]
	@publisher_id [smallint],
	@publisher_db [sysname],
	@publication [sysname],
	@subscriber_id [smallint],
	@subscriber_db [sysname],
	@subscription_type [int],
	@subscriber_name [sysname],
	@anonymous_subid [uniqueidentifier],
	@reinitanon [bit]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	declare @independent_agent bit
	declare @xact_seqno_length int
	declare @agent_id int
	declare @third_party_flag bit
	declare @retcode int
	declare @anonymous int
	declare @sub_agent_id int
	declare @allow_subscription_copy bit
	declare @immediate_sync bit
	declare @endraiserror bit

	select @anonymous 		= 2
	select @endraiserror 	= 0
	
	if @publication is null
		select @independent_agent = 0
	else
		select @independent_agent = 1
	
	-- @publisher_id and @subscriber_id are always from master..sysservers, so we need to fetch from MSreplservers
	select @publisher_id = sys.fn_MSrepl_getsrvidfromdistdb(@publisher_id)
	If  @subscription_type <>  @anonymous -- for Anonymous subscribers, @subscriber_id is passed as 0. In all other case, we should do translation
		select @subscriber_id = sys.fn_MSrepl_getsrvidfromdistdb(@subscriber_id)

    select  top 1
        @third_party_flag = thirdparty_flag,
		@allow_subscription_copy = allow_subscription_copy,
		@immediate_sync = immediate_sync
		from dbo.MSpublications where
		publisher_id = @publisher_id and
		publisher_db = @publisher_db and
		publication = @publication or 
		(@publication is null and independent_agent = 0)

	-- Get agent id
	if @subscription_type = @anonymous
	begin
		exec @retcode = sys.sp_MSadd_anonymous_agent
			@publisher_id   = @publisher_id,
			@publisher_db   = @publisher_db,
			@publication    = @publication,
			@subscriber_db  = @subscriber_db,
			@subscriber_name = @subscriber_name,
			@anonymous_subid =  @anonymous_subid output,
			@agent_id = @agent_id output,
			@reinitanon = @reinitanon
		if @@error <> 0 or @retcode <> 0
			return (1)

		-- Refer to sp_MSget_subscription_guid
		select @sub_agent_id = virtual_agent_id from
			MSdistribution_agents where
			id = @agent_id
	end 
	else
	begin
		select @agent_id = id
		from MSdistribution_agents where
			 publisher_id = @publisher_id and
			 publisher_db = @publisher_db and
			 (publication = @publication or
			 (@publication is null and publication = N'ALL')) and
			 subscription_type = @subscription_type and
			 subscriber_id = @subscriber_id and
			 subscriber_db = @subscriber_db

		-- If cannont find the agent entry, ignore @subscriber_db and try again 
		-- for non SQL subscribers
		-- Note that this preserved backward compatibility for 7.0 publisher, 7.0 pull distribution agent or 6.5 pub.
		-- In 7.0, we hard code name 'DSN'.
		-- In 6.5 pub, the db name is real database name.
		-- In 8.0, distribution agent sends in unlocalized '(default destination)' as default db name for 
		-- non SQL subscribers..
		if @agent_id is null 
		begin
			declare @publisher sysname
			declare @subscriber sysname
			select @publisher = srvname from MSreplservers where
				srvid = @publisher_id
			select @subscriber = srvname from MSreplservers where
				srvid = @subscriber_id
			if exists (select * from MSsubscriber_info where
				publisher = @publisher and
				subscriber = @subscriber and
				type <> 0)
			begin
				select @agent_id = id
				from MSdistribution_agents where
					 publisher_id = @publisher_id and
					 publisher_db = @publisher_db and
					 (publication = @publication or
					 (@publication is null and publication = N'ALL')) and
					 subscription_type = @subscription_type and
					 subscriber_id = @subscriber_id 
			end
		end

		select @sub_agent_id = @agent_id
	end

	-- If the agent id is still null here we have a problem and must either 
	-- raiserror and exit or perform more processing and do a deferred raiserror
	if @agent_id is null
	begin
		-- If cannot find the publication and the agent, raise
		--  error saying invalid publication.
		-- 
		-- Note: 
		-- We can not fail if publication not exists but agent 
		-- exists It is an upgrade case. 
		if @third_party_flag is null
		begin
			-- The publication(s) does not exist just exit completely
			RAISERROR (21073, 16, -1)
			return(1)
		end
		
		-- Set flag to perform the deferred raiseerror at the end of the proc
		select @endraiserror = 1

		-- Attempt to retrieve the agent id for the invalid subscription or the 
		-- subscription whose publication does not allow independednt agents
		-- this will allow our agents to continue on and log history information
		select top 1 @agent_id = agent_id
			from dbo.MSpublications mp,
					MSsubscriptions ms
			where mp.publication				= @publication	
					and mp.publisher_id 		= @publisher_id 
					and	mp.publisher_db 		= @publisher_db
					and ms.publisher_id 		= mp.publisher_id
					and	ms.publisher_db 		= mp.publisher_db
					and ms.subscription_type 	= @subscription_type
					and ms.subscriber_id 		= @subscriber_id 
					and ms.subscriber_db 		= @subscriber_db

		-- without the agent id we can not continue but must still raiserror
		if @agent_id is null
		begin
			goto EndRaiseError
		end

		select @sub_agent_id = @agent_id
	end

	-- Reset null properties
	-- It is an upgrade case.
	if @third_party_flag is null 
		select @third_party_flag = 0
	if @allow_subscription_copy is null
		select @allow_subscription_copy = 0

	/*
	** Get the time when the subscription is active and succeed.
	*/
	/*
	select Top 1 @last_status=runstatus, @last_sync = time from MSdistribution_history 
		where agent_id = @agent_id order by timestamp DESC
	
	if @last_status = 6 and EXISTS (select * from MSdistribution_history where agent_id = @agent_id and runstatus = @success) 
				select Top 1 @last_sync = time from MSdistribution_history where agent_id = @agent_id and runstatus = @success
						order by timestamp DESC	

	if @last_sync is not NULL and @independent_agent = 1 --by pass the retention check for non-independent agnt
	begin
		if (@last_sync < dateadd(hour, -@retention, getdate()))
		   and (@retention <> 0)
 				select @expired = 1 
	end
	*/
 /* 
	** Avoid returning a NULL value 
	** Otherwise, distribution agent may fail
	*/
	select @xact_seqno_length = 0

	/* 
	**  Get the lengh of xact_seqno
	**   Currently, unique across the publisher
	*/
	select top 1 @xact_seqno_length = DATALENGTH(subscription_seqno)
	from dbo.MSsubscriptions s where
		agent_id = @sub_agent_id
		
	/* xact_seqno for snapshot trans are longer for native publishers*/
	if @third_party_flag = 0
	begin
		select @xact_seqno_length = 14
	end

	-- Security check. Do it here to let the agent fail at the beginning
	exec @retcode = sys.sp_MScheck_pull_access
		@agent_id = @sub_agent_id,
		@agent_type = 0 -- distribution agent
	if @@error <> 0 or @retcode <> 0
		return (1)
	
	-- Get update_mode
	declare @update_mode int
	
	-- Use max because:
	-- One agent can have mixed read only (0) and synctran (1) subscriptions. 
	-- The update mode value
	-- is used in subscriber triggers. It is ok to set update mode to synctran
	-- in mixed case because the triggers will not be create for read only.
	-- Queued mode require independent agent.
	select @update_mode = max(update_mode) from dbo.MSsubscriptions where
		agent_id = @agent_id
	
	-- For anonymous agents, update_mode is read only.
	if @update_mode is null
		set @update_mode = 0

	-- Get attach_version guid
	declare @attach_version binary(16)
	if @allow_subscription_copy <> 0
	begin
		declare @publication_id int
		declare @virtual_agent_id int
		declare @virtual smallint
		set @virtual = -1

		-- Get publication_id
		select @publication_id = publication_id
			from dbo.MSpublications where
			publisher_id = @publisher_id and
			publisher_db = @publisher_db and
			publication = @publication 

		if @publication_id is null
		begin
			RAISERROR (21040, 16, -1, @publication)
			return 1
		end

		-- Get version agent_id
		select top 1 @virtual_agent_id = agent_id from dbo.MSsubscriptions where
			publisher_id = @publisher_id and
			publisher_db = @publisher_db and
			publication_id = @publication_id and
			subscriber_id = @virtual

		select @attach_version = subscription_guid from MSdistribution_agents
			where id = @virtual_agent_id
	end
	else
		-- set a irrelevent guid. It should never be used.
		select @attach_version = newid()

	-- Get subscription guid
	-- Use sub_agent_id so that both anonymous and well-known work.
	-- Refer to sp_MSget_subscription_guid. You need to make change to that sp when changing
	-- this.
	declare @subscription_guid binary(16)
	select @subscription_guid = subscription_guid from MSdistribution_agents where
		id = @sub_agent_id
	
	select 'xact_seqno_length' = @xact_seqno_length,
			'agent_id' = @agent_id,
			'agent_name' = distribAgent.name,
			'anonymous subid' = distribAgent.anonymous_subid,
			'expired ' = convert(int, 0),
			'dts_package_name' = distribAgent.dts_package_name,
			'dts_package_password' = sys.fn_repldecryptver4(distribAgent.dts_package_password),
			'dts_package_location' = distribAgent.dts_package_location,
			'immediate_sync' = @immediate_sync,
			'allow_subscription_copy' = @allow_subscription_copy,
			'queue_id' = distribAgent.queue_id,
			'update_mode' = @update_mode,
			'attach_version' = @attach_version,
			'subscription_guid' = @subscription_guid,
			'queue_server' = distribAgent.queue_server,
			'reset_partial_snapshot_progress' = distribAgent.reset_partial_snapshot_progress,
			distribAgent.subscriptionstreams,
			profileName.profile_name
		from MSdistribution_agents as distribAgent
		INNER JOIN msdb..MSagent_profiles as profileName
		on distribAgent.profile_id = profileName.profile_id
		where distribAgent.id = @agent_id
	if @@error <> 0 return 1
	
EndRaiseError:
	if @endraiserror = 1
	begin
		-- Raise a special error for a common error case: user specified publication
		-- name for non independent agent publication.
		-- If the specified publication name is in dbo.MSpublications table then
		-- the publication is configured to use a non-independent distribution
		-- agent. Raise a different error if this is the case
		if @publication is not null and 
			exists (select * from dbo.MSpublications 
					where publication = @publication and 
						  publisher_id = @publisher_id and
						  publisher_db = @publisher_db and
						  independent_agent = 0)  
		begin
			RAISERROR (21133, 16, -1, @publication)
		end
		-- If anything else then we know the subscription is bad
		else
		begin
			 -- Invalid subscription
			RAISERROR (21056, 16, -1, @publication)
		end
	
		return (1)
	end

	return (0)
end
GO
GRANT EXECUTE ON [sys].[sp_MShelp_distribution_agentid] TO [public] AS [dbo]
GO
