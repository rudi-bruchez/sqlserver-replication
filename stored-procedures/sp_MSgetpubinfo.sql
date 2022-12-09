SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSgetpubinfo]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSgetpubinfo] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSgetpubinfo]
	@publication [sysname],
	@publisher [sysname],
	@pubdb [sysname]
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON
	
	--don't further qualify with server name and DB name - it's just security checking
	declare @retcode int
	exec @retcode = sys.sp_MSrepl_PAL_rolecheck
	if (@retcode <> 0) or (@@error <> 0)
	        return 1

	select pubid from dbo.sysmergepublications where name = @publication and
			LOWER(publisher) = LOWER(@publisher) and LOWER(publisher_db) = LOWER(@pubdb)
			
GO
GRANT EXECUTE ON [sys].[sp_MSgetpubinfo] TO [public] AS [dbo]
GO
