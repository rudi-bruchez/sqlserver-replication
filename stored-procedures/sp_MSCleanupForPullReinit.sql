SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSCleanupForPullReinit]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSCleanupForPullReinit] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSCleanupForPullReinit]
	@publication [sysname],
	@publisher_db [sysname],
	@publisher [sysname]
WITH EXECUTE AS CALLER
AS
declare @pubid         uniqueidentifier
    declare @artid         uniqueidentifier
    declare @retcode    smallint

    /*
    ** Security Check
    */
    EXEC @retcode = sys.sp_MSreplcheck_publish
    IF @@ERROR <> 0 or @retcode <> 0
        return (1)

	if @publisher is NULL
		set @publisher = publishingservername()

    -- This only gets called after database is enable to subscribe, so
    -- sysmergepublications should exist
    select @pubid = pubid from dbo.sysmergepublications 
        where name = @publication and 
              publisher_db = @publisher_db and
              upper(publisher collate SQL_Latin1_General_CP1_CS_AS) = upper(@publisher collate SQL_Latin1_General_CP1_CS_AS) and
              status <> 7 -- REPLICA_STATUS_BeforeRestore

    /* Normal case - nothing to cleanup, just return */
    if @pubid is null
        return (1)    

    select @retcode = 0
    exec @retcode = sys.sp_MSCleanupForPullReinitWithPubId @pubid = @pubid
    
    return @retcode
GO
GRANT EXECUTE ON [sys].[sp_MSCleanupForPullReinit] TO [public] AS [dbo]
GO
