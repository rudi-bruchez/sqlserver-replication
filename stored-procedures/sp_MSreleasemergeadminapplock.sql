SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSreleasemergeadminapplock]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSreleasemergeadminapplock] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSreleasemergeadminapplock]
	@lockowner [nvarchar](32)
WITH EXECUTE AS CALLER
AS
begin
    set nocount on

    declare @retcode smallint
    declare @lock_resource nvarchar(255)
    declare @publisher sysname
    declare @publisher_db sysname
    declare @DbPrincipal sysname 

    select @publisher = publishingservername() 
    select @publisher_db = DB_NAME(DB_ID()) 

    /* 
    ** Security Check.
    */
    exec @retcode = sys.sp_MSreplcheck_publish
    if @retcode<>0 or @@error<>0
        return 1
        
    select @retcode = 0
    
    -- use the dbowner role
    select @DbPrincipal = N'db_owner'
    select @lock_resource = N'MSinternal_repl_merge_admin_' + convert(nvarchar(6), db_id()) 

    exec @retcode = sp_releaseapplock @Resource = @lock_resource, @LockOwner = @lockowner, @DbPrincipal = @DbPrincipal
    if @@error<>0 or @retcode<0
        return 1
    else
        return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSreleasemergeadminapplock] TO [public] AS [dbo]
GO
