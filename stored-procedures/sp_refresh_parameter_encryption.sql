SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_refresh_parameter_encryption]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_refresh_parameter_encryption] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_refresh_parameter_encryption]
	@name [nvarchar](776),
	@namespace [nvarchar](20)
WITH EXECUTE AS CALLER
AS
declare @ret int
	exec @ret = sys.sp_refreshsqlmodule_internal @name, @namespace, 0 /*viewonly*/, 1 /*recursive_encryption_deduction*/
	return @ret
GO
GRANT EXECUTE ON [sys].[sp_refresh_parameter_encryption] TO [public] AS [dbo]
GO
