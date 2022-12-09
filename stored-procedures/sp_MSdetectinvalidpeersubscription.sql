SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdetectinvalidpeersubscription]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdetectinvalidpeersubscription] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdetectinvalidpeersubscription]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@dest_table [sysname],
	@dest_owner [sysname],
	@article [sysname],
	@type [sysname]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	declare @OPT_ENABLED_FOR_P2P int
	select @OPT_ENABLED_FOR_P2P = 0x1
	
	declare @retcode 		int,
			@agent_id 		int,
			@subscriber		sysname,
			@subscriber_db	sysname

	select @subscriber		= @@SERVERNAME,
			@subscriber_db	= DB_NAME()
			
	-- security check for subscriber
	exec @retcode = sys.sp_MSreplcheck_subscribe 
    if @@error <> 0 or  @retcode <> 0 
    begin
        return 1
    end

	-- if this not a republisher then we can just exit
	if sys.fn_MSrepl_istranpublished(db_name(),0) = 0
    begin
    	return 0
    end
    
	select @agent_id = id
		from MSsubscription_agents
		where publisher = @publisher
			and publisher_db = @publisher_db
			and publication = @publication
	if @@error <> 0
		or @agent_id is NULL
	begin
		-- Could not find a valid Agent Id for the subscription to Publisher @publisher, database @publisher_db, publication @publication.
		raiserror(21758, 16, -1, @publisher, @publisher_db, @publication)
		return 1
	end

	-- if we do not find a publication by the name as @publication 
	-- then we can continue without error and without any warnings.
	if not exists(select *
					from syspublications
					where name = @publication
						and (options & @OPT_ENABLED_FOR_P2P) = @OPT_ENABLED_FOR_P2P)
	begin
		return 0
	end

	if upper(@type) = N'ADD'
	begin
		if not exists(select *
						from MSsubscription_articles mssa
							join sysextendedarticlesview sa
								on mssa.dest_table = sa.dest_table
									and isnull(mssa.owner, N'dbo') = isnull(sa.dest_owner, N'dbo')
							join syspublications sp
								on sa.pubid = sp.pubid
						where mssa.agent_id = @agent_id
							and sp.name = @publication
							and (sp.options & @OPT_ENABLED_FOR_P2P) = @OPT_ENABLED_FOR_P2P
							and mssa.article = @article
							and sa.dest_table = @dest_table
							and isnull(sa.dest_owner, N'dbo') = isnull(@dest_owner, N'dbo'))
		begin
			-- Peer-To-Peer topologies require identical articles in publications at all nodes prior to synchronizing. Articles in publication [@publisher].[@publisher_db].[publication] do not match articles in [@subscriber].[@subscriber_db].[publication].
			raiserror(20803, 16, -1, @publisher, @publisher_db, @publication, @subscriber, @subscriber_db, @publication)
			return 1
		end
	end
	else if upper(@type) = 'DEL'
	begin
		delete MSsubscription_articles
			where agent_id = @agent_id
				and article = @article
		
		if exists(select *
					from sysextendedarticlesview sa
						join syspublications sp
							on sa.pubid = sp.pubid
					where sp.name = @publication
						and (sp.options & @OPT_ENABLED_FOR_P2P) = @OPT_ENABLED_FOR_P2P
						and sa.name = @article
						and sa.dest_table = @dest_table
						and isnull(sa.dest_owner, N'dbo') = isnull(@dest_owner, N'dbo'))
		begin
			-- Peer-To-Peer topologies require identical articles in publications at all nodes prior to synchronizing. Articles in publication [@publisher].[@publisher_db].[publication] do not match articles in [@subscriber].[@subscriber_db].[publication].
			raiserror(20803, 16, -1, @publisher, @publisher_db, @publication, @subscriber, @subscriber_db, @publication)
			return 1
		end
	end
	
	return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSdetectinvalidpeersubscription] TO [public] AS [dbo]
GO
