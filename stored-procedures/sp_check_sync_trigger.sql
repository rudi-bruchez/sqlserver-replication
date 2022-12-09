SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_check_sync_trigger]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_check_sync_trigger] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_check_sync_trigger]
	@trigger_procid [int],
	@trigger_op [char](10) OUTPUT,
	@owner [sysname]
WITH EXECUTE AS CALLER
AS
begin
    declare @trigid int
    --
    -- Security check
    -- Make sure this proc is infact being called from the given object(trigger)
    -- 
    if (trigger_nestlevel(@trigger_procid) = 0)
    begin
        raiserror(14126, 16, 2)
        return -1
    end
    --
    -- Security check: the caller of this SP has to be one of the 
    -- predefined replication triggers defined in the db
    --
    if not exists (select so.object_id from (dbo.MSreplication_objects as ro join sys.objects as so
        on ro.object_name = so.name)
        where so.object_id = @trigger_procid and ro.object_type = 'T' 
        and (@owner is null or schema_name(so.schema_id) = @owner))
    begin
        raiserror(14126, 16, 3)
        return -1
    end
    --
    -- process
    --
    select @trigger_op = NULL
    select @trigid = so1.object_id from sys.objects so1, sys.objects so2 where
        so1.type = N'TR' and so1.name like N'trg_MSsync_ins_%' and so1.parent_object_id = so2.parent_object_id
        and so2.object_id = @trigger_procid
    
    -- if nestlevel of insert trigger on same table > 0 then bail
    if trigger_nestlevel( @trigid ) > 0
         return 1
    else
        return 0
end
GO
GRANT EXECUTE ON [sys].[sp_check_sync_trigger] TO [public] AS [dbo]
GO
