SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSreleasemakegenerationapplock]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSreleasemakegenerationapplock] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSreleasemakegenerationapplock]
WITH EXECUTE AS CALLER
AS
set nocount on

    declare @retcode smallint
    declare @lock_resource nvarchar(255)
    declare @DbPrincipal sysname

    -- Security check
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck 
    if (@retcode <> 0) or (@@error <> 0)
            return 1
    
    select @retcode = 0
    select @lock_resource = N'MSinternal_makegeneration_inprogress' + 
                convert(nvarchar(11), db_id())
                
    if exists (select * from sys.database_principals where name=N'MSmerge_PAL_role' and type = 'R')
        select @DbPrincipal = N'MSmerge_PAL_role'
    else
        select @DbPrincipal = N'db_owner'
                
       exec @retcode = sp_releaseapplock @Resource = @lock_resource, @LockOwner = N'Session', @DbPrincipal = @DbPrincipal
       if @@error <> 0 or @retcode < 0
        return (1)    
    else
        return (0)
                
GO
GRANT EXECUTE ON [sys].[sp_MSreleasemakegenerationapplock] TO [public] AS [dbo]
GO
