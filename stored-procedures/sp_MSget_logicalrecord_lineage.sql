SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSget_logicalrecord_lineage]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSget_logicalrecord_lineage] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSget_logicalrecord_lineage]
	@pubid [uniqueidentifier],
	@parent_nickname [int],
	@parent_rowguid [uniqueidentifier],
	@dest_common_gen [bigint]
WITH EXECUTE AS CALLER
AS
begin
        
    declare @metadata_type  tinyint, 
                    @logical_record_lineage varbinary(311),
                    @retcode smallint,
                    @procname nvarchar(270),
                    @num_dest_changed_rows int
                        
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @pubid = @pubid 
    if (@retcode <> 0) or (@@error <> 0)
        return 1
        
    select @procname= 'dbo.' + select_proc from dbo.sysmergearticles 
            where nickname = @parent_nickname and pubid=@pubid
            
    set @metadata_type = 4
    set @logical_record_lineage = NULL
    set @num_dest_changed_rows = 0
    
    -- check for row in base table
    exec @retcode= @procname @maxschemaguidforarticle = NULL, @type=@metadata_type output, @rowguid=@parent_rowguid
    if @@error <>0 or @retcode <> 0 
        return (1)
        
    begin tran
    if (@metadata_type = 3)
    begin
                select @metadata_type = 2, @logical_record_lineage = logical_record_lineage
               from dbo.MSmerge_contents
               with (serializable)
               where tablenick = @parent_nickname and rowguid = @parent_rowguid
    end
    else
    begin
                -- row is not in base table; either it is in tombstone, or it is missing
        set @metadata_type= 0
        
        select  @metadata_type = type, @logical_record_lineage = logical_record_lineage
                                from dbo.MSmerge_tombstone where
                                tablenick = @parent_nickname and rowguid = @parent_rowguid
     end
     
    select @num_dest_changed_rows = count(*) from dbo.MSmerge_contents mc join 
					(select distinct nickname from dbo.sysmergepartitioninfoview where logical_record_parent_nickname = @parent_nickname)
					as smpi
                on mc.tablenick = smpi.nickname
                and mc.logical_record_parent_rowguid = @parent_rowguid
                and (mc.generation > @dest_common_gen or mc.generation = 0)
                
        select @num_dest_changed_rows = @num_dest_changed_rows + count(*) from dbo.MSmerge_tombstone mc 
			join (select distinct nickname from dbo.sysmergepartitioninfoview where logical_record_parent_nickname = @parent_nickname)
					as smpi
                on mc.tablenick = smpi.nickname
                and mc.logical_record_parent_rowguid = @parent_rowguid
                and (mc.generation > @dest_common_gen or mc.generation = 0)
                
        commit tran

        -- select out our result set
    select @logical_record_lineage, @metadata_type, @num_dest_changed_rows

    return (0)
end
GO
GRANT EXECUTE ON [sys].[sp_MSget_logicalrecord_lineage] TO [public] AS [dbo]
GO
