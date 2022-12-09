SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSsetreplicaschemaversion]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSsetreplicaschemaversion] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSsetreplicaschemaversion]
	@subid [uniqueidentifier],
	@schemaversion [int],
	@schemaguid [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    /*
    ** Check to see if current publication has permission
    */
    declare @retcode int

    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @repid = @subid
    if (@retcode <> 0) or (@@error <> 0)
        return 1
    
    update dbo.sysmergesubscriptions set schemaversion = @schemaversion, schemaguid = @schemaguid
        where subid = @subid
        
    if @@error <> 0     
        return (1)

    return (0)
end
GO
GRANT EXECUTE ON [sys].[sp_MSsetreplicaschemaversion] TO [public] AS [dbo]
GO
