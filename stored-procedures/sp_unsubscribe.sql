SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_unsubscribe]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_unsubscribe] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_unsubscribe]
	@publication [sysname],
	@article [sysname]
WITH EXECUTE AS CALLER
AS
-- New 7.0 sp_dropsubscription parameters
    DECLARE @subscriber     sysname
    DECLARE @destination_db sysname    
    DECLARE @retcode        int 

    SET NOCOUNT ON
    
    -- sp_unsubscribe has to be callled from a remote subscriber
    -- If not, we state that it is unsupported
    SELECT @subscriber = @@REMSERVER
    IF @subscriber IS NULL
    BEGIN
        RAISERROR (21023, 16, -1,'sp_unsubscribe')
        RETURN(1)
    END

    -- 6.5 didn't support having multiple databases on the same subscriber
    -- subscribing to the same publication so here, all subscriptions to the
    -- same publication will be dropped 
    SELECT @destination_db = NULL
    
    -- Call sp_dropsubscription to do the real work
    EXEC @retcode = sys.sp_dropsubscription @publication = @publication,
                                        @article = @article,
                                        @subscriber = @subscriber,
                                        @destination_db = @destination_db
    RETURN @retcode
    
GO
GRANT EXECUTE ON [sys].[sp_unsubscribe] TO [public] AS [dbo]
GO
