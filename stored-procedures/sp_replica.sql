SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_replica]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_replica] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_replica]
	@tabname [nvarchar](92),
	@replicated [nvarchar](5)
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON
	RAISERROR (21023, 16, -1,'sp_replica')
	RETURN(1)
GO
GRANT EXECUTE ON [sys].[sp_replica] TO [public] AS [dbo]
GO
