SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSacquireserverresourcefordynamicsnapshot]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSacquireserverresourcefordynamicsnapshot] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSacquireserverresourcefordynamicsnapshot]
	@publication [sysname],
	@max_concurrent_dynamic_snapshots [int]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    declare @retcode int
    declare @pubid uniqueidentifier
    declare @process_name sysname
    declare @PALRole sysname
    select @retcode = 0
    

    if object_id('dbo.sysmergepublications') is null
    begin
        raiserror(21423, 16, -1, @publication)
        return (1) 
    end

    select @pubid = null
    select @pubid = pubid 
      from dbo.sysmergepublications
     where name = @publication 
       and publisher_db = db_name()
       and upper(publisher) = upper(publishingservername())
             
    if @pubid is null   
    begin
        raiserror(21423, 16, -1, @publication)
        return (1) 
    end

    if {fn ISPALUSER(@pubid)} <> 1
    begin
        raiserror(21423, 16, -1, @publication)
        return (1) 
    end
    
    -- Since we have gone through the PAL check already, the PAL role
    -- should have been set. The following call to sp_MSrepl_GetPALRole 
    -- is nothing more than a way to retrieve the PAL role name
    select @PALRole = NULL
    select @PALRole = sys.fn_MSmerge_GetPALRole(@pubid)
    if @PALRole is NULL
        return 1

    -- The following string construction will never overflow
    -- sysname
    select @process_name = N'ReplicationSnapshotAgent' + 
        convert(nvarchar(40), @pubid)     

    -- Acquire head of queue lock first
    exec @retcode = sys.sp_MSacquireHeadofQueueLock
        @process_name = @process_name,
        @queue_timeout = 0,
        @no_result = 1,
        @DbPrincipal = @PALRole

    if @@error<>0
        return (1)

    if @retcode<>0
        goto Failure

    exec @retcode = sys.sp_MSacquireSlotLock 
        @process_name = @process_name,
        @concurrent_max = @max_concurrent_dynamic_snapshots,
        @DbPrincipal = @PALRole
    if @@error<>0
        return (1)
    
    -- Also return the PAL role as a separate result set, this is 
    -- used later on by the snapshot agent to release the dynamic snapshot
    -- applock under the proper security principal
    select @PALRole     

Failure:

    return @retcode
end
GO
GRANT EXECUTE ON [sys].[sp_MSacquireserverresourcefordynamicsnapshot] TO [public] AS [dbo]
GO
