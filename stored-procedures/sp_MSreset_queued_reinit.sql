SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSreset_queued_reinit]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSreset_queued_reinit] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSreset_queued_reinit]
	@subscriber [sysname],
	@subscriber_db [sysname],
	@artid [int]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    declare @retcode int
                ,@publication sysname
    --
    -- PAL security check
    -- Get publication name using artid
    --
    select @publication = p.name
    from syspublications p join sysarticles a on p.pubid = a.pubid
    where a.artid = @artid
    if (@publication is null)
    begin
        return (1)
    end
    exec @retcode = sys.sp_MSreplcheck_pull @publication = @publication
    if @@error <> 0 or @retcode <> 0
    begin
        return (1)
    end
    --
    -- Validate @subscriber
    --
    --
    -- validate @subscriber_db, @artid
    --
    if exists (select * 
        from dbo.syssubscriptions
        where artid = @artid 
            and srvname = UPPER(@subscriber) 
            and dest_db = @subscriber_db)
    begin
        --
        -- set the reinit flag
        --
        update dbo.syssubscriptions
        set queued_reinit = 0
        where artid = @artid 
            and srvname = UPPER(@subscriber) 
            and dest_db = @subscriber_db
        if (@@error != 0)
            return (1)
    end
    else
    begin
        return (1)
    end
    --
    -- all done
    --
    return (0)
end            
GO
GRANT EXECUTE ON [sys].[sp_MSreset_queued_reinit] TO [public] AS [dbo]
GO
