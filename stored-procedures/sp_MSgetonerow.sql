SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSgetonerow]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSgetonerow] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSgetonerow]
	@tablenick [int],
	@rowguid [uniqueidentifier],
	@pubid [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
declare @retcode    smallint
    declare @procname   sysname

    /*
    ** Check to see if current publication has permission
    */
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @pubid = @pubid, @tablenick = @tablenick
    if (@retcode <> 0) or (@@error <> 0)
        return 1
    
    select @procname = 'dbo.' + select_proc from dbo.sysmergearticles where nickname = @tablenick and pubid=@pubid
    
    exec @retcode = @procname @maxschemaguidforarticle = NULL, @type =1, @rowguid=@rowguid
    IF @@ERROR<>0 or @retcode<>0 RETURN (1)
    return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSgetonerow] TO [public] AS [dbo]
GO
