SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_changeqreader_agent]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_changeqreader_agent] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_changeqreader_agent]
	@job_login [nvarchar](257),
	@job_password [sysname],
	@frompublisher [bit]
WITH EXECUTE AS CALLER
AS
BEGIN
	SET NOCOUNT ON
	
	DECLARE @retcode			int,
			@qreader_exists 	bit

	IF @frompublisher = 0
	BEGIN
		-- Security Check: require sysadmin of dist 
		IF IS_SRVROLEMEMBER('sysadmin') != 1
		BEGIN
			RAISERROR(21089,16,-1) 
			RETURN 1
		END

		-- database must be distribution db
		IF sys.fn_MSrepl_isdistdb(DB_NAME()) <> 1
		BEGIN
			RAISERROR (21482, 16, -1, 'sp_changeqreader_agent', 'distribution')
			RETURN (1)
		END
	END
	ELSE
	BEGIN
		-- Security Check: require sysadmin of publisher 
		IF IS_SRVROLEMEMBER('sysadmin') != 1
		BEGIN
			RAISERROR(21089,16,-1) 
			RETURN 1
		END

		-- database must be publishing db
		IF sys.fn_MSrepl_istranpublished(DB_NAME(), 0) <> 1
		BEGIN
			RAISERROR (21482, 16, -1, 'sp_changeqreader_agent', 'publisher_db')
			RETURN (1)
		END
	END

	--
	-- if executed from publisher
	--
	IF @frompublisher = 1
	BEGIN
		DECLARE @loc_publisher sysname
				,@loc_distribdb sysname
				,@rpcsrvname sysname
				,@rpc nvarchar(1000)
		--
		-- get the distributor rpc info
		--
		SELECT @loc_publisher = CONVERT(sysname, SERVERPROPERTY('ServerName'))
		EXEC @retcode = sys.sp_MSrepl_getdistributorinfo @publisher = @loc_publisher,
															@rpcsrvname = @rpcsrvname OUTPUT,
															@distribdb = @loc_distribdb OUTPUT

		IF @@error <> 0 OR @retcode <> 0 or (@rpcsrvname IS NULL) or (@loc_distribdb IS NULL)
		BEGIN
			RAISERROR (14080, 16, -1, @loc_publisher)
			RETURN (1)
		END
		--
		-- execute the RPC
		--
		select @rpc = quotename(@rpcsrvname) + N'.' + quotename(@loc_distribdb) + N'.dbo.sp_changeqreader_agent'
		exec @retcode = @rpc @job_login = @job_login,
								@job_password = @job_password,
								@frompublisher 	= 0
		IF @@error != 0
			select @retcode = 1

		RETURN @retcode
	END	

	-- if job login is specified
	IF @job_login IS NOT NULL
	BEGIN
		IF sys.fn_replisvalidwindowsloginformat(@job_login) != 1 AND sys.fn_MSrepl_editionid() != 32 -- @job_login is Distributor's SQL user in CL
		BEGIN
			-- '@job_login' must be a valid Windows Login in the form : 'MACHINE\Login' or 'DOMAIN\Login'. Please see the documentation for 'sp_changeqreader_agent'.
			RAISERROR(21797, 16, -1, '@job_login', 'sp_changeqreader_agent')
			RETURN 1
		END
	END
	
	EXEC @retcode = sys.sp_MSreplagentjobexists @exists = @qreader_exists output,
												@type = 4
	IF @@ERROR <> 0 or @retcode <> 0
		RETURN 1

	IF @qreader_exists = 0
	BEGIN
		-- "The qreader agent for publisher (%s), database (N/A), publication (N/A) could not be found."
		RAISERROR(21799, 16, -1, 'qreader', @@servername, 'N/A', 'N/A')
		RETURN 1
	END
	
	EXECUTE @retcode = sys.sp_MSadd_qreader_agent @job_login = @job_login,
													@job_password = @job_password,
													@internal = N'YUKON'
	IF @@ERROR <> 0 or @retcode <> 0
		RETURN 1
		
	RETURN 0
END
GO
GRANT EXECUTE ON [sys].[sp_changeqreader_agent] TO [public] AS [dbo]
GO
