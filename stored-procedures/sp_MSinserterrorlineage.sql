SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSinserterrorlineage]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSinserterrorlineage] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSinserterrorlineage]
	@tablenick [int],
	@rowguid [uniqueidentifier],
	@lineage [varbinary](311),
	@compatlevel [int]
WITH EXECUTE AS CALLER
AS
declare @retcode int
    
    -- Security Checking 
    -- PAL users have access
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @tablenick = @tablenick
    if (@retcode <> 0) or (@@error <> 0)
        return 1
    if @compatlevel < 90
        set @lineage= {fn LINEAGE_80_TO_90(@lineage)}

    if exists (select * from MSmerge_errorlineage where tablenick = @tablenick and
                rowguid = @rowguid)
            update MSmerge_errorlineage set lineage = @lineage where tablenick = @tablenick and
                rowguid = @rowguid
    else
            insert into MSmerge_errorlineage (tablenick, rowguid, lineage) 
                values (@tablenick, @rowguid, @lineage)
    if @@ERROR <> 0 return (1)

    return 0
GO
GRANT EXECUTE ON [sys].[sp_MSinserterrorlineage] TO [public] AS [dbo]
GO
