SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdropretry]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdropretry] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdropretry]
	@tname [sysname],
	@pname [sysname]
WITH EXECUTE AS CALLER
AS
declare @retcode int
    declare @quotedtname nvarchar(258) -- max characters that quotename can return
    declare @quotedpname nvarchar(258)

    /*
    ** Check to see if current publication has permission
    */
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck 
    if (@retcode <> 0) or (@@error <> 0)
            return 1

    select @quotedtname = quotename(@tname)
    select @quotedpname = quotename(@pname)

    exec ('drop table ' + @quotedtname)
    if @@ERROR <> 0 return(1)
    exec ('drop procedure ' + @quotedpname)
    if @@ERROR <> 0 return(1)
    return (0)  
GO
GRANT EXECUTE ON [sys].[sp_MSdropretry] TO [public] AS [dbo]
GO
