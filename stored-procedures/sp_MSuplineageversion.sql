SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSuplineageversion]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSuplineageversion] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSuplineageversion]
	@tablenick [int],
	@rowguid [uniqueidentifier],
	@version [int]
WITH EXECUTE AS CALLER
AS
declare @replnick binary(6)
    declare @curversion int
    declare @lineage varbinary(311)
    declare @retcode int
    declare @colv varbinary(2953)
    declare @col_tracking int
    declare @rowintombstone int
    
    /*
    ** Check to see if current publication has permission
    */
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @tablenick = @tablenick
    if (@retcode <> 0) or (@@error <> 0)
        return 1
    
    exec sys.sp_MSgetreplnick @replnick = @replnick out
    if (@@error <> 0) or @replnick IS NULL 
        begin
        RAISERROR (14055, 11, -1)
        RETURN(1)
        end                 
    if (@rowguid is null)
        begin
        RAISERROR(14043, 16, -1, '@rowguid', 'sp_MSuplineageversion')
        return (1)
        end
    if (@tablenick is null)
        begin
        RAISERROR(14043, 16, -1, '@tablenick', 'sp_MSuplineageversion')
        return (1)
        end

    select @col_tracking = column_tracking
             from dbo.sysmergearticles where nickname = @tablenick

    begin transaction
    save tran sp_MSuplineageversion

    -- get lineage, locking row in MSmerge_contents. If not found there, also try MSmerge_tombstone
    set @rowintombstone= 0
    select @lineage = lineage, @colv = colv1 from dbo.MSmerge_contents with (UPDLOCK ROWLOCK index = 1) where tablenick = @tablenick and
            rowguid = @rowguid
    if (@lineage is null)
    begin
        select @lineage = lineage from dbo.MSmerge_tombstone with (UPDLOCK ROWLOCK index = 1) where tablenick = @tablenick and
            rowguid = @rowguid
        set @colv= NULL
        set @rowintombstone= 1
    end
    if (@lineage is null)
    begin
        RAISERROR(14043, 16, -1, '@lineage', 'sp_MSuplineageversion')
        goto Failure
    end

    set @curversion = 0
    while (@curversion < @version)
    begin
        set @lineage= { fn UPDATELINEAGE(@lineage, @replnick, 1) }
        set @curversion= { fn GETMAXVERSION(@lineage) }
    end
    if (@col_tracking = 0 or @colv is NULL)
        set @colv = NULL
    else
        set @colv = { fn UPDATECOLVBM(@colv, @replnick, 0x01, 0x00, @curversion) }
        
    -- update lineage in MSmerge_contents or MSmerge_tombstone
    if (@rowintombstone = 0)
    begin
        update dbo.MSmerge_contents set lineage = @lineage, colv1 = @colv where 
            tablenick = @tablenick and rowguid = @rowguid
    end
    else
    begin
        update dbo.MSmerge_tombstone set lineage = @lineage where
            tablenick = @tablenick and rowguid = @rowguid
    end

    commit
    return (0)
Failure:
    rollback tran sp_MSuplineageversion
    commit tran
    return(1)
GO
GRANT EXECUTE ON [sys].[sp_MSuplineageversion] TO [public] AS [dbo]
GO
