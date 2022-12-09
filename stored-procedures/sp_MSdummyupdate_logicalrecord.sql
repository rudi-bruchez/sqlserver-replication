SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdummyupdate_logicalrecord]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdummyupdate_logicalrecord] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdummyupdate_logicalrecord]
	@parent_rowguid [uniqueidentifier],
	@parent_nickname [int],
	@dest_common_gen [bigint]
WITH EXECUTE AS CALLER
AS
declare @retcode int
    
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @tablenick = @parent_nickname 
    if (@retcode <> 0) or (@@error <> 0)
        return 1

    update dbo.MSmerge_contents set generation = 0
    where rowguid = @parent_rowguid
    and tablenick = @parent_nickname
    
    if @@rowcount = 0
    begin
        update dbo.MSmerge_tombstone set generation = 0
        where rowguid = @parent_rowguid
        and tablenick = @parent_nickname
    end
    
    update dbo.MSmerge_contents set generation = 0
    from
    dbo.MSmerge_contents mc join 
    (select distinct nickname from dbo.sysmergepartitioninfoview where logical_record_parent_nickname = @parent_nickname)
		as smpi
    on mc.tablenick = smpi.nickname
    and mc.logical_record_parent_rowguid = @parent_rowguid
    and mc.generation > @dest_common_gen
                
    
    update dbo.MSmerge_tombstone set generation = 0
    from
    dbo.MSmerge_tombstone mc join 
    (select distinct nickname from dbo.sysmergepartitioninfoview where logical_record_parent_nickname = @parent_nickname)
		as smpi
    on mc.tablenick = smpi.nickname
    and mc.logical_record_parent_rowguid = @parent_rowguid
    and mc.generation > @dest_common_gen
    
    if @@error <> 0
        return 1
            
    return 0
GO
GRANT EXECUTE ON [sys].[sp_MSdummyupdate_logicalrecord] TO [public] AS [dbo]
GO
