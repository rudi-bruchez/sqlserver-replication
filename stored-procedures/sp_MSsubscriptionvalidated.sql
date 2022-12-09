SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSsubscriptionvalidated]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSsubscriptionvalidated] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSsubscriptionvalidated]
	@subid [uniqueidentifier],
	@pubid [uniqueidentifier],
	@log_attempt [bit]
WITH EXECUTE AS CALLER
AS
declare @now datetime
    declare @retcode int

    select @now=getdate()
    
    if ({fn ISPALUSER(@pubid)} <> 1)
    begin
        if (@pubid is NULL)
        begin
                RAISERROR (21723, 16, -1, 'sp_MSsubscriptionvalidated')
                return 1
        end
        else
        begin
                RAISERROR (14126, 11, -1)
                return 1
        end
    end

    if @log_attempt=0
        update dbo.sysmergesubscriptions set last_validated = @now, attempted_validate=@now
            where subid = @subid and pubid = @pubid
    else
        update dbo.sysmergesubscriptions set attempted_validate = @now
            where subid = @subid and pubid = @pubid     
    if @@rowcount <> 1 or @@error <> 0
    begin
        RAISERROR (20070, 16, -1)
        return (1)
    end
    return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSsubscriptionvalidated] TO [public] AS [dbo]
GO
