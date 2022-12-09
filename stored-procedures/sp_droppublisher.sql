SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_droppublisher]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_droppublisher] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_droppublisher]
	@publisher [sysname],
	@type [nvarchar](5)
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON
	RAISERROR (21023, 16, -1,'sp_droppublisher')
	RETURN(1)

GO
GRANT EXECUTE ON [sys].[sp_droppublisher] TO [public] AS [dbo]
GO
