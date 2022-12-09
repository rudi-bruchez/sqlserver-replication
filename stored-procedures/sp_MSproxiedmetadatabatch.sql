SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSproxiedmetadatabatch]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSproxiedmetadatabatch] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSproxiedmetadatabatch]
	@tablenick [int],
	@rowguid [uniqueidentifier],
	@proxied_lineage [varbinary](311),
	@proxied_colv [varbinary](2953),
	@proxy_logical_record_lineage [bit],
	@compatlevel [int]
WITH EXECUTE AS CALLER
AS
declare @local_lineage      varbinary(311)
    declare @local_version      int
    declare @proxied_version    int
    declare @incontents         tinyint
    declare @retcode int
    
    -- Security Checking 
    -- PAL user access
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @tablenick = @tablenick
    if (@retcode <> 0) or (@@error <> 0)
        return 1
    
    set @proxied_version = {fn GETMAXVERSION(@proxied_lineage)}

    if (@proxy_logical_record_lineage = 0)
        select @local_lineage = lineage from dbo.MSmerge_contents
            where tablenick = @tablenick and rowguid = @rowguid
    else
        select @local_lineage = logical_record_lineage from dbo.MSmerge_contents
            where tablenick = @tablenick and rowguid = @rowguid

    if @local_lineage is not null
        set @incontents= 1
    else
    begin
    
        -- cannot proxy if logical record parent row is no longer in contents.
        --if (@proxy_logical_record_lineage = 1)
        --    return (0)
            
        if (@proxy_logical_record_lineage = 0)
            select @local_lineage = lineage from dbo.MSmerge_tombstone
                where tablenick = @tablenick and rowguid = @rowguid
        else
            select @local_lineage = logical_record_lineage from dbo.MSmerge_tombstone
                where tablenick = @tablenick and rowguid = @rowguid

        if @local_lineage is not null
            set @incontents= 0
        else
            return(0)
    end

    set @local_version= {fn GETMAXVERSION(@local_lineage)}

    -- make sure that local lineage was not updated since the publisher proxied its last change
    -- if it was updated, we leave it unchanged
    if @local_version <= @proxied_version
    begin
        if @compatlevel < 90
        begin
            if @proxied_lineage is not null
                set @proxied_lineage= {fn LINEAGE_80_TO_90(@proxied_lineage)}
            if @proxied_colv is not null and @proxy_logical_record_lineage = 0
                set @proxied_colv= {fn COLV_80_TO_90(@proxied_colv)}
        end
        
        if @incontents = 1
        begin
            if (@proxy_logical_record_lineage = 0)
                update dbo.MSmerge_contents with (rowlock) set lineage = @proxied_lineage, colv1 = @proxied_colv
                    where tablenick = @tablenick and rowguid = @rowguid and
                    -- lineage compare makes sure lineage has not changed since @local_lineage was retrieved
                    lineage = @local_lineage 
            else
                update dbo.MSmerge_contents with (rowlock) set logical_record_lineage = @proxied_lineage
                    where tablenick = @tablenick and rowguid = @rowguid and
                    -- logical_record_lineage compare makes sure lineage has not changed since @local_lineage was retrieved
                    logical_record_lineage = @local_lineage 
        end
        else
        begin
            if (@proxy_logical_record_lineage = 0)
                update dbo.MSmerge_tombstone with (rowlock) set lineage = @proxied_lineage
                    where tablenick = @tablenick and rowguid = @rowguid and
                        -- lineage compare makes sure lineage has not changed since @local_lineage was retrieved
                        lineage = @local_lineage 
            else        
                update dbo.MSmerge_tombstone with (rowlock) set logical_record_lineage = @proxied_lineage
                where tablenick = @tablenick and rowguid = @rowguid and
                    -- logical_record_lineage compare makes sure lineage has not changed since @local_lineage was retrieved
                    logical_record_lineage = @local_lineage 
        end
    end

    return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSproxiedmetadatabatch] TO [public] AS [dbo]
GO
