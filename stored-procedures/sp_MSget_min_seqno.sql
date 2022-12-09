SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSget_min_seqno]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSget_min_seqno] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSget_min_seqno]
	@agent_id [int],
	@xact_seqno [varbinary](16) OUTPUT
WITH EXECUTE AS CALLER
AS
BEGIN
	declare @publisher_db_id int,
		@publisher sysname, 
		@publisher_dbname sysname,
		@publication_id int,
		@dbversion int,
		@publication sysname, 
		@retcode int,
		@IsP2PAgent bit,
		@nosync_type tinyint

	--
	-- Security Check
	-- 
	if @agent_id is not null
	begin
		exec @retcode = sys.sp_MScheck_pull_access
			@agent_id = @agent_id,
			@agent_type = 0 -- distribution agent
		if @@error <> 0 or @retcode <> 0
			return (1)
	end
	else
	begin
		return (1)
	end

	--exec sys.sp_MSispeertopeeragent @agent_id = @agent_id, @is_p2p = @IsP2PAgent output

	--if @@error <> 0 or @IsP2PAgent <> 0
	--begin
	--    return (1)
	--end

   select @publisher_db_id = publisher_database_id
   from MSdistribution_agents
   where id = @agent_id             

	if @publisher_db_id is null
		return (1)

   --MSsubscriptions has a clustered unique key (agent_id, article_id). For one agent_id, there may
   --be multiple article_id. However, all rows with the same @agent_id should have a same value on nosync_type
   select @nosync_type = nosync_type
   from MSsubscriptions
   where agent_id = @agent_id

	if @nosync_type != 3
	begin
		-- In the case where we have a different nosync type, this tells
		--  the distribution agent that can begin replication.
		-- This should be removed in the future.
		select @xact_seqno = 0x00000000000000000001
		return (0)
	end

	select top 1 @xact_seqno = xact_seqno 
		from MSrepl_transactions msrt 
			where msrt.publisher_database_id=@publisher_db_id
			order by xact_seqno asc

	return(0)
END

--
-- Name: sp_MSget_repl_commands
--
-- Descriptions: Note: sp_MSget_repl_commands and sp_MSget_repl_count have very similar
--  queries. Any changes to one of them should be applied to all others.
--
-- Parameters: as defined in create statement
--
-- Returns: 0 - success
--          1 - Otherwise
--
-- BUGBUG: If resource db support does not improve - this SP should be moved back
-- to instdist.sql for supportability. It accesses system catalogs
-- 
-- Security: Public procedure invoked via RPC. PAL check
-- Requires Certificate signature for catalog access
--
raiserror(15339,-1,-1,'sp_MSget_repl_commands')
GO
GRANT EXECUTE ON [sys].[sp_MSget_min_seqno] TO [public] AS [dbo]
GO
