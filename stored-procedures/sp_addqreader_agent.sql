SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_addqreader_agent]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_addqreader_agent] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_addqreader_agent]
	@job_login [nvarchar](257),
	@job_password [sysname],
	@job_name [sysname],
	@frompublisher [bit]
WITH EXECUTE AS CALLER
AS
BEGIN
	SET NOCOUNT ON
	DECLARE @retcode			int,
			@qreader_exists 	bit

	if (@frompublisher = 0)
	begin
		-- Security Check: require sysadmin/dbo of dist 
		IF IS_SRVROLEMEMBER('sysadmin') != 1
		BEGIN
			RAISERROR(21089,16,-1) 
			RETURN 1
		END

		-- database must be distribution db
		IF sys.fn_MSrepl_isdistdb(DB_NAME()) <> 1
		BEGIN
			RAISERROR (21482, 16, -1, 'sp_addqreader_agent', 'distribution')
			RETURN (1)
		END
	end
	else
	begin
		-- Security Check: require sysadmin of publisher 
		IF IS_SRVROLEMEMBER('sysadmin') != 1
		BEGIN
			RAISERROR(21089,16,-1) 
			RETURN 1
		END

		-- database must be publishing db
		IF sys.fn_MSrepl_istranpublished(DB_NAME(), 0) <> 1
		BEGIN
			RAISERROR (14013, 16, -1)
			RETURN (1)
		END
	end

	--
	-- if executed from publisher
	--
	if (@frompublisher = 1)
	begin
		declare @loc_publisher sysname
				,@loc_distribdb sysname
				,@rpcsrvname sysname
				,@rpc nvarchar(1000)
		--
		-- get the distributor rpc info
		--
		select @loc_publisher = CONVERT(sysname, SERVERPROPERTY('ServerName'))
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
		select @rpc = quotename(@rpcsrvname) + N'.' + quotename(@loc_distribdb) + N'.dbo.sp_addqreader_agent'
		exec @retcode = @rpc @job_login
							,@job_password
							,@job_name
							,0
		if (@@error != 0)
			select @retcode = 1
		--
		-- return
		--
		return @retcode
	end

	--
	-- If we are here - this SP is being executed on distributor
	--

	-- if we do not require yukon security then check paramters.
	IF sys.fn_yukonsecuritymodelrequired(NULL) = 0
	BEGIN
		IF @job_login IS NULL
		BEGIN
			IF @job_password IS NOT NULL
			BEGIN
				-- Parameter '@job_login' can be set to 'NULL' only when '@job_password' is set to 'NULL'.
				RAISERROR(21678, 16, -1, '@job_login', 'NULL', '@job_password', 'NULL')
				RETURN 1
			END
		END
		ELSE
		BEGIN
			IF @job_password IS NULL
			BEGIN
				-- Parameter '@job_password' can be set to 'NULL' only when '@job_login' is set to 'NULL'.
				RAISERROR(21678, 16, -1, '@job_password', 'NULL', '@job_login', 'NULL')
				RETURN 1
			END

			IF sys.fn_replisvalidwindowsloginformat(@job_login) != 1 AND sys.fn_MSrepl_editionid() != 32 -- @job_login is Distributor's SQL user in CL
			BEGIN
				-- '@job_login' must be a valid Windows Login in the form : 'MACHINE\Login' or 'DOMAIN\Login'. Please see the documentation for 'sp_addqreader_agent'.
				RAISERROR(21797, 16, -1, '@job_login', 'sp_addqreader_agent')
				RETURN 1
			END
		END
	END
	-- if yukon sec required then a valid windows login/password is required
	ELSE
	BEGIN
		IF @job_login IS NULL
			OR @job_password IS NULL
		BEGIN
			-- Only members of the sysadmin fixed server role can perform this operation without specifying @job_login or @job_password.
			RAISERROR(21832, 16, -1, '@job_login or @job_password')
			RETURN 1
		END

		IF sys.fn_replisvalidwindowsloginformat(@job_login) != 1 AND sys.fn_MSrepl_editionid() != 32 -- @job_login is Distributor's SQL user in CL
		BEGIN
			-- '@job_login' must be a valid Windows Login in the form : 'MACHINE\Login' or 'DOMAIN\Login'. Please see the documentation for 'sp_addqreader_agent'.
			RAISERROR(21797, 16, -1, '@job_login', 'sp_addqreader_agent')
			RETURN 1
		END
	END

	IF @job_name IS NULL
	BEGIN
		EXECUTE @retcode = sys.sp_MSreplagentjobexists @exists = @qreader_exists output,
													@type = 4
		IF @@ERROR <> 0 or @retcode <> 0
			RETURN 1

		IF @qreader_exists = 1
		BEGIN
			-- "The %s already exists. Use '%' to update any settings/properties."
			RAISERROR(21831, 16, -1, 'qreader agent', 'sp_changeqreader_agent')
			RETURN 1
		END
	END

	BEGIN TRANSACTION tr_addqreader_agent
	SAVE TRANSACTION tr_addqreader_agent
	
	EXECUTE @retcode = sys.sp_MSadd_qreader_agent @job_login = @job_login,
													@job_password = @job_password,
													@name = @job_name,
													@internal = N'YUKON'
													
	IF @@ERROR <> 0 or @retcode <> 0
		GOTO UNDO

	-- If we didn't need to create the job but 
	-- we were given the job_login and job_password
	-- then we will attempt to change them or add
	-- NOTE:
	-- We do this at the very end because the actual
	-- agent must be added prior to setting the login
	-- and passwords...
	IF @job_name IS NOT NULL
	BEGIN
		IF @job_login IS NOT NULL
		BEGIN
			EXECUTE @retcode = sys.sp_changeqreader_agent @job_login = @job_login,
															@job_password = @job_password,
															@frompublisher = @frompublisher
			IF @@ERROR <> 0 or @retcode <> 0
				GOTO UNDO
		END
	END

	COMMIT TRANSACTION tr_addqreader_agent
	
	RETURN 0
UNDO:
	ROLLBACK TRANSACTION tr_addqreader_agent
	COMMIT TRANSACTION 

	RETURN 1
END
GO
GRANT EXECUTE ON [sys].[sp_addqreader_agent] TO [public] AS [dbo]
GO
