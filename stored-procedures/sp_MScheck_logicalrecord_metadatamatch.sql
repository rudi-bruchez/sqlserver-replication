SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MScheck_logicalrecord_metadatamatch]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MScheck_logicalrecord_metadatamatch] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MScheck_logicalrecord_metadatamatch]
	@metadata_type [tinyint],
	@parent_nickname [int],
	@parent_rowguid [uniqueidentifier],
	@logical_record_lineage [varbinary](311),
	@pubid [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
declare @match int, @existing_lineage varbinary(311), @retcode int, @sel_proc nvarchar(255)
    
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @pubid = @pubid 
    if (@retcode <> 0) or (@@error <> 0)
        return 1
        
    select @match = 0, @existing_lineage = NULL
    
    if @metadata_type = 3
    begin
            --lock the parent row
            select @sel_proc = 'dbo.' + select_proc from dbo.sysmergearticles 
                    where pubid = @pubid and nickname = @parent_nickname
            exec @retcode = @sel_proc @maxschemaguidforarticle = NULL, @type = 8, @rowguid=@parent_rowguid
            if @@error <> 0 or @retcode <> 0
                    return 1
    end
    
    select @existing_lineage = logical_record_lineage 
    from dbo.MSmerge_contents with (updlock) 
    where tablenick = @parent_nickname 
    and rowguid =  @parent_rowguid 
            
    if @existing_lineage = @logical_record_lineage and @metadata_type = 2
    begin
                select @match = 1
        end
    else if @existing_lineage is null
    begin      
                select @existing_lineage = logical_record_lineage 
                from dbo.MSmerge_tombstone with (updlock) 
                where tablenick = @parent_nickname 
                and rowguid = @parent_rowguid 
            
        if @existing_lineage = @logical_record_lineage and @metadata_type in (1,5,6)
                begin
                        select @match = 1
                end
                else if @existing_lineage is null
                begin
            if @metadata_type in (0,3)
            begin
                                select @match = 1
                        end
                end
        end
   
    if (@match = 0)
    begin
                raiserror(22521, 16, -1)
                return 1
        end
    return 0
GO
GRANT EXECUTE ON [sys].[sp_MScheck_logicalrecord_metadatamatch] TO [public] AS [dbo]
GO
