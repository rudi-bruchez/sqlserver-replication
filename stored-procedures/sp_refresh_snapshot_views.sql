SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_refresh_snapshot_views]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_refresh_snapshot_views] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_refresh_snapshot_views]
	@rgCode [int]
WITH EXECUTE AS CALLER
AS
declare @retcode int = 0
	exec @retcode = sys.sp_refresh_snapshot_views_internal @rgCode
	return @retcode
GO
GRANT EXECUTE ON [sys].[sp_refresh_snapshot_views] TO [public] AS [dbo]
GO
