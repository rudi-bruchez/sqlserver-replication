SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSupdate_singlelogicalrecordmetadata]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSupdate_singlelogicalrecordmetadata] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSupdate_singlelogicalrecordmetadata]
	@logical_record_parent_nickname [int],
	@logical_record_parent_rowguid [uniqueidentifier],
	@replnick [binary](6),
	@parent_row_inserted [bit] OUTPUT
WITH EXECUTE AS CALLER
AS
declare @logical_record_parent_oldmaxversion int, 
            @logical_record_lineage varbinary(311), 
            @logical_record_parent_regular_lineage varbinary(311), 
            @logical_record_parent_gencur bigint,
            @rows_updated int,
            @error int,
            @logical_record_parent_pubid uniqueidentifier,
            @logical_record_parent_objid int,
            @unqual_sourcename nvarchar(540),
            @source_object nvarchar(270)

    select top 1 @logical_record_parent_pubid = pubid, @logical_record_parent_objid = objid 
    from dbo.sysmergearticles 
    where nickname = @logical_record_parent_nickname

    select @source_object = QUOTENAME(SCHEMA_NAME(schema_id)) + '.' + QUOTENAME(name) 
    from sys.objects 
    where object_id = @logical_record_parent_objid
                
    select @unqual_sourcename = sys.fn_replreplacesinglequote(@source_object)
    
    if ((object_name(@logical_record_parent_objid) is null
    		or (has_perms_by_name(@unqual_sourcename, 'OBJECT', 'SELECT') 
    			|has_perms_by_name(@unqual_sourcename, 'OBJECT', 'UPDATE')
    			|has_perms_by_name(@unqual_sourcename, 'OBJECT', 'INSERT')
    			|has_perms_by_name(@unqual_sourcename, 'OBJECT', 'DELETE')=0))
    	and {fn ISPALUSER(@logical_record_parent_pubid)} <> 1)
    begin
        raiserror(15247, 11, -1)
        return 1
    end
    
    select @parent_row_inserted = 0
    
    if @logical_record_parent_rowguid is null
        return 0
    
    select top 1    @logical_record_parent_oldmaxversion = maxversion_at_cleanup
    from dbo.sysmergearticles 
    where nickname = @logical_record_parent_nickname

    exec sys.sp_MSmerge_getgencur @logical_record_parent_nickname, 1, @logical_record_parent_gencur output
    
    update dbo.MSmerge_tombstone 
        set logical_record_lineage = { fn UPDATELINEAGE(logical_record_lineage, @replnick, @logical_record_parent_oldmaxversion+1) }
        where tablenick = @logical_record_parent_nickname
        and rowguid = @logical_record_parent_rowguid
    select @rows_updated = @@rowcount, @error = @@error
    
    if @error <> 0
        return 1
        
    if @rows_updated = 1
        return 0 -- no need to insert tombstone if rows_updated = 0. This proc is never called to insert a parent's tombstone.
    
    update dbo.MSmerge_contents 
        set logical_record_lineage = { fn UPDATELINEAGE(logical_record_lineage, @replnick, @logical_record_parent_oldmaxversion+1) }
        where tablenick = @logical_record_parent_nickname
        and rowguid = @logical_record_parent_rowguid
    select @rows_updated = @@rowcount, @error = @@error
    
    if @error <> 0
        return 1
        
    if @rows_updated = 0
    begin
        select @logical_record_lineage = { fn UPDATELINEAGE(0x0, @replnick, @logical_record_parent_oldmaxversion+1) }
        
        -- if no cleanup done yet, use 1 as the version.
        if @logical_record_parent_oldmaxversion = 1
            select @logical_record_parent_regular_lineage = { fn UPDATELINEAGE(0x0, @replnick, 1) }
        else 
            select @logical_record_parent_regular_lineage = @logical_record_lineage
            
        insert into dbo.MSmerge_contents (tablenick, rowguid, lineage, colv1, generation, partchangegen,                                            
                logical_record_parent_rowguid, logical_record_lineage) 
            values (@logical_record_parent_nickname, @logical_record_parent_rowguid, @logical_record_parent_regular_lineage, 
                0x00, @logical_record_parent_gencur, NULL, @logical_record_parent_rowguid, @logical_record_lineage)
        if @@error <> 0
            return 1
        
        select @parent_row_inserted = 1
    end
    
    return 0

GO
GRANT EXECUTE ON [sys].[sp_MSupdate_singlelogicalrecordmetadata] TO [public] AS [dbo]
GO
