SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_changedistributor_password]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_changedistributor_password] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_changedistributor_password]
	@password [sysname]
WITH EXECUTE AS CALLER
AS
declare @distributor sysname
	declare @distnetname sysname
	declare @retcode int
	declare @login sysname

	/*
	** Security Check: require sysadmin
	*/
	IF (ISNULL(IS_SRVROLEMEMBER('sysadmin'),0) = 0)
	BEGIN
		RAISERROR(21089,16,-1) 
		RETURN (1)
	END

	select @login = 'distributor_admin'
	SELECT @distributor = NULL
	SELECT @distributor = srvname, @distnetname = datasource 
		FROM master.dbo.sysservers
		WHERE  srvstatus & 8 <> 0
	
	exec @retcode = sys.sp_addlinkedsrvlogin 
		@rmtsrvname= @distributor,
		@useself = 'false',
		@locallogin = NULL,
		@rmtuser = @login,
		@rmtpassword = @password
	IF @@error <> 0 OR @retcode <> 0
	BEGIN
		RETURN (1)
	END

	if UPPER(@distnetname) = UPPER(@@servername)
	begin
			-- Change the password if the distributor is local
		EXEC @retcode = sys.sp_password NULL, @password, 'distributor_admin'
		if @@error <> 0 or @retcode <> 0
			return(1)
	end

	return (0)
GO
GRANT EXECUTE ON [sys].[sp_changedistributor_password] TO [public] AS [dbo]
GO
