SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSrepl_IsUserInAnyPAL]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSrepl_IsUserInAnyPAL] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSrepl_IsUserInAnyPAL]
	@raise_error [bit]
WITH EXECUTE AS CALLER
AS
-- sysadmin or db_owner have access
    if is_member('db_owner') = 1 
    return 0

    if exists (select name from sys.objects where name='sysmergepublications') and
       exists (select name from dbo.sysmergepublications where ({fn ISPALUSER(pubid)} = 1))
    begin
        return 0
    end
    else
    begin
        if @raise_error = 1
            RAISERROR (14126, 11, -1)
        return (1)
    end
GO
GRANT EXECUTE ON [sys].[sp_MSrepl_IsUserInAnyPAL] TO [public] AS [dbo]
GO
