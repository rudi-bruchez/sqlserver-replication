SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSreleasesnapshotdeliverysessionlock]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSreleasesnapshotdeliverysessionlock] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSreleasesnapshotdeliverysessionlock]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    declare @retcode int
    declare @resource nvarchar(255)
    select @retcode = 0
    exec @retcode = sys.sp_MSreplcheck_subscribe
    if @retcode <> 0 or @@error <> 0
    begin
        select @retcode = 1
        goto FAILURE
    end
    select @resource = N'snapshot_delivery_in_progress_' + 
                       db_name() collate database_default
    exec @retcode = sys.sp_releaseapplock @Resource = @resource,
                                          @LockOwner = 'Session',
                                          @DbPrincipal = N'db_owner'

    if @retcode < 0 or @@error <> 0
    begin
        select @retcode = 1
        goto FAILURE
    end
    select @retcode = 0
FAILURE:
    return @retcode
end
GO
GRANT EXECUTE ON [sys].[sp_MSreleasesnapshotdeliverysessionlock] TO [public] AS [dbo]
GO
