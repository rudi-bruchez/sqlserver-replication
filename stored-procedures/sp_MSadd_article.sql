SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSadd_article]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSadd_article] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSadd_article]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@article [sysname],
	@article_id [int],
	@destination_object [sysname],
	@source_object [sysname],
	@description [nvarchar](255),
	@source_owner [sysname],
	@destination_owner [sysname],
	@internal [sysname]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	declare @publisher_id smallint
	declare @publication_id int
	declare @retcode int
	declare @thirdparty_flag bit
	declare @immediate_sync bit
	declare @allow_anonymous bit
	declare @subscription_seqno binary(16)
	declare @subscribed tinyint
	declare @active tinyint

	select @subscribed = 1  
	select @active = 2
		
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
	-- sp_MSvalidate_distpublisher ensures this
	--
	/*
	if (sys.fn_MSrepl_isdistdb (db_name()) != 1)
	begin
		raiserror(21482, 16, -1, 'sp_MSadd_article', 'distribution')
		return (1)
	end
	*/
	-- Check if publisher is a defined as a distribution publisher in the current database
	exec @retcode = sys.sp_MSvalidate_distpublisher @publisher, @publisher_id OUTPUT
	if @retcode <> 0
	begin
		return(1)
	end

	-- Get publication id
	select @publication_id = publication_id,  
		@thirdparty_flag = thirdparty_flag,
		@immediate_sync = immediate_sync, @allow_anonymous = allow_anonymous 
		from dbo.MSpublications where
		publisher_id = @publisher_id and 
		publisher_db = @publisher_db and
		publication = @publication
	if @publication_id is NULL
	begin
		raiserror (20026, 11, -1, @publication)
		return (1)
	end

	-- Make sure article does not already exist
	if exists (select * from MSarticles where publication_id = @publication_id and
		publisher_id = @publisher_id and publisher_db = @publisher_db and article = @article)
	begin
		if @thirdparty_flag = 1
		begin
			raiserror (14030, 16, -1, @article, @publication)
			return (1)
		end
		else
		begin
			exec @retcode = sys.sp_MSdrop_article
				@publisher = @publisher,
				@publisher_db = @publisher_db,
				@publication = @publication,
				@article = @article
			if @retcode <> 0 or @@error <> 0
			begin
				return (1)
			end
		end
	end

	-- If it is a third party publication - check if a subscription exists
	-- for the publication already. If it does then we cannot add any
	-- articles - the existing subscriptions will have to dropped first and then
	-- resubscribed
	-- excluding virtual subscriptions.
	if (@thirdparty_flag = 1)
	begin
		if exists (select * from dbo.MSsubscriptions where 
				publisher_id = @publisher_id and 
				publisher_db = @publisher_db and 
				publication_id = @publication_id and
				subscriber_id >= 0)
		begin
			raiserror(21131, 16, -1, @publication)
			return (1)
		end
	end

	begin tran
	save tran MSadd_article

	-- Generate new article id when one is not provided by a 
	-- third party publisher or merge publication
	if @article_id is NULL
	begin
		if (@thirdparty_flag = 1)
		begin
			-- Generate unique id per publisher
			select @article_id = max(article_id) + 1 from MSarticles where 
				publisher_id = @publisher_id
		end
		else
		begin
			-- 6.5 behavior : retain for compatibility
			-- NOTE: article_id is incremented per publisher/publisher_db/publication
			select @article_id = max(article_id) + 1 from MSarticles where 
				publisher_id = @publisher_id and
				publisher_db = @publisher_db and
				publication_id = @publication_id
		end

		if @article_id is null
			select @article_id = 1
	end
	else
	begin
		--
		-- for third party publisher - validate the article id
		--
		if (@thirdparty_flag = 1)
		begin
			if exists (select * from MSarticles where
					article_id = @article_id and
					publisher_id = @publisher_id and
					publisher_db = @publisher_db and
					publication_id = @publication_id)
			begin
				if @@trancount > 0
				begin
					rollback tran MSadd_article
					commit tran
				end
				raiserror (14155, 16, 2)
				return (1)
			end
		end
	end

	insert into MSarticles (publisher_id, publisher_db, publication_id, 
							article, article_id, destination_object, 
		 					source_owner, source_object, description, destination_owner)
		values (@publisher_id, @publisher_db, @publication_id,
				@article, @article_id, @destination_object, 
				@source_owner, @source_object, @description, @destination_owner)
	if @@error <> 0
	begin
		if @@trancount > 0
		begin
			rollback tran MSadd_article
			commit tran
		end
		return (1)
	end

	-- For third party publications create immediate sync and anonymous virtual subscription
	-- with 'subscribed' status and then change anonymous virtual to 'active' status
	-- SQL Server publications will do this via RPC calls to sp_MSadd_subscription
	if @thirdparty_flag = 1 
	begin
		select @subscription_seqno = 0x00  
		if @immediate_sync = 1
		begin
			-- @status passed to sp_MSadd_subscription should always be @subscribed.
			exec @retcode = sys.sp_MSadd_subscription
				@publisher = @publisher,
				@publisher_db = @publisher_db,
				@publication = @publication,
				@article_id = @article_id,
				@subscriber = NULL,                 -- virtual subscription
				@status = @subscribed,              
				@subscription_seqno = @subscription_seqno,
				@sync_type = 1,  -- virtual subscriptions are automatic sync type 
				@internal = @internal
			if @retcode <> 0 or @@error <> 0
			begin
				if @@trancount > 0
				begin
					rollback tran MSadd_article
					commit tran
				end
				return (1)
			end
			-- For SQL publications, we have logic to immediately active the 
			-- virtual anonymous subscription to no_sync subscriptions. However, this
			-- feature is not exposed (You need to pass undocumented command line arg 
			-- '-NoInitialSync' to the distribution agent for the anonymous subscription).
			-- Do the same for 3rd party publications

			if @allow_anonymous = 1
			begin
							/*
							@publisher sysname,
							@publisher_db sysname,
							@subscriber sysname,
							@article_id int,
							@status int,
							@subscription_seqno varbinary(16),
							--post 6x
							@destination_db sysname = '%'
							*/
				exec @retcode = sys.sp_MSupdate_subscription
					@publisher = @publisher,
					@publisher_db = @publisher_db,
					@subscriber = NULL,                 -- virtual subscription
					@article_id = @article_id,
					@status = @active,              
					@subscription_seqno = @subscription_seqno,
					@destination_db = '%' -- For virtual sub, @destination_db is not used. Can pass in anything
				if @retcode <> 0 or @@error <> 0
				begin
					if @@trancount > 0
					begin
						rollback tran MSadd_article
						commit tran
					end
					return (1)
				end
			end
		end
	end

	commit tran
end
GO
GRANT EXECUTE ON [sys].[sp_MSadd_article] TO [public] AS [dbo]
GO
