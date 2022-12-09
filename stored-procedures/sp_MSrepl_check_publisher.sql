SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSrepl_check_publisher]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSrepl_check_publisher] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSrepl_check_publisher]
	@publisher_type [sysname],
	@publisher [sysname],
	@security_mode [bit],
	@login [nvarchar](255),
	@password [nvarchar](255),
	@connect_timeout [int]
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @retcode int

	IF UPPER(@publisher_type) IN ('ORACLE', 'ORACLE GATEWAY')
	BEGIN
		EXEC sys.sp_ORAcheckpublisher	@publisher,
								@security_mode,
								@login,
								@password,
								@connect_timeout
	END
	ELSE
	BEGIN
		RAISERROR(21645, 16, -1, @publisher_type)
		RETURN (1)
	END
END
GO
GRANT EXECUTE ON [sys].[sp_MSrepl_check_publisher] TO [public] AS [dbo]
GO
