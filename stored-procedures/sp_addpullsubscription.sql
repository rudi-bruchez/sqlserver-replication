SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_addpullsubscription]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_addpullsubscription] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_addpullsubscription]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@independent_agent [nvarchar](5),
	@subscription_type [nvarchar](9),
	@description [nvarchar](100),
	@update_mode [nvarchar](30),
	@immediate_sync [bit]
WITH EXECUTE AS CALLER
AS
BEGIN

    SET NOCOUNT ON

    /*
    ** Declarations.
    */

    DECLARE @retcode int
    DECLARE @subscription_type_id int   /* 1 = pull, 2 = anonymous */
    DECLARE @independent_agent_id bit
    DECLARE @update_mode_id     tinyint 

    -- For attach
    if exists (select * from sys.objects where name = 'MSrepl_restore_stage')
    begin
        raiserror(21211, 16, -1)
        return 1
    end
    /* 
    ** Check if replication components are installed on this server
    */
    exec @retcode = sys.sp_MS_replication_installed
    if (@retcode <> 1)
    begin
        return (1)
    end
    /*
    ** Security Check
    */
    EXEC @retcode = sys.sp_MSreplcheck_subscribe
    IF @@ERROR <> 0 or @retcode <> 0
        RETURN(1)
    /*
    ** Parameter Check: @publisher
    ** Check to make sure that the publisher is define
    */
    IF @publisher IS NULL
    BEGIN
        RAISERROR (14043, 16, -1, '@publisher', 'sp_addpullsubscription')
        RETURN (1)
    END

    IF @publisher = 'all'
    BEGIN
        RAISERROR (14136, 16, -1)
        RETURN (1)
    END

    -- Get publisher without port number
    exec sys.sp_MSget_server_portinfo 
        @name = @publisher, 
        @srvname = @publisher OUTPUT

    EXECUTE @retcode = sys.sp_validname @publisher
    IF @@ERROR <> 0 OR @retcode <> 0
       RETURN (1)

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
    */
    IF @publication IS NULL
    BEGIN
        RAISERROR (14043, 16, -1, '@publication', 'sp_addpullsubscription')
        RETURN (1)
    END

    IF @publication = 'all'
    BEGIN
        RAISERROR (14136, 16, -1)
        RETURN (1)
    END

    EXECUTE @retcode = sys.sp_validname @publication
    IF @@ERROR <> 0 OR @retcode <> 0
       RETURN (1)
    --
    -- Current database (subscribing database cannot be master)
    --
    if (lower(db_name()) = 'master')
    begin
        RAISERROR (21481, 16, 1)
        RETURN (1)
    end

    IF @independent_agent IS NULL OR LOWER(@independent_agent collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('true', 'false')
        BEGIN
            RAISERROR (14148, 16, -1, '@independent_agent')
            RETURN (1)
        END

    IF LOWER(@independent_agent collate SQL_Latin1_General_CP1_CS_AS) = 'true' 
        SELECT @independent_agent_id = 1
    ELSE 
        SELECT @independent_agent_id = 0
    /*
    ** Parameter Check:  @subscription_type
    ** The @status value can be:
    **
    **       type_id       type
    **      ======   ========
    **           0              push
    **           1           pull
    **           2           anonymous
    **
    **    Note: @subscription_type = push is only used by distribution agents
    */
    IF @subscription_type IS NULL OR LOWER(@subscription_type collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('push', 'pull','anonymous')
    BEGIN
        RAISERROR (20016, 16, -1)
        RETURN (1)
    END

    IF LOWER(@subscription_type collate SQL_Latin1_General_CP1_CS_AS) = 'pull'    
        SELECT @subscription_type_id = 1
    ELSE IF LOWER(@subscription_type collate SQL_Latin1_General_CP1_CS_AS) = 'anonymous'  
        SELECT @subscription_type_id = 2
    ELSE
        SELECT @subscription_type_id = 0

    IF @independent_agent_id = 0 AND @subscription_type_id = 2
    BEGIN
        RAISERROR (21026, 16, -1)
        RETURN (1)
    END
    --
    -- Parameter check: @update_mode
    --
    IF (@update_mode IS NULL OR LOWER(@update_mode collate SQL_Latin1_General_CP1_CS_AS) NOT IN 
            ('read only', 'sync tran', 'queued tran', 'failover','queued failover'))
    BEGIN
        RAISERROR (20502, 16, -1, '@update_mode')
        RETURN (1)
    END
    -- Anonymous subscriptions should not be allowed to 
    -- subscribe with 'synctran option'    
    IF LOWER(@update_mode collate SQL_Latin1_General_CP1_CS_AS) in ('sync tran', 'queued tran', 'failover') and
        @subscription_type_id = 2 
    begin                      
           RAISERROR (21057, 16, -1)
        RETURN (1)
    end
    --
    -- set the @update_mode_id
    -- NOTE when the distribution agent does the subscription initialization
    -- the queued failover case will be update to a valie of (3 or 5)based on
    -- the queue type - as the failover state in MSsubscription_agents will then
    -- correctly identify the current state of update_mode on the subscriber
    -- 
    select @update_mode_id = case
        when LOWER(@update_mode collate SQL_Latin1_General_CP1_CS_AS) = 'sync tran' then 1
        when LOWER(@update_mode collate SQL_Latin1_General_CP1_CS_AS) = 'queued tran' then 4
        when LOWER(@update_mode collate SQL_Latin1_General_CP1_CS_AS) = 'failover' then 5
        when LOWER(@update_mode collate SQL_Latin1_General_CP1_CS_AS) = 'queued failover' then 6
        else 0
    end

    begin tran
    save TRAN addpullsubscription
		
    /* 
    ** Check to see if MSreplication_subscriptions and MSsubscription_properties 
    ** tables exists. If not, create it.
    */
    exec @retcode = sys.sp_MScreate_sub_tables_internal
                @tran_sub_table = 1,
                @property_table = 1
    IF @@ERROR <> 0 or @retcode <> 0
        goto UNDO
    /*
    ** Check to make sure that the subscription does not already exist
    */
    declare @sub_type int
    select @sub_type = subscription_type 
    from MSreplication_subscriptions 
    WHERE UPPER(publisher) = UPPER(@publisher) AND
            publisher_db  = @publisher_db AND
            publication = @publication
    --
    -- It is not allowed to subscribe to the same publication twice even with
    -- differnet subscription type. Raise special error for push
    --
    if @sub_type is not null
    begin
        if @sub_type = 0
        begin
            raiserror (20594, 16, -1)
            GOTO UNDO            
        end
        else
        begin
            RAISERROR (14058, 16, -1)
            GOTO UNDO
        end
    end
    /*
    ** Add the subscription
    */
    INSERT MSreplication_subscriptions  (publisher,
                                                    publisher_db,
                                                    publication,
                                                    independent_agent,
                                                    subscription_type,
                                                    distribution_agent,
                                                    description,
                                                    time,
                                                    transaction_timestamp,
                                                    update_mode,
                                                    immediate_sync)
    VALUES (@publisher,
                    @publisher_db,
                    @publication,
                    @independent_agent_id,    
                    @subscription_type_id,
                    NULL,
                    @description,
                    getdate(),
                    0,
                    @update_mode_id,
                    @immediate_sync
                    )
    IF @@ERROR <> 0
    BEGIN
       RAISERROR (14057, 16, -1)
       GOTO UNDO
    END

    COMMIT TRAN
    RETURN (0)

UNDO:
    IF @@TRANCOUNT > 0
    begin
        ROLLBACK TRAN addpullsubscription
        COMMIT TRAN   
    end
    return 1
END
GO
GRANT EXECUTE ON [sys].[sp_addpullsubscription] TO [public] AS [dbo]
GO
