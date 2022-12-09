SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_adddistpublisher]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_adddistpublisher] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_adddistpublisher]
	@publisher [sysname],
	@distribution_db [sysname],
	@security_mode [int],
	@login [sysname],
	@password [sysname],
	@working_directory [nvarchar](255),
	@trusted [nvarchar](5),
	@encrypted_password [bit],
	@thirdparty_flag [bit],
	@publisher_type [sysname],
	@storage_connection_string [nvarchar](255)
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @cmd		nvarchar(4000)
	DECLARE @retcode	int
	DECLARE @distdb_in_secondary bit

	SET @retcode = 0
	SET @cmd = N''

	-- DEPRECATED PARAMETER: @trusted
	-- For security reasons, @trusted is no longer supported.
	-- Implicitly, it must always be @trusted == false.  If
	-- anything other than false is supplied, an error is thrown.
	IF LOWER(@trusted collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('false')
	BEGIN
		RAISERROR(21698, 16, -1, '@trusted')
		RETURN (1)
	END
	
	-- Check if HREPL
	IF NOT @publisher_type = N'MSSQLSERVER'
	BEGIN
		SET @cmd = @cmd + QUOTENAME(@distribution_db) + N'.'
	END

	-- Check if dist db is secondary in AG and if it is in readable state
	select @distdb_in_secondary = sys.fn_MSrepl_isdistdbsecondary(@distribution_db)
	
	if (@distdb_in_secondary = 1)
	BEGIN 
		if not exists (select * from sys.availability_replicas where replica_id = 
					(
						select hdr.replica_id from sys.dm_hadr_database_replica_states as hdr where hdr.database_id = db_id(@distribution_db collate database_default)
					)
					and secondary_role_allow_connections = 2
                   )
				    BEGIN
						RAISERROR (25036, 16, -1)
						RETURN (1)
					END
	END 	

	-- Add sp
	SET @publisher = UPPER(@publisher) COLLATE DATABASE_DEFAULT
	set @cmd = @cmd + N'sys.sp_MSrepl_adddistpublisher'
	
	EXEC @retcode = @cmd
					@publisher,
					@distribution_db,
					@security_mode,
					@login,
					@password,
					@working_directory,
					@trusted,
					@encrypted_password,
					@thirdparty_flag,
					@publisher_type,
					@storage_connection_string

	RETURN (@retcode)
END
GO
GRANT EXECUTE ON [sys].[sp_adddistpublisher] TO [public] AS [dbo]
GO
