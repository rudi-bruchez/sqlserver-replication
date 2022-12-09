SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MScheck_tran_retention]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MScheck_tran_retention] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MScheck_tran_retention]
	@xact_seqno [varbinary](16),
	@agent_id [int]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	declare @retcode tinyint	
	declare @date datetime
	declare @retention int
	declare	@expired int
	declare @publisher_database_id int

	-- Security Check
	exec @retcode = sys.sp_MScheck_pull_access @agent_id = @agent_id,	-- agent id
												@agent_type = 0 		-- only called by distribution agent
	if @@error <> 0 or @retcode <> 0
	begin
		return (1)
	end
	
	select @publisher_database_id = publisher_database_id from MSdistribution_agents
		where id = @agent_id

	select @date = entry_time from MSrepl_transactions where
		xact_seqno = @xact_seqno and
		publisher_database_id = @publisher_database_id

	select @retention = max_distretention from msdb..MSdistributiondbs where
		name = db_name()

	if (@date is not null and datediff(minute, @date, getdate()) < @retention*60) or
		-- For 'sync with backup' dist db where
		-- the dist db might be restored to a previous version so that the subscriber's
		-- xact_seqno is larger.
	   (@date is null and not exists (select * from MSrepl_transactions where
		xact_seqno >= @xact_seqno and
		publisher_database_id = @publisher_database_id))
		select @expired = 0
	else
		select @expired = 1
	
	select N'expired' = @expired
end
GO
GRANT EXECUTE ON [sys].[sp_MScheck_tran_retention] TO [public] AS [dbo]
GO
