SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdistributoravailable]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdistributoravailable] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdistributoravailable]
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @distribdb sysname,
		@retcode int

	exec @retcode = sp_MSrepl_getdistributorinfo
		@distribdb = @distribdb OUTPUT

	select 'distribdb' = @distribdb
 
	return @retcode
END
GO
GRANT EXECUTE ON [sys].[sp_MSdistributoravailable] TO [public] AS [dbo]
GO
