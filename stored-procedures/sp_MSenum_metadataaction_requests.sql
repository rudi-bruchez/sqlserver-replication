SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenum_metadataaction_requests]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenum_metadataaction_requests] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenum_metadataaction_requests]
	@tablenick_last [int],
	@rowguid_last [uniqueidentifier],
	@pubid [uniqueidentifier],
	@max_rows [int]
WITH EXECUTE AS CALLER
AS
set nocount on
    declare @retcode int
    
    -- Security check
    exec @retcode= sys.sp_MSreplcheck_subscribe     
    if @retcode<>0 or @@error<>0 return 1

    select top (@max_rows) tablenick, rowguid, action
            from dbo.MSmerge_metadataaction_request
            where (tablenick=@tablenick_last and rowguid>@rowguid_last) 
                            or
                      (tablenick>@tablenick_last)
            order by tablenick asc, rowguid asc

    if @@error<>0 
        return 1
    else 
        return 0
GO
GRANT EXECUTE ON [sys].[sp_MSenum_metadataaction_requests] TO [public] AS [dbo]
GO
