SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSreleasedynamicsnapshotapplock]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSreleasedynamicsnapshotapplock] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSreleasedynamicsnapshotapplock]
	@publication [sysname],
	@partition_id [int]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on

    declare @retcode smallint
    declare @lock_resource nvarchar(255)
    declare @pubnumber smallint
    declare @publisher sysname
    declare @publisher_db sysname
    declare @pubid uniqueidentifier
    declare @PALRole sysname   	

    select @publisher = publishingservername() 
    select @publisher_db = DB_NAME(DB_ID()) 

    /* 
    ** Security Check.
    */
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @publication = @publication
    if @retcode<>0 or @@error<>0
        return 1
        
    -- partition id can be >= 0 
    if @partition_id = -1
        return 0
        
        select @retcode = 0
    select @pubnumber = publication_number, @pubid = pubid from dbo.sysmergepublications  
        where name=@publication and upper(publisher)=upper(@publisher) and publisher_db=@publisher_db
    if @pubnumber is NULL or @pubnumber = 0 
    begin
        RAISERROR (20026, 16, -1, @publication)
        return 1
    end

    select @lock_resource = N'MSinternal_dynamic_snapshot_' + 
                    convert(nvarchar(6), db_id()) + '_' +
                    convert(nvarchar(6), @pubnumber) + '_' +
                    convert(nvarchar(11), @partition_id)

    -- Since we have gone through the PAL check already, the PAL role
    -- should have been set. The following call to fn_MSmerge_GetPALRole 
    -- is nothing more than a way to retrieve the PAL role name
    select @PALRole = NULL
    select @PALRole = sys.fn_MSmerge_GetPALRole(@pubid)
    if @PALRole is NULL
        return 1

    exec @retcode = sp_releaseapplock @Resource = @lock_resource, @LockOwner = N'Session', @DbPrincipal = @PALRole
    if @@error <> 0 or @retcode < 0
        return 1
    else
        return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSreleasedynamicsnapshotapplock] TO [public] AS [dbo]
GO
