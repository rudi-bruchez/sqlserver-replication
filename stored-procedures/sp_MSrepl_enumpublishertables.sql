SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSrepl_enumpublishertables]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSrepl_enumpublishertables] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSrepl_enumpublishertables]
	@publisher [sysname],
	@silent [bit]
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @retcode	int
	DECLARE @publisher_type	sysname
	DECLARE @cmd		nvarchar(4000)
	DECLARE @distribdb	sysname
	
	SET @retcode = 0

	--
	-- Security Check: require sysadmin
	--
	IF (ISNULL(IS_SRVROLEMEMBER('sysadmin'),0) = 0)
	BEGIN
		RAISERROR(21089,16,-1) 
		RETURN (1)
	END

	EXEC @retcode = sys.sp_MSrepl_getdistributorinfo	@publisher      = @publisher,
														@publisher_type	= @publisher_type OUTPUT,
														@distribdb		= @distribdb OUTPUT

	IF @retcode <> 0
	BEGIN
		RETURN (@retcode)
	END

	IF @distribdb IS NULL
	BEGIN
		RAISERROR(21600, 16, -1, @publisher)
		RETURN(1)
	END

	-- Create temp table to store the results (if not already available)
	IF object_id(N'tempdb..#publishertables', 'U') IS NULL
	BEGIN
		CREATE TABLE #publishertables
		(
			owner						sysname,
			name						sysname,
			has_valid_pk				bit,
			has_unique_with_nullable	bit,
			is_published				bit,
			has_explicit_select_grant	bit,
			is_tranpublished			bit
		)
	END

	-- Get per provider method for determining publisher tables
	IF UPPER(@publisher_type) IN ('ORACLE', 'ORACLE GATEWAY')
	BEGIN
		SET @cmd = QUOTENAME(@distribdb) + N'.sys.sp_ORAenumpublishertables'

		EXEC @retcode = @cmd @publisher

		IF (@silent = 0)
		BEGIN
			SELECT	*
			FROM	#publishertables
			ORDER BY owner, name

			DROP TABLE #publishertables
		END
	END
	ELSE
	BEGIN
		RAISERROR(21645, 16, -1, @publisher_type)
		SET @retcode = 1
	END

	RETURN (@retcode)
END
GO
GRANT EXECUTE ON [sys].[sp_MSrepl_enumpublishertables] TO [public] AS [dbo]
GO
