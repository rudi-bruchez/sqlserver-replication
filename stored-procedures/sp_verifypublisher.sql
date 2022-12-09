SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_verifypublisher]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_verifypublisher] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_verifypublisher]
	@publisher [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @retcode	int
	DECLARE	@publisher_type	sysname
	DECLARE @cmd		nvarchar(4000)
	
	-------- security check, db_owner
	exec @retcode = dbo.sp_MSreplcheck_publish
	if @@ERROR <> 0 or @retcode <> 0
		return(1)

	-- Get publisher information
	EXEC @retcode = sys.sp_MSrepl_getpublisherinfo	@publisher		= @publisher,
													@publisher_type	= @publisher_type OUTPUT,
													@rpcheader		= @cmd OUTPUT
	
	IF @retcode <> 0
		RETURN (@retcode)

	-- Execute provider-specific verification
	IF UPPER(@publisher_type) IN ('ORACLE', 'ORACLE GATEWAY')
	BEGIN
		SET @publisher = UPPER(@publisher) COLLATE DATABASE_DEFAULT
		SELECT @cmd = @cmd + 'sys.sp_ORAverifypublisher'
		EXEC @retcode = @cmd @publisher
	END
	ELSE
	BEGIN
		RAISERROR(21645, 16, -1, @publisher_type)
		SET @retcode = 1
	END

	return @retcode
END
GO
GRANT EXECUTE ON [sys].[sp_verifypublisher] TO [public] AS [dbo]
GO
