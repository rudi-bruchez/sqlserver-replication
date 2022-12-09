SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MShelpmergedynamicsnapshotjob]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MShelpmergedynamicsnapshotjob] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MShelpmergedynamicsnapshotjob]
	@publication [sysname],
	@dynamic_snapshot_jobname [sysname],
	@dynamic_snapshot_jobid [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    declare @retcode int

    exec @retcode = sys.sp_MSreplcheck_publish
    if @@error<>0 or @retcode<>0
        return 1
    
    if object_id('sysmergepublications') is NULL
    begin
        return 0
    end

    select 'id' = j.id,
           'job_name' = j.name,
           'job_id' = j.job_id, 
           'suser_sname' = j.dynamic_filter_login,
           'host_name' = j.dynamic_filter_hostname,
           'dynamic_snapshot_location' = j.dynamic_snapshot_location
      from dbo.sysmergepublications p
     inner join MSdynamicsnapshotjobs j
        on p.pubid = j.pubid
     where (p.name = @publication or @publication = N'%')
       and (j.name = @dynamic_snapshot_jobname or @dynamic_snapshot_jobname = N'%')
       and (j.job_id = @dynamic_snapshot_jobid or @dynamic_snapshot_jobid is null) 

    if @@error <> 0
        return (1)
    else
        return (0)

end
GO
GRANT EXECUTE ON [sys].[sp_MShelpmergedynamicsnapshotjob] TO [public] AS [dbo]
GO
