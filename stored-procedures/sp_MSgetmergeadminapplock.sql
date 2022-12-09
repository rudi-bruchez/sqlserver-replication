SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSgetmergeadminapplock]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSgetmergeadminapplock] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSgetmergeadminapplock]
	@timeout [int],
	@lockmode [nvarchar](32),
	@lock_acquired [int] OUTPUT,
	@lockowner [nvarchar](32)
WITH EXECUTE AS CALLER
AS
set nocount on

    declare @retcode smallint
    declare @lock_resource nvarchar(255)
    declare @publisher sysname
    declare @publisher_db sysname
    declare @DbPrincipal sysname

    select @publisher = publishingservername() 
    select @publisher_db = DB_NAME() 

    select @retcode = 0
    select @lock_acquired = -1

    exec @retcode = sys.sp_MSreplcheck_publish
    if @retcode<>0 or @@ERROR<>0
        return 1

    -- use the dbowner role
    select @DbPrincipal = N'db_owner'
    select @lock_resource = N'MSinternal_repl_merge_admin_' + convert(nvarchar(6), db_id()) 

    exec @retcode = sp_getapplock @Resource = @lock_resource,
                                  @LockMode = @lockmode,
                                  @LockOwner = @lockowner,
                                  @LockTimeout = @timeout, -- wait till the the given @timeout time to get it
                                  @DbPrincipal = @DbPrincipal
    if @@error<>0 or @retcode<0 -- lock was not acquired
    begin
        raiserror(20712, 16, -1, @publisher_db)
        select @retcode = 1
        select @lock_acquired = -1
    end
    else
        select @lock_acquired = 1

    return @retcode
GO
GRANT EXECUTE ON [sys].[sp_MSgetmergeadminapplock] TO [public] AS [dbo]
GO
