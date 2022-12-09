SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSadd_logreader_agent]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSadd_logreader_agent] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSadd_logreader_agent]
	@name [nvarchar](100),
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@local_job [bit],
	@job_existing [bit],
	@job_id [binary](16),
	@publisher_security_mode [smallint],
	@publisher_login [sysname],
	@publisher_password [nvarchar](524),
	@job_login [nvarchar](257),
	@job_password [sysname],
	@publisher_type [sysname],
	@internal [sysname],
	@publisher_engine_edition [int]
WITH EXECUTE AS CALLER
AS
BEGIN
	SET NOCOUNT ON

    /*
    ** Declarations.
    */
    DECLARE @retcode            int
                ,@agent_args         nvarchar(255)
                ,@publisher_id       smallint
                ,@loc_publisher_db	sysname
                ,@profile_id         int
                ,@logreader_type     int
                ,@databasename       sysname
                ,@agent_id           int
                ,@category_name      sysname
                ,@platform_nt binary
                ,@srvproduct nvarchar(128)
                ,@datasource nvarchar(4000)	
                ,@job_step_uid		uniqueidentifier
				,@listener			sysname = NULL
				,@distribution_db	sysname

	-- Security Check: require sysadmin
	IF (ISNULL(IS_SRVROLEMEMBER('sysadmin'),0) = 0)
	BEGIN
		RAISERROR(21089,16,-1) 
		RETURN 1
	END
	--
	-- security check
	-- Has to be executed from distribution database
	--
	if (sys.fn_MSrepl_isdistdb (db_name()) != 1)
	begin
		raiserror(21482, 16, -1, 'sp_MSadd_logreader_agent', 'distribution')
		return (1)
	end
	
	/*
	** Initializations
	*/
	select @platform_nt = 0x1,
			@job_step_uid = NULL

    select @publisher_id = srvid --, @srvproduct = srvproduct, @datasource = datasource  -- We dont use these 2 variables, so commenting them out
	from MSreplservers where
        UPPER(srvname) = UPPER(@publisher)

	-- ONLY ALLOW THIS IN 8.0 or less CASE
	IF @internal = N'PRE-YUKON'
	BEGIN
		-- if @name is not null and @job_existing = 1, the proc is from DMO scripting
		-- check to see if the job is there are not, if not, reset @job_existing and
		-- @name values. This is for the case when the user generate the script at
		-- the publisher but did not re-create repl jobs at the distributor.
		if @local_job = 1 and @job_existing = 1 and @name is not null and 
		   @name <> N''
		begin
			if not exists (select * from msdb.dbo.sysjobs_view  
				where name = @name 
				and UPPER(originating_server) = UPPER(CONVERT(sysname, SERVERPROPERTY('ServerName')))
				and master_server = 0)
			begin
				set @job_existing = 0
				set @name = null
			end
		end
	END
	
   	-- For naming purposes, use @publisher instead of @publisher_db for HREPL
   	-- publishers that don't support publisher db notion
	IF @publisher_type LIKE N'ORACLE%'
	BEGIN
		SELECT @loc_publisher_db = @publisher
	END
	ELSE
	BEGIN
		SELECT @loc_publisher_db = @publisher_db
	END

	IF NOT @publisher_type = N'MSSQLSERVER'
	BEGIN
		-- in the heter case, if user specified integrated security 
		-- for the publisher security at sp_adddistpublisher time then
		-- the provided logreader agent job_login must be the same...
		IF EXISTS(SELECT * 
						FROM msdb..MSdistpublishers
						WHERE distribution_db = DB_NAME()
							AND name = @publisher
							AND login != @job_login
							AND security_mode = 1
							AND publisher_type = @publisher_type)
		BEGIN
			-- The job_login provided must match the publisher login specified when adding the distribution publisher (sp_adddistpublisher).
			RAISERROR(22537, 16, -1)
			RETURN 1
		END
	END
	
	BEGIN TRAN

	-- If creating locally, try to drop it first
	IF @local_job = 1 and @job_existing = 0
	begin
		EXEC sys.sp_MSdrop_logreader_agent 
			@publisher = @publisher,
			@publisher_db = @publisher_db,
			@publication = @publication  
		IF @@ERROR <> 0
			GOTO UNDO
	end

	/* Code for log reader agent type in MSagent_profiles */
	SELECT @logreader_type = 2

	-- Get the default profile ID for the logreader agent type. If a third party publication
	-- no profile is used.
	if exists (select * from dbo.MSpublications where 
				publisher_id = @publisher_id and
				publisher_db = @publisher_db and
				publication = @publication and
				thirdparty_flag = 1)
	begin
		set @profile_id = 0
	end
	else
	begin
		SELECT @profile_id = profile_id FROM msdb..MSagent_profiles WHERE 
			agent_type = @logreader_type and
			def_profile = 1
	end

	-- if the publisher sec info was not provided then default
	-- the vals to the values provided durring sp_adddistpublisher...
	-- this is only possible when called by SYSADMIN or 8.0 pub.
	IF @publisher_security_mode is NULL
	BEGIN
		select @publisher_security_mode = security_mode, 
				@publisher_login = login,
				@publisher_password = password
			from msdb.dbo.MSdistpublishers 
			where UPPER(name) = UPPER(@publisher) 
				and distribution_db = db_name()
				and publisher_type = @publisher_type
	END
	ELSE
	BEGIN
		-- if WINDOWS authentication then clear out the login/password
		IF @publisher_security_mode = 1
		BEGIN
			select @publisher_login = '',
					@publisher_password = newid()
		END

		-- Encrypt the password before storing
		EXEC @retcode = sys.sp_MSreplencrypt @publisher_password OUTPUT
		IF @@ERROR <> 0 OR  @retcode <> 0
			GOTO UNDO
	END

	-- If publisher_id, publisher_db pair is not in MSpublisher_databases then add it.  This will be used
	-- to store a publisher_database_id in the MSrepl_transactions and MSrepl_commands table.
	IF NOT EXISTS (select * 
						from MSpublisher_databases 
						where publisher_id = @publisher_id 
							and publisher_db = @publisher_db)
	BEGIN
		INSERT INTO MSpublisher_databases (publisher_id, publisher_db, publisher_engine_edition) 
				VALUES (@publisher_id, @publisher_db, @publisher_engine_edition)
		IF @@ERROR <> 0
			GOTO UNDO
			
		INSERT INTO MSrepl_backup_lsns (publisher_database_id) VALUES (@@identity)
		IF @@ERROR <> 0
			GOTO UNDO
	END
	
	-- Cloud Lifter edition (CL) uses values provided through @job_login and @job_password
	-- for SQL authentication (Windows authentication and proxies are not supported in CL)
	DECLARE @cl_login nvarchar(257), @cl_password nvarchar(524)
	IF sys.fn_MSrepl_editionid() = 32 AND @job_login IS NOT NULL AND @job_password IS NOT NULL
	BEGIN
		-- @job_login and @job_password should be nullified to avoid use of them for proxy configuration
		SELECT @cl_login = @job_login, @cl_password = @job_password, @job_login = NULL, @job_password = NULL
		-- Encrypt the password before storing
		EXEC @retcode = sys.sp_MSreplencrypt @cl_password OUTPUT
		IF @@ERROR <> 0 OR @retcode <> 0
			GOTO UNDO
	END

	/* 
	** Insert row
	*/
	INSERT INTO MSlogreader_agents (name, publisher_id, publisher_db, publication, 
					local_job, profile_id, 
					publisher_security_mode, publisher_login, publisher_password, 
					job_login, job_password)
		 VALUES ('',@publisher_id, @publisher_db, @publication, 
					@local_job, @profile_id, 
					@publisher_security_mode, @publisher_login, @publisher_password, 
					@cl_login, @cl_password)
	IF @@ERROR <> 0
		GOTO UNDO

	set @agent_id = @@IDENTITY
		
	DECLARE @name_is_generated bit
	SELECT @name_is_generated = 0     
	IF @name IS NULL OR @name = N''
	BEGIN
		SELECT @name_is_generated = 1
				,@name = CONVERT(nvarchar(43),@publisher ) + '-' + CONVERT(nvarchar(43),@loc_publisher_db) + '-' + CONVERT(nvarchar, @@IDENTITY)
	END

	-- If the generated name already exists, re-generate the name with a 
	-- guid appended
	IF @name_is_generated = 1
	BEGIN
		IF EXISTS (SELECT * FROM msdb.dbo.sysjobs_view 
					WHERE name = @name 
					  AND UPPER(originating_server) = UPPER(CONVERT(sysname, SERVERPROPERTY('ServerName')))
					  and master_server = 0)
		BEGIN
			SELECT @name = fn_repluniquename(newid(), @publisher, @loc_publisher_db, null, null)
		END            
	END
	
	-- Add Perfmon instance
	dbcc addinstance ("SQL Replication Logreader", @name)

	IF @local_job = 1 and @job_existing = 0
	BEGIN            
		-- Get publisher port number
		declare @publisher_with_port sysname
		exec sys.sp_MSget_server_portinfo 
			@name = @publisher,
			@srvname_with_port = @publisher_with_port OUTPUT

		-- Get servername port number
		declare @srvname_with_port sysname
		exec sys.sp_MSget_server_portinfo 
			@name = @@SERVERNAME,
			@srvname_with_port = @srvname_with_port OUTPUT 

		SELECT @agent_args = '-Publisher ' + QUOTENAME(@publisher_with_port)


        IF @publisher_type = N'MSSQLSERVER'
        BEGIN
			SELECT @distribution_db = distribution_db FROM msdb.dbo.MSdistpublishers WHERE name = @publisher
			IF (EXISTS (SELECT * FROM sys.dm_hadr_database_replica_states WHERE database_id = DB_ID(@distribution_db))) and serverproperty('EngineEdition') <> 8 -- -- Check AG DMV when its not Managed Instance
			BEGIN
				SELECT TOP 1 @listener = dns_name FROM sys.availability_group_listeners AGL
					INNER JOIN sys.dm_hadr_database_replica_states DBRepl ON AGL.group_id = DBRepl.group_id
					WHERE DBRepl.database_id = DB_ID(@distribution_db)
				IF @listener IS NULL
				BEGIN
					RAISERROR(25033, 16, -1)
					GOTO UNDO
				END
			END
			SELECT @agent_args = @agent_args + ' -PublisherDB ' + QUOTENAME(@publisher_db)
        END


        SELECT @agent_args = @agent_args + ' -Distributor ' + QUOTENAME(ISNULL(@listener,@srvname_with_port))

		-- Always use integrated security for local connections
		select @agent_args = @agent_args + ' -DistributorSecurityMode 1 '
		
		DECLARE @nullchar nchar(20)
		SELECT @nullchar = NULL

		set @databasename = db_name()
		-- Get Logreader category name (assumes category_id = 13)
		select @category_name = name FROM msdb.dbo.syscategories where category_id = 13
		set @publisher = (@publisher_with_port)
		EXECUTE @retcode = dbo.sp_MSadd_repl_job
		@name = @name,
		@subsystem = 'LogReader',
		@server = @publisher,
		@databasename = @databasename,
		@enabled = 1,
		@freqtype = 64,       /* Auto-Start */
		@freqinterval                   = 1,
		@freqsubtype                    = 1,
		@freqsubinterval                = 1,
		@freqrelativeinterval= 1,
		@freqrecurrencefactor   = 1,
		@activestartdate                = 0,
		@activeenddate                  = 0,
		@activestarttimeofday   = 0,
		@activeendtimeofday     = 0,
		@nextrundate                    = 12355,
		@nextruntime                    = 13423,
		@runpriority                    = 0,
		@emailoperatorname              = @nullchar,
		@retryattempts = 10,            
		@retrydelay = 1,    
		@command = @agent_args,
		@loghistcompletionlevel = 0,
		@category_name = @category_name,
		@failure_detection = 1,
		@agent_id = @agent_id,
		@job_login = @job_login,
		@job_password = @job_password,
		@job_id = @job_id OUTPUT,
		@job_step_uid = @job_step_uid OUTPUT
  
	   IF @@ERROR <> 0 or @retcode <> 0
			GOTO UNDO
	END

	if @local_job = 1 and @job_existing = 1 
	begin
		if @job_id is null
		begin
			select @job_id = sjv.job_id
			from msdb.dbo.sysjobs_view as sjv
				join msdb.dbo.sysjobsteps as sjs
					on sjv.job_id = sjs.job_id
			where sjv.name = @name
				and sjv.master_server = 0
				and UPPER(sjv.originating_server) = UPPER(CONVERT(sysname, SERVERPROPERTY('ServerName')))
				and sjv.category_id = 13
				and sjs.subsystem = N'LogReader'
				and sjs.database_name = db_name()
			
			if @job_id IS NULL
			begin
				-- Message from msdb.dbo.sp_verify_job_identifiers
				RAISERROR(14262, -1, -1, 'Logreader Job', @name)          
				GOTO UNDO
			end
		end
		else
		begin
			if not exists (select * from msdb.dbo.sysjobs_view  
				where job_id = @job_id 
				and UPPER(originating_server) = UPPER(CONVERT(sysname, SERVERPROPERTY('ServerName')))
				and master_server = 0)
			begin
				-- Message from msdb.dbo.sp_verify_job_identifiers
				RAISERROR(14262, -1, -1, 'Job', @name)          
				GOTO UNDO
			end
		end
	end

	-- retrieve the job step uid
	if @job_id is NOT NULL
		and @job_step_uid is NULL
	begin
		select @job_step_uid = sjs.step_uid
			from msdb.dbo.sysjobs_view as sjv
				join msdb.dbo.sysjobsteps as sjs
					on sjv.job_id = sjs.job_id
			where sjv.job_id = @job_id
				and sjv.master_server = 0
				and UPPER(sjv.originating_server) = UPPER(CONVERT(sysname, SERVERPROPERTY('ServerName')))
				and sjv.category_id = 13
				and sjs.subsystem = N'LogReader'
				and sjs.database_name = db_name()
	end

	-- Generate a job GUID for remote agents. This will be used by the UI to uniquely
	-- identify rows returned by the enums
	if @local_job = 0
	begin
		-- Third party publication will pass in logreader agent name which is created as
		-- a SQLServerAgent job.
		if @name is not null 
			select @job_id = job_id from msdb.dbo.sysjobs_view where
				name = @name
		if @job_id is null
			set @job_id = newid()
		-- Reset @local_job to 1 so that repl monitor can start the job.
		-- In sp_MSdrop_logreader_agent, we will not drop the job if the publication 
		-- is from third party.
		else
			set @local_job = 1
	end

	UPDATE MSlogreader_agents 
	SET name = @name,
			job_id = @job_id,
			job_step_uid = @job_step_uid
	WHERE id = @agent_id
	IF @@ERROR <> 0
		GOTO UNDO
	
	COMMIT TRAN

	RETURN(0)

UNDO:
	if @@TRANCOUNT = 1
		ROLLBACK TRAN
	else
		COMMIT TRAN
	return(1)
END
GO
GRANT EXECUTE ON [sys].[sp_MSadd_logreader_agent] TO [public] AS [dbo]
GO
