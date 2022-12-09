SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSreset_attach_state]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSreset_attach_state] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSreset_attach_state]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@subscription_type [int]
WITH EXECUTE AS CALLER
AS
BEGIN
    set nocount on
    declare  @retcode int
                ,@agent_id int

    --
    --  Security Check
    --
    EXEC @retcode = sys.sp_MSreplcheck_subscribe
    IF @@ERROR <> 0 or @retcode <> 0
        RETURN(1)
    --
    -- For non independent agent publications
    --
    if @publication is null or @publication = ''
        select @publication = 'ALL'
    --
    -- complete the operation in a transaction
    --
    begin transaction
    --
    -- Processing specific to Queued updating subscriptions
    --
    select @agent_id = id
    from dbo.MSsubscription_agents 
    where UPPER(publisher) = UPPER(@publisher)
        and publisher_db =  @publisher_db
        and publication = @publication
        and subscription_type = @subscription_type
        and update_mode in (2,3,4,5)
    if (@agent_id is not null)
    begin
        --
        -- reinitialize the queue for each article in this subscription
        --
        declare @artid int        
        declare #hc_article CURSOR LOCAL FORWARD_ONLY for 
            select artid 
            from dbo.MSsubscription_articles 
            where agent_id = @agent_id
        open #hc_article
        fetch #hc_article into @artid
        while (@@fetch_status != -1)
        begin        
            --
            -- we cannot have an NULL article id
            --
            if (@artid IS NULL)
            begin
                raiserror(20046, 16, 1)
                goto failure
            end
            --
            -- reset the queue
            --
            exec @retcode = sys.sp_MSreset_queue @publisher, @publisher_db, @publication, @artid
            IF (@retcode != 0 or @@ERROR != 0)
            begin
                raiserror(21465, 16, 1, 'sp_MSreset_queue')
                goto failure
            end
            --
            -- fetch next article
            --
            fetch #hc_article into @artid
        end -- while cursor
        close #hc_article
        deallocate #hc_article
    end -- end processing queued subscription
    --
    -- Update the attach state
    --
    update MSsubscription_agents 
    set attach_state = 0
    where UPPER(publisher) = UPPER(@publisher)
        and publisher_db =  @publisher_db
        and publication = @publication
        and subscription_type = @subscription_type
    if (@@error != 0)
        goto failure
    --
    -- All done 
    -- commit the transaction
    --
    commit transaction
    return (0)
failure:
    --
    -- Rollback transaction
    --
    if (@@trancount > 0)
        rollback transaction
    return (1)
END
GO
GRANT EXECUTE ON [sys].[sp_MSreset_attach_state] TO [public] AS [dbo]
GO
