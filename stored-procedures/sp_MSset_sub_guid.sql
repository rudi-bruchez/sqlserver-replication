SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSset_sub_guid]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSset_sub_guid] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSset_sub_guid]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@subscription_type [int],
	@subscription_guid [binary](16),
	@queue_id [sysname],
	@queue_server [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
    set nocount on
    declare @retcode int
                ,@independent_agent bit
                ,@subqueue_id sysname

    --  Security Check
    EXEC @retcode = sys.sp_MSreplcheck_subscribe
    IF @@ERROR <> 0 or @retcode <> 0
        RETURN(1)

    -- For non independent agent publications
    if @publication is null or @publication = ''
    begin
        select @publication = 'ALL'
                ,@independent_agent = 0
    end
    else
        select @independent_agent = 1

    if @queue_id = N''
        select @queue_id = NULL

    if @queue_server = N''
        select @queue_server = NULL
    --
    -- Special processing when we are dealing with pull SQL queue updating subscription
    --
    if ((@subscription_type = 1) and substring(@queue_id, 1, 10) = N'mssqlqueue')
    begin
        --
        -- For SQL Queue case - Check the current queue_id on the table
        --
        select @subqueue_id = queue_id
        from dbo.MSsubscription_agents
        where UPPER(publisher) = UPPER(@publisher)
            and publisher_db =  @publisher_db
            and publication = @publication
            and subscription_type = @subscription_type
        if (@subqueue_id is not NULL and substring(@subqueue_id, 1, 10) = N'mssqlqueue')
        begin
            --
            -- Use the local Queue ID on subscriber as this contains the queue version. 
            -- We are attaching an initialized subscription and do not want to change the 
            -- queue version stored in queue_id for SQL Queues. The value passed by Distribution
            -- Agent is from the distributor metadata and does not contain the queue version information.
            -- This is specific to SQL Queues only.
            --
            select @queue_id = @subqueue_id
        end
    end
    --
    -- Update metadata in MSsubscription_agents
    --
    update MSsubscription_agents set      
        queue_id = @queue_id
        ,queue_server = @queue_server
    where UPPER(publisher) = UPPER(@publisher)
    and publisher_db =  @publisher_db
    and publication = @publication
    and subscription_type = @subscription_type

    update MSreplication_subscriptions set      
        [time] = getdate(),
        subscription_guid = @subscription_guid
    where UPPER(publisher) = UPPER(@publisher)
        and publisher_db =  @publisher_db
        and (@independent_agent = 0 or publication = @publication)
        and subscription_type = @subscription_type
        and independent_agent = @independent_agent
END
GO
GRANT EXECUTE ON [sys].[sp_MSset_sub_guid] TO [public] AS [dbo]
GO
