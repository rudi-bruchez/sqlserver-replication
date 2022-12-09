SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSget_repl_cmds_anonymous]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSget_repl_cmds_anonymous] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSget_repl_cmds_anonymous]
	@agent_id [int],
	@last_xact_seqno [varbinary](16),
	@no_init_sync [bit],
	@get_count [tinyint],
	@compatibility_level [int]
WITH EXECUTE AS CALLER
AS
begin
   set nocount on

   declare @virtual_agent_id int    /* virtual sub agent id */
			,@anonymous_agent_id int  /* virtual anonymous agent id */
			,@retcode int

	-- Note @agent_id will be overwritten later.
	select  @virtual_agent_id =   virtual_agent_id,
			@anonymous_agent_id = anonymous_agent_id
		from MSdistribution_agents where
			id = @agent_id
	
	-- Return error if agent entry does not exists (being deleted).
	if @virtual_agent_id is null
	begin
		raiserror(21072, 16, -1)
		return(1)
	end

	-- If no init sync, use anonymous account to start immediately.
	-- If first time or right after reinit,  use virtual account. 
	-- otherwise use virtual anonymous account
	if  @no_init_sync = 1 
		select @agent_id = @anonymous_agent_id
	else if @last_xact_seqno = 0x00 
		select @agent_id = @virtual_agent_id
	else
		select @agent_id = @anonymous_agent_id
	--
	-- Call main procedure to get commands
	-- PAL security check done inside this sp
	--
	exec @retcode = sys.sp_MSget_repl_commands 
		@agent_id = @agent_id,
		@last_xact_seqno = @last_xact_seqno,
		@get_count = @get_count,
		@compatibility_level = @compatibility_level

	return @retcode
end
GO
GRANT EXECUTE ON [sys].[sp_MSget_repl_cmds_anonymous] TO [public] AS [dbo]
GO
