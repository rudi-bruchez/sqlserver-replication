SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSrepl_monitor_job_at_failover]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSrepl_monitor_job_at_failover] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSrepl_monitor_job_at_failover]
	@database_name [sysname],
	@all [bit]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on

    declare @retval bit

    -- security check
    -- only sysadmin can execute this
    --
    if (isnull(is_srvrolemember('sysadmin'),0) = 0) 
    begin
        raiserror(21089, 16, -1)
        return 1
    end

	if serverproperty('EngineEdition') <> 8 -- We dont need to sync repl agent jobs on Managed Instance
	begin
		exec @retval = sys.sp_MSrepl_sync_agent_jobs
			@database_name = @database_name,
			@all = @all
    
		if (@@error <> 0 or @retval <> 0)
			return 1

		exec @retval = sys.sp_MSrepl_adjust_job_status
			@database_name = @database_name,
			@all = @all

		if (@@error <> 0 or @retval <> 0)
			return 1
	end

    return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSrepl_monitor_job_at_failover] TO [public] AS [dbo]
GO
