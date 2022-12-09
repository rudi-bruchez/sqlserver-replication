SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSget_snapshot_history]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSget_snapshot_history] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSget_snapshot_history]
	@agent_id [int],
	@timestamp [timestamp],
	@rowcount [int]
WITH EXECUTE AS CALLER
AS
set nocount on
	
	declare @retcode 			tinyint

	-- Security check - If the agent is in cache then it can access
	exec @retcode = sys.sp_MScheck_pull_access @agent_type = 0, @agent_id = 0, @publication_id = 0
	if @@error <> 0 or @retcode <> 0
		return (1)

	-- Has to be executed from distribution database
	if sys.fn_MSrepl_isdistdb (db_name()) != 1
	begin
		raiserror (21482, 16, -1, 'sp_MSget_snapshot_history', 'distribution')
		return 1
	end

	if @rowcount is not NULL
		set rowcount @rowcount
		
	select runstatus, comments, timestamp from MSsnapshot_history where agent_id = @agent_id and timestamp > @timestamp    
GO
GRANT EXECUTE ON [sys].[sp_MSget_snapshot_history] TO [public] AS [dbo]
GO
