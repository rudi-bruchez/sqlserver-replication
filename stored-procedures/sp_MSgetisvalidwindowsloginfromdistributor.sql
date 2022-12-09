SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSgetisvalidwindowsloginfromdistributor]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSgetisvalidwindowsloginfromdistributor] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSgetisvalidwindowsloginfromdistributor]
	@login [nvarchar](257),
	@isvalid [bit] OUTPUT,
	@publisher [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
	SET NOCOUNT ON
	
	DECLARE @retcode 			int,
			@dbname 			sysname,
			@distproc			nvarchar(4000),
			@distributor_rpc	sysname,
			@distribution_db	sysname

	SELECT @isvalid = 0,
			@dbname = DB_NAME()
	
	-- if db is publisher we will reroute to distributor
	IF sys.fn_MSrepl_ispublished(@dbname) = 1
	BEGIN
		-- Security Check
		EXEC @retcode = sys.sp_MSreplcheck_publish
		IF @@ERROR <> 0 OR @retcode <> 0
			RETURN 1

		-- retrieve the distributor db information
		EXEC @retcode = sys.sp_helpdistributor @rpcsrvname = @distributor_rpc OUTPUT,
												@distribdb = @distribution_db OUTPUT,
												@publisher = @publisher
		IF @@ERROR <> 0 OR @retcode <> 0 OR @distributor_rpc IS NULL OR @distribution_db IS NULL
		BEGIN
			-- "The Distributor has not been installed correctly."
			RAISERROR (20036, 16, -1)
			RETURN 1
		END

		SELECT @distproc = QUOTENAME(@distributor_rpc) + '.' + QUOTENAME(@distribution_db) + '.sys.sp_MSgetisvalidwindowsloginfromdistributor'

		EXEC @retcode = @distproc @login = @login,
									@isvalid = @isvalid OUTPUT
		
		IF @@ERROR <> 0 OR @retcode <> 0
			RETURN 1
	END
	-- if we are at the distributor db then return the value
	ELSE IF sys.fn_MSrepl_isdistdb (@dbname) = 1
	BEGIN
		-- Security Check
		IF IS_MEMBER('db_owner') != 1 
		BEGIN
			RAISERROR(14260, 16, -1)
			RETURN 1
		END
		
		SELECT @isvalid = sys.fn_replisvalidwindowsloginformat(@login)
	END
	-- else raise an error
	ELSE
	BEGIN
		-- The database is not published.
		RAISERROR (18757, 16, -1)
		RETURN 1
	END

	RETURN 0
END
GO
GRANT EXECUTE ON [sys].[sp_MSgetisvalidwindowsloginfromdistributor] TO [public] AS [dbo]
GO
