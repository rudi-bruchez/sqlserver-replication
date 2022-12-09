SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSrepl_enumtablecolumninfo]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSrepl_enumtablecolumninfo] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSrepl_enumtablecolumninfo]
	@publisher [sysname],
	@owner [sysname],
	@tablename [sysname]
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
														@publisher_type = @publisher_type OUTPUT,
														@distribdb		= @distribdb OUTPUT

	IF @retcode <> 0
	BEGIN
		RETURN (@retcode)
	END

	IF UPPER(@publisher_type) IN ('ORACLE', 'ORACLE GATEWAY')
	BEGIN
		SET @cmd = QUOTENAME(@distribdb) + N'.sys.sp_ORAenumtablecolumninfo'

		EXEC @retcode = @cmd
						@publisher,
						@owner,
						@tablename
	END
	ELSE
	BEGIN
		RAISERROR(21645, 16, -1, @publisher)
		RETURN (1)
	END

	RETURN (@retcode)
END
GO
GRANT EXECUTE ON [sys].[sp_MSrepl_enumtablecolumninfo] TO [public] AS [dbo]
GO
