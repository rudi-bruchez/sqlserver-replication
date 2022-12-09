SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_get_distributor]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_get_distributor] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_get_distributor]
WITH EXECUTE AS CALLER
AS
BEGIN
    SET NOCOUNT ON

    DECLARE @retcode 					tinyint,
    		@has_access 				bit,
			@proc						nvarchar(4000),
			@cmd						nvarchar(4000),
			@database					sysname,
			@is_distdb					bit,
			@distributor 				sysname,
    		@installed 					bit,
    		@distdb_installed 			bit,
    		@is_distpublisher 			bit,
    		@has_remote_distpublisher 	bit
    
	SELECT @has_access					= 0,
			@proc						= NULL,
			@cmd						= NULL,
			@database					= NULL,
			@distributor 				= NULL,
    		@installed 					= 0,
    		@distdb_installed 			= 0,
    		@is_distpublisher 			= 0,
    		@has_remote_distpublisher 	= 0
	
	-- sysadmin can view any information
	IF IS_SRVROLEMEMBER('sysadmin') = 1
		SELECT @has_access = 1
	
	-- In this section, if we don't have access yet, we will go 
	-- through all publisher and distribution databases and check
	-- what permissions a user has to determine if they have access
	IF @has_access = 0
	BEGIN
		DECLARE #curDbs CURSOR LOCAL FAST_FORWARD FOR
			SELECT sys.fn_MSrepl_isdistdb(name),
					name
				FROM master..sysdatabases
				WHERE HAS_DBACCESS(name) = 1
					AND name NOT IN ( N'master' COLLATE DATABASE_DEFAULT,
										N'tempdb' COLLATE DATABASE_DEFAULT,
										N'msdb'   COLLATE DATABASE_DEFAULT,
										N'model'   COLLATE DATABASE_DEFAULT)
					AND (sys.fn_MSrepl_ispublished(name) = 1
						OR sys.fn_MSrepl_isdistdb(name) = 1)
		OPEN #curDbs

		FETCH #curDbs INTO @is_distdb, @database
		
		WHILE (@@FETCH_STATUS = 0)
		BEGIN
			IF @is_distdb = 1
			BEGIN
				-- DISTRIBUTION DATABASES
				--
				-- Check if the user is DBO of Distribution DB or in ReplMonitor 
				-- or PAL in hetero. If so we will grant them access to the info
				SELECT @proc = QUOTENAME(@database) + '.sys.sp_executesql',
						@cmd = N'IF IS_MEMBER(N''db_owner'') = 1 OR ISNULL(IS_MEMBER(N''replmonitor''), 0) = 1 OR sys.fn_isrolemember(0, SUSER_SNAME(), NULL) = 1 BEGIN SELECT @has_access = 1 END ELSE BEGIN SELECT @has_access = 0 END'

				EXEC @retcode = @proc @cmd,
										N'@has_access bit output',
										@has_access output
				IF @@ERROR != 0 OR @retcode != 0
					GOTO FAILURE
			END
			ELSE
			BEGIN
				-- PUBLISHER DATABASES
				--
				-- Check if the user is DBO or PAL of MERGE or TRAN (no hetero)
				-- Published database. If so we will grant them access to the info
				SELECT @proc = QUOTENAME(@database) + '.sys.sp_executesql',
						@cmd = N'IF IS_MEMBER(N''db_owner'') = 1 OR sys.fn_isrolemember(0, SUSER_SNAME(), NULL) = 1 BEGIN SELECT @has_access = 1 END ELSE BEGIN SELECT @has_access = 0 END'

				EXEC @retcode = @proc @cmd,
										N'@has_access bit output',
										@has_access output
				IF @@ERROR != 0 OR @retcode != 0
					GOTO FAILURE
			END

			IF @has_access = 1
				BREAK

			FETCH #curDbs INTO @is_distdb, @database
		END

		CLOSE #curDbs
		DEALLOCATE #curDbs
	END

	-- if the user has access then we will retrieve
	-- the information... if not then we return NULLs
	IF @has_access = 1
	BEGIN
		SELECT @distributor = datasource 
    		FROM master.dbo.sysservers
			WHERE srvstatus & 8 <> 0

		IF @distributor IS NOT NULL
    		SELECT @installed = 1

		IF UPPER(@distributor) = UPPER(@@SERVERNAME)
		BEGIN
			IF EXISTS (SELECT * FROM msdb.dbo.MSdistributiondbs) 
				SELECT @distdb_installed = 1
			
			IF EXISTS (SELECT * FROM msdb..MSdistpublishers WHERE UPPER(name) = UPPER(@@SERVERNAME) COLLATE database_default)
				SELECT @is_distpublisher = 1
			
			IF EXISTS (SELECT * FROM msdb..MSdistpublishers WHERE UPPER(name) <> UPPER(@@SERVERNAME) COLLATE database_default)
				SELECT @has_remote_distpublisher = 1
		END
	END

    SELECT 'installed'							= @installed, 
			'distribution server'				= @distributor,
            'distribution db installed'			= @distdb_installed,
            'is distribution publisher'			= @is_distpublisher,
            'has remote distribution publisher' = @has_remote_distpublisher

	RETURN 0
FAILURE:
	RETURN 1
END
GO
GRANT EXECUTE ON [sys].[sp_get_distributor] TO [public] AS [dbo]
GO
