SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_helpreplfailovermode]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_helpreplfailovermode] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_helpreplfailovermode]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@failover_mode_id [tinyint] OUTPUT,
	@failover_mode [nvarchar](10) OUTPUT
WITH EXECUTE AS CALLER
AS
BEGIN
    declare    @subfound bit
            ,@retcode int
            ,@update_mode int

    --
    -- security check
    --
    exec @retcode = sys.sp_MSreplcheck_subscribe
    if @@error <> 0 or @retcode <> 0
    begin
        return (1)
    end
    --
    -- Check if the table MSsubscription_agents exists
    --
    if object_id('MSsubscription_agents') is not NULL
    begin
        --
        -- Only valid to get failover_mode, if failover_mode is failover (3,5)
        --
        if exists (select * from dbo.MSsubscription_agents
                where UPPER(publisher) = UPPER(@publisher) and 
                    publisher_db = @publisher_db and
                    publication = @publication and
                    update_mode in (3,5) )
            select @subfound = 1
        else
            select @subfound = 0
    end
    else
        select @subfound = 0
    
    --
    -- Did we find an entry for initialized failover subscription
    --
    if (@subfound = 0)
    begin
        --
        -- Three possibilities : uninitialized subscription, non existent subscription
        -- or a non-mixed mode. Check If we have a PULL uninitialized subscription
        --
        if object_id('MSreplication_subscriptions') is not NULL
        begin                
            select @update_mode = update_mode 
            from dbo.MSreplication_subscriptions
            where publisher = @publisher 
                and publisher_db = @publisher_db
                and publication = @publication 
            if (@update_mode is null)
            begin
                select @subfound = 0
            end
            begin
                --
                -- unitialized PULL subscription : return the values
                --
                select @failover_mode_id = case when (@update_mode = 6) then 1 else 0 end
                select @subfound = 1
            end
        end

        if (@subfound = 0)
        begin
            raiserror(20588, 16, -1)
            return 1
        end
    end
    else
    begin
        --
        -- we found our subscription
        --
        select @failover_mode_id = cast(failover_mode as tinyint)
        from dbo.MSsubscription_agents
        where UPPER(publisher) = UPPER(@publisher) and 
            publisher_db = @publisher_db and
            publication = @publication and
            update_mode in (3,5) 
        --
        -- initialize to 'immediate' if necessary
        --
        if @failover_mode_id not in (0, 1)
        begin
            raiserror (22576, 11, 1, @failover_mode_id, @publisher, @publisher_db, @publication)
            update dbo.MSsubscription_agents 
            set failover_mode = 0
            where UPPER(publisher) = UPPER(@publisher) and 
                publisher_db = @publisher_db and
                publication = @publication and
                update_mode in (3,5) 

            select @failover_mode_id = 0
        end
    end
    --
    -- prepare the output
    --
    select @failover_mode = case 
        when @failover_mode_id = 0 then N'immediate'
        when @failover_mode_id = 1 then N'queued'
        end
        
    select N'failover_mode value'  = @failover_mode_id, 
            N'failover_mode' = @failover_mode
    --
    -- all done
    --
    return 0
END
GO
GRANT EXECUTE ON [sys].[sp_helpreplfailovermode] TO [public] AS [dbo]
GO
