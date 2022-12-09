SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_validatecache]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_validatecache] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_validatecache]
	@publisher [sysname],
	@publication [sysname],
	@article [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
	SET NOCOUNT ON

	DECLARE @cmd			nvarchar(4000)
	DECLARE @retcode		int
	DECLARE @publisher_type	sysname

	-- Security Check: requires sysadmin, done in sp_MSrepl_getpublisherinfo

	SET @retcode = 0

	EXEC @retcode = sys.sp_MSrepl_getpublisherinfo	@publisher      = @publisher,
													@rpcheader      = @cmd OUTPUT,
													@publisher_type	= @publisher_type OUTPUT,
													@hreplOnly      = 1							
	
	IF @retcode <> 0
		RETURN (@retcode)

	-- Error if the publisher is not an Oracle publisher
	IF @publisher_type NOT LIKE 'ORACLE%'
	BEGIN
		RAISERROR (21687, 16, -1, @publisher, @publisher_type)
    	RETURN (1)
	END

	SET @publisher = UPPER(@publisher) COLLATE DATABASE_DEFAULT
	set @cmd = @cmd + N'sys.sp_MSrepl_validatecache'
	
	EXEC @retcode = @cmd	@publisher,
		@publication,
		@article
	RETURN (@retcode)
END
GO
GRANT EXECUTE ON [sys].[sp_validatecache] TO [public] AS [dbo]
GO
