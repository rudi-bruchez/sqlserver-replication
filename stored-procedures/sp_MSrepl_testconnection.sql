SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSrepl_testconnection]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSrepl_testconnection] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSrepl_testconnection]
	@publisher_type [sysname],
	@publisher [sysname],
	@security_mode [bit],
	@login [sysname],
	@password [sysname],
	@connect_timeout [int]
WITH EXECUTE AS CALLER
AS
BEGIN
	SET ANSI_WARNINGS ON
	
	DECLARE	@cmd		nvarchar(MAX)
	DECLARE	@p1			int
	DECLARE	@retcode	int
	DECLARE @provider   sysname
	DECLARE @type		sysname

	-------- security check, db_owner
	EXEC @retcode =	dbo.sp_MSreplcheck_publish
	IF @@ERROR <> 0	or @retcode	<> 0
	BEGIN
		RETURN(1)
	END

	-- Validate	parameters - @security_mode
	IF @security_mode =	0
	BEGIN
		IF @login IS NULL OR @login = N''
		BEGIN
			-- For all EXTENDED_SPECS size of provided string needs to be defined in bytes
			RAISERROR(7801, 16, -1, 12, N'@login')
			RETURN (1)
		END
		
		IF @password IS NULL OR @password = N''
		BEGIN
			-- For all EXTENDED_SPECS size of provided string needs to be defined in bytes
			RAISERROR(7801, 16, -1, 18, N'@password')
			RETURN (1)
		END
	END

	-- Construct ad-hoc connection string
	IF UPPER(@publisher_type) = N'MSSQLSERVER'
	BEGIN
		SET @cmd =	'SELECT @p1 = 1 FROM OPENDATASOURCE(''SQLOLEDB'', ''Data Source=' +	@publisher +
					CASE
						WHEN @security_mode = 0 THEN
							';User ID=' + sys.fn_replreplacesinglequote(@login) +
							';Password=' + sys.fn_replreplacesinglequote(@password)
						ELSE
							';TRUSTED_CONNECTION=Yes'
					END +
					';Timeout=' + convert(nvarchar(50), @connect_timeout) +
					';'').master.sys.objects'
		
		-- Test connection
		BEGIN TRY
			EXEC @retcode = sp_executesql @cmd, N'@p1 int', @p1 = 1
		END TRY
		BEGIN CATCH
			RAISERROR(21670, 16, -1, @publisher)
			RETURN (1)
		END CATCH
		RETURN (0)
	END
	
	IF UPPER(@publisher_type) LIKE N'ORACLE%'
	BEGIN
		-- Verify that the version of SQL*PLUS that loads through the system path
		-- is from a sufficiently current version of the Oracle client code to
		-- support Oracle publishing.
		EXEC @retcode = sys.sp_MSrepl_verify_oracle_client_version
		IF @retcode != 0 OR @@ERROR != 0
			RETURN (1)				

		-- Get provider type
		EXEC @retcode = sys.sp_IHgetprovider @publisher_type, @provider OUTPUT
	
		IF @retcode != 0 OR @@ERROR != 0
		BEGIN
			RETURN (1)
		END

		IF(@provider = N'OraOLEDB.ORACLE')
		BEGIN
			--- Verify that the Oracle provider is registered and that the registered DLL exists
			EXEC @retcode = sys.sp_MSrepl_verify_oracle_provider_isregistered
			IF @retcode != 0 OR @@ERROR != 0
				RETURN (1)				

			--- Fix oracle provider setting to force inproc usage because of oracle bug
			EXEC @retcode = sys.sp_MSrepl_set_oracle_provider_inproc_on64bit
			IF @retcode != 0 OR @@ERROR != 0
				RETURN (1)				
		END

		SET @cmd =	'SELECT @p1 = 1 FROM OPENDATASOURCE(' + QUOTENAME(@provider,'''') + ', ''Data Source=' + sys.fn_replreplacesinglequote(@publisher) +
					';User ID=''''' + sys.fn_replreplacesinglequote(sys.fn_replreplacesinglequote(@login)) +
					''''';Password=''''' + sys.fn_replreplacesinglequote(sys.fn_replreplacesinglequote(@password)) + 
					''''';Timeout=' + convert(nvarchar(50), @connect_timeout) +
					';'')..SYS.DUAL'
					
		-- Test connection 
		BEGIN TRY
			EXEC @retcode = sp_executesql @cmd, N'@p1 int', @p1 = 1
		END TRY
		BEGIN CATCH
			IF(@provider = N'OraOLEDB.ORACLE')
			BEGIN
				RAISERROR(21626, 16, -1, @publisher)
			END
			ELSE
			BEGIN
				RAISERROR(21627, 16, -1, @publisher)
			END	

			RETURN (1)
		END CATCH
		
		RETURN (0)
	END	

	-- Invalid publisher type
	RAISERROR(21645, 16, -1, @publisher_type)
	RETURN (1)
END
GO
GRANT EXECUTE ON [sys].[sp_MSrepl_testconnection] TO [public] AS [dbo]
GO
