SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_publishdb]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_publishdb] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_publishdb]
	@dbname [sysname],
	@value [nvarchar](5)
WITH EXECUTE AS CALLER
AS
DECLARE @retcode int

	EXECUTE @retcode = sys.sp_replicationdboption @dbname, 'publish', @value

	IF @@ERROR <> 0 or @retcode <> 0
	BEGIN
	   RETURN (1)
	END

	RETURN(0)
GO
GRANT EXECUTE ON [sys].[sp_publishdb] TO [public] AS [dbo]
GO
