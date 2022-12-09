SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSsendtosqlqueue]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSsendtosqlqueue] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSsendtosqlqueue]
	@objid [int],
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@owner [sysname],
	@tranid [sysname],
	@data [varbinary](8000),
	@datalen [int],
	@commandtype [int],
	@cmdstate [bit]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    --
    -- Security check
    -- Make sure this proc is infact being called from the given object(trigger)
    -- 
    if (trigger_nestlevel(@objid) = 0)
    begin
        raiserror(14126, 16, 2)
        return 1
    end
    --
    -- Security check: the caller of this SP has to be one of the 
    -- predefined replication objects for this subscription
    --
    if not exists (select so.object_id from (dbo.MSreplication_objects as ro join sys.objects as so
        on ro.object_name = so.name)
        where so.object_id = @objid and ro.object_type = 'T' 
        and (@owner is null or schema_name(so.schema_id) = @owner))
    begin
        raiserror(14126, 16, 3)
        return 1
    end
    --
    -- insert into the queue table
    --
    insert into dbo.MSreplication_queue with (rowlock) (publisher,publisher_db,publication,tranid,data,datalen,commandtype,cmdstate)
        values(UPPER(@publisher),@publisher_db,@publication,@tranid,@data,@datalen,@commandtype,@cmdstate)
    if (@@error != 0)
        return 1
    --
    -- Update MSrepl_queuedtraninfo
    --
    if exists (select *
        from dbo.MSrepl_queuedtraninfo with (nolock)
        where publisher = UPPER(@publisher) 
            and publisher_db = @publisher_db 
            and publication = @publication
            and tranid = @tranid)
    begin
        --
        -- row for this transaction exists - update it
        --
        update dbo.MSrepl_queuedtraninfo with (rowlock)
        set maxorderkey = @@identity
            ,commandcount = commandcount + 1
        where publisher = UPPER(@publisher)
            and publisher_db = @publisher_db 
            and publication = @publication
            and tranid = @tranid
    end
    else
    begin
        --
        -- row for this transaction does not exist - insert it
        --
        insert into dbo.MSrepl_queuedtraninfo with (rowlock) (publisher,publisher_db,publication,tranid,maxorderkey,commandcount)
        values (UPPER(@publisher),@publisher_db,@publication,@tranid,@@identity,1)
    end
    if (@@error != 0)
        return 1
    --
    -- all done
    --
    return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSsendtosqlqueue] TO [public] AS [dbo]
GO
