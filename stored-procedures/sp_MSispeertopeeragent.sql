SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSispeertopeeragent]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSispeertopeeragent] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSispeertopeeragent]
	@agent_id [int],
	@is_p2p [int] OUTPUT
WITH EXECUTE AS CALLER
AS
begin
	set nocount on
	
	declare @retcode 			tinyint,
			@publisher_db 		sysname,
			@publisher_id 		int,
			@publication 		sysname,
			@num_p2p_pubs int

	declare @OPT_ENABLED_FOR_P2P int

	select @OPT_ENABLED_FOR_P2P = 0x1

	-- security check - the distribution agent must have access
	exec @retcode = sp_MScheck_pull_access @agent_id = @agent_id, @agent_type = 0
	if @@error <> 0 or @retcode <> 0
	begin
		return 1
	end
	
	-- Has to be executed from distribution database
	if sys.fn_MSrepl_isdistdb (db_name()) != 1
	begin
		-- sp_MSispeertopeeragent can only be executed in the distribution database.
		raiserror (21482, 16, -1, 'sp_MSispeertopeeragent', 'distribution')
		return 1
	end

   	select @publisher_db 	= publisher_db,
			@publisher_id 	= publisher_id,
			@publication 	= publication
		from MSdistribution_agents 
		where id = @agent_id

	-- find out if there are any PeerToPeer publications for this agent
	if lower(@publication) = 'all'
	begin
		--shared agent (one agent for all publications that go to a single subscriber)
		--Get all the subscriptions for this agent, then find out all the publications
		select @num_p2p_pubs = count(*)
			from dbo.MSsubscriptions mss 
				inner join dbo.MSpublications msp 
					on mss.publisher_id 		= msp.publisher_id
						and mss.publisher_db 	= msp.publisher_db
						and mss.publication_id 	= msp.publication_id
			where mss.agent_id = @agent_id
				and (msp.options & @OPT_ENABLED_FOR_P2P) = @OPT_ENABLED_FOR_P2P
	end
	else
	begin
		--independent agent (one agent for each publication)
		select @num_p2p_pubs = count(*)
			from dbo.MSpublications msp
			where msp.publication 		= @publication
				and	msp.publisher_db 	= @publisher_db
				and msp.publisher_id 	= @publisher_id
				and (msp.options & @OPT_ENABLED_FOR_P2P) = @OPT_ENABLED_FOR_P2P
	end

	if @num_p2p_pubs > 0
		select @is_p2p = 1
	else
		select @is_p2p = 0

	return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSispeertopeeragent] TO [public] AS [dbo]
GO
