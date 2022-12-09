SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_dropdistributor]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_dropdistributor] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_dropdistributor]
	@no_checks [bit],
	@ignore_distributor [bit]
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON

	/*
	** Declarations.
	*/
	DECLARE @retcode int
	DECLARE @distributor sysname
	DECLARE @agentname nvarchar(100)
	DECLARE @distbit int
	DECLARE @distribdb sysname
	DECLARE @foundSubscriber int
	DECLARE @proc nvarchar(255) 
	declare @optname sysname
	declare @name sysname
	DECLARE @transpublishdb_bit int
	DECLARE @mergepublishdb_bit int
	declare @job_name nvarchar(100)
	declare @alert_name nvarchar(100)
	declare @dist_rpcname sysname
	declare @alert_id   int
	declare @callback sysname
   
	/*
	** Security Check: require sysadmin
	*/
	IF (ISNULL(IS_SRVROLEMEMBER('sysadmin'),0) = 0)
	BEGIN
		RAISERROR(21089,16,-1) 
		RETURN (1)
	END

	SELECT @transpublishdb_bit = 1
	SELECT @mergepublishdb_bit = 4
	SELECT @foundSubscriber = 0
	SELECT @distbit = 16

	-- Get distributor name
	select @distributor = datasource, @dist_rpcname = srvname from master.dbo.sysservers 
		WHERE srvstatus & 8 <> 0
	if @distributor is null
	BEGIN
		RAISERROR (21043, 16, -1)
		RETURN(1)
	END

	if @no_checks = 1
	begin
		-- We are in bruteforce cleanup mode, drop everything.
		DECLARE hCdropdistributor CURSOR LOCAL FAST_FORWARD FOR
				SELECT name, N'publish' FROM master.dbo.sysdatabases      
					WHERE (category & @transpublishdb_bit) <> 0 
				UNION
				select name, N'merge publish' from master.dbo.sysdatabases
					WHERE (category & @mergepublishdb_bit) <> 0
				FOR READ ONLY

		OPEN hCdropdistributor
		FETCH hCdropdistributor INTO @name, @optname
	
		WHILE (@@fetch_status <> -1)
		BEGIN
						
			EXECUTE @retcode  = sys.sp_replicationdboption	@dbname				= @name,
															@optname			= @optname,
															@value				= 'false',
															@ignore_distributor	= @ignore_distributor
			
			IF @@ERROR <> 0 OR @retcode <> 0
			BEGIN
				CLOSE hCdropdistributor
				DEALLOCATE hCdropdistributor
				RETURN (1)
			END
			FETCH hCdropdistributor INTO @name, @optname
		end

		CLOSE hCdropdistributor
		DEALLOCATE hCdropdistributor
	
		-- Drop subscribers of local SQL Server publisher
		EXECUTE @retcode  = sys.sp_dropsubscriber	@subscriber			= 'all',
													@ignore_distributor	= @ignore_distributor

		IF @@ERROR <> 0 OR @retcode <> 0
			RETURN (1)

		-- Drop subscribers and associated subscriptions of heterogeneous publishers using this server
		-- as their distributor
		IF UPPER(@distributor) = UPPER(@@SERVERNAME) 
		begin
		
			if exists (select * from msdb.sys.objects where name = 'MSdistpublishers'
				and type = 'U')
			begin
				-- Clean up heterogeneous subscribers
				DECLARE hCdrophsubscriber CURSOR LOCAL FAST_FORWARD FOR
						SELECT name FROM msdb..MSdistpublishers
						WHERE publisher_type <> 'MSSQLSERVER'
				FOR READ ONLY

				OPEN hCdrophsubscriber
				FETCH hCdrophsubscriber INTO @name

				WHILE (@@fetch_status <> -1)
				BEGIN
					exec @retcode = sys.sp_dropsubscriber	@subscriber			= 'all',
															@ignore_distributor	= @ignore_distributor,
															@publisher			= @name,
															@reserved			= 'drop_subscriptions'
				
					IF @@ERROR <> 0 OR @retcode <> 0
					BEGIN
						CLOSE hCdrophsubscriber
						DEALLOCATE hCdrophsubscriber
						RETURN (1)
					END
					FETCH hCdrophsubscriber INTO @name
				end

				CLOSE hCdrophsubscriber
				DEALLOCATE hCdrophsubscriber
			end            
		end    

		IF UPPER(@distributor) = UPPER(@@SERVERNAME) 
		begin

			if exists (select * from msdb.sys.objects where name = 'MSdistpublishers'
				and type = 'U')
			begin
				-- Clean up dist publishers
				DECLARE hCdropdistributor CURSOR LOCAL FAST_FORWARD FOR
						SELECT name FROM msdb..MSdistpublishers
				FOR READ ONLY

				OPEN hCdropdistributor
				FETCH hCdropdistributor INTO @name 

				WHILE (@@fetch_status <> -1)
				BEGIN
					exec @retcode = sys.sp_dropdistpublisher @publisher = @name,
																@no_checks = @no_checks,
																@ignore_distributor = @ignore_distributor  
					
					IF @@ERROR <> 0 OR @retcode <> 0
					BEGIN
						CLOSE hCdropdistributor
						DEALLOCATE hCdropdistributor
						RETURN (1)
					END
					FETCH hCdropdistributor INTO @name 
				end

				CLOSE hCdropdistributor
				DEALLOCATE hCdropdistributor
			end

			if (@ignore_distributor = 0
					or @no_checks = 1)
				and exists (select * from msdb.sys.objects where name = 'MSdistributiondbs' and type = 'U') 
				and exists (select * from msdb.sys.objects where name = 'MSdistpublishers' and type = 'U') 
			begin

				-- Clean up distribution dbs
				DECLARE hCdropdistributor CURSOR LOCAL FAST_FORWARD FOR
						SELECT name FROM msdb..MSdistributiondbs
				FOR READ ONLY

				OPEN hCdropdistributor
				FETCH hCdropdistributor INTO @name

				WHILE (@@fetch_status <> -1)
				BEGIN
					exec @retcode = sys.sp_dropdistributiondb @database = @name

					IF @@ERROR <> 0 OR @retcode <> 0
					BEGIN
						CLOSE hCdropdistributor
						DEALLOCATE hCdropdistributor
						RETURN (1)
					END
					FETCH hCdropdistributor INTO @name
				end

				CLOSE hCdropdistributor
				DEALLOCATE hCdropdistributor
			end
		end
	end
	
	-- If everything should be cleaned up when we reach here with @no_checks = 1
	/*
	** If local distributor, check if there are any distributor databases
	*/
	
	IF UPPER(@distributor) = UPPER(@@SERVERNAME) 
	BEGIN
		if exists (select * from msdb.sys.objects where name = 'MSdistributiondbs'
			and type = 'U')
		begin
			IF EXISTS (SELECT * FROM msdb..MSdistributiondbs)
			BEGIN
				RAISERROR (14121, 16, -1, @distributor)
				RETURN(1)
			END
		end
	END
	ELSE
	begin
		-- Check to see if there are database published.
		if exists (SELECT * FROM master.dbo.sysdatabases      
			WHERE (category & @transpublishdb_bit) <> 0 or 
			(category & @mergepublishdb_bit) <> 0)
		begin
			raiserror(21045, 16, -1)
			return(1)
		end

	end

	/*
	** if @ignore_distributor = 1, we are in bruteforce cleanup mode, don't do RPC.
	*/
	if @ignore_distributor = 0 
	begin
		/*
		** Get distribution server information
		*/
		EXEC @retcode = sys.sp_MSrepl_getdistributorinfo @publisher = @@SERVERNAME,
			@distribdb = @distribdb OUTPUT
		IF @@error <> 0 OR @retcode <> 0
		BEGIN
			RAISERROR (14071, 16, -1)
			RETURN (1)
		END

		IF @distribdb is NOT NULL
		BEGIN
			/* 
			** Deactivate the dist publisher at the  distributor 
			** Only do this if @distribdb is NOT NULL, which means the dist publisher
			** if defined.
			*/
			SELECT @proc = RTRIM(@dist_rpcname) + '.master.sys.sp_changedistpublisher'
				EXECUTE @retcode = @proc @@SERVERNAME, 'active','false'
			IF @@error <> 0 OR @retcode <> 0
			BEGIN
				RETURN (1)
			END
		END
	end


	/*
	** Clear the server option to indicate that this is a distributor.
	*/
	EXECUTE @retcode = sys.sp_serveroption @dist_rpcname, 'dist', false
	IF @@error <> 0 OR @retcode <> 0
		BEGIN
			RETURN(1)
		END

	-- Prevent dropping local server entry accidentally if user 
	-- set 'dist' server option on local server.
	if UPPER(@dist_rpcname) <> UPPER(@@servername)
	begin
		-- get the servername that was persisted in the sysservers table
		SELECT @dist_rpcname = sys.fn_getpersistedservernamecasevariation(@dist_rpcname) collate database_default
	
		exec @retcode = sys.sp_dropserver @dist_rpcname, 'droplogins'
		IF @@error <> 0 OR @retcode <> 0
		BEGIN
			RETURN(1)
		END
	end


	-- Drop table after unmark distributor to prevent 
	-- sp_helpdist* failures.

	/* If local, Drop replication category and alerts */
	IF UPPER(@distributor) = UPPER(@@SERVERNAME)
	BEGIN

	-- Attempts to drop distributor_login, no big deal if it's still in use and we can't drop, don't quit here.

		declare @distributor_login sysname
		select @distributor_login = 'distributor_admin'

		if exists (select * from master.dbo.syslogins where loginname = @distributor_login collate database_default)
		begin
			EXEC @retcode = sys.sp_droplogin @loginame = @distributor_login
	 end

		-- Drop Distributor Alerts and Jobs
		exec @retcode = sys.sp_MSdrop_distributor_alerts_and_responses
		IF @@ERROR <> 0 or @retcode <> 0
		BEGIN
			return (1)            
		END

        -- Drop Distribution DB Job Sync Monitor job
        exec @retcode = sys.sp_MSdrop_jobsync_monitor_job
        IF @@ERROR <> 0 or @retcode <> 0
        BEGIN
            return (1)            
        END

        -- Drop the two system tables.
        if exists (select * from msdb.sys.objects where name = 'MSdistpublishers'
            and type = 'U')
            drop table msdb..MSdistpublishers
    
        if @@error <> 0 
            return 1 ;

		if exists (select * from msdb.sys.objects where name = 'MSdistributiondbs'
			and type = 'U')
			drop table msdb..MSdistributiondbs

		if @@error <> 0
			return 1 ;

		if exists (select * from msdb.sys.objects where name = 'MSdistributor'
				and type = 'U')
			drop table msdb..MSdistributor

		if @@error <> 0
			return 1 ;

		if exists (select * from msdb.sys.objects where name = 'sysreplicationalerts'
				and type = 'U')
			drop table msdb.dbo.sysreplicationalerts

		if @@error <> 0
			return 1 ;


		if exists (select * from msdb.sys.objects where name = 'MSagent_profiles'
			and type = 'U')
			drop table msdb..MSagent_profiles

		if @@error <> 0
			return 1 ;


	   if exists (select * from msdb.sys.objects where name = 'MSagent_parameters'
				and type = 'U')
			drop table msdb..MSagent_parameters

		if @@error <> 0
			return 1 ;

	END
	EXEC @retcode = sys.sp_MSrepl_drop_expired_sub_cleanup_job

	-- Unregister sp_MSrepl_startup as a startup stored procedure
	-- CL Note: for a managed instance environment it should use 'failover' callback instead of 'startup'
	-- Defect 11687782: current version of CL(MI) blocks sp_procoption, so let's temporarily skip this call for this SKU
	IF NOT sys.fn_MSrepl_editionid() = 32 BEGIN
		select @callback = case when sys.fn_MSrepl_editionid() = 32 then 'failover' else 'startup' end
		exec @retcode = master.sys.sp_procoption 'sp_MSrepl_startup', @callback, 'false'
		if @@error <> 0 or @retcode <> 0
			return 1
	END

	RETURN (0)        
GO
GRANT EXECUTE ON [sys].[sp_dropdistributor] TO [public] AS [dbo]
GO
