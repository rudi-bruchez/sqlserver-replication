SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSmap_partitionid_to_generations]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSmap_partitionid_to_generations] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSmap_partitionid_to_generations]
	@partition_id [int]
WITH EXECUTE AS CALLER
AS
declare @retcode smallint

    exec @retcode = sys.sp_MSrepl_PAL_rolecheck
    if (@retcode <> 0) or (@@error <> 0)
        return 1

    if exists (select * from dbo.MSmerge_contents)
    begin
        insert into dbo.MSmerge_generation_partition_mappings (publication_number, partition_id, 
                    generation, changecount)
            select cpm.publication_number, cpm.partition_id, mc.generation, count(*)
            from dbo.MSmerge_current_partition_mappings cpm join dbo.MSmerge_contents mc
            on mc.tablenick = cpm.tablenick
            and mc.rowguid = cpm.rowguid
            and cpm.partition_id = @partition_id
            group by cpm.publication_number, cpm.partition_id, mc.generation
    end
    
    insert into dbo.MSmerge_generation_partition_mappings (publication_number, partition_id, 
                    generation, changecount)
            select ppm.publication_number, ppm.partition_id, ppm.generation, count(*)
            from dbo.MSmerge_past_partition_mappings ppm
            where ppm.partition_id = @partition_id
            group by ppm.publication_number, ppm.partition_id, ppm.generation
                        
    return 0
GO
GRANT EXECUTE ON [sys].[sp_MSmap_partitionid_to_generations] TO [public] AS [dbo]
GO
