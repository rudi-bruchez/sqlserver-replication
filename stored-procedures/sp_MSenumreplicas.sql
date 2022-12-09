SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenumreplicas]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenumreplicas] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenumreplicas]
	@pubid [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
declare @inactive tinyint

    /*
    ** Check to see if current publication has permission
    */
    if ({ fn ISPALUSER(@pubid) } <> 1)
    begin   
        RAISERROR (14126, 11, -1)
        return (1)
    end

    select @inactive = 0
    if object_id('MSmerge_contents') is NULL
    begin
        RAISERROR(20054 , 16, -1)
        return (1)
    end

    select subs.subid, {fn REPLNICK_90_TO_80(subs.replnickname)}, 
           subs.subscriber_type, subs.subscription_type, 
           subs.priority, subs.schemaversion, subs.schemaguid, subs.datasource_type, subs.subscriber_server, subs.subscriber_server,  
           subs.db_name, subs.status, subs.pubid, subs.sync_type, subs.description, subs.pubid, pubs.name, pubs.distributor
           from dbo.sysmergesubscriptions subs
           left outer join dbo.sysmergepublications pubs
           on subs.subid = pubs.pubid
                where subs.status <> @inactive
                    and subs.subscriber_type = 1
                    -- If called by 8.0 reconciler on 9.0 replica: It does not know about status 7.
                    and subs.status <> 7 -- REPLICA_STATUS_BeforeRestore
                    order by convert(binary, subs.subid)
    IF @@ERROR <>0 return (1) 
    return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSenumreplicas] TO [public] AS [dbo]
GO
