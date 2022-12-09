SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_adddistributor]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_adddistributor] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_adddistributor]
	@distributor [sysname],
	@heartbeat_interval [int],
	@password [sysname],
	@from_scripting [bit]
WITH EXECUTE AS CALLER
AS
BEGIN

	SET NOCOUNT ON

	/*
	** Declarations.
	*/
	DECLARE @retcode int
				,@agentname nvarchar(100)
				,@command nvarchar(255)
				,@distribution_db sysname
				,@distproc nvarchar(255)
				,@dist_rpcname sysname
				,@dist_datasource sysname
				,@server_added bit
				,@login sysname
				,@callback sysname
				,@provstr nvarchar(4000) 
				,@distserver_with_port sysname

	EXEC sys.sp_MSget_server_portinfo  
		@distributor,
		@distributor OUTPUT,
		@distserver_with_port OUTPUT

	SET @provstr = sys.fn_getproviderstring(@distserver_with_port)
				
	/*
	** Security Check: require sysadmin
	*/
	IF (ISNULL(IS_SRVROLEMEMBER('sysadmin'),0) = 0)
	BEGIN
		RAISERROR(21089,16,-1) 
		RETURN (1)
	END

	select @server_added = 0 
	select @login = 'distributor_admin'

	-- Verify that this SKU is allowed to be a distributor
	exec @retcode = sys.sp_MSsku_allows_replication
	if @@error <> 0 return 1
	if @retcode <> 0
	begin
		raiserror(21105, 16, -1)
		return (1)
	end

	/* 
	** Check if replication components are installed on this server
	*/
	exec @retcode = sys.sp_MS_replication_installed
	if (@retcode <> 1)
	begin
		return (1)
	end

	-- Must be at master db.
	IF db_name() <> 'master'
	BEGIN
		RAISERROR(5001, 16,-1)
		return (1)
	END
	/*
	** Parameter Check:  @distributor.
	** Check to make sure that the distributor is not NULL and that it
	** conforms to the rules for identifiers.
	*/
	IF @distributor IS NULL
		BEGIN
			RAISERROR (14043, 16, -1, '@distributor', 'sp_adddistributor')
			RETURN (1)
		END

	EXECUTE @retcode = sys.sp_validname @distributor

	IF @@ERROR <> 0 OR @retcode <> 0
	   RETURN (1)
	
	 -- Verify password
	 IF (@password IS NULL) OR (@password = N'')
	BEGIN
		IF (UPPER(CONVERT(sysname, ServerProperty('ServerName'))) = UPPER(@distributor))
		BEGIN
			-- LOCAL DISTRIBUTOR: Seed password with random value
			SELECT @password = convert(sysname, newid())
		END
		ELSE
		BEGIN
			-- REMOTE DISTRIBUTOR: Require non-null password for security
			RAISERROR(21768, 16, -1)
			RETURN (1)
		END
	END

	if isnumeric(@heartbeat_interval) = 0 or convert(int, isnull(@heartbeat_interval, 0)) < 1
	begin
		raiserror (21115, 16, -1, @heartbeat_interval, '@heartbeat_interval')
		return 1
	end
	
	/*
	** Check to make sure that the distributor doesn't already exist.
	*/
	SELECT @dist_rpcname = NULL
	SELECT @dist_rpcname = srvname
			   ,@dist_datasource = datasource 
	FROM master.dbo.sysservers
	WHERE  srvstatus & 8 <> 0
	IF @dist_rpcname IS NOT NULL
	BEGIN
		RAISERROR (14099, 16, -1, @dist_datasource)
		RETURN(1)
	END

	-- drop repl_distributor if it exists.
	if exists (select * from master.dbo.sysservers where lower(srvname collate SQL_Latin1_General_CP1_CS_AS) = 
		N'repl_distributor'  collate SQL_Latin1_General_CP1_CS_AS)
	begin
		exec @retcode = sys.sp_dropserver 'repl_distributor', 'droplogins'
		IF @@error <> 0 OR @retcode <> 0
		BEGIN
			RETURN(1)
		END
	end

	-- Add the linked server entry for the distributor
	-- Note we do this even for local server for consistancy
	-- We will always use UPPERCASE name
	select @distributor = upper(@distributor)

	exec @retcode = sp_addlinkedserver @server = N'repl_distributor', @srvproduct = N'SQL Server' , @linkedstyle = 0
	IF @@error <> 0 OR @retcode <> 0
	BEGIN
		RETURN (1)
	END

	exec @retcode = sys.sp_setnetname N'repl_distributor', @distributor
	IF @@error <> 0 OR @retcode <> 0
	BEGIN
		RETURN (1)
	END
	exec @retcode = sys.sp_serveroption N'repl_distributor', N'provider string', @provstr
	IF @@error <> 0 OR @retcode <> 0
	BEGIN
		RETURN (1)
	END

	select @server_added = 1

	EXECUTE @retcode = sp_MSset_repl_serveroptions 'repl_distributor'
	IF @@error <> 0 OR @retcode <> 0
	BEGIN
		goto UNDO
	END

	-- Mark system
	EXECUTE @retcode = sys.sp_serveroption  'repl_distributor', 'system','true'
	IF @@error <> 0 OR @retcode <> 0
	BEGIN
		goto UNDO
	END
		
	exec @retcode = sys.sp_addlinkedsrvlogin 
		@rmtsrvname= 'repl_distributor',
		@useself = 'false',
		@locallogin = NULL,
		@rmtuser = @login,
		@rmtpassword = @password
	IF @@error <> 0 OR @retcode <> 0
	BEGIN
		goto UNDO
	END

	/*
	** If this is not the local server, remote distributor must be set up first
	*/
	IF UPPER(@distributor) <> UPPER(@@SERVERNAME)
	BEGIN
		-- make sure distributor version is >= publisher version
		declare @dist_ver bigint
		select @dist_ver = 0
		EXEC @retcode = repl_distributor.master.sys.sp_executesql N'select @dist_ver = @@microsoftversion', 
										N'@dist_ver bigint output', @dist_ver output
		IF (@retcode <> 0 or @@ERROR <> 0)
		begin
				GOTO UNDO
		end
		-- compare major versions
		if (@dist_ver & 0xFF000000 < @@microsoftversion & 0xFF000000 )
		begin
				RAISERROR (21320,16,-1)
				GOTO UNDO
		end
		/*
		** Test to see if the local server is defined as publisher/subscriber
		** at the remove distributor.
		** Note: cannot call sp_helpdistributor locally since the server is not
		** marked for distribution.
		** We can not move the serveroption call before this RPC because RPC failure
		** may cause the SP to terminate. Thus, we can not UNDO the server option.
		*/
		SELECT @distproc = 'repl_distributor.master.sys.sp_helpdistributor'
	
		DECLARE @loc_directory             nvarchar(255)
		DECLARE @loc_account             nvarchar(255)
		DECLARE @loc_mindistretention     int
		DECLARE @loc_maxdistretention     int
		DECLARE @loc_historyretention   int  
		DECLARE @loc_historycleanupagent nvarchar(100)
		DECLARE @loc_distribcleanupagent nvarchar(100)
		DECLARE @alert_name nvarchar(100)
		DECLARE @alert_id int

		--
		-- from publisher
		--
		EXECUTE @retcode = @distproc
			@distributor = @distributor OUTPUT,
			@distribdb = @distribution_db OUTPUT,
			@directory = @loc_directory OUTPUT,
			@account = @loc_account OUTPUT,
			@min_distretention = @loc_mindistretention OUTPUT,
			@max_distretention = @loc_maxdistretention OUTPUT,
			@history_retention = @loc_historyretention OUTPUT,
			@history_cleanupagent = @loc_historycleanupagent OUTPUT,
			@distrib_cleanupagent = @loc_distribcleanupagent OUTPUT,
			@publisher = @@SERVERNAME,
			@local = 'local'
		IF @@error <> 0 OR @retcode <> 0 OR @distribution_db is NULL
		BEGIN
			RAISERROR (21007,16,1)
			GOTO UNDO
		END

		--cleanup potential leftover here rather than in sys.sp_changedistpublisher as it used to be
		--because sp_changedistpublisher is public proc which can be called by user in ad-hoc fashion
		if @distribution_db is not null 
		begin 
			SELECT @distproc = 'repl_distributor.' + quotename(@distribution_db) + '.sys.sp_MSdistpublisher_cleanup'
			EXECUTE @retcode = @distproc @@SERVERNAME
			IF @@error <> 0 OR @retcode <> 0
			BEGIN
				GOTO UNDO
			END
		end 

		/* Activate the dist publisher at the remote distributor */
		SELECT @distproc = 'repl_distributor.master.sys.sp_changedistpublisher'
		EXECUTE @retcode = @distproc @@SERVERNAME, 'active','true'
		IF @@error <> 0 OR @retcode <> 0
		BEGIN
			GOTO UNDO
		END
	END
	ELSE
	/* set the registry */
	BEGIN
		EXEC @retcode = sys.sp_MScreate_distributor_tables 
		if @@error <> 0 or @retcode <> 0
			goto UNDO

		declare @distributor_login sysname
		select @distributor_login = 'distributor_admin'

		-- Add publisher/subscriber rpc login
		if not exists (select * from master.dbo.syslogins where loginname = @distributor_login collate database_default and is_srvrolemember('sysadmin', @distributor_login) = 1)
		begin
			EXEC @retcode = sys.sp_addlogin @loginame = @distributor_login,
					@passwd = @password
			if @@error <> 0 or @retcode <> 0
				goto UNDO

			-- Add the login to sysadmin
			-- Refer to sp_MSpublication_access in distribution db
			if is_srvrolemember('sysadmin', @distributor_login) <> 1
			begin
				exec @retcode = sys.sp_addsrvrolemember @distributor_login, 'sysadmin'
				IF @@error <> 0 OR @retcode <> 0
					goto UNDO
			end
		end
		else
		begin
			-- Change the password if the distributor is local
			EXEC @retcode = sys.sp_password NULL, @password, 'distributor_admin'
			if @@error <> 0 or @retcode <> 0
				goto UNDO
		end

		if @from_scripting <> 1
		begin
			-- Add Replication Agent Checkup Agent
			exec @retcode = sys.sp_MScreate_replication_checkup_agent @heartbeat_interval = @heartbeat_interval
			if @@error <> 0 or @retcode <> 0
				goto UNDO
		end
		
		delete msdb..MSdistributor where property = 'heartbeat_interval'
		if @@error <> 0
			goto UNDO
		insert into msdb..MSdistributor (property, value) values ('heartbeat_interval',
				convert(nvarchar(10), @heartbeat_interval))
		if @@error <> 0 
			goto UNDO

		-- Add Replication Alerts and Response Jobs
		exec @retcode = sys.sp_MSadd_distributor_alerts_and_responses
			@from_scripting = @from_scripting
		if @@error <> 0 or @retcode <> 0
			goto UNDO

		-- Add Distribution DB Job Sync Monitor job
		exec @retcode = sys.sp_MSadd_jobsync_monitor_job
		if @@error <> 0 or @retcode <> 0
			goto UNDO
	END

	/*
	** Set the server option to indicate that there is a distributor.
	*/
	EXECUTE @retcode = sys.sp_serveroption 'repl_distributor', 'dist', true
	IF @@error <> 0 OR @retcode <> 0
	BEGIN
		GOTO UNDO
	END

	-- Set sp_MSrepl_startup to be a startup stored procedure
	-- Note: This needs to be after the marking the distribution server
	-- CL Note: for a managed instance environment it should use 'failover' callback instead of 'startup'
	-- Defect 11687782: current version of CL(MI) blocks sp_procoption, so let's temporarily skip this call for this SKU
	IF NOT sys.fn_MSrepl_editionid() = 32 BEGIN
		select @callback = case when sys.fn_MSrepl_editionid() = 32 then 'failover' else 'startup' end
		exec @retcode = sys.sp_procoption 'sp_MSrepl_startup', @callback, 'true'
		if @@error <> 0 or @retcode <> 0
			goto UNDO1
	END

	exec @retcode = sys.sp_MSrepl_startup_internal
	if @@error <> 0 or @retcode <> 0
		goto UNDO1

	EXEC @retcode = sys.sp_MSrepl_add_expired_sub_cleanup_job
	IF @@ERROR <> 0 or @retcode <> 0
	BEGIN
		GOTO UNDO1
	END
	
	RETURN (0)

UNDO1:
	exec sys.sp_serveroption 'repl_distributor', 'dist', false
	EXEC sys.sp_MSrepl_drop_expired_sub_cleanup_job

UNDO:
	IF @server_added = 1
	begin
		-- Drop the remote logins, otherwise, sp_dropserver will fail.
		EXECUTE sys.sp_dropserver 'repl_distributor', 'droplogins'
	end
	
	RETURN (1)
END
GO
GRANT EXECUTE ON [sys].[sp_adddistributor] TO [public] AS [dbo]
GO
