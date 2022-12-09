SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MShelp_distdb]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MShelp_distdb] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MShelp_distdb]
	@publisher_name [sysname]
WITH EXECUTE AS CALLER
AS
-- Current user must have PAL access to at least one distribution database
declare @retcode int
exec @retcode = sys.sp_MSrepl_DistributorPALAccess
if @retcode <> 0 or @@error <> 0
BEGIN
	select NULL where 1=2   /* We still want an empty rowset for some agents */
	return(1)
end

if exists (select name from msdb.sys.objects where name = 'MSdistpublishers')
begin
	select distribution_db from msdb..MSdistpublishers
	where UPPER(name collate database_default) = UPPER(@publisher_name) collate database_default
end
else 
	select NULL where 1=2   /* We still want an empty rowset for some agents */
GO
GRANT EXECUTE ON [sys].[sp_MShelp_distdb] TO [public] AS [dbo]
GO
