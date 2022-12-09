SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_helpsubscriberinfo]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_helpsubscriberinfo] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_helpsubscriberinfo]
	@subscriber [sysname],
	@publisher [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @cmd		nvarchar(4000)
	DECLARE @retcode	int

	SET @retcode = 0

	EXEC @retcode = sys.sp_MSrepl_getpublisherinfo	@publisher			= @publisher,
													@rpcheader			= @cmd OUTPUT,
													@skipSecurityCheck	= 1
	
	IF @retcode <> 0
		RETURN (@retcode)

	IF @publisher IS NULL
		SET @publisher = publishingservername()

	-- Add sp
	SET @publisher = UPPER(@publisher) COLLATE DATABASE_DEFAULT
	set @cmd = @cmd + N'sys.sp_MSrepl_helpsubscriberinfo'

	EXEC @retcode = @cmd
					@subscriber,
					@publisher,
					NULL

	RETURN (@retcode)
END
GO
GRANT EXECUTE ON [sys].[sp_helpsubscriberinfo] TO [public] AS [dbo]
GO
