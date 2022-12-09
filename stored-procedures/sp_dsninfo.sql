SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_dsninfo]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_dsninfo] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_dsninfo]
	@dsn [varchar](128),
	@infotype [varchar](128),
	@login [varchar](128),
	@password [varchar](128),
	@dso_type [int]
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON

	DECLARE @distributor sysname
	DECLARE @distproc nvarchar (300)
	DECLARE @retcode int
	DECLARE @dsotype_odbc int
	DECLARE @dsotype_oledb int

	select @dsotype_odbc = 1
	select @dsotype_oledb = 3

	/*
	** Security Check: require sysadmin
	*/
	IF (ISNULL(IS_SRVROLEMEMBER('sysadmin'),0) = 0)
	BEGIN
		RAISERROR(21089,16,-1) 
		RETURN (1)
	END

	/*
	** Get distribution server information for remote RPC
	** subscription calls.
	*/

	EXEC @retcode = sys.sp_MSrepl_getdistributorinfo @rpcsrvname = @distributor OUTPUT
	IF @@error <> 0 OR @retcode <> 0
		BEGIN
		RAISERROR (14071, 16, -1)
			RETURN (1)
	END

	if (@dso_type = @dsotype_odbc)
	begin
		/*
		** Call xp_dsninfo
		*/
		SELECT @distproc = QUOTENAME(RTRIM(@distributor)) + '.master.dbo.xp_dsninfo'
		EXEC @retcode = @distproc @dsn, @infotype, @login, @password
		IF @@error <> 0
			BEGIN
			RAISERROR (14071, 16, -1)
			RETURN (1)
		END
	end
	else if (@dso_type = @dsotype_oledb)
	begin
		/*
		** Call sp_oledbinfo
		*/
		EXEC @retcode = sys.sp_oledbinfo @dsn, @infotype, @login, @password
		IF @@error <> 0
			BEGIN
			RAISERROR (14071, 16, -1)
			RETURN (1)
		END
	end

GO
GRANT EXECUTE ON [sys].[sp_dsninfo] TO [public] AS [dbo]
GO
