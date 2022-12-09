SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[sp_MSrepl_startup]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [dbo].[sp_MSrepl_startup] AS' 
END
GO
ALTER PROCEDURE [dbo].[sp_MSrepl_startup]
WITH EXECUTE AS CALLER
AS
exec sys.sp_MSrepl_startup_internal
GO
EXEC sp_procoption N'[dbo].[sp_MSrepl_startup]', 'startup', '1'
GO
