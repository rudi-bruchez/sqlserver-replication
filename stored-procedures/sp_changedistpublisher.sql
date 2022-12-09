SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_changedistpublisher]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_changedistpublisher] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_changedistpublisher]
	@publisher [sysname],
	@property [sysname],
	@value [nvarchar](255)
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON

	/*
	** Declarations.
	*/
	DECLARE @retcode			int
	DECLARE @new_security_mode	int
	DECLARE @new_login			sysname
	DECLARE @new_password		nvarchar(524)
	DECLARE @distbit			int
	DECLARE @new_active			int
	DECLARE @command			nvarchar(524)
	DECLARE @dyn_command		nvarchar(MAX)
	declare @distribdb			sysname
	DECLARE @platform_nt		binary
	DECLARE @publisher_type		sysname
	DECLARE @publisher_id		int
	DECLARE @enc_string			nvarchar(779)
	
	SELECT @platform_nt = 0x1
	SELECT @distbit = 16
	
	/*
	** Security Check: require sysadmin
	*/
	IF (ISNULL(IS_SRVROLEMEMBER('sysadmin'),0) = 0)
	BEGIN
		RAISERROR(21089,16,-1) 
		RETURN (1)
	END

	/*
	** Parameter Check:  @property.
	** If the @property parameter is NULL, print the options.
	*/

	IF @property IS NULL
		BEGIN
			CREATE TABLE #tab1 (properties sysname collate database_default not null)
			INSERT INTO #tab1 VALUES ('distribution_db')
			INSERT INTO #tab1 VALUES ('working_directory')
			IF (sys.fn_MSrepl_editionid() = 32) INSERT INTO #tab1 VALUES ('storage_connection_string')
			INSERT INTO #tab1 VALUES ('security_mode')
			INSERT INTO #tab1 VALUES ('login')
			INSERT INTO #tab1 VALUES ('password')
			INSERT INTO #tab1 VALUES ('active')
			INSERT INTO #tab1 VALUES ('trusted')
			SELECT * FROM #tab1
			RETURN (0)
		END

	/*
	** Parameter Check:  @property.
	** Check to make sure that @property is a valid property in
	** msdb.dbo.MSdistpublishers.
	*/
	IF sys.fn_MSrepl_editionid() = 32
	BEGIN
		-- Let's handle Cloud Lifter scenario separately
		IF @property IS NULL OR LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) NOT IN
			('distribution_db',
			 'working_directory',
			 'storage_connection_string',
			 'security_mode',
			 'login',
			 'password',
			 'active',
			 'trusted')
			BEGIN
				RAISERROR (14115, 16, -1, 
				'''distribution_db'', ''working_directory'', ''storage_connection_string'', ''security_mode'', ''login'', ''password'', ''active'', or ''trusted''')
				RETURN (1)
			END
	END
	ELSE
		IF @property IS NULL OR LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) NOT IN 
			('distribution_db',
			 'working_directory',
			 'security_mode',
			 'login',
			 'password',
			 'active',
			 'trusted')
			BEGIN
				RAISERROR (14115, 16, -1, 
				'''distribution_db'', ''working_directory'', ''security_mode'', ''login'', ''password'', ''active'', or ''trusted''')
				RETURN (1)
			END

	/*
	** Check to make sure this is a distributor
	*/
	IF NOT EXISTS (SELECT * FROM master.dbo.sysservers
			  WHERE UPPER(datasource collate database_default) = UPPER(@@SERVERNAME) collate database_default
				 AND srvstatus & 8 <> 0)
	BEGIN
		RAISERROR (14114, 16, -1, @@SERVERNAME)
		RETURN(1)
	END

	-- Get publisher type
	EXEC @retcode = sys.sp_MSrepl_getdistributorinfo @publisher      = @publisher,
													 @publisher_type = @publisher_type OUTPUT

	IF (@retcode <> 0) OR (@publisher_type IS NULL)
	BEGIN
		RAISERROR(21169, 16, -1, @publisher, @@SERVERNAME, @publisher)
		RETURN (@retcode)
	END

	-- Get the distribution db name.
	SELECT	@distribdb = distribution_db
	FROM	msdb..MSdistpublishers
	WHERE	UPPER(name collate database_default) = UPPER(@publisher) collate database_default

	-- Reject unsupported HREPL properties
	IF @publisher_type != N'MSSQLSERVER'
	BEGIN
		IF  LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) IN ('trusted')
		BEGIN
			RAISERROR(21649, 16, -1, @property)
			RETURN(1)
		END
	END

	-- retrieve the publisher id
	SELECT @publisher_id = server_id 
		FROM sys.servers
		WHERE UPPER(name collate database_default) = UPPER(@publisher) collate database_default
	/*
	** Change the property.
	*/
	IF LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = 'distribution_db'
		BEGIN
			IF @value IS NULL
				BEGIN
					RAISERROR (14043, 16, -1, '@value', 'sp_changedistpublisher')
					RETURN (1)
				END

			IF @value <> @distribdb and 
				EXISTS (SELECT * FROM msdb.dbo.MSdistpublishers WHERE
				UPPER(name collate database_default) = UPPER(@publisher) collate database_default and active = 1)
			BEGIN
				RAISERROR (21046, 16, -1)
				RETURN (1)
			END

			/*
			** Check if database is configured as a distributor database
			*/
			IF NOT EXISTS (SELECT * FROM master.dbo.sysdatabases
			  WHERE name = @value collate database_default
				 AND category & @distbit <> 0)
				BEGIN
					RAISERROR (14117, 16, -1, @value)
					RETURN(1)
				END

			UPDATE msdb..MSdistpublishers SET distribution_db = @value
				WHERE UPPER(name collate database_default) = UPPER(@publisher) collate database_default
			IF @@error <> 0 
				BEGIN
					RETURN (1)
				END
		END
   
	IF LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = 'working_directory'
		BEGIN
			IF @value IS NULL
				BEGIN
					RAISERROR (14043, 16, -1, '@value', 'sp_changedistpublisher')
					RETURN (1)
				END

			
			-- Validate the working directory 
			-- Remove heading and trailing spaces
			select @value = RTRIM(LTRIM(@value))

			-- if the last char is '\', remove it.

			if substring(@value, len(@value),1) = '\'
				select @value = substring(@value, 1,
					len(@value)-1)

			-- Don't do validation if it is a UNC path due to security problem.
			-- If the server is started as a service using local system account, we
			-- don't have access to the UNC path.
			if substring(@value, 1,2) <> '\\'
			begin
				if not exists (select 1 from sys.dm_os_file_exists(@value) where file_is_a_directory > 0)
				begin
					raiserror (21037, 16, -1, @value)
					return 1
				end
			end

			UPDATE msdb..MSdistpublishers SET working_directory = @value
				WHERE UPPER(name collate database_default) = UPPER(@publisher) collate database_default
			IF @@error <> 0 
				BEGIN
					RETURN (1)
				END
		END

	IF LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = 'storage_connection_string'
		BEGIN
			SELECT @enc_string = @value,
				@command = QUOTENAME(@distribdb) + '.sys.sp_MSrepl_encrypt_access_string'

			EXEC @retcode = @command @enc_string OUTPUT
			IF @@error <> 0 OR @retcode <> 0
				RETURN (1)

			UPDATE msdb..MSdistpublishers SET storage_connection_string = @enc_string
				WHERE UPPER(name collate database_default) = UPPER(@publisher) collate database_default
			IF @@error <> 0 
				RETURN (1)
		END

	IF LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = 'security_mode'
		BEGIN
			IF @value IS NULL
				BEGIN
					RAISERROR (14043, 16, -1, '@value', 'sp_changedistpublisher')
					RETURN (1)
				END

			-- HREPL: Reject security_mode changes
			IF @publisher_type != N'MSSQLSERVER'
			BEGIN
				RAISERROR(21649, 16, -1, 'security_mode')
				RETURN (1)
			END

			/*
			** Set the SecurityMode registry key value
			*/
			SELECT @new_security_mode = CONVERT(int, @value)

			/* 
			** Check for invalid values 
			*/
			IF @new_security_mode < 0 OR @new_security_mode > 1
				BEGIN
					RAISERROR(14109, 16, -1)
					RETURN (1)
				END

			IF (UPPER(@publisher) = UPPER(@@SERVERNAME) and ( @platform_nt != platform() & @platform_nt ) and @new_security_mode = 1)
			BEGIN
				RAISERROR(21038, 16, -1)
				RETURN (1)
			END

			-- Security Mode 1 
			IF @new_security_mode = 1
			BEGIN
				SELECT @new_password = newid(),
						@command = QUOTENAME(@distribdb) + '.sys.sp_MSreplencrypt'
						
				EXEC @retcode = @command @new_password OUTPUT
				IF @@error <> 0 OR @retcode <> 0
					RETURN (1)    	

				UPDATE msdb..MSdistpublishers 
					SET security_mode = 1,
						login = N'',
						password = @new_password
					WHERE UPPER(name collate database_default) = UPPER(@publisher) collate database_default
				IF @@error <> 0 
					RETURN (1)
			END
			-- Security Mode 0
			ELSE
			BEGIN
				UPDATE msdb..MSdistpublishers 
					SET security_mode = 0
					WHERE UPPER(name collate database_default) = UPPER(@publisher) collate database_default
				IF @@error <> 0 
					RETURN (1)
			END
		END

	IF LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = 'login'
		BEGIN
			IF @value IS NULL
			BEGIN
				RAISERROR (14043, 16, -1, '@value', 'sp_changedistpublisher')
				RETURN (1)
			END
			
			-- HREPL: Reject login changes
			IF @publisher_type != N'MSSQLSERVER'
			BEGIN
				RAISERROR(21649, 16, -1, 'login')
				RETURN (1)
			END

			/*
			** Set the Login registry key value
			*/
			SELECT @new_login = CONVERT(sysname, @value)

			UPDATE msdb..MSdistpublishers SET login = @new_login
				WHERE UPPER(name collate database_default) = UPPER(@publisher) collate database_default
			IF @@error <> 0 
			BEGIN
				RETURN (1)
			END
		END

	IF LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = 'password'
		BEGIN
			-- Set the Password registry key value
			SELECT @new_password = CONVERT(nvarchar(524), @value)

			-- HREPL: Verify password
			IF @publisher_type != N'MSSQLSERVER'
			BEGIN
				DECLARE @remote_login sysname
				
				-- Get login
				SELECT	@remote_login	= login
				FROM	msdb..MSdistpublishers
				WHERE	UPPER(name collate database_default) = UPPER(@publisher) collate database_default
						AND security_mode = 0

				IF @remote_login IS NOT NULL
				BEGIN
					EXEC @retcode = sys.sp_MSchangerepllinkedsrvrpassword @server       = @publisher,
																		  @remote_login = @remote_login,
																		  @new_password = @new_password,
																		  @server_type  = @publisher_type
					IF @@error <> 0 OR @retcode <> 0
						RETURN (1)
				END
			END

			-- Encrypt the password, must use the distdb certs/keys
			SELECT @command = QUOTENAME(@distribdb) + '.sys.sp_MSreplencrypt'
			
			EXEC @retcode = @command @new_password OUTPUT
			IF @@error <> 0 OR @retcode <> 0
				RETURN (1)    	
				
			UPDATE msdb..MSdistpublishers SET password = @new_password
				WHERE UPPER(name collate database_default) = UPPER(@publisher) collate database_default
			IF @@error <> 0 
				BEGIN
					RETURN (1)
				END
		 END

	IF LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = 'active'
		BEGIN
			/*
			** Check for a valid  value.
			*/

			IF LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('true', 'false')
			BEGIN
				RAISERROR (14137, 16, -1)
				RETURN (1)
			END
			IF LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) = 'true'
			begin
				SELECT @new_active = 1
			end
			ELSE
			BEGIN
				SELECT @new_active = 0
			END

			/*
			** Set the Active registry key value
			*/
			UPDATE msdb..MSdistpublishers SET active = @new_active
				WHERE UPPER(name collate database_default) = UPPER(@publisher) collate database_default
			IF @@error <> 0
			BEGIN
				RETURN (1)
			END

		END

	IF LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = 'trusted'
	BEGIN
		--
		-- Check for a valid  value.
		--
		IF LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('true', 'false')
		BEGIN
			RAISERROR (14137, 16, -1)
			RETURN (1)
		END
		
		-- DEPRECATED OPTION: trusted
		-- For security reasons, trusted is no longer supported.
		-- Implicitly, it must always be trusted == false.  If
		-- anything other than false is supplied, an error is thrown.
		IF LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) = 'true'
		BEGIN
			RAISERROR(21698, 16, -1, 'trusted')
			RETURN (1)
		END

		-- IF TRUSTED == FALSE, do nothing since this is no longer supported.
	END

  
	/*
	** Return succeed.
	*/
	RAISERROR (21035, 10, -1, @property)

DONE:    
	RETURN (0)
GO
GRANT EXECUTE ON [sys].[sp_changedistpublisher] TO [public] AS [dbo]
GO
