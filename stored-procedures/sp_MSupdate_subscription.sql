SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSupdate_subscription]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSupdate_subscription] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSupdate_subscription]
	@publisher [sysname],
	@publisher_db [sysname],
	@subscriber [sysname],
	@article_id [int],
	@status [int],
	@subscription_seqno [varbinary](16),
	@destination_db [sysname]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on
	declare @publisher_id smallint  
	declare @subscriber_id smallint
	declare @automatic tinyint
	declare @snapshot_seqno_flag bit
	declare @virtual smallint 
	declare @virtual_anonymous smallint 
	declare @retcode int
	declare @active tinyint
	declare @subscribed tinyint
	declare @agent_id int
	declare @sync_type tinyint
	declare @virtual_agent_id int
	declare @publication_id int
	declare @publisher_database_id int
	--
	-- security check
	-- only db_owner can execute this
	--
	if (is_member ('db_owner') != 1) 
	begin
		raiserror(14260, 16, -1)
		return (1)
	end
	
	select @automatic = 1
	select @virtual = - 1
	select @virtual_anonymous = - 2
	select @active = 2
	select @subscribed = 1

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
        select @destination_db = '%'
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

	select @publisher_database_id = id
	  from dbo.MSpublisher_databases
	 where publisher_db = @publisher_db
	   and publisher_id = @publisher_id 

	begin tran
	save transaction MSupdate_subscription

	if @status = @active
	begin
		-- Activating the subscription
		/*
		**  It will be used by:
		**  1. no_sync subscriptions
		**  2. subscriptions on immediate_sync pub that are activate 
		**  using virtual subscritpions's snapshots.
		**  3. snapshot agents for 6.5 publishers
		*/
		-- Get agent_id etc
		select @agent_id = agent_id, @sync_type = sync_type,
			@publication_id = publication_id
			from dbo.MSsubscriptions where
			publisher_id = @publisher_id and
			publisher_database_id = @publisher_database_id and
			article_id = @article_id and
			subscriber_id = @subscriber_id and 
			-- Use equal so 6.x publisher will get nothing (since @destination_db is '%')
			subscriber_db = @destination_db

		-- If immediate_sync publication and sync type is auto_sync
		-- Set the subscription_seqno and snapshot_seqno to be of the virtual subscription 
		-- for real subscription when activating the subscription.
		-- We have to do it for the whole publication to prevent the
		-- distribution agent from picking up partial snapshot transaction
		if  @subscriber IS NOT NULL AND
			@sync_type = @automatic and
			exists (select * from dbo.MSpublications p where
				-- publication_id is unique across dist db
				p.publication_id = @publication_id and
				p.immediate_sync = 1 
				)
		begin
			-- Get virtual agent_id
			select @virtual_agent_id = agent_id from dbo.MSsubscriptions where
				publisher_id = @publisher_id and
				publisher_database_id = @publisher_database_id and
				article_id = @article_id and
				subscriber_id = @virtual

			-- Note it is possible that the virtual subscriptions
			-- were deactivated during clean up.
			/* Update the subscription table for the whole publication */
			-- Note: You need to change sp_MSreset_subscription_seqno when you 
			-- change this query
			update dbo.MSsubscriptions  set 
				snapshot_seqno_flag =  
					(select subscription_seqno from dbo.MSsubscriptions rs2
						where
						rs2.agent_id = @virtual_agent_id and
						rs2.article_id = rs1.article_id),
				status =    
					(select status from dbo.MSsubscriptions rs2
						where
						rs2.agent_id = @virtual_agent_id and
						rs2.article_id = rs1.article_id),
				-- Use current date rather than virtual sub date for the
				-- calculation in cleanup 
				subscription_time = getdate(),
				subscription_seqno = 
					(select subscription_seqno from dbo.MSsubscriptions rs2
						where
						rs2.agent_id = @virtual_agent_id and
						rs2.article_id = rs1.article_id),
				publisher_seqno = 
					(select publisher_seqno from dbo.MSsubscriptions rs2
						where
						rs2.agent_id = @virtual_agent_id and
						rs2.article_id = rs1.article_id),
				ss_cplt_seqno = 
					(select ss_cplt_seqno from dbo.MSsubscriptions rs2
						where
						rs2.agent_id = @virtual_agent_id and
						rs2.article_id = rs1.article_id)
				from dbo.MSsubscriptions rs1 where
					agent_id = @agent_id and
					sync_type = @automatic and
					status = @subscribed            
			if @@ERROR <> 0
				goto UNDO
		end
		else
		begin
			update dbo.MSsubscriptions set status = @status, subscription_time = getdate(), 
				publisher_seqno = @subscription_seqno, ss_cplt_seqno = @subscription_seqno,
				-- Have to do this. Refer to anonymous agent "no init sync" option logic above
				-- and sp_MSset_snapshot_seqno.
				snapshot_seqno_flag = 0
			  from dbo.MSsubscriptions with (index(iMSsubscriptions)) 
				where
				  publisher_id = @publisher_id and
				  publisher_database_id = @publisher_database_id and
				  article_id = @article_id and
				  ((@subscriber_id <> @virtual and (subscriber_id = @subscriber_id and ((@destination_db = N'%') or (subscriber_db = @destination_db)) )) or
				  -- Activate virtual_anonymous but NOT virtual
				  -- This is for no init option for anonymous agent
				  -- Refer to sp_addsubscription , sp_MSget_repl_cmds_anonymous
				  -- and sp_MSset_snapshot_seqno
				  (@subscriber_id =  @virtual and subscriber_id = @virtual_anonymous))
			if @@error <> 0
				goto UNDO
		
			-- For 6.5 publishers.
			-- Snapshot agents of 6.5 publishers will call sp_changesubstatus which will
			-- RPC this stored procedure to activate the subscription. The RPC calls are
			-- not in one transaction.
			-- We have to do it for the whole publication to prevent the
			-- distribution agent from picking up partial snapshot transaction

			-- Get publication_id 
			-- The publication_id and sync type are set by SNAPSHOT agent 
			-- calling sp_MSset_snapshot_xact_seqno
			-- Don't do it if @subscriber_id is virtual to prevent virtual sub
			-- to be activated.
			if @destination_db = '%' and @subscriber_id <> @virtual
			begin
				declare @publication_id_6x int
				-- Get the publication_id.
				-- Note that if the sync_type is not automatic, the publication_id
				-- will be null. In this case, we will not do the later
				-- update (we don't need to)
				select top 1 @publication_id_6x = publication_id from dbo.MSsubscriptions 
					where   publisher_id = @publisher_id and
							publisher_database_id = @publisher_database_id and
							subscriber_id = @subscriber_id and 
							sync_type = @automatic and
							article_id = @article_id

				if @publication_id_6x <> NULL
				begin
					update dbo.MSsubscriptions set status = @status, subscription_time = getdate() 
					  from dbo.MSsubscriptions with (index(iMSsubscriptions))
						where
						  publisher_id = @publisher_id and
						  publisher_database_id = @publisher_database_id and
						  subscriber_id = @subscriber_id and 
						  sync_type = @automatic and
						  publication_id = @publication_id_6x and
						  status <> @status
					if @@error <> 0
						goto UNDO
				end
			end
		end
	end -- End activating the subscription
	else
	begin -- Deactivating the subscription or change it from 'subscribed' to 'initiated'
		/*
		**  If @status is @active, it will be used by:
		**  sp_reinitsubscription at publisher to reset the subscription status to 'subscribed'
		**  If @status is @initiated (2), it will be used by snapshot agent with 
		**  sp_MSactivate_auto_sub => sp_changesubstatus.
		*/
		update dbo.MSsubscriptions
		   set status = @status,
			   publisher_seqno = @subscription_seqno, 
			   ss_cplt_seqno = @subscription_seqno
		  from dbo.MSsubscriptions with (index(iMSsubscriptions))
			where
			publisher_id = @publisher_id and
			publisher_database_id = @publisher_database_id and
			article_id = @article_id and
			((@subscriber_id <> @virtual and (subscriber_id = @subscriber_id and ((@destination_db = N'%') or (subscriber_db = @destination_db)) )) or
			-- Deactivating both virtual and virtual anonymous
			(@subscriber_id =  @virtual and (subscriber_id = @virtual or (subscriber_id = @virtual_anonymous and
			-- When changing to @initiated, do not change activated virtual_anonymous_subscription.
			(status = @subscribed or snapshot_seqno_flag = 0)))))

		if @@error <> 0
			goto UNDO

		-- Set the reset_partial_snapshot_progress bit if we are reinitializing
		if @status = @subscribed
		begin
			update dbo.MSdistribution_agents
			   set reset_partial_snapshot_progress = 1
			  from dbo.MSdistribution_agents da
		inner join dbo.MSsubscriptions sub
				on (da.id = sub.agent_id
				or da.virtual_agent_id = sub.agent_id
				or da.anonymous_agent_id = sub.agent_id)
			 where
				sub.publisher_id = @publisher_id and
				sub.publisher_database_id = @publisher_database_id and
				sub.article_id = @article_id and
				((@subscriber_id <> @virtual and (sub.subscriber_id = @subscriber_id and ((@destination_db = N'%') or (sub.subscriber_db = @destination_db)) )) or
				-- Deactivating both virtual and virtual anonymous
				(@subscriber_id =  @virtual and (sub.subscriber_id = @virtual or (sub.subscriber_id = @virtual_anonymous and
				-- When changing to @initiated, do not change activated virtual_anonymous_subscription.
				(status = @subscribed or sub.snapshot_seqno_flag = 0))))) and
				-- Don't update virtual agents
				da.subscriber_id not in (@virtual, @virtual_anonymous)
			if @@error <> 0
				goto UNDO
		end
	end
	
	commit transaction
	return (0)

UNDO:
	if @@TRANCOUNT > 0
	begin
		ROLLBACK TRAN MSupdate_subscription
		COMMIT TRAN
	end
	return(1)
end
GO
GRANT EXECUTE ON [sys].[sp_MSupdate_subscription] TO [public] AS [dbo]
GO
