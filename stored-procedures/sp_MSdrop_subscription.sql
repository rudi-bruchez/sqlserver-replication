SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdrop_subscription]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdrop_subscription] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdrop_subscription]
	@publisher [sysname],
	@publisher_db [sysname],
	@subscriber [sysname],
	@article_id [int],
	@subscriber_db [sysname],
	@publication [sysname],
	@article [sysname]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	declare @publisher_id smallint
	declare @subscriber_id smallint
	declare @name nvarchar (100)
	declare @retcode int
	declare @push tinyint
	declare @anonymous tinyint
	declare @keep_for_last_run bit
	declare @virtual smallint
	declare @virtual_anonymous smallint
	declare @independent_agent bit
	declare @publication_id int
	declare @subscription_type int
	declare @thirdparty_flag bit
	declare @id             int
	declare @publication_name sysname
	declare @queued_sub_precount int

	--
	-- security check
	-- only db_owner can execute this
	--
	if (is_member ('db_owner') != 1) 
	begin
		raiserror(14260, 16, -1)
		return (1)
	end
	--
	-- security check
	-- Has to be executed from distribution database
	--
	if (sys.fn_MSrepl_isdistdb (db_name()) != 1)
	begin
		raiserror(21482, 16, -1, 'sp_MSdrop_subscription', 'distribution')
		return (1)
	end

	select @push = 0        -- const: push subscription type 
	select @anonymous = 2   -- const: push subscription type 
	select @virtual = -1    -- const: virtual subscriber id 
	select @virtual_anonymous = -2  -- const: virtual anonymous subscriber id 

	-- Select the current count of the queued subscribers prior to 
	-- dropping this subscription
	select @queued_sub_precount = count(*) from dbo.MSsubscriptions 
	where update_mode in (2,3,4,5,6,7)

	-- Save off name for dummy status row
	select @publication_name = @publication

	-- Check if publisher is a defined as a distribution publisher in the current database
	exec @retcode = sys.sp_MSvalidate_distpublisher @publisher, @publisher_id OUTPUT
	if @retcode <> 0
	begin
		return(1)
	end

    -- Check if subscriber exists
    if @subscriber is null
    begin
        select @subscriber_id = @virtual
        -- hardcoded in sp_MSadd_subscription
        select @subscriber_db = 'virtual'
    end
    else
        select @subscriber_id = srvid from MSreplservers, MSsubscriber_info where 
            UPPER(srvname) = UPPER(@subscriber) and
            UPPER(subscriber) = UPPER(@subscriber) and
            UPPER(publisher) = UPPER(@publisher)
    if @subscriber_id is NULL
    begin
        raiserror (20032, 16, -1, @subscriber, @publisher) 
        return (1)
    end

	-- If publication exists this is a post 6.x publisher
	if @publication is not NULL
	begin
		select @publication_id = publication_id,
			   @thirdparty_flag = thirdparty_flag
			from dbo.MSpublications where
			publisher_id = @publisher_id and
			publisher_db = @publisher_db and
			publication = @publication
			
		-- Get article_id 
		if @article is not NULL and @article_id = 0
		begin
			select @article_id = article_id from MSarticles where 
				publisher_id = @publisher_id and
				publisher_db = @publisher_db and
				publication_id = @publication_id and
				article = @article
		end
		-- Check that subscription exists
		-- Only do the check for post 6x publisher
		if not exists (select * from dbo.MSsubscriptions where 
			publisher_id = @publisher_id and 
			publisher_db = @publisher_db and 
			publication_id = @publication_id and
			subscriber_id = @subscriber_id and
			subscriber_db = @subscriber_db)
		begin
			if @thirdparty_flag = 1
			begin
				raiserror (14050, 16, -1)
				return(1)
			end
			else
				return (0)
		end
	end

	-- get the subscription type
	-- used when dropping dist agent
	select @subscription_type = subscription_type, 
		@independent_agent = independent_agent
		from dbo.MSsubscriptions where
		publisher_id = @publisher_id and
		publisher_db = @publisher_db and
		(publication_id = @publication_id or
		 @publication_id is NULL) and
		(@article_id is NULL or
		article_id = @article_id) and
		(subscriber_id = @subscriber_id and
		(subscriber_db = @subscriber_db or @subscriber_id = @virtual))

	begin transaction
	save transaction MSdrop_subscription

	-- Delete the subscription 
	-- For anonymous type, delete virtual anonymous subscription also
	-- if deleting the  virtual subscription 
	-- (since there can be only one subscriber_id per article, subscriber_db doesn't matter)
	delete from dbo.MSsubscriptions where
		publisher_id = @publisher_id and
		publisher_db = @publisher_db and
		(publication_id = @publication_id or
		 @publication_id is NULL) and
		(@article_id is NULL or
		article_id = @article_id) and
		((subscriber_id = @subscriber_id and
		(subscriber_db = @subscriber_db or @subscriber_id = @virtual)) or
		-- Delete virtual anonymous subscription 
		-- if deleting virtual subscription for a anonymous publication
	   (@subscriber_id = @virtual and subscriber_id = @virtual_anonymous))

	if @@error <> 0
	begin
		if @@trancount > 0
		begin
			rollback transaction MSdrop_subscription
			commit transaction  -- to finish off the tran we started in this proc (though 
							-- work was rolled back to savepoint)
		end
		return 1
	end
	
	-- If it is the last subscription for the distribution agent, drop the dist agent
	if not exists (select * from dbo.MSsubscriptions    where
		publisher_id = @publisher_id and
		publisher_db = @publisher_db and
		(publication_id = @publication_id or
		@publication_id is NULL or
		 @independent_agent = 0 ) and
		independent_agent = @independent_agent and
		subscriber_id = @subscriber_id and
		subscriber_db = @subscriber_db and
		subscription_type = @subscription_type)
	begin
		-- Harded coded in sp_MSadd_subscription.
		if @independent_agent = 0
			select @publication = 'ALL'
		/*
		** Get agentid to check history record
		*/
		select @id=id from MSdistribution_agents where 
		publisher_id = @publisher_id and
		publisher_db = @publisher_db and
		publication = @publication and
		subscriber_id = @subscriber_id and
		subscriber_db = @subscriber_db

	/*
	** If the subscription has not yet been synced, there is no need for subscriber side cleanup 
	** therefore no need for the last agent run.
	*/
	if exists (select * from MSdistribution_history where agent_id = @id)
		select @keep_for_last_run = 0 -- default is not to do cleanup
	else 
		select @keep_for_last_run = 0


	/*
	** Delete distribution task.
	*/
		execute @retcode = sys.sp_MSdrop_distribution_agent 
			@publisher_id = @publisher_id,
			@publisher_db = @publisher_db,
			@publication = @publication,
			@subscriber_id = @subscriber_id,
			@subscriber_db = @subscriber_db,
			@subscription_type = @subscription_type,
			@keep_for_last_run = @keep_for_last_run  

		if @@error <> 0 or @retcode <> 0
		begin
			if @@trancount > 0
			begin
				rollback transaction MSdrop_subscription
				commit transaction  -- to finish off the tran we started in this proc (though 
								-- work was rolled back to savepoint)
			end
			return 1
		end
	end

	
	-- Delete anonymous agents that are not in subscription table anymore
	-- It is due to dropping articles. Don't raise messages
	if @subscriber_id = @virtual
	begin
		delete MScached_peer_lsns 
			where agent_id in (select msda.id 
								from MSdistribution_agents msda
									join dbo.MSsubscriptions mss
									on msda.anonymous_agent_id <> mss.agent_id
								where msda.anonymous_agent_id is not null)
		 if @@error <> 0
		begin
			if @@trancount > 0
			begin
				rollback transaction MSdrop_subscription
				commit transaction  -- to finish off the tran we started in this proc (though 
								-- work was rolled back to savepoint)
			end
			return 1
		end					
			
		delete MSdistribution_agents where
			anonymous_agent_id is not null and 
			not exists (select * from dbo.MSsubscriptions s where
				s.agent_id = anonymous_agent_id)


		if @@error <> 0
		begin
			if @@trancount > 0
			begin
				rollback transaction MSdrop_subscription
				commit transaction  -- to finish off the tran we started in this proc (though 
								-- work was rolled back to savepoint)
			end
			return 1
		end
	end


	-- delete any rows in syncstate tracking table

	delete MSsync_states where 
		publisher_id = @publisher_id and
		publisher_db = @publisher_db and
		publication_id = @publication_id 

	if @@error <> 0
	begin
		if @@trancount > 0
		begin
			rollback transaction MSdrop_subscription
			commit transaction  -- to finish off the tran we started in this proc (though 
							-- work was rolled back to savepoint)
		end
		return 1
	end


	commit transaction
end
GO
GRANT EXECUTE ON [sys].[sp_MSdrop_subscription] TO [public] AS [dbo]
GO
