SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSchange_priority]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSchange_priority] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSchange_priority]
	@subid [uniqueidentifier],
	@value [nvarchar](255)
WITH EXECUTE AS CALLER
AS
declare @retcode int
    exec @retcode = dbo.sp_MSreplcheck_subscribe
    if @retcode <> 0 or @@error <> 0
        return 1
        
    update dbo.sysmergesubscriptions set priority = convert(real, @value)
           where subid = @subid
GO
GRANT EXECUTE ON [sys].[sp_MSchange_priority] TO [public] AS [dbo]
GO
