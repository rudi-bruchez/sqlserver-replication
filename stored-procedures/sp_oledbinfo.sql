SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_oledbinfo]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_oledbinfo] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_oledbinfo]
	@server [nvarchar](128),
	@infotype [nvarchar](128),
	@login [nvarchar](128),
	@password [nvarchar](128)
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON

	DECLARE @distributor sysname
	DECLARE @distproc nvarchar (255)
	DECLARE @retcode int

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

	select @distproc = QUOTENAME(rtrim(@distributor)) + '.master.sys.sp_MSget_oledbinfo'
	exec @retcode = @distproc @server, @infotype, @login, @password
	IF @@error <> 0
		BEGIN
		RAISERROR (14071, 16, -1)
		RETURN (1)
	END

GO
GRANT EXECUTE ON [sys].[sp_oledbinfo] TO [public] AS [dbo]
GO
