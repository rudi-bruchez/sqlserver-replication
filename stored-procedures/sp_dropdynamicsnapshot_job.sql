SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_dropdynamicsnapshot_job]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_dropdynamicsnapshot_job] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_dropdynamicsnapshot_job]
	@publication [sysname],
	@dynamic_snapshot_jobname [sysname],
	@dynamic_snapshot_jobid [uniqueidentifier],
	@ignore_distributor [bit]
WITH EXECUTE AS CALLER
AS
declare @retcode int
    exec @retcode = sys.sp_MSreplcheck_publish
    if @@error <> 0 or @retcode <> 0
        return (1)
    exec @retcode = sys.sp_MSdropmergedynamicsnapshotjob 
                        @publication,
                        @dynamic_snapshot_jobname,
                        @dynamic_snapshot_jobid,
                        @ignore_distributor
    return @retcode
GO
GRANT EXECUTE ON [sys].[sp_dropdynamicsnapshot_job] TO [public] AS [dbo]
GO
