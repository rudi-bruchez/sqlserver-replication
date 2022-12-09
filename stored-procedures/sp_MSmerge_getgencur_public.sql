SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSmerge_getgencur_public]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSmerge_getgencur_public] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSmerge_getgencur_public]
	@tablenick [int],
	@changecount [int],
	@gen_cur [bigint] OUTPUT
WITH EXECUTE AS CALLER
AS
begin
    declare @gen bigint
    declare @retcode int
    
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @tablenick = @tablenick
    if @retcode <> 0 or @@error<> 0
         return 1

    exec @retcode = sys.sp_MSmerge_getgencur @tablenick, @changecount, @gen_cur output

    return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSmerge_getgencur_public] TO [public] AS [dbo]
GO
