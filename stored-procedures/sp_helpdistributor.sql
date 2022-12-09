SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_helpdistributor]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_helpdistributor] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_helpdistributor]
	@distributor [sysname] OUTPUT,
	@distribdb [sysname] OUTPUT,
	@directory [nvarchar](255) OUTPUT,
	@account [nvarchar](255) OUTPUT,
	@min_distretention [int] OUTPUT,
	@max_distretention [int] OUTPUT,
	@history_retention [int] OUTPUT,
	@history_cleanupagent [nvarchar](100) OUTPUT,
	@distrib_cleanupagent [nvarchar](100) OUTPUT,
	@publisher [sysname],
	@local [nvarchar](5),
	@rpcsrvname [sysname] OUTPUT,
	@publisher_type [sysname] OUTPUT,
	@deletebatchsize_xact [int] OUTPUT,
	@deletebatchsize_cmd [int] OUTPUT,
	@dist_listener [sysname] OUTPUT
WITH EXECUTE AS CALLER
AS
BEGIN

	SET NOCOUNT ON

	/*
	** Declarations.
	*/
	DECLARE @loc_distributor         sysname
	DECLARE @loc_distribdb             sysname
	DECLARE @loc_directory             nvarchar(255)
	DECLARE @loc_account             nvarchar(255)
	DECLARE @loc_mindistretention     int
	DECLARE @loc_maxdistretention     int
	DECLARE @loc_historyretention   int  
	DECLARE @loc_deletebatchsize_xact int
	DECLARE @loc_deletebatchsize_cmd int
	DECLARE @loc_historycleanupagent nvarchar(100)
	DECLARE @loc_distribcleanupagent nvarchar(100)
	DECLARE @loc_security_mode  int  
	DECLARE @loc_login sysname
	DECLARE @loc_password sysname
	declare @loc_rpcsrvname sysname
	DECLARE @loc_publishertype sysname
	DECLARE @proc nvarchar(255)
	DECLARE @retcode int
	declare @rpcsrvlogin sysname
	declare @srvid smallint
	declare @dist_rpcname sysname
	declare @platform_nt binary
	declare @has_dbowner_access bit
	declare @has_PAL_access bit
	declare @login sysname
	declare @SQLStmt nvarchar(4000)
	declare @isDynamicBatchSizeSupported bit = 0
	declare @isDistDBInAGSupported bit = 0
	declare @loc_dist_listener sysname = NULL
	
	select @has_dbowner_access = 1
	select @has_PAL_access = 1
	select @platform_nt = 0x1
	select @login = suser_sname(suser_sid())

	--
	-- processing for publisher
	--
	IF @publisher IS NULL
	BEGIN
		/* 
		** 6.x compatibility 
		** If local is set, we know the call is from a publisher. 
		** set it to be @@REMSERVER 
		** Otherwise, set it to be local server name
		** Note: @@REMSERVER is NULL for local sp calls 
		*/
		IF LOWER(@local) = 'local' AND @@REMSERVER IS NOT NULL
			SELECT @publisher = @@REMSERVER
		ELSE
			SELECT @publisher = publishingservername()
	END
	ELSE
		exec sys.sp_MSget_server_portinfo 
			@name = @publisher, 
			@srvname = @publisher OUTPUT

	--
	-- Set attribute indicating whether user is 'db_owner'.  
	--
	if LOWER(@local) <> 'local' or @local is NULL
	begin
			-- Determine whether user has dbowner access
			if not ((is_srvrolemember('sysadmin') = 1) or
						(is_member('db_owner') = 1 and
						sys.fn_MSrepl_ispublished(db_name()) = 1)
			)
			begin
				select @has_dbowner_access = 0

				-- Setting @loc_account to '%' prevents reading the registry for the
				-- account information at a remote distributor if user isn't authorized.
				select @loc_account = '%'
			end
	end	

	/*
	** Get the distribution server
	*/
	SELECT	@dist_rpcname = srvname,
			@loc_distributor = datasource,
			@srvid = srvid,
			@loc_rpcsrvname = srvname
	FROM	master.dbo.sysservers
	WHERE	srvstatus & 8 <> 0

	if @loc_distributor is null
		GOTO DONE

	select @rpcsrvlogin = null
	-- sysoledbusers is for outgoing rpc servers only so it should be 
	-- appropriate for querying the remote login of the distributor link. But 
	-- as a safety measure, we will query sysremotelogins (for incoming RPC 
	-- calls) if no remote login is returned from sysoledbusers to maintain 
	-- full compatibility with the sysxlogins query that we used before. 
	select	@rpcsrvlogin = rmtloginame
	from	master.dbo.sysoledbusers
	where	rmtsrvid = @srvid and loginsid is NULL 

	if @rpcsrvlogin is null
	begin
		select	@rpcsrvlogin = remoteusername 
		from	master.dbo.sysremotelogins 
		where	remoteserverid = @srvid and sid is NULL 
	end

	/*
	** If remote distribuiton, execute sys.sp_helpdistributor on distribution
	** server.
	*/
	IF UPPER(@loc_distributor) <> UPPER(@@SERVERNAME)
	BEGIN

		SELECT @proc = @dist_rpcname + '.master.sys.sp_executesql'
		SELECT @SQLStmt = N'if exists (Select * from sys.all_parameters where object_id = OBJECT_ID(''sp_helpdistributor'') and [name] = ''@deletebatchsize_cmd'')
				SELECT @isDynamicBatchSizeSupported = 1
			else
				SELECT @isDynamicBatchSizeSupported = 0'
		EXECUTE @retcode = @proc 
			@stmt = @SQLStmt, 
			@params = N'@isDynamicBatchSizeSupported bit OUTPUT', 
			@isDynamicBatchSizeSupported = @isDynamicBatchSizeSupported OUTPUT

		IF @retcode <> 0 or @@ERROR <> 0
			RETURN (1)

		SELECT @proc = @dist_rpcname + '.master.sys.sp_executesql'
		SELECT @SQLStmt = N'if exists (Select * from sys.all_parameters where object_id = OBJECT_ID(''sp_helpdistributor'') and [name] = ''@dist_listener'')
				SELECT @isDistDBInAGSupported = 1
			else
				SELECT @isDistDBInAGSupported = 0'
		EXECUTE @retcode = @proc 
			@stmt = @SQLStmt, 
			@params = N'@isDistDBInAGSupported bit OUTPUT', 
			@isDistDBInAGSupported = @isDistDBInAGSupported OUTPUT

		IF @retcode <> 0 or @@ERROR <> 0
			RETURN (1)

		SELECT @proc = @dist_rpcname + '.master.sys.sp_helpdistributor'
		--
		-- from publisher
		--
		if (@isDynamicBatchSizeSupported = 0 and @isDistDBInAGSupported = 0)
		BEGIN
			EXECUTE @retcode = @proc
				@loc_distributor OUTPUT,
				@loc_distribdb OUTPUT,
				@loc_directory OUTPUT,
				@loc_account OUTPUT,
				@loc_mindistretention OUTPUT,
				@loc_maxdistretention OUTPUT,
				@loc_historyretention OUTPUT,
				@loc_historycleanupagent OUTPUT,
				@loc_distribcleanupagent OUTPUT,
				@@SERVERNAME,
				@local = 'local',
				@publisher_type = @loc_publishertype OUTPUT
		END
		ELSE if (@isDynamicBatchSizeSupported = 1 and @isDistDBInAGSupported = 0)
		BEGIN
			EXECUTE @retcode = @proc
				@loc_distributor OUTPUT,
				@loc_distribdb OUTPUT,
				@loc_directory OUTPUT,
				@loc_account OUTPUT,
				@loc_mindistretention OUTPUT,
				@loc_maxdistretention OUTPUT,
				@loc_historyretention OUTPUT,
				@loc_historycleanupagent OUTPUT,
				@loc_distribcleanupagent OUTPUT,
				@@SERVERNAME,
				@local = 'local',
				@publisher_type = @loc_publishertype OUTPUT,
				@deletebatchsize_xact = @loc_deletebatchsize_xact OUTPUT,
				@deletebatchsize_cmd = @loc_deletebatchsize_cmd OUTPUT
		END
		ELSE if (@isDynamicBatchSizeSupported = 0 and @isDistDBInAGSupported = 1)
		BEGIN
			EXECUTE @retcode = @proc
				@loc_distributor OUTPUT,
				@loc_distribdb OUTPUT,
				@loc_directory OUTPUT,
				@loc_account OUTPUT,
				@loc_mindistretention OUTPUT,
				@loc_maxdistretention OUTPUT,
				@loc_historyretention OUTPUT,
				@loc_historycleanupagent OUTPUT,
				@loc_distribcleanupagent OUTPUT,
				@@SERVERNAME,
				@local = 'local',
				@publisher_type = @loc_publishertype OUTPUT,
				@dist_listener = @loc_dist_listener OUTPUT
		END
		ELSE
		BEGIN
			EXECUTE @retcode = @proc
				@loc_distributor OUTPUT,
				@loc_distribdb OUTPUT,
				@loc_directory OUTPUT,
				@loc_account OUTPUT,
				@loc_mindistretention OUTPUT,
				@loc_maxdistretention OUTPUT,
				@loc_historyretention OUTPUT,
				@loc_historycleanupagent OUTPUT,
				@loc_distribcleanupagent OUTPUT,
				@@SERVERNAME,
				@local = 'local',
				@publisher_type = @loc_publishertype OUTPUT,
				@deletebatchsize_xact = @loc_deletebatchsize_xact OUTPUT,
				@deletebatchsize_cmd = @loc_deletebatchsize_cmd OUTPUT,
				@dist_listener = @loc_dist_listener OUTPUT
		END
		IF @retcode <> 0 or @@ERROR <> 0
			RETURN (1)

		GOTO DONE
	END
	--
	-- validate the calling publisher
	--
	SELECT 	@loc_distribdb = distribution_db,
			@loc_directory = working_directory,
			@loc_publishertype = publisher_type
	FROM	msdb.dbo.MSdistpublishers
	WHERE	UPPER(name collate database_default ) = UPPER(@publisher) collate database_default 
	IF @@ERROR <> 0
		RETURN 1 

	-- 
	-- If distribution db is NULL, there is no matching distributor.
	-- This typically would happen when calling on a distributor that
	-- only has HREPL publishers.  This case should result in no output
	--
	IF (@loc_distribdb IS NULL)
	BEGIN
		RETURN (0)
	END
	
	-- Security.  Connection to remote distributor must have 'sysadmin' or 'db_owner' 
	-- in distribution database authorization. This prevents user from bypassing
	-- security checks by explicitly setting 'local' parameter in the call.  
	if LOWER(@local) = 'local'
	begin
		exec @retcode = sys.sp_MSrepl_isdbowner @loc_distribdb
		if @retcode <> 1 or @@error <> 0
			RETURN (1)
	end

	-- Check AG DMV when its not Managed Instance
	If serverproperty('EngineEdition') <> 8 
	BEGIN
	-- Fetch the listener name if the distribution db is part of AG.
		SELECT TOP 1 @loc_dist_listener = dns_name FROM sys.availability_group_listeners AGL
		INNER JOIN sys.dm_hadr_database_replica_states DBRepl ON AGL.group_id = DBRepl.group_id
		WHERE DBRepl.database_id = DB_ID(@loc_distribdb)
	END
	SELECT  @loc_mindistretention = min_distretention,      
	        @loc_maxdistretention = max_distretention,
	        @loc_historyretention = history_retention,
			@loc_deletebatchsize_xact = deletebatchsize_xact,
			@loc_deletebatchsize_cmd = deletebatchsize_cmd
	FROM	msdb.dbo.MSdistributiondbs
	WHERE	name = @loc_distribdb collate database_default 

	/*
	** Fetch the distribution account name.
	*/
	IF ((@distributor = '%' AND @distribdb = '%' AND @directory = '%'
		AND @account = '%' AND @min_distretention = -1 AND @max_distretention = -1 
		AND @deletebatchsize_xact = -1 AND @deletebatchsize_cmd = -1
		AND @history_retention = -1 AND @history_cleanupagent = '%' 
		AND @distrib_cleanupagent = '%' AND @publisher_type = '%' AND @rpcsrvname = '%' ) 
		OR @account IS NULL) and ( platform() & @platform_nt = @platform_nt ) and ( @has_dbowner_access = 1 )
	BEGIN
		declare @instance sysname
		declare @regkey nvarchar(260)
		-- not changing for instapi work. hardcoding this path
		select @instance = convert(sysname, SERVERPROPERTY('InstanceName'))
		select @regkey = 'SYSTEM\CurrentControlSet\Services\'
		-- default installation
		if @instance is null
			SELECT @regkey = @regkey + 'SQLServerAgent' 
		else
			SELECT @regkey = @regkey + 'SQLAgent$' + @instance

		SELECT @proc = 'master.dbo.xp_regread'
		EXECUTE @retcode = @proc 'HKEY_LOCAL_MACHINE',
			  @regkey,
			  'ObjectName',
			@param = @loc_account OUTPUT
		IF @@ERROR <> 0 OR @retcode <> 0
			SELECT @loc_account = NULL
	END

	/*
	** Fetch the history cleanup agentname.
	*/
	IF @loc_distribdb IS NOT NULL
		SELECT @loc_historycleanupagent = formatmessage (20567, @loc_distribdb)

	/*
	** Fetch the distribution cleanup agent name.
	*/
	IF @loc_distribdb IS NOT NULL
		SELECT @loc_distribcleanupagent = formatmessage (20568, @loc_distribdb)


	DONE:

	/*
	** If user does not have 'db_owner' authorization, NULL restricted return parameters.  
	*/
	if @has_dbowner_access = 0
	begin
		select @loc_account = NULL
		select @loc_mindistretention = NULL
		select @loc_historyretention = NULL
		select @loc_historycleanupagent = NULL
		select @loc_distribcleanupagent = NULL
		select @rpcsrvlogin = NULL
		select @loc_deletebatchsize_xact = NULL
		select @loc_deletebatchsize_cmd = NULL
		select @loc_dist_listener = NULL
	end

	/*
	** If @directory is to be returned and user does not have 'db_owner' access, check for PAL access.  
	*/
	IF ((@distributor = '%' AND @distribdb = '%' AND @directory = '%'
		AND @account = '%' AND @min_distretention = -1 AND @max_distretention = -1 
		AND @deletebatchsize_xact = -1 AND @deletebatchsize_cmd = -1
		AND @history_retention = -1 AND @history_cleanupagent = '%' 
		AND @distrib_cleanupagent = '%' AND @rpcsrvname = '%' and @publisher_type = '%')
		OR ( @directory is NULL ))
		AND ( LOWER(@local) <> 'local' or @local is NULL )
		AND ( @has_dbowner_access = 0 )
		AND (@loc_rpcsrvname is not null and @loc_distribdb is not null)
	begin
		-- Check to determine whether the current user is in the PAL
		-- of any publication that makes use of this publisher.
			   create table #pub (publisher_db sysname, publication sysname)

       		SELECT @proc = RTRIM(ISNULL(@loc_dist_listener,@loc_rpcsrvname)) + '.' + RTRIM(@loc_distribdb) + '.sys.sp_MSpublication_access'
       		INSERT into #pub (publisher_db, publication)
       		EXEC @retcode =	@proc
			 @publisher	= @publisher,
			 @operation	= N'get_publications',
			 @login		= @login
   
			   if not exists (select * from #pub)
					   select @loc_directory = NULL
	 end

	/*
	** Return result set if no output parameters
	*/

	IF (@distributor = '%' AND @distribdb = '%' AND @directory = '%'
			AND @account = '%' AND @min_distretention = -1 AND @max_distretention = -1 
			AND @deletebatchsize_xact = -1 AND @deletebatchsize_cmd = -1
			AND @history_retention = -1 AND @history_cleanupagent = '%' 
			AND @distrib_cleanupagent = '%' AND @rpcsrvname = '%' and @publisher_type = '%'
			AND @dist_listener = '%')
	SELECT	'distributor'				 = @loc_distributor,
			'distribution database'		 = @loc_distribdb,
			'directory'				 = @loc_directory,
			'account'					 = @loc_account,
			'min distrib retention'		 = @loc_mindistretention,
			'max distrib retention'		 = @loc_maxdistretention,
			'history retention'			 = @loc_historyretention,
			'history cleanup agent'		 = @loc_historycleanupagent,
			'distribution cleanup agent' = @loc_distribcleanupagent,
			'rpc server name' = @loc_rpcsrvname,
			'rpc login name' = @rpcsrvlogin,
			'publisher type' = @loc_publishertype,
			'delete batch size xact' = @loc_deletebatchsize_xact,
			'delete batch size cmd' = @loc_deletebatchsize_cmd,
			'distribution_listener' = @loc_dist_listener

	/*
	** Return output parameters if requested.
	*/

	IF @distributor IS NULL
	    SELECT @distributor = @loc_distributor
	IF @distribdb IS NULL
	    SELECT @distribdb = @loc_distribdb
	IF @directory IS NULL
	    SELECT @directory = @loc_directory
	IF @account IS NULL
	    SELECT @account = @loc_account
	IF @min_distretention IS NULL
	    SELECT @min_distretention = @loc_mindistretention
	IF @max_distretention IS NULL
	    SELECT @max_distretention = @loc_maxdistretention
	IF @deletebatchsize_xact IS NULL
		SELECT @deletebatchsize_xact = @loc_deletebatchsize_xact
	IF @deletebatchsize_cmd IS NULL
		SELECT @deletebatchsize_cmd = @loc_deletebatchsize_cmd
	IF @history_retention IS NULL
	    SELECT @history_retention = @loc_historyretention
	IF @history_cleanupagent IS NULL
	    SELECT @history_cleanupagent = @loc_historycleanupagent
	IF @distrib_cleanupagent IS NULL
	    SELECT @distrib_cleanupagent = @loc_distribcleanupagent
	IF @publisher_type IS NULL
		SELECT @publisher_type = @loc_publishertype
	IF @dist_listener IS NULL
		SELECT @dist_listener = @loc_dist_listener

	IF @rpcsrvname IS NULL
	BEGIN
		--
		-- BUGBUG : The value for @rpcsrvname must match the value returned by 
		--			sp_MSrepl_getdistributorinfo or we will see indefinite blocking  
		--			in some areas of our code. Example-incremental add article. So 
		-- 			if you make a change here make it in sp_MSrepl_getdistributorinfo
		--
		-- For the following cases use LOCAL SERVER NAME
		-- 	1. Hetero will always use local server
		-- 	2. Local distributor with sysadmin access (used to avoid blocking issues)
		IF @loc_publishertype != N'MSSQLSERVER' 
			OR (IS_SRVROLEMEMBER('sysadmin') = 1 
				AND UPPER(@loc_distributor) = UPPER(@@SERVERNAME))
		BEGIN
			SELECT @rpcsrvname = srvname
				FROM master.dbo.sysservers
				WHERE UPPER(srvname collate database_default ) = UPPER(@loc_distributor)
		END
		-- Remote distributor or local with non-sysadmin rights
		ELSE
		BEGIN
			SELECT @rpcsrvname = @loc_rpcsrvname
		END
	END

	RETURN (0)
END
GO
GRANT EXECUTE ON [sys].[sp_helpdistributor] TO [public] AS [dbo]
GO
