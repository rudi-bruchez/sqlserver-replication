SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdetectinvalidpeerconfiguration]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdetectinvalidpeerconfiguration] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdetectinvalidpeerconfiguration]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname]
WITH EXECUTE AS CALLER
AS
begin
	declare @OPT_ENABLED_FOR_P2P int
	
	declare @retcode 					bit,
			@agent_id 					int,
			@subscriber					sysname,
			@subscriber_db				sysname,
			@subscriber_publication		sysname,
			@subscriber_article_count	int,
			@publisher_article_count	int,
			@matching_article_count		int

	select @OPT_ENABLED_FOR_P2P = 0x1

	select @subscriber		= @@SERVERNAME,
			@subscriber_db 	= db_name()
	
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

	-- if this subscriber (republisher) has any articles that are in a 
	-- different P2P publication but are shared with this subscription then
	-- this is an invalid configuration and we must raise an error to bail
	select @subscriber_publication = sp.name
		from MSsubscription_articles mssa
			join sysextendedarticlesview sa
				on mssa.dest_table = sa.dest_table
					and isnull(mssa.owner, N'dbo') = isnull(sa.dest_owner, N'dbo')
			join syspublications sp
				on sa.pubid = sp.pubid
		where mssa.agent_id = @agent_id
			and sp.name != @publication
			and (sp.options & @OPT_ENABLED_FOR_P2P) = @OPT_ENABLED_FOR_P2P
			
	if @subscriber_publication is not NULL
	begin
		-- Peer-To-Peer topologies require identical publication names on each publisher. The distribution agent for publication [@publisher].[@publisher_db].[publication] is attempting to synchronize articles that exist in publication [@subscriber].[@subscriber_db].[publication].
		raiserror(20809, 16, -1, @publisher, @publisher_db, @publication, @subscriber, @subscriber_db, @subscriber_publication)
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
	
	-- retrieve article counts for the following:
	--		1. Number of articles for the current subscription
	--		2. Number of articles for the local publication
	--		3. Number of articles that base objects match between sub/pub
	select @subscriber_article_count = count(artid)
			from MSsubscription_articles 		
			where agent_id = @agent_id

	select @publisher_article_count = count(sa.artid)  
			from syspublications sp
				join sysextendedarticlesview sa					
					on sa.pubid = sp.pubid
			where sp.name = @publication
				and (sp.options & @OPT_ENABLED_FOR_P2P) = @OPT_ENABLED_FOR_P2P

	select @matching_article_count = count(sa.artid)
			from syspublications sp
				join sysextendedarticlesview sa					
					on sa.pubid = sp.pubid
				join MSsubscription_articles mssa
					on mssa.dest_table = sa.dest_table
						and isnull(mssa.owner, N'dbo') = isnull(sa.dest_owner, N'dbo')
			where mssa.agent_id = @agent_id
				and sp.name = @publication
				and (sp.options & @OPT_ENABLED_FOR_P2P) = @OPT_ENABLED_FOR_P2P
			
	if @publisher_article_count != @matching_article_count
		or @subscriber_article_count != @matching_article_count
	begin
		-- Peer-To-Peer topologies require identical articles in publications at all nodes prior to synchronizing. Articles in publication [@publisher].[@publisher_db].[publication] do not match articles in [@subscriber].[@subscriber_db].[publication].
		raiserror(20803, 10, -1, @publisher, @publisher_db, @publication, @subscriber, @subscriber_db, @publication) with log
	end		
	
	return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSdetectinvalidpeerconfiguration] TO [public] AS [dbo]
GO
