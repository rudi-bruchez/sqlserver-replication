SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSget_type_wrapper]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSget_type_wrapper] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSget_type_wrapper]
	@tabid [int],
	@colid [int],
	@colname [sysname] OUTPUT,
	@typestring [nvarchar](4000) OUTPUT
WITH EXECUTE AS CALLER
AS
begin
    declare @retcode int
    
    -- Since Merge needs this proc to be public we will put a dbo check here
    exec @retcode = sys.sp_MSreplcheck_publish
    if @retcode <> 0 or @@error<> 0
        return 1

    -- now we will call sp_MSget_type with tempdb context
    exec @retcode = tempdb.sys.sp_MSget_type @tabid, @colid, @colname output, @typestring output
    return @retcode
end
GO
GRANT EXECUTE ON [sys].[sp_MSget_type_wrapper] TO [public] AS [dbo]
GO
