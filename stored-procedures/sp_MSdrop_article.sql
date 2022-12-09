SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdrop_article]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdrop_article] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdrop_article]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@article [sysname]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	declare @publisher_id smallint
	declare @publication_id int
	declare @article_id int
	declare @retcode int
	declare @thirdparty_flag bit
	declare @immediate_sync bit

	--
	-- security check
	-- only db_owner can execute this
	--
	if (is_member ('db_owner') != 1) 
	begin
		raiserror(14260, 16, -1)
		return (1)
	end
	-- Check if publisher is a defined as a distribution publisher in the current database
	exec @retcode = sys.sp_MSvalidate_distpublisher @publisher, @publisher_id OUTPUT
	if @retcode <> 0
	begin
		return(1)
	end

	-- Make sure publication exists
	select @publication_id = publication_id, @thirdparty_flag = thirdparty_flag,
		@immediate_sync = immediate_sync
		from dbo.MSpublications where 
		publication = @publication and
		publisher_id = @publisher_id and 
		publisher_db = @publisher_db
	if @publication_id is NULL
	begin
		raiserror(20026, 16, -1, @publication)
		return (1)
	end

	-- Make sure article exists
	declare @source_object sysname
	select @article_id = article_id, @source_object = source_object
		from MSarticles where 
		publication_id = @publication_id and
		publisher_id = @publisher_id and 
		publisher_db = @publisher_db and 
		article = @article
	if @article_id is NULL
	begin
		if @thirdparty_flag = 1
		begin
			raiserror(20027, 16, -1, @article)
			return (1)
		end
		else
			return (0)
	end

	-- Check to make sure that there are no subscriptions on the article
	if exists (select * from dbo.MSsubscriptions where 
		publisher_id = @publisher_id and
		publisher_db = @publisher_db and
		publication_id = @publication_id and
		article_id = @article_id and
		subscriber_id >= 0)             -- ignore virtual subscriptions
	begin
		raiserror(14046, 16, -1)
		return(1)
	end

	begin tran
	save tran MSdrop_article

	if @immediate_sync = 1
	begin
		-- For immediate sync subscriptions, we may need to adjust the
		-- article ids of the snapshot header or trailer commands

		declare @min_artid int
		declare @new_min_artid int
		declare @snapshot_bit int
		set @snapshot_bit = 0x80000000

		select @min_artid = min(article_id) 
		  from MSarticles
		 where publication_id = @publication_id
		   and publisher_id = @publisher_id
		   and publisher_db = @publisher_db
		if @@error <> 0
		begin
			if @@trancount > 0
			begin
				rollback tran MSdrop_article
				commit tran
			end
			return (1)
		end

		if @min_artid = @article_id
		begin
			select @new_min_artid = min(article_id) 
			  from MSarticles
			 where publication_id = @publication_id
			   and publisher_id = @publisher_id
			   and publisher_db = @publisher_db
			   and article_id > @min_artid
			if @@error <> 0
			begin
				if @@trancount > 0
				begin
					rollback tran MSdrop_article
					commit tran
				end
				return (1)
			end

			if @new_min_artid is not null
			begin 
				update MSrepl_commands
				   set article_id = @new_min_artid
				 where article_id = @article_id
				   and publisher_database_id = (select id from MSpublisher_databases where publisher_id = @publisher_id and publisher_db = @publisher_db)
				   and (type & ~@snapshot_bit) in (25, 50, 51, 52, 53, 54, 55, 56 ,57, 58) -- Command type list must match that in sp_MSget_repl_commands
				if @@error <> 0
				begin
					if @@trancount > 0
					begin
						rollback tran MSdrop_article
						commit tran
					end
					return (1)
				end
			end
		end
	end

	-- For third party publications drop immediate sync and anonymous virtual subscriptions
	-- SQL Server publications will do this via RPC calls to sp_MSadd_subscription
	if @thirdparty_flag = 1 and @immediate_sync = 1
	begin
		begin
			exec @retcode = sys.sp_MSdrop_subscription
				@publisher = @publisher,
				@publisher_db = @publisher_db,
				@publication = @publication,
				@article_id = @article_id,
				@subscriber = NULL                  -- virtual subscription
			if @retcode <> 0 or @@error <> 0
			begin
				if @@trancount > 0
				begin
					rollback tran MSdrop_article
					commit tran
				end
				return (1)
			end
		end
	end

	delete from MSarticles where
		publisher_id = @publisher_id and
		publisher_db = @publisher_db and
		publication_id = @publication_id and
		article_id = @article_id
	if @@error <> 0
	begin
		if @@trancount > 0
		begin
			rollback tran MSdrop_article
			commit tran
		end
		return (1)
	end

	if not exists (select * from MSarticles  where 
		publisher_id = @publisher_id and
		publisher_db = @publisher_db and
		source_object = @source_object)
	begin
		delete MSrepl_identity_range where 
			publisher = @publisher and
			publisher_db = @publisher_db and
			tablename = @source_object
		if @@ERROR <> 0 begin
			if @@trancount > 0
				ROLLBACK TRAN
			RETURN (1)
		end
	end

	commit tran
end
GO
GRANT EXECUTE ON [sys].[sp_MSdrop_article] TO [public] AS [dbo]
GO
