SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSset_logicalrecord_metadata]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSset_logicalrecord_metadata] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSset_logicalrecord_metadata]
	@parent_nickname [int],
	@parent_rowguid [uniqueidentifier],
	@logical_record_lineage [varbinary](311)
WITH EXECUTE AS CALLER
AS
declare @retcode smallint, @rowcount int, @error int
    
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @tablenick = @parent_nickname
    if (@retcode <> 0) or (@@error <> 0)
        return 1

    update dbo.MSmerge_contents set logical_record_lineage = @logical_record_lineage
    where tablenick = @parent_nickname
    and rowguid = @parent_rowguid
    
    select @rowcount = @@rowcount, @error = @@error
    
    if @error <> 0
            return 1
    
    if @rowcount = 0
    begin
        update dbo.MSmerge_tombstone set logical_record_lineage = @logical_record_lineage
        where tablenick = @parent_nickname
        and rowguid = @parent_rowguid

        select @rowcount = @@rowcount, @error = @@error
        
        if @error <> 0
                return 1
                    
        /*if @rowcount = 0
        begin
                declare @lineage varbinary(311), @replnick binary(6), @oldmaxversion int, @gen_cur bigint
                
                select top 1 @oldmaxversion = maxversion_at_cleanup, @gencur = gen_cur
                from dbo.sysmergearticles
                where nickname = @parent_nickname
        
                execute sys.sp_MSgetreplnick @replnick = @replnick output
                if @@error <> 0
                        return 1
                        
                set @lineage = { fn UPDATELINEAGE(0x0, @replnick, @oldmaxversion+1) }  
                insert into dbo.MSmerge_contents (tablenick, rowguid, generation, partchangegen, lineage, colv1,
                                                                                        marker, logical_record_parent_rowguid, logical_record_lineage,
                                                                                        logical_record_change_gen)
                        values(@parent_nickname, @parent_rowguid, @gencur, NULL, @lineage, 0x00,
                                                                                        NULL, @parent_rowguid, @logical_record_lineage, NULL)
                                                                                        
                if @error <> 0
                        return 1
        end */
    end
            
    return 0
GO
GRANT EXECUTE ON [sys].[sp_MSset_logicalrecord_metadata] TO [public] AS [dbo]
GO
