SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_dropreplsymmetrickey]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_dropreplsymmetrickey] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_dropreplsymmetrickey]
	@check_replication [bit],
	@throw_error [bit]
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @error_number 	int,
			@error_severity int,
			@error_state 	int


	-- security check
    IF IS_MEMBER('db_owner') != 1
	BEGIN
		RAISERROR(21050, 14, -1)
		RETURN 1
    END

	IF @check_replication = 1
	BEGIN
		-- if requested we want to ensure that the current database is not :
		--		1) tran published
		--		2) tran subscriber
		--		3) merge published
		--		4) merge subscriber
	    IF sys.fn_MSrepl_istranpublished(DB_NAME(), 1) = 1
			OR (OBJECT_ID(N'MSreplication_subscriptions', N'U') IS NOT NULL
				OR OBJECT_ID(N'MSsubscription_properties', N'U') IS NOT NULL)
			OR sys.fn_MSrepl_ismergepublished(DB_NAME()) = 1
			OR (OBJECT_ID(N'MSmerge_replinfo', N'U') IS NOT NULL
				OR OBJECT_ID(N'sysmergesubscriptions', N'U') IS NOT NULL
				OR OBJECT_ID(N'sysmergepublications', N'U') IS NOT NULL
				OR OBJECT_ID(N'MSsubscription_properties', N'U') IS NOT NULL)
		BEGIN
			RETURN 0
		END
	END
	
	BEGIN TRY
		DROP SYMMETRIC KEY SQLSERVER_REPLICATION
	END TRY
	BEGIN CATCH
		-- we eat the following error:
		--  Msg 15151, Level 16, State 1, Line 1
		--  Cannot drop the symmetric key 'SQLSERVER_REPLICATION', because it does not exist or you do not have permission.
		IF @@ERROR != 15151
		BEGIN
			IF @throw_error = 1
			BEGIN
				SELECT @error_number = ERROR_NUMBER(), 
						@error_severity = ERROR_SEVERITY(), 
						@error_state = ERROR_STATE()

				RAISERROR(@error_number, @error_severity, @error_state)
			END
			
			RETURN 1
		END
	END CATCH

	BEGIN TRY
		DROP CERTIFICATE SQLSERVER_REPLICATION
	END TRY
	BEGIN CATCH
		-- we eat the following error:
		--  Msg 15151, Level 16, State 1, Line 1
		--  Cannot drop the certificate 'SQLSERVER_REPLICATION', because it does not exist or you do not have permission.
		IF @@ERROR != 15151
		BEGIN
			IF @throw_error = 1
			BEGIN
				SELECT @error_number = ERROR_NUMBER(), 
						@error_severity = ERROR_SEVERITY(), 
						@error_state = ERROR_STATE()

				RAISERROR(@error_number, @error_severity, @error_state)
			END
			
			RETURN 1
		END
	END CATCH
	
	RETURN 0
END
GO
GRANT EXECUTE ON [sys].[sp_dropreplsymmetrickey] TO [public] AS [dbo]
GO
