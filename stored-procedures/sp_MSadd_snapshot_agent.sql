SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSadd_snapshot_agent]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSadd_snapshot_agent] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSadd_snapshot_agent]
	@name [nvarchar](100),
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@publication_type [int],
	@local_job [bit],
	@freqtype [int],
	@freqinterval [int],
	@freqsubtype [int],
	@freqsubinterval [int],
	@freqrelativeinterval [int],
	@freqrecurrencefactor [int],
	@activestartdate [int],
	@activeenddate [int],
	@activestarttimeofday [int],
	@activeendtimeofday [int],
	@command [nvarchar](4000),
	@job_existing [bit],
	@snapshot_jobid [binary](16) OUTPUT,
	@publisher_security_mode [smallint],
	@publisher_login [sysname],
	@publisher_password [nvarchar](524),
	@job_login [nvarchar](257),
	@job_password [sysname],
	@publisher_type [sysname],
	@internal [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
	SET NOCOUNT ON

	/*
	** Declarations.
	*/
	DECLARE @retcode					int
	DECLARE @publisher_id				smallint
	DECLARE @loc_publisher_db			sysname
	DECLARE @profile_id					int
	DECLARE @snapshot_type				int
	DECLARE @databasename				sysname
	DECLARE @agent_id					int
	DECLARE @category_name				sysname
	DECLARE @platform_nt				binary
	DECLARE @srvproduct					nvarchar(128)
	DECLARE @datasource					nvarchar(4000)
	DECLARE @snapshot_job_step_uid		uniqueidentifier
	 
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
		raiserror(21482, 16, -1, 'sp_MSadd_snapshot_agent', 'distribution')
		return (1)
	end
	
	/*
	** Initializations
	*/
	select @platform_nt = 0x1

    select	@publisher_id = srvid
			--,@srvproduct = srvproduct, -- We dont use these 2 variables, so commenting them out
			--@datasource = datasource
	from	MSreplservers
	where	UPPER(srvname) = UPPER(@publisher)

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

	-- Always use integrated security for local connections
	select @command = @command + ' -DistributorSecurityMode 1 '
	
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
		-- in the hetero case, if user specified integrated security 
		-- for the publisher security at sp_adddistpublisher time then
		-- the provided snapshot agent job_login must be the same...
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

	-- ONLY ALLOW THIS IN 8.0 or less CASE
	IF @internal = N'PRE-YUKON'
	BEGIN
		-- if @name is not null and @job_existing = 1, the proc is from DMO scripting
		-- check to see if the job is there or not, if not, reset @job_existing
		-- value. This is for the case when the user generate the script at
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
	
	BEGIN TRAN
	SAVE TRAN tran_addsnapagent
	
	/* Code for snapshot agent type in MSagent_profiles */
	SELECT @snapshot_type = 1

	-- Get the default profile ID for the snapshot agent type. If a third party publication
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
			agent_type = @snapshot_type and
			def_profile = 1
	end

	-- if the publisher sec info was not provided then default
	-- the vals to the values provided durring sp_adddistpublisher...
	-- this is only possible when called by SYSADMIN or 8.0 pub.
	IF @publisher_security_mode is NULL
	BEGIN
		SELECT @publisher_security_mode = security_mode, 
				@publisher_login = login,
				@publisher_password = password
			FROM msdb.dbo.MSdistpublishers 
			WHERE UPPER(name) = UPPER(@publisher) 
				AND distribution_db = db_name()
				AND publisher_type =  @publisher_type 
	END
	ELSE
	BEGIN
		-- if WINDOWS authentication then clear out the login/password
		IF @publisher_security_mode = 1
		BEGIN
			SELECT @publisher_login = '',
					@publisher_password = newid()
		END

		-- Encrypt the password before storing
		EXEC @retcode = sys.sp_MSreplencrypt @publisher_password OUTPUT
		IF @@ERROR <> 0 OR  @retcode <> 0
			GOTO UNDO
	END
	
	if not exists (select * from MSsnapshot_agents where
		publisher_id = @publisher_id and
		publisher_db = @publisher_db and
		publication = @publication and
		dynamic_filter_login is NULL and
		dynamic_filter_hostname is NULL)
	begin		
		/* 
		** Insert row
		*/
		INSERT INTO MSsnapshot_agents (name, publisher_id, publisher_db, publication, publication_type,
								local_job, profile_id,
								publisher_security_mode, publisher_login, publisher_password,
								job_login, job_password)
			 VALUES ('',@publisher_id, @publisher_db, @publication, @publication_type, 
			 		@local_job, @profile_id,
			 		@publisher_security_mode, @publisher_login, @publisher_password,
			 		@cl_login, @cl_password)
		IF @@ERROR <> 0
			GOTO UNDO

		set @agent_id = @@IDENTITY
	end
	else
	begin
		-- also retrieve the currently set	
		select @agent_id = id from MSsnapshot_agents where
			publisher_id = @publisher_id and
			publisher_db = @publisher_db and
			publication = @publication and
			dynamic_filter_login is NULL and
			dynamic_filter_hostname is NULL
		
	end
	
	DECLARE @name_is_generated bit
	SELECT @name_is_generated = 0     
	IF @name IS NULL OR @name = N''
	BEGIN
		SELECT	@name_is_generated = 1
		SELECT	@name = CONVERT(nvarchar(28),@publisher)   + '-' + CONVERT(nvarchar(28),@loc_publisher_db) + '-' + 
						CONVERT(nvarchar(28),@publication) + '-' + CONVERT(nvarchar, @agent_id)
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
			SELECT @name = fn_repluniquename(newid(), @publisher, @loc_publisher_db, @publication, null)
		END            
	END

	-- Add Perfmon instance
	dbcc addinstance ("SQL Replication Snapshot", @name)

	IF @local_job = 1 and @job_existing = 0
	BEGIN

		DECLARE @nullchar nchar(20)
		SELECT @nullchar = NULL

		set @databasename = db_name()
		-- Get Snapshot category name (assumes category_id = 15)
		select @category_name = name FROM msdb.dbo.syscategories where category_id = 15

		EXECUTE @retcode = dbo.sp_MSadd_repl_job 
			@name = @name, 
			@subsystem = 'Snapshot', 
			@server = @publisher, 
			@databasename = @databasename, 
			@enabled = 1, 
			@freqtype = @freqtype, 
			@freqinterval = @freqinterval, 
			@freqsubtype = @freqsubtype, 
			@freqsubinterval = @freqsubinterval, 
			@freqrelativeinterval = @freqrelativeinterval, 
			@freqrecurrencefactor = @freqrecurrencefactor, 
			@activestartdate = @activestartdate, 
			@activeenddate = @activeenddate, 
			@activestarttimeofday = @activestarttimeofday, 
			@activeendtimeofday = @activeendtimeofday, 
			@nextrundate = 0,
			@nextruntime = 0,
			@runpriority = 0,
			@emailoperatorname = @nullchar,
			@retryattempts = 10, 
			@retrydelay = 1, 
			@command = @command, 
			@loghistcompletionlevel = 0, 
			@emailcompletionlevel = 0, 
			@description = @nullchar,
			@tagadditionalinfo = @nullchar,
			@tagobjectid = 0, 
			@tagobjecttype = 0, 
			@category_name = @category_name,
			@failure_detection = 1,
			@agent_id = @agent_id,
			@job_login = @job_login,
			@job_password = @job_password,
			@job_id = @snapshot_jobid OUTPUT,
			@job_step_uid = @snapshot_job_step_uid OUTPUT
  
	   IF @@ERROR <> 0 or @retcode <> 0
			GOTO UNDO
	END

	if @local_job = 1 and @job_existing = 1 
	begin
		if @snapshot_jobid is null
		begin
			select @snapshot_jobid = sjv.job_id
			from msdb.dbo.sysjobs_view as sjv
				join msdb.dbo.sysjobsteps as sjs
					on sjv.job_id = sjs.job_id
			where sjv.name = @name
				and sjv.master_server = 0
				and UPPER(sjv.originating_server) = UPPER(CONVERT(sysname, SERVERPROPERTY('ServerName')))
				and sjv.category_id = 15
				and sjs.subsystem = N'Snapshot'
				and sjs.database_name = db_name()
			
			if @snapshot_jobid IS NULL
			begin
				-- Message from msdb.dbo.sp_verify_job_identifiers
				RAISERROR(14262, -1, -1, 'Snapshot Job', @name)          
				GOTO UNDO
			end
		end
		else
		begin
			if not exists (select * from msdb.dbo.sysjobs_view 
				where job_id = @snapshot_jobid 
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
	if @snapshot_jobid is NOT NULL
		and @snapshot_job_step_uid is NULL
	begin
		select @snapshot_job_step_uid = sjs.step_uid
			from msdb.dbo.sysjobs_view as sjv
				join msdb.dbo.sysjobsteps as sjs
					on sjv.job_id = sjs.job_id
			where sjv.job_id = @snapshot_jobid
				and sjv.master_server = 0
				and UPPER(sjv.originating_server) = UPPER(CONVERT(sysname, SERVERPROPERTY('ServerName')))
				and sjv.category_id = 15
				and sjs.subsystem = N'Snapshot'
				and sjs.database_name = db_name()
	end
	
/* Moved up
	-- Get the job id if it already exists
	if @local_job = 1 and @job_existing = 1 
	begin
		select @snapshot_jobid = job_id from msdb.dbo.sysjobs_view 
		where job_id = @snapshot_jobid 
		and UPPER(originating_server) = UPPER(CONVERT(sysname, SERVERPROPERTY('ServerName')))
		and master_server = 0
		if @snapshot_jobid IS NULL
		begin
			-- Message from msdb.dbo.sp_verify_job_identifiers
			RAISERROR(14262, -1, -1, 'Job', @name)          
			GOTO UNDO
		end
	end
*/

	-- Generate a job GUID for remote agents. This will be used by the UI to uniquely
	-- identify rows returned by the enums
	if @local_job = 0
	begin
		-- Third party publication will pass in snapshot agent name which is created as
		-- a SQLServerAgent job.
		if @name is not null 
			select @snapshot_jobid = job_id from msdb.dbo.sysjobs_view where
				name = @name
		if @snapshot_jobid is null
			set @snapshot_jobid = newid()
		-- Reset @local_job to 1 so that repl monitor can start the job.
		-- In sp_MSdrop_snapshot_agent, we will not drop the job if the publication 
		-- is from third party.
		else
			set @local_job = 1
	end

	-- Caution: @local job might be changed from the passed in value.
	UPDATE MSsnapshot_agents 
		SET name = @name,
			job_id = @snapshot_jobid,
			-- Update the following fields because the row maybe added before this sp call
			-- by sp_MSadd_publication.
			publication_type = @publication_type,
			local_job = @local_job, 
			profile_id = @profile_id,
			job_step_uid = @snapshot_job_step_uid,
			publisher_security_mode = @publisher_security_mode, 
			publisher_login = @publisher_login, 
			publisher_password = @publisher_password,
			job_login = @cl_login,
			job_password = @cl_password
		WHERE id = @agent_id

	IF @@ERROR <> 0
		GOTO UNDO

	COMMIT TRAN tran_addsnapagent

	RETURN(0)

UNDO:
	ROLLBACK TRAN tran_addsnapagent
	COMMIT TRAN
	
	return(1)
END
GO
GRANT EXECUTE ON [sys].[sp_MSadd_snapshot_agent] TO [public] AS [dbo]
GO
