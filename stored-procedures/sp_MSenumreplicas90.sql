SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenumreplicas90]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenumreplicas90] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenumreplicas90]
WITH EXECUTE AS CALLER
AS
declare @inactive tinyint

    -- Security check
    declare @retcode int
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck 
    if (@retcode <> 0) or (@@error <> 0)
            return 1

    select @inactive = 0
    if object_id('sysmergesubscriptions') is NULL
    begin
        RAISERROR(20054 , 16, -1)
        return (1)
    end

    select subs.subid, subs.replnickname, 
           subs.subscriber_type, subs.subscription_type, 
           subs.priority, subs.schemaversion, subs.schemaguid, subs.datasource_type, NULL, subs.subscriber_server,  
           subs.db_name, subs.status, subs.replicastate, subs.sync_type, subs.description, subs.pubid, pubs.name, pubs.distributor,
           subs.replica_version
           from dbo.sysmergesubscriptions subs
           left outer join dbo.sysmergepublications pubs
           on subs.subid = pubs.pubid
           where subs.status <> @inactive
               and subs.subscriber_type = 1
               order by convert(binary, subs.subid)
    IF @@ERROR <>0 return (1) 
    return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSenumreplicas90] TO [public] AS [dbo]
GO
