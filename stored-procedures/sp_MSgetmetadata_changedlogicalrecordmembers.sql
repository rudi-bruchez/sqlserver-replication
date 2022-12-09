SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSgetmetadata_changedlogicalrecordmembers]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSgetmetadata_changedlogicalrecordmembers] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSgetmetadata_changedlogicalrecordmembers]
	@parent_rowguid [uniqueidentifier],
	@commongen [bigint],
	@parent_nickname [int]
WITH EXECUTE AS CALLER
AS
declare @retcode int
    
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @tablenick = @parent_nickname
    if (@retcode <> 0) or (@@error <> 0)
        return 1

    select mc.tablenick, mc.rowguid, mc.generation, type=2, mc.lineage, mc.colv1
    from dbo.MSmerge_contents mc join 
    (select distinct nickname from dbo.sysmergepartitioninfoview where logical_record_parent_nickname = @parent_nickname)
		as smpi
    on mc.tablenick = smpi.nickname
    and mc.logical_record_parent_rowguid = @parent_rowguid
    and mc.generation > @commongen
    
    UNION
    
    select mc.tablenick, mc.rowguid, mc.generation, mc.type, mc.lineage, NULL
    from dbo.MSmerge_tombstone mc join
    (select distinct nickname from dbo.sysmergepartitioninfoview where logical_record_parent_nickname = @parent_nickname)
		as smpi
    on mc.tablenick = smpi.nickname
    and mc.logical_record_parent_rowguid = @parent_rowguid
    and mc.generation > @commongen
    
    return 0
GO
GRANT EXECUTE ON [sys].[sp_MSgetmetadata_changedlogicalrecordmembers] TO [public] AS [dbo]
GO
