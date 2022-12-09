SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSresetsnapshotdeliveryprogress]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSresetsnapshotdeliveryprogress] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSresetsnapshotdeliveryprogress]
	@snapshot_session_token [nvarchar](260)
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    declare @retcode int
    select @retcode = 0
    exec @retcode = sys.sp_MSreplcheck_subscribe 
    if @retcode <> 0 or @@error <> 0
    begin
        select @retcode = 1
        goto FAILURE
    end
    if object_id('dbo.MSsnapshotdeliveryprogress') is not null
    begin
        delete dbo.MSsnapshotdeliveryprogress
        where session_token = @snapshot_session_token
        if @retcode <> 0 or @@error <> 0
        begin
            select @retcode = 1
            goto FAILURE
        end
    end
    if @retcode <> 0 or @@error <> 0
    begin
        select @retcode = 1
        goto FAILURE
    end


FAILURE:
    return @retcode    
end
GO
GRANT EXECUTE ON [sys].[sp_MSresetsnapshotdeliveryprogress] TO [public] AS [dbo]
GO
