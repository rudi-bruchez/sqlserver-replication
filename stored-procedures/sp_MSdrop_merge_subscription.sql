SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdrop_merge_subscription]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdrop_merge_subscription] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdrop_merge_subscription]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname],
	@subscription_type [nvarchar](15)
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	declare @publisher_id smallint
	declare @subscriber_id smallint
	declare @retcode int
	declare @publication_id int
	declare @job_id binary(16)
	declare @thirdparty_flag bit
	declare @id                 int
	declare @keep_for_last_run  bit

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
		raiserror(21482, 16, -1, 'sp_MSdrop_merge_subscription', 'distribution')
		return (1)
	end
	-- Check if publisher is a defined as a distribution publisher in the current database
	exec @retcode = sys.sp_MSvalidate_distpublisher @publisher, @publisher_id OUTPUT
	if @retcode <> 0
	begin
		return(1)
	end

	-- Get the publication information 
	select @publication_id = publication_id,
		@thirdparty_flag = thirdparty_flag
		from dbo.MSpublications where
		publisher_id = @publisher_id and
		publisher_db = @publisher_db and
		publication = @publication
	if @publication_id is NULL
	begin
		raiserror(20026, 16, -1, @publication)
		return (1)
	end

    -- Check if subscriber exists
    select @subscriber_id = srvid from MSreplservers where UPPER(srvname) = UPPER(@subscriber) 
    if @subscriber_id is NULL
    begin
	    if not exists (select * from MSmerge_subscriptions where 
	        publisher_id = @publisher_id and 
	        publisher_db = @publisher_db and 
	        publication_id = @publication_id and
	        UPPER(subscriber) = UPPER(@subscriber) and
	        subscriber_db = @subscriber_db)
	    begin
            raiserror (20032, 16, -1, @subscriber, @publisher) 
    	    return (1)
		end    	    
	end

	-- Check that subscription exists
	if not exists (select * from dbo.MSmerge_subscriptions where 
		publisher_id = @publisher_id and 
		publisher_db = @publisher_db and 
		publication_id = @publication_id and
		UPPER(subscriber) = UPPER(@subscriber) and
		subscriber_db = @subscriber_db)
	begin
		if @thirdparty_flag = 1
		begin
			--UNDONE : Add this back again when we add pull subscriptions metedata at the distributor
			--raiserror (14050, 10, -1)
			return(1)
		end
		else
			return (0)
	end

	begin tran
	save transaction MSdrop_merge_subscription

	-- Delete the subscription 
	-- For anonymous type, delete virtual anonymous subscription also
	-- if deleting the  virtual subscription 
	-- (since there can be only one subscriber_id per article, subscriber_db doesn't matter)
	delete from dbo.MSmerge_subscriptions where
		publisher_id = @publisher_id and
		publisher_db = @publisher_db and
		publication_id = @publication_id and
		UPPER(subscriber) = UPPER(@subscriber) and
		subscriber_db = @subscriber_db
	if @@error <> 0
	begin
		goto FAILURE
	end

	/*
	** Get agentid to check history record
	*/
	select @id=id from dbo.MSmerge_agents where 
		publisher_id = @publisher_id and
		publisher_db = @publisher_db and
		publication = @publication and
		UPPER(subscriber_name) = UPPER(@subscriber) and
		subscriber_db = @subscriber_db

	/*
	** If the subscription has not yet been synced, there is no need for subscriber side cleanup 
	** therefore no need for the last agent run.
	*/
	if exists (select * from dbo.MSmerge_history where agent_id = @id) and @subscription_type='push'
		select @keep_for_last_run = 0 -- cleanup code is not activated.
	else 
		select @keep_for_last_run = 0
	
	/*
	** Delete Merge agent and meta data, if it exists
	*/
	EXECUTE @retcode = sys.sp_MSdrop_merge_agent 
		@publisher = @publisher,
		@publisher_db = @publisher_db,
		@publication = @publication,
		@subscriber = @subscriber,
		@subscriber_db = @subscriber_db,
		@keep_for_last_run = @keep_for_last_run
	if @@error <> 0 or @retcode <> 0
	begin
		goto FAILURE
	end

	commit transaction
	return 0
FAILURE:
	if @@trancount > 0
	begin   
		ROLLBACK TRANSACTION MSdrop_merge_subscription
		COMMIT TRANSACTION
	end
	return 1
end
GO
GRANT EXECUTE ON [sys].[sp_MSdrop_merge_subscription] TO [public] AS [dbo]
GO
