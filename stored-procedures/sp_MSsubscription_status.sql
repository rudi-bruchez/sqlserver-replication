SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSsubscription_status]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSsubscription_status] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSsubscription_status]
	@agent_id [int]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	declare @retcode tinyint
	declare @status tinyint
	declare @inactive tinyint
	declare @active tinyint
	declare @subscribed tinyint
	declare @initiated tinyint
	declare @article_id int
	declare @publication sysname
	declare @article sysname
	declare @msg nvarchar(255)
	declare @automatic tinyint
	declare @none tinyint
	declare @success int
	declare @last_sync datetime
	declare @publication_id int
	declare @is_p2p bit

	select @success = 2
	select @inactive = 0
	select @subscribed = 1
	select @active = 2
	select @initiated = 3
	SELECT @automatic = 1
	select @none = 2
	select @is_p2p = 0

	-- Security Check
	-- Only perform security check if user is not a member of replmonitor
	if isnull(is_member(N'replmonitor'), 0) != 1
	begin
		-- Security Check
		exec @retcode = sys.sp_MScheck_pull_access @agent_id = @agent_id,	-- agent id
									@agent_type = 0 		-- only called by distribution agent
		if @@error <> 0 or @retcode <> 0
		begin
			return (1)
		end
	end
	
	-- If one article is inactive, and no_sync subscription fail.
	if exists (select * from dbo.MSsubscriptions where
		status = @inactive and
		sync_type in (@none, @automatic) and
		agent_id = @agent_id)
	begin
		-- Find out if there are any PeerToPeer publications for this agent
		exec sys.sp_MSispeertopeeragent @agent_id = @agent_id, @is_p2p = @is_p2p output
	
		if @is_p2p = 1
		begin
			 -- The subscription(s) have been marked inactive. You will have to rebuild the topology surrounding this node. See Peer-To-Peer documentation for more information.
			raiserror(18854, 16,-1)
			return(1)
		end
		
		-- The subscription(s) have been marked inactive and must be reinitialized. NoSync subscriptions will need to be dropped and recreated.
		raiserror(21074, 16,-1)
		return(1)
	end
	else if exists (select * from dbo.MSsubscriptions where
		status = @subscribed and
		sync_type = @none and
		agent_id = @agent_id)
	begin
		select @status = @subscribed,
				@msg = formatmessage(18857)
	end
	else
	begin
		select top 1 @article_id = article_id,
			@publication_id = publication_id
			from dbo.MSsubscriptions where
			agent_id = @agent_id and
			sync_type = @automatic and
			status = @subscribed

		if @publication_id is not null
		begin
			-- Get the publication name to use later in the formated message
			select @publication = publication from dbo.MSpublications where
				publication_id = @publication_id

			-- If there's more than one article in subscribed state
			-- Send a general waiting message.
			-- Otherwise, indicate the article name
			if exists (select * from dbo.MSsubscriptions where
				agent_id = @agent_id and
				status = @subscribed and
				sync_type = @automatic and
				article_id <> @article_id)
			begin
				-- Snapshot not available message
				if @publication is not null
					select @msg = formatmessage(21075, @publication)
				else -- It is null for 6.5
					select @msg = formatmessage(21088)
			end
			else
			begin
				-- article_id is unique across pub db for tran
				-- but merge article may use the same id
				select @article = article from MSarticles where
					article_id = @article_id and
					publication_id = @publication_id
				-- It is null for 6.5
				if @article is not null
					select @msg = formatmessage(21076, @article)
				else
				begin
					-- Snapshot not available message
					if @publication is not null
						select @msg = formatmessage(21075, @publication)
					else -- It is null for 6.5
						select @msg = formatmessage(21088)
				end
			end

			-- If one article is active, the status is active
			if exists ( select * from dbo.MSsubscriptions where
				agent_id = @agent_id and
				sync_type = @automatic and
				status = @active)
				set @status = @active
			else
				set @status = @subscribed
		end
		else
		-- For concurrent snapshot, logreader has to run first.
		begin
	 		select top 1 @publication_id = publication_id, @status = status from dbo.MSsubscriptions s where
					s.status = @initiated and
					s.agent_id = @agent_id and
					s.sync_type = @automatic

			if @publication_id is not null
			begin
				select @publication = publication from dbo.MSpublications where
					publication_id = @publication_id
				select @msg = formatmessage(21388, @publication)
			end
		end
	end
	
	-- If nothing returned, all articles are active.
	select 'msg' = @msg, 'status' = @status 
		where @msg is not null
end
GO
GRANT EXECUTE ON [sys].[sp_MSsubscription_status] TO [public] AS [dbo]
GO
