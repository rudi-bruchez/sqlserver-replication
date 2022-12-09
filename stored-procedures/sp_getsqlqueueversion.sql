SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_getsqlqueueversion]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_getsqlqueueversion] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_getsqlqueueversion]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@version [int] OUTPUT
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    declare @retcode int
                ,@queueidstring sysname

    --
    -- Security check
    --
    exec @retcode = sp_MSreplcheck_subscribe
    if @@error != 0 or @retcode != 0
        return 1
    --
    -- the subscription must be initialized
    --
    if exists (select * from sys.objects where name = 'MSsubscription_agents')
    begin
        --
        -- do the select for sql queues
        --
        select @queueidstring = substring(queue_id, 1, 10) 
                 ,@version = cast(substring(queue_id, 12, 10)  as int)
        from dbo.MSsubscription_agents
        where publisher = UPPER(@publisher) 
            and publisher_db = @publisher_db 
            and publication = @publication
            and update_mode in (4,5)
        if (@queueidstring = N'mssqlqueue')
        begin
            --
            -- found the entry
            --
            if (@version = 0)
                select @version = 1
        end
        else
        begin
            --
            -- No subscription exists
            --
            select @version = 0
            return 0
        end
    end
    else
    begin
        --
        -- No subscription exists
        --
        select @version = 0
        return 0
    end
    --
    -- all done
    --
    return 0
end
GO
GRANT EXECUTE ON [sys].[sp_getsqlqueueversion] TO [public] AS [dbo]
GO
