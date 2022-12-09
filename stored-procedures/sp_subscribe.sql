SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_subscribe]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_subscribe] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_subscribe]
	@publication [sysname],
	@article [sysname],
	@destination_db [sysname],
	@sync_type [nvarchar](15),
	@loopback_detection [nvarchar](5)
WITH EXECUTE AS CALLER
AS
begin

    -- New 7.0 sp_addsubscription parameters
    DECLARE @subscriber                  sysname
    DECLARE @status                      sysname
    DECLARE @subscription_type           nvarchar(4)
    DECLARE @update_mode                 nvarchar(15)
    DECLARE @enabled_for_syncmgr         nvarchar(5)
    DECLARE @retcode                     int

    SET NOCOUNT ON

    -- sp_subscribe has to be called from a remote subscriber 
    -- If not, we state that it is unsupported
    SELECT @subscriber = @@REMSERVER
    IF @subscriber IS NULL
    BEGIN
      RAISERROR (21023, 16, -1,'sp_subscribe')
      RETURN(1)
    END
    
    SELECT @status = NULL
    SELECT @subscription_type = 'push'
    SELECT @update_mode = 'read only'
    SELECT @enabled_for_syncmgr = 'false'

    -- Call sp_addsubscription to do the actual work
    EXEC @retcode = sys.sp_addsubscription @publication = @publication,
                                           @article = @article,
                                           @destination_db = @destination_db,
                                           @sync_type = @sync_type,
                                           @subscriber = @subscriber,
                                           @status = @status,
                                           @subscription_type = @subscription_type,
                                           @update_mode = @update_mode,
                                           @loopback_detection = @loopback_detection,
                                           @enabled_for_syncmgr = @enabled_for_syncmgr
                                        
    RETURN @retcode   
end
GO
GRANT EXECUTE ON [sys].[sp_subscribe] TO [public] AS [dbo]
GO
