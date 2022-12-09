SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_subscriptionsummary]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_subscriptionsummary] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_subscriptionsummary]
	@publication [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname],
	@publisher [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @cmd            nvarchar(4000),
			@retcode        int,
			@publisher_type sysname

	SET @retcode = 0
   
	EXEC @retcode = sys.sp_MSrepl_getpublisherinfo @publisher       = @publisher,
												   @rpcheader       = @cmd OUTPUT,
												   @publisher_type  = @publisher_type OUTPUT
	IF @retcode <> 0
	BEGIN
		RETURN (@retcode)
	END

	SET @publisher = UPPER(@publisher) COLLATE DATABASE_DEFAULT
	SET @cmd = @cmd  + N'sys.sp_MSrepl_subscriptionsummary'
	
	EXEC @retcode = @cmd
			@publication = @publication,
			@subscriber = @subscriber,
			@subscriber_db = @subscriber_db,
			@publisher = @publisher,
			@publisher_type = @publisher_type

END
GO
GRANT EXECUTE ON [sys].[sp_subscriptionsummary] TO [public] AS [dbo]
GO
