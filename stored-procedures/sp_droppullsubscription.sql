SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_droppullsubscription]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_droppullsubscription] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_droppullsubscription]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@reserved [bit],
	@from_backup [bit]
WITH EXECUTE AS CALLER
AS
BEGIN
    SET NOCOUNT ON

    DECLARE @name                        nvarchar(255)
    DECLARE @retcode                    int
    DECLARE @agent_id                    binary(16)
    DECLARE @job_step_uid				uniqueidentifier
    DECLARE @publisher_ex                sysname
    DECLARE @publisher_db_ex            sysname
    DECLARE @publication_ex                sysname
    DECLARE @expanded                    bit
    DECLARE @subscription_type_id        int
    DECLARE @count_sub                    int
    DECLARE @drop_null_pub                bit
    DECLARE @drop_push_bit                bit
    DECLARE @push                        int
    DECLARE @implicit_transaction        int
    DECLARE @close_cursor_at_commit        int
    DECLARE @owner_sid                    varbinary(85)
    DECLARE @owner_name                    sysname
    DECLARE @qualified_publication_name    nvarchar(512)
    DECLARE @publisherlinkusertodrop       sysname
    SELECT @expanded = 0
    SELECT @drop_null_pub = 0
    SELECT @push = 0

    -- Get the original set value off IMPLICIT_TRANSACTIONS and CURSOR_CLOSE_ON_COMMIT
    -- before set these two to off
    select @implicit_transaction = 0
    select @close_cursor_at_commit = 0

    IF (@reserved = 0)
    BEGIN
        SELECT @implicit_transaction = @@options & 2
        SELECT @close_cursor_at_commit = @@options & 4
        SET IMPLICIT_TRANSACTIONS OFF
        SET CURSOR_CLOSE_ON_COMMIT OFF
    END

    -- Security Check
    EXEC @retcode = sys.sp_MSreplcheck_subscribe
    IF @@ERROR <> 0 or @retcode <> 0
        RETURN(1)

    SELECT @drop_push_bit = 0   
    
    -- Check parameter and set expressions used by cursor
    
    IF @publisher IS NULL
    BEGIN
        RAISERROR (14043, 16, -1, '@publisher', 'sp_droppullsubscription')
        RETURN (1)
    END

    IF @publisher = 'all'
    BEGIN
        SELECT @publisher_ex = '%'
        SELECT @expanded = 1
    END
    ELSE
    BEGIN
        EXECUTE @retcode = sys.sp_validname @publisher
        IF @retcode <> 0
        RETURN (1)
        SELECT @publisher_ex = @publisher
    END

    IF @publisher_db = 'all'
    BEGIN
        SELECT @publisher_db_ex = '%'
        select @expanded = 1
    END
    ELSE IF @publisher_db IS NOT NULL
    BEGIN
        SELECT @publisher_db_ex = @publisher_db
    END
    ELSE
    BEGIN
        -- @publisher_db is NULL for Oracle publishers only
        SELECT    @publisher_db     = @publisher,
                @publisher_db_ex = @publisher
    END

    -- Publication '' is not a valid name but it may be in the publication name in the table. 
    IF @publication IS NULL OR @publication = ''
    BEGIN
        SELECT @drop_null_pub = 1
    END
    ELSE IF @publication = 'all'
    BEGIN
        SELECT @publication_ex = '%'
        SELECT @expanded = 1
        SELECT @drop_null_pub = 1
    END
    ELSE
    BEGIN
        EXECUTE @retcode = sys.sp_validname @publication
        IF @retcode <> 0
        RETURN (1)
        SELECT @publication_ex = @publication
    END

    -- Check to see if the  subscription table exists
    IF object_id('MSreplication_subscriptions', 'U') is NULL
    BEGIN
        IF @expanded = 0
        BEGIN
            RAISERROR(14135, 11, -1,  @publisher, @publisher_db, @publication)
            RETURN(1)
        END
        ELSE
        BEGIN
            RETURN(0)
        END
    END

    IF @expanded = 0 
    BEGIN 
        -- Check to see if the subscription entry exists
        IF NOT EXISTS
        (
            SELECT    *
            FROM     MSreplication_subscriptions 
            WHERE    UPPER(publisher) = UPPER(@publisher)
              AND    publisher_db = @publisher_db
              AND    publication = @publication
        )
        BEGIN
            RAISERROR(14135, 11, -1, @publisher, @publisher_db, @publication)
            RETURN(1)
        END

        -- Make sure the subscription is not push type if @drop_push_bit = 0
        IF @drop_push_bit = 0
        BEGIN
            IF EXISTS
            (
                SELECT    *
                FROM    MSreplication_subscriptions 
                WHERE    UPPER(publisher) = UPPER(@publisher)
                  AND    publisher_db = @publisher_db
                  AND    publication = @publication
                  AND    subscription_type = @push
                  AND    @drop_push_bit = 0
            )
            BEGIN
                RAISERROR(20017, 16, -1)
                RETURN(1)
            END
        END
    END
    ELSE
    BEGIN
        -- Open a cursor and call recursively if
        -- parameters are expanded.
        -- Note: Any expression check on null value is false
        -- @subscription_type_id is NULL <==> push
        -- @subscription_type_id is NOT NULL <==> non push
        -- Have to use static cursor option because 
        DECLARE hCdroppullsubscription CURSOR STATIC LOCAL FORWARD_ONLY FOR
        SELECT DISTINCT    publisher,
                        publisher_db,
                        publication
        FROM    MSreplication_subscriptions
        WHERE    ((@publisher_ex = N'%') OR (UPPER(publisher) = UPPER(@publisher_ex)))
          AND    ((@publisher_db_ex = N'%') OR ( publisher_db = @publisher_db_ex))
          AND    (publication LIKE @publication_ex OR (@drop_null_pub = 1 AND publication IS NULL))
          AND    ((@drop_push_bit =0 AND subscription_type <> @push) OR @drop_push_bit = 1)
        FOR READ ONLY
        
        OPEN    hCdroppullsubscription
        FETCH    hCdroppullsubscription
        INTO    @publisher,
                @publisher_db,
                @publication

        WHILE (@@fetch_status <> -1)
        BEGIN
            EXEC @retcode =    sys.sp_droppullsubscription    @publisher        = @publisher, 
                                                        @publisher_db    = @publisher_db,
                                                        @publication    = @publication, 
                                                        @reserved        = 1,
                                                        @from_backup    = @from_backup

            FETCH    hCdroppullsubscription
            INTO    @publisher, 
                    @publisher_db,
                    @publication
        END

        CLOSE hCdroppullsubscription
        DEALLOCATE hCdroppullsubscription

        RETURN (0)
    END
    
    -- Only members of the sysadmin group and the creator of the distribution
    -- agent can drop a pull subscription successfully. This behavior matches 
    -- the behavior of the sysjobs_view. DBO of the subscriber database, 
    -- sysadmins (owner is undefined) can drop a subscription if the owner_sid 
    -- is null.
    EXEC sys.sp_MSget_pullsubsagent_owner @publisher    = @publisher,
                                          @publisher_db    = @publisher_db,
                                          @publication    = @publication,
                                          @owner_sid    = @owner_sid OUTPUT

    IF (@owner_sid IS NOT null AND (SUSER_SID() <> @owner_sid) AND
        (ISNULL(IS_SRVROLEMEMBER('sysadmin'),0) = 0))
    BEGIN
        SELECT @owner_name = SUSER_SNAME(@owner_sid)
        SELECT @qualified_publication_name = @publisher + N':' + 
                                             @publisher_db + N':' +
                                             @publication

        RAISERROR(21121,16,-1,@owner_name, @qualified_publication_name) 

        RETURN (1)
    END

    -- Get the agent name, it may be dropped later.
    -- Adding condition 'agent_id IS NOT NULL' to WHERE clause to handle 
    -- NULL agent_id entries that are added when Subscription Stream is used.
    SELECT @agent_id = agent_id
    FROM    MSreplication_subscriptions
    WHERE    UPPER(publisher) = UPPER(@publisher)
      AND    publisher_db = @publisher_db
      AND    publication = @publication 
      AND    agent_id IS NOT NULL

	SELECT @job_step_uid = job_step_uid
    FROM MSsubscription_properties
    WHERE UPPER(publisher) = UPPER(@publisher)
       AND publisher_db = @publisher_db
       AND publication = @publication
       AND publication_type IN (0, 1)
       
    -- If the agent is used by other subscription, don't drop it.
    IF (SELECT count(*) FROM MSreplication_subscriptions WHERE agent_id = @agent_id) > 1
    BEGIN
        SELECT @agent_id = NULL
    END

    -- Unlink the publisher from subscription (updating subscriptions)
    -- Need to do this outside explicit transaction
    set @publisherlinkusertodrop = null
    exec @retcode = sys.sp_unlink_publication_internal 
        @publisher = @publisher
        ,@publisher_db = @publisher_db
        ,@publication = @publication
        ,@publisherlinkusertodrop = @publisherlinkusertodrop OUTPUT
    if (@retcode != 0 or @@error != 0)
        return (1)

    BEGIN TRAN
    SAVE TRAN droppullsubscription

    -- Drop the subscription entry and the distribution agent if it exists 
    -- If the distribution agent is not used anymore,
    -- drop the agent if it exists
    IF @agent_id IS NOT NULL
    BEGIN
        IF EXISTS
        (
            SELECT    *
            FROM    msdb.dbo.sysjobs_view
            WHERE    job_id = @agent_id
        )
        BEGIN
            -- Checks if the job name matches one that is generated
            -- by replication
            EXEC @retcode = sys.sp_MSispulldistributionjobnamegenerated @publisher		= @publisher,
                                                                        @publisher_db   = @publisher_db,
                                                                        @publication    = @publication,
                                                                        @job_id         = @agent_id

            IF @@ERROR <> 0
            BEGIN
                GOTO UNDO
            END

            -- Only drop jobs if the name was generated
            IF @retcode = 0
            BEGIN
                EXEC @retcode = sys.sp_MSdrop_repl_job @job_id = @agent_id,
                										@job_step_uid = @job_step_uid

                IF @@ERROR <> 0 or @retcode <> 0
                BEGIN
                    GOTO UNDO
                END

                -- Delete MSreplication_subsciptions table after dropping 
                -- the distribution agent and delay one second
                -- to avoid deadlock with it.
                WAITFOR DELAY '00:00:01'
            END
        END

    END

    -- Call sp_MSunregistersubscription so that the reg entries get deleted
    DECLARE @subscriber_db sysname
    SET @subscriber_db = DB_NAME()

    EXEC @retcode =    sys.sp_MSunregistersubscription    @publisher        = @publisher,
                                                    @publisher_db    = @publisher_db,
                                                    @publication    = @publication,
                                                    @subscriber        = @@SERVERNAME,
                                                    @subscriber_db    = @subscriber_db

    IF @retcode != 0 OR @@ERROR != 0
    BEGIN
        GOTO UNDO
    END
    
    IF OBJECT_ID('MSsubscription_properties') IS NOT NULL
    BEGIN
        DELETE FROM MSsubscription_properties 
        WHERE    UPPER(publisher) = UPPER(@publisher)
          AND    publisher_db = @publisher_db
          AND    publication = @publication 

        IF @@ERROR <> 0
        BEGIN
            GOTO UNDO
        END

        IF NOT EXISTS (SELECT * FROM MSsubscription_properties)
        BEGIN
            exec @retcode = sys.sp_MSsub_cleanup_prop_table

            IF @@ERROR <> 0 OR @retcode <> 0
               BEGIN
                GOTO UNDO
            END
        END
    END
    
    -- Clean up metadata at subscriber side
    -- Note: sp_subscription_cleanup should be called after deleting the row
    -- in MSreplication_subscriptions.
    exec @retcode = sys.sp_subscription_cleanup    @publisher        = @publisher,
                                                @publisher_db    = @publisher_db,
                                                @publication    = @publication,
                                                @from_backup    = @from_backup

    IF @retcode<>0 OR @@ERROR<>0
    BEGIN
        GOTO UNDO
    END

    --
    -- drop table MSreplication_subscriptions if empty and
    -- not in recursive call
    --
    IF OBJECT_ID('MSreplication_subscriptions') IS NOT NULL
    BEGIN
        IF (@reserved = 0 AND NOT EXISTS (SELECT * FROM MSreplication_subscriptions))
        BEGIN
            DROP TABLE MSreplication_subscriptions

            IF @@ERROR <> 0
            BEGIN
                GOTO UNDO
            END
        END
    END

    COMMIT TRAN

    if @publisherlinkusertodrop is not null
    begin
        exec @retcode = sys.sp_dropuser @name_in_db = @publisherlinkusertodrop
        if @@error <> 0 or @retcode <> 0
            return (1)        
    end

    -- Set back the two settings if needed 
    if @reserved = 0
    BEGIN
        IF @implicit_transaction <>0 
            SET IMPLICIT_TRANSACTIONS ON
        IF @close_cursor_at_commit <>0 
            SET CURSOR_CLOSE_ON_COMMIT ON
    END
    RETURN (0)

UNDO:
    IF @@TRANCOUNT > 0
    BEGIN
        ROLLBACK TRAN droppullsubscription
        COMMIT TRAN   
    END

    -- Set back the two settings if needed
    if @reserved = 0
    BEGIN
        IF @implicit_transaction <>0 
            SET IMPLICIT_TRANSACTIONS ON
        IF @close_cursor_at_commit <>0 
            SET CURSOR_CLOSE_ON_COMMIT ON
    END

    RETURN (1)
END
GO
GRANT EXECUTE ON [sys].[sp_droppullsubscription] TO [public] AS [dbo]
GO
