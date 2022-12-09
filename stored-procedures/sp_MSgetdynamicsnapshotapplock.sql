SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSgetdynamicsnapshotapplock]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSgetdynamicsnapshotapplock] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSgetdynamicsnapshotapplock]
	@publication [sysname],
	@partition_id [int],
	@lock_acquired [int] OUTPUT,
	@timeout [int]
WITH EXECUTE AS CALLER
AS
set nocount on

    declare @retcode smallint
    declare @lock_resource nvarchar(255)
    declare @pubnumber smallint
    declare @publisher sysname
    declare @publisher_db sysname
    declare @pubid uniqueidentifier   	
    declare @PALRole sysname

    select @publisher = publishingservername() 
    select @publisher_db = DB_NAME() 
    select @pubnumber = 0

    select @retcode = 0
    select @lock_acquired = -1

    -- partition id can be >= 0 
    if @partition_id = -1
    begin
        raiserror(20627, 16, -1)
        return 1
    end

    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @publication = @publication
    if @retcode<>0 or @@ERROR<>0
        return 1

    select @pubnumber = publication_number, @pubid = pubid  from dbo.sysmergepublications  
            where name=@publication and upper(publisher)=upper(@publisher) and publisher_db=@publisher_db
    if @pubnumber is NULL or @pubnumber = 0 
    begin
        RAISERROR (20026, 16, -1, @publication)
        return 1
    end

    -- Since we have gone through the PAL check already, the PAL role
    -- should have been set. The following call to fn_MSmerge_GetPALRole 
    -- is nothing more than a way to retrieve the PAL role name
    select @PALRole = NULL
    select @PALRole = sys.fn_MSmerge_GetPALRole(@pubid)
    if @PALRole is NULL
        return 1

    select @lock_resource = N'MSinternal_dynamic_snapshot_' + 
                    convert(nvarchar(6), db_id()) + '_' +
                    convert(nvarchar(6), @pubnumber) + '_' +
                    convert(nvarchar(11), @partition_id)

    exec @retcode = sp_getapplock @Resource = @lock_resource,
                                  @LockMode = N'Exclusive',
                                  @LockOwner = N'Session',
                                  @LockTimeout = @timeout, -- wait till the the given @timeout time to get it
                                  @DbPrincipal = @PALRole
    if @@error = 0
    begin
        select @lock_acquired = @retcode
        select @retcode = 0
    end
    else
    begin
        select @lock_acquired = -1
        select @retcode  = 1
    end

    return @retcode
GO
GRANT EXECUTE ON [sys].[sp_MSgetdynamicsnapshotapplock] TO [public] AS [dbo]
GO
