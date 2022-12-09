SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSunregistersubscription]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSunregistersubscription] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSunregistersubscription]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
    /* 
    ** Drop the corresponding registry entry for MobileSync
    */
    declare @enabled    int
    declare    @retcode     int
    declare @regkey        nvarchar(1000)

    select @retcode = 0
    
    exec @retcode = sys.sp_MSreplcheck_subscribe

    if @@error <> 0 or @retcode <> 0
    BEGIN
        RETURN 1
    END

    -- Mark enabled_for_syncmgr bit before trying to delete the key
    -- If the row exists in MSreplication_properties table, 
    -- set enabled_for_syncmgr bit
    -- The logic need to be here because UI call this sp directly.
    IF OBJECT_ID('MSsubscription_properties') IS NOT NULL
    BEGIN
        UPDATE    MSsubscription_properties
        SET        enabled_for_syncmgr = 0
        WHERE    UPPER(publisher) = UPPER(@publisher)
          AND    publisher_db =  @publisher_db
          AND    publication = @publication

        IF @@ERROR <> 0
            RETURN 1
    END

    -- regdelete returns 'Access Denied' message if key does not exist; check before delete
    EXEC sys.sp_MSsubscription_enabled_for_syncmgr    @publisher,
                                                    @publisher_db,
                                                    @publication,
                                                    @subscriber,
                                                    @subscriber_db,
                                                    @enabled OUT,
                                                    @regkey OUT
    IF @@ERROR <> 0
        RETURN 1
        
    IF @enabled = 1 AND LEN(@regkey) > 0
    BEGIN
        EXECUTE @retcode = master.dbo.xp_regdeletekey 'HKEY_LOCAL_MACHINE', @regkey

        IF @@error != 0 OR @retcode != 0
        BEGIN
            return 1
        END
    END

    return 0
END
GO
GRANT EXECUTE ON [sys].[sp_MSunregistersubscription] TO [public] AS [dbo]
GO
