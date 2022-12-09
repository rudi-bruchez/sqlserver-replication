SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_repldeletequeuedtran]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_repldeletequeuedtran] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_repldeletequeuedtran]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@tranid [sysname],
	@orderkeylow [bigint],
	@orderkeyhigh [bigint]
WITH EXECUTE AS CALLER
AS
begin
    declare @retcode int
    set nocount on
    --
    -- Security check
    --
    exec @retcode = sp_MSreplcheck_subscribe
    if @@error != 0 or @retcode != 0
        return 1
    --
    -- validate inputs
    --
    if (@tranid is null 
            or @orderkeylow is null or @orderkeylow = 0 
            or @orderkeyhigh is null or @orderkeyhigh = 0
            or @orderkeyhigh < @orderkeylow)
        return 1
    --
    -- begin local transaction
    --
    begin transaction sp_repldeletequeuedtran
    save transaction sp_repldeletequeuedtran
    --
    -- delete rows from MSreplication_queue
    --
    delete dbo.MSreplication_queue with (rowlock)
    where publisher = UPPER(@publisher)
        and publisher_db = @publisher_db
        and publication = @publication
        and tranid = @tranid 
        and orderkey between @orderkeylow and @orderkeyhigh
    if (@@error != 0)
        goto Error
    --
    -- delete row from MSrepl_queuedtraninfo
    --
    delete dbo.MSrepl_queuedtraninfo with (rowlock)
    where publisher = UPPER(@publisher)
        and publisher_db = @publisher_db
        and publication = @publication
        and tranid = @tranid 
    if (@@error != 0)
        goto Error
    --
    -- commit local transaction
    --
    commit transaction sp_repldeletequeuedtran
    --
    -- all done
    --
    return 0

Error:
    rollback transaction sp_repldeletequeuedtran
    commit transaction
    return 1
end
GO
GRANT EXECUTE ON [sys].[sp_repldeletequeuedtran] TO [public] AS [dbo]
GO
