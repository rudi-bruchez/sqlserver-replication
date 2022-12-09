SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_reinitpullsubscription]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_reinitpullsubscription] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_reinitpullsubscription]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname]
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON
    
    declare @subscription_type int    
    declare @sync_type tinyint
    
    /*
    ** Security Check
    */
    
      declare @retcode     int  
    EXEC @retcode = sys.sp_MSreplcheck_subscribe
    IF @@ERROR <> 0 or @retcode <> 0
        RETURN(1)

    /*
    ** Initializations.
    */
   
    /*
    ** Parameter Check: @publisher
    ** Check to make sure that the publisher is define
    */
    IF @publisher IS NULL
    BEGIN
        RAISERROR (14043, 16, -1, '@publisher', 'sp_reinitpullsubscription')
        RETURN (1)
    END

    IF @publisher = 'all'
    BEGIN
        RAISERROR (14136, 16, -1)
        RETURN (1)
    END

    EXECUTE @retcode = sys.sp_validname @publisher

    IF @@ERROR <> 0 OR @retcode <> 0
       RETURN (1)

        -- Get publisher port number
    exec sys.sp_MSget_server_portinfo 
        @name = @publisher, 
        @srvname = @publisher OUTPUT

    /*
    ** Parameter Check: @publisher_db
    */
    IF @publisher_db = 'all'
    BEGIN
        RAISERROR (14136, 16, -1)
        RETURN (1)
    END

    IF @publisher_db IS NOT NULL
    BEGIN
        EXECUTE @retcode = sys.sp_validname @publisher_db
        IF @@ERROR <> 0 OR @retcode <> 0
            RETURN (1)
    END
    ELSE
    BEGIN
        -- @publisher_db is NULL for Oracle publishers only
        SET @publisher_db = @publisher
    END

    /*
    ** Parameter Check: @publication
    ** 
    */
    IF @publication IS NULL
    BEGIN
        RAISERROR (14043, 16, -1, '@publication', 'sp_reinitpullsubscription')
        RETURN (1)
    END

    IF LOWER(@publication) = 'all'
        select @publication = '%'
    ELSE
    BEGIN
        EXECUTE @retcode = sys.sp_validname @publication

        IF @@ERROR <> 0 OR @retcode <> 0
        RETURN (1)
    END

    -- Peer-To-Peer subscriptions cannot be reinited
    IF OBJECT_ID(N'MSpeer_lsns', 'U') is not NULL
    BEGIN
        -- Check if we should raise an
        IF exists(select * 
                    from MSpeer_lsns
                    where originator = UPPER(@publisher)
                        and originator_db = @publisher_db
                        and originator_publication like @publication)
        BEGIN
            -- Subscriptions to publications that are enabled for ''Peer-To-Peer'' cannot be reinitialized.
            raiserror(20801, 16, -1)
            return (1)
        END        
    END
    
    IF NOT EXISTS (SELECT * FROM  MSreplication_subscriptions 
                WHERE UPPER(publisher) = UPPER(@publisher) AND
                      publisher_db  = @publisher_db AND
                      publication like @publication )
    BEGIN
            RAISERROR(14135, 11, -1,  @publisher, @publisher_db, @publication)
            RETURN(1)
    END
        
    select @sync_type = immediate_sync 
        from MSreplication_subscriptions
        WHERE UPPER(publisher) = UPPER(@publisher) AND publisher_db  = @publisher_db AND publication like @publication 

    IF @sync_type = 0
    BEGIN
        raiserror(21059, 16, -1)
        return (1)
    END
    
    -- 
    -- Since it is the user's desire to reinitialize the pull subscriptions,
    -- we should make sure that new snapshots are delivered from scratch
    -- to this subscription database by resetting the snapshot delivery
    -- progress table.
    --
    exec @retcode = sys.sp_resetsnapshotdeliveryprogress
    if @retcode <> 0 or @@error <> 0
        return (1)

    UPDATE MSreplication_subscriptions set 
        transaction_timestamp = cast(0x00 as binary(15)) + cast(substring(transaction_timestamp, 16, 1) as binary(1))
        WHERE UPPER(publisher) = UPPER(@publisher) AND
                      publisher_db  = @publisher_db AND
                      publication like @publication
    if @@ERROR<>0 
        RETURN (1)

    -- Reset the attach state so that the distribution agent will not adjust attach state.
    if @publication <> '%'
    begin
        select @subscription_type = subscription_type from MSreplication_subscriptions
            WHERE UPPER(publisher) = UPPER(@publisher) AND
                          publisher_db  = @publisher_db AND
                          publication = @publication and
                          -- Don't do this for push
                          subscription_type <> 0
        if @subscription_type is not null
        begin
            exec @retcode = sys.sp_MSreset_attach_state 
                @publisher = @publisher,
                @publisher_db = @publisher_db,
                @publication = @publication,
                @subscription_type = @subscription_type
            if @retcode <> 0 or @@error <> 0
                return (1)
        end
    end
GO
GRANT EXECUTE ON [sys].[sp_reinitpullsubscription] TO [public] AS [dbo]
GO
