SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSrepl_testadminconnection]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSrepl_testadminconnection] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSrepl_testadminconnection]
	@distributor [sysname],
	@password [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @retcode      int
	DECLARE @linkedsvr    sysname
	DECLARE @login        sysname

	-------- security check, db_owner
	EXEC @retcode = dbo.sp_MSreplcheck_publish
	IF @@ERROR <> 0 or @retcode <> 0
	BEGIN
		RETURN(1)
	END
	
	SELECT @linkedsvr    = CONVERT(sysname, newid()),
		   @login        = N'distributor_admin'

	-- Verify @distributor
	IF @distributor IS NULL OR @distributor = N''
	BEGIN
		RAISERROR (14043, 16, -1, '@distributor', 'sp_MSrepl_testadminconnection')
		RETURN (1)
	END

	EXEC @retcode = sys.sp_validname @distributor

	IF @@ERROR <> 0 OR @retcode <> 0
	   RETURN (1)

	-- Validate @password
	IF @password IS NULL OR @password = N''
	BEGIN
		RAISERROR(14043, 16, -1, N'@password', 'sp_MSrepl_testadminconnection')
		RETURN (1)
	END

	-- Add temporary linked server entry to test distributor_admin credentials
	EXEC @retcode = sys.sp_addserver  @linkedsvr
	IF @@error <> 0 OR @retcode <> 0
	BEGIN
		RETURN (1)
	END

	-- Mark system link
	EXECUTE @retcode = sys.sp_serveroption  @linkedsvr, 'system', 'true'
	IF @@error <> 0 OR @retcode <> 0
	BEGIN
		GOTO UNDO
	END

	-- Set net name of test link to distributor server name
	EXECUTE @retcode = sys.sp_setnetname  @linkedsvr, @distributor
	IF @@error <> 0 OR @retcode <> 0
	BEGIN
		GOTO UNDO
	END
		
	exec @retcode = sys.sp_addlinkedsrvlogin    @rmtsrvname  = @linkedsvr,
												@useself     = 'false',
												@locallogin  = NULL,
												@rmtuser     = @login,
												@rmtpassword = @password
	IF @@error <> 0 OR @retcode <> 0
	BEGIN
		GOTO UNDO
	END
	
	-- Test connection
	BEGIN TRY
		DECLARE @distproc nvarchar(max)
		DECLARE @result int
		
		SELECT @distproc = QUOTENAME(RTRIM(@linkedsvr)) + '.master.sys.sp_executesql'
		EXEC @retcode = @distproc N'SELECT @p1=@@microsoftversion', N'@p1 int OUTPUT', @result OUTPUT
	END TRY
	BEGIN CATCH
		RAISERROR(21670, 16, -1, @distributor)
		SET @retcode = 1
	END CATCH
	
	-- Cleanup
UNDO:
	IF EXISTS (SELECT * FROM sys.servers WHERE name = @linkedsvr)
	BEGIN
		EXEC sys.sp_dropserver @linkedsvr, 'droplogins'
	END
	
	RETURN (@retcode)
END
GO
GRANT EXECUTE ON [sys].[sp_MSrepl_testadminconnection] TO [public] AS [dbo]
GO
