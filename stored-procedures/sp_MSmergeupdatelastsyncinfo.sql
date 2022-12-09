SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSmergeupdatelastsyncinfo]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSmergeupdatelastsyncinfo] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSmergeupdatelastsyncinfo]
	@subid [uniqueidentifier],
	@last_sync_status [int],
	@last_sync_summary [sysname]
WITH EXECUTE AS CALLER
AS
set nocount on

declare @retcode    int

-- Security check
exec @retcode= sys.sp_MSrepl_PAL_rolecheck @repid = @subid
if @retcode<>0 or @@error<>0 return 1

update dbo.sysmergesubscriptions 
    set last_sync_status = @last_sync_status, 
        last_sync_summary = @last_sync_summary, 
        last_sync_date = getdate()
    where subid = @subid
if @@rowcount <> 1 or @@ERROR<>0
begin
    raiserror('Could not update last sync info', 16, -1)
    return (1)
end
return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSmergeupdatelastsyncinfo] TO [public] AS [dbo]
GO
