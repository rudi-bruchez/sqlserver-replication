SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSgetarticlereinitvalue]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSgetarticlereinitvalue] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSgetarticlereinitvalue]
	@subscriber [sysname],
	@subscriberdb [sysname],
	@publication [sysname],
	@artid [int],
	@reinit [int] OUTPUT
WITH EXECUTE AS CALLER
AS
begin
    set NOCOUNT ON
    declare @retcode int
    
    --
    -- return NULL if no parameters supplied
    --
    if ((@subscriber IS NULL) or (@subscriberdb IS NULL) or (@publication is null) or (@artid IS NULL))
    begin
        select @reinit = NULL
        return 1
    end
    --
    -- PAL security check
    --
    exec @retcode = sys.sp_MSreplcheck_pull @publication = @publication
    if @@error <> 0 or @retcode <> 0
    begin
        return (1)
    end
    --
    -- get the value of reinit flag
    --
    select @reinit = queued_reinit 
    from syssubscriptions 
        where srvname = UPPER(@subscriber) 
		and (srvname is not null and len(srvname)> 0)
        and artid = @artid 
        and dest_db = @subscriberdb
    --
    -- All done
    --
    return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSgetarticlereinitvalue] TO [public] AS [dbo]
GO
