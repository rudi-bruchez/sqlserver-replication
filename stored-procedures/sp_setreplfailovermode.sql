SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_setreplfailovermode]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_setreplfailovermode] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_setreplfailovermode]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@failover_mode [nvarchar](10),
	@override [tinyint]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    declare @failover_mode_id bit, 
            @current_failover_mode_id bit,
            @retcode int,
            @queue_id sysname,
            @fqueue_empty int,
            @update_mode int,
            @queue_server sysname

    --
    -- security check
    --
    exec @retcode = sys.sp_MSreplcheck_subscribe
    if @@error <> 0 or @retcode <> 0
        return (1)
    --
    -- validate @failover_mode
    --
    if @failover_mode not in (N'immediate', N'sync', N'queued')
    begin
        raiserror (21184, 16, 1, N'@failover_mode', N'immediate', N'sync', N'queued')
        return 1            
    end
    select @failover_mode_id = case when (@failover_mode in (N'immediate', N'sync')) then 0 else 1 end
    --
    -- MSsubscription_agents should exist
    --
    if not exists (select * from sys.objects where name = N'MSsubscription_agents')
    begin
        raiserror(20588, 16, -1)
        return 1
    end
    --
    -- Only valid to get/set failover_mode, 
    -- if update_mode is failover (3,5)
    --
    select    @queue_id = queue_id, 
            @queue_server = queue_server,
            @current_failover_mode_id = failover_mode,
            @update_mode = update_mode
    from MSsubscription_agents
    where UPPER(publisher) = UPPER(@publisher) and 
        publisher_db = @publisher_db and
        publication = @publication and
        update_mode in (3,5)
    --
    -- no such row exists
    --
    if (@current_failover_mode_id is NULL)        
    begin
        raiserror (21185, 16, 1)
        return 1
    end
    --
    -- should have a queue entry
    --
    if (@queue_id is NULL)
    begin
        raiserror(21186, 16, 1, @publisher)
        return 1
    end
    --
    -- do the transition
    --
    if ((@current_failover_mode_id = 0 and @failover_mode_id = 0) or
            (@current_failover_mode_id = 1 and @failover_mode_id = 1))
    begin
        --
        -- Going from immediate to immediate, queued to queued is no-op
        --
        raiserror (21187, 16, 1)
    end
    else if (@current_failover_mode_id = 0 and @failover_mode_id = 1)
    begin
        --
        -- Going from immediate to queued : update MSsubscription_agents
        --
        update MSsubscription_agents
            set failover_mode = @failover_mode_id
            where UPPER(publisher) = UPPER(@publisher) and 
                publisher_db = @publisher_db and
                publication = @publication and
                update_mode in (3,5)
        --
        -- create queue if necessary
        --
        if object_id(N'dbo.MSreplication_queue') is null
        begin
            exec @retcode = sp_MScreate_sub_tables_internal
                @tran_sub_table = 0,
                @property_table = 0,
                @sqlqueue_table = 1
        end
        --
        -- We are done
        --
        raiserror (21188, 10, 1, 'immediate', 'queued')
    end
    else if (@current_failover_mode_id = 1 and @failover_mode_id = 0)
    begin
        --
        -- Going from queued to immediate : if override is not set
        -- then check if the queue is empty and then allow if empty.
        -- If override is set, just update MSsubscription_agents
        --
        if (@override = 0)
        begin
            if (@update_mode = 3)
            begin
                --
                -- MSMQ processing
                -- prefix the queue_id with queue server in direct format
                -- and then perform peek in the queue
                --
                select @queue_id = N'DIRECT=OS:' + @queue_server + N'\PRIVATE$\' + @queue_id
                exec @retcode = sys.xp_peekqueue @queue_id, @fqueue_empty output, 0
                if (@@error != 0 or @retcode != 0)
                begin
                    raiserror(21465, 16, 1, 'xp_peekqueue')
                    return 1
                end
                --
                -- queue should be empty
                --
                if (@fqueue_empty != 1)
                begin
                    raiserror(21189, 16, 1, @queue_id)
                    return 1
                end
            end
            else
            begin
                --
                -- SQL Queue processing
                -- MSreplication_queue should exist
                --
                if object_id(N'dbo.MSreplication_queue') is null
                begin
                    raiserror(20588, 16, -1)
                    return 1
                end
                --
                -- queue should be empty
                --
                if exists (select * from MSreplication_queue 
                    where UPPER(publisher) = UPPER(@publisher) and 
                            publisher_db = @publisher_db and
                            publication = @publication )
                begin
                    raiserror(21189, 16, 2, @queue_id)
                    return 1
                end
            end
        end
        else
        begin
            raiserror(21190, 10, 1, 'queued', 'immediate')
        end
        --
        -- update MSsubscription_agents
        --
        update MSsubscription_agents
            set failover_mode = @failover_mode_id
            where UPPER(publisher) = UPPER(@publisher) and 
                publisher_db = @publisher_db and
                publication = @publication and
                update_mode in (3,5)

        raiserror (21188, 10, 1, 'queued', 'immediate')
    end
    --
    -- All done
    --
    return 0
end
GO
GRANT EXECUTE ON [sys].[sp_setreplfailovermode] TO [public] AS [dbo]
GO
