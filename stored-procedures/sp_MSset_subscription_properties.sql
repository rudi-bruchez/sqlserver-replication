SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSset_subscription_properties]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSset_subscription_properties] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSset_subscription_properties]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@subscription_type [int],
	@allow_subscription_copy [bit],
	@queue_id [sysname],
	@update_mode [int],
	@attach_version [binary](16),
	@queue_server [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
    set nocount on
    declare @retcode int
                ,@failover_mode bit

    --  Security Check
    EXEC @retcode = sys.sp_MSreplcheck_subscribe
    IF @@ERROR <> 0 or @retcode <> 0
        RETURN(1)

    -- For non independent agent publications
    if @publication is null or @publication = ''
        set @publication = 'ALL'

    if @queue_server = N''
        select @queue_server = NULL

    if @queue_id = N''
        select @queue_id = NULL

    --
    -- Failover mode is overloaded in @update_mode
    -- Get the proper values for failover_mode and update_mode
    --
    if (@update_mode in (6,7))
    begin
        -- Failover with Queued as the default mode
        if (@update_mode = 6)
        begin
            -- sql queues
            select @update_mode = 5
                     ,@failover_mode = 1
        end
        else
        begin
            -- MQ queues
            select @update_mode = 3
                     ,@failover_mode = 1
        end
    end
    else
    begin
        -- for all other cases, failover_mode should be initialized to 0
        select @failover_mode = 0
    end
    --
    -- Update metadata in MSsubscription_agents
    --
    update dbo.MSsubscription_agents set      
        allow_subscription_copy = @allow_subscription_copy,
        update_mode = @update_mode,
        failover_mode = @failover_mode,
        queue_id = @queue_id,
        queue_server = @queue_server,
        attach_version = @attach_version
    where UPPER(publisher) = UPPER(@publisher)
        and publisher_db =  @publisher_db
        and publication = @publication
        and subscription_type = @subscription_type
    --
    -- for queued pull subscriptions 
    -- update column update_mode in MSreplication_subscriptions
    -- as we never know the right update_mode until initialization
    --
    if ((@subscription_type = 1) and (@queue_id IS NOT NULL) and
    exists (select * from MSreplication_subscriptions 
        WHERE UPPER(publisher) = UPPER(@publisher) AND
            publisher_db  = @publisher_db AND
            publication = @publication AND
            subscription_type = @subscription_type))
    begin
        update MSreplication_subscriptions 
        set update_mode = @update_mode
        WHERE UPPER(publisher) = UPPER(@publisher) AND
            publisher_db  = @publisher_db AND
            publication = @publication AND
            subscription_type = @subscription_type
    end
END
GO
GRANT EXECUTE ON [sys].[sp_MSset_subscription_properties] TO [public] AS [dbo]
GO
