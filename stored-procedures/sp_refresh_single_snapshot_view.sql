SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_refresh_single_snapshot_view]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_refresh_single_snapshot_view] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_refresh_single_snapshot_view]
	@view_name [nvarchar](261),
	@rgCode [int]
WITH EXECUTE AS CALLER
AS
declare @retcode int = 0
	declare @schema_name sysname 
	declare @object_name sysname
	if (parsename(@view_name, 3) is not null) or (parsename(@view_name, 4) is not null) or (parsename(@view_name, 2) is null)
		raiserror(10655, -1, -1)
	else
	begin
		select @object_name = parsename(@view_name, 1), @schema_name = parsename(@view_name, 2)
		exec @retcode = sys.sp_refresh_single_snapshot_view_internal @schema_name, @object_name, @rgCode
	end
	return @retcode
GO
GRANT EXECUTE ON [sys].[sp_refresh_single_snapshot_view] TO [public] AS [dbo]
GO
