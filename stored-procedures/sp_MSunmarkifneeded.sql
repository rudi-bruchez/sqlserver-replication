SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSunmarkifneeded]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSunmarkifneeded] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSunmarkifneeded]
	@object [sysname],
	@pubid [uniqueidentifier],
	@pre_command [int],
	@publisher [sysname],
	@publisher_db [sysname]
WITH EXECUTE AS CALLER
AS
declare @table_in_use    int
declare @retcode         int

exec @retcode = sys.sp_MSreplcheck_subscribe
if @@error<>0 or @retcode<>0
    return (1)
        
select @table_in_use = 0
--if pre-creation_command is 'drop (1)' or 'truncate (3)', then disallow this deployment if there is already an article using that table.
--other commands like 'delete, truncate, none are fine'

if exists (select * from dbo.sysmergearticles where objid=object_id(@object) and pubid in
    (select pubid from dbo.sysmergepublications where LOWER(publisher)=LOWER(@publisher) and 
        publisher_db=@publisher_db and pubid<>@pubid))
    OR
    ((@pre_command=1 or @pre_command=3) and 
        EXISTS (select * from dbo.sysmergearticles where objid=object_id(@object) and pubid <> @pubid and pubid not in
            (select pubid from dbo.sysmergepublications where LOWER(publisher)=LOWER(publishingservername()) and publisher_db=db_name())))  
begin
    select @table_in_use = 1
    select @table_in_use
    return (0)
end
exec @retcode = sys.sp_MSunmarkreplinfo @object=@object
if @retcode <>0 or @@error<>0
    return (1)
select @table_in_use 
return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSunmarkifneeded] TO [public] AS [dbo]
GO
