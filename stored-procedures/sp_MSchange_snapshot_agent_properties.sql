SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSchange_snapshot_agent_properties]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSchange_snapshot_agent_properties] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSchange_snapshot_agent_properties]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@frequency_type [int],
	@frequency_interval [int],
	@frequency_subday [int],
	@frequency_subday_interval [int],
	@frequency_relative_interval [int],
	@frequency_recurrence_factor [int],
	@active_start_date [int],
	@active_end_date [int],
	@active_start_time_of_day [int],
	@active_end_time_of_day [int],
	@snapshot_job_name [nvarchar](100),
	@publisher_security_mode [int],
	@publisher_login [sysname],
	@publisher_password [nvarchar](524),
	@job_login [nvarchar](257),
	@job_password [sysname],
	@publisher_type [sysname]
WITH EXECUTE AS CALLER
AS
begin
	declare @retcode		bit,
			@publisher_id	int,
			@agent_id		int,
			@agent_exists	bit,
			@job_id			uniqueidentifier,
			@job_step_uid	uniqueidentifier,
			@pubsecmode 	int,
			@proxy_id       int

	-- security: Has to be executed by SA of dist db
	if is_srvrolemember('sysadmin') != 1
	begin
		-- You do not have the required permissions to complete the operation.
		raiserror (20604, 16, -1)
		return 1
	end

	select @proxy_id = NULL
	
	begin transaction tran_sp_MSchange_snapshot
	save transaction tran_sp_MSchange_snapshot

	-- Get publisher port number
	exec sys.sp_MSget_server_portinfo 
		@name = @publisher, 
		@srvname = @publisher OUTPUT

	-- retrieve the publisher id
	select @publisher_id = srvid 
		from MSreplservers 
		where upper(srvname) = upper(@publisher)
	if @publisher_id is null
	begin
		-- Publisher @publisher does not exist.
		raiserror(21618, 16, -1, @publisher)
		goto FAILED
	end

	if @publisher_security_mode is not NULL
		or @publisher_login is not NULL
		or @publisher_password is not NULL
	begin
		
		-- if WINDOWS authentication then clear out the login/password
		if @publisher_security_mode = 1
		begin
			select @publisher_login = '',
					@publisher_password = newid()
		end

		-- Encrypt the password before storing
		exec @retcode = sys.sp_MSreplencrypt @publisher_password OUTPUT
		if @@error <> 0 or  @retcode <> 0
			goto FAILED
		
		update MSsnapshot_agents
			set publisher_security_mode = isnull(@publisher_security_mode, publisher_security_mode),
				publisher_login = isnull(@publisher_login, publisher_login),
				publisher_password = isnull(@publisher_password, publisher_password)
			where publisher_id = @publisher_id
				and publisher_db = @publisher_db
				and publication = @publication
		if @@error <> 0
			goto FAILED
	end
	
	-- Cloud Lifter edition (CL) uses values provided through @job_login and @job_password
	-- for SQL authentication (Windows authentication and proxies are not supported in CL)
	if sys.fn_MSrepl_editionid() = 32 and (@job_login is not NULL or @job_password is not NULL)
	begin
		declare @cl_login nvarchar(257), @cl_password nvarchar(524)
		-- @job_login and @job_password should be nullified to avoid use of them for proxy configuration
		select @cl_login = @job_login, @cl_password = @job_password, @job_login = null, @job_password = null
		-- Encrypt the password before storing
		exec @retcode = sys.sp_MSreplencrypt @cl_password OUTPUT
		if @@error <> 0 or @retcode <> 0
			goto FAILED
		update MSsnapshot_agents
			set job_login = isnull(@cl_login, job_login),
				job_password = isnull(@cl_password, job_password)
			where publisher_id = @publisher_id
				and publisher_db = @publisher_db
				and publication = @publication
		if @@error <> 0
			goto FAILED
	end

	if @job_login is not NULL
		or @job_password is not NULL
		or @snapshot_job_name is not NULL
		or @frequency_type is not NULL
		or @frequency_interval is not NULL
		or @frequency_subday is not NULL
		or @frequency_subday_interval is not NULL
		or @frequency_relative_interval is not NULL
		or @frequency_recurrence_factor is not NULL
		or @active_start_date is not NULL
		or @active_end_date is not NULL
		or @active_start_time_of_day is not NULL
		or @active_end_time_of_day is not NULL
	begin
		-- HETERO check only
		if @publisher_type != N'MSSQLSERVER'
		begin
			-- we can only allow @job_login change for Hetero when
			-- the publisher_security_mode is standard security...
			select @pubsecmode = security_mode
				from msdb..MSdistpublishers
				where name = @publisher
					and distribution_db = db_name()

			if @pubsecmode is not NULL 
				AND @pubsecmode != 0
				AND @job_login is not NULL
			begin
				-- "@job_login can only be specified/changed for heterogeneous publications when the publisher security_mode (for sp_adddistpublisher) is set to 0."
				RAISERROR(21842, 16, -1, '@job_login', 'the publisher security_mode (for sp_adddistpublisher)', '0')
				goto FAILED
			end
		end

		DECLARE #cursorSnapAgents CURSOR LOCAL FAST_FORWARD FOR		
			SELECT mssa.name,
					CAST(mssa.job_id as uniqueidentifier),
					mssa.job_step_uid
				FROM msdb.dbo.sysjobs_view sjv
					JOIN MSsnapshot_agents mssa
						ON sjv.job_id = CAST(mssa.job_id as uniqueidentifier)
					JOIN msdb.dbo.sysjobsteps sjs
						ON sjv.job_id = sjs.job_id
							AND mssa.job_step_uid = sjs.step_uid
				WHERE mssa.publisher_id = @publisher_id
					AND mssa.publisher_db = @publisher_db
					AND mssa.publication = @publication
		FOR READ ONLY

		OPEN #cursorSnapAgents

		FETCH #cursorSnapAgents INTO @snapshot_job_name, @job_id, @job_step_uid

		WHILE @@FETCH_STATUS <> -1
		BEGIN
			IF @job_id IS NOT NULL
				AND @job_step_uid IS NULL
			BEGIN
				SELECT @job_step_uid 	= sjs.step_uid 
				FROM msdb.dbo.sysjobs_view as sjv 
					JOIN msdb.dbo.sysjobsteps as sjs 
						ON sjv.job_id = sjs.job_id 
				WHERE sjv.job_id = @job_id
					AND sjv.master_server = 0
					AND UPPER(sjv.originating_server) = UPPER(CONVERT(sysname, SERVERPROPERTY('ServerName')))
					AND sjv.category_id = 15
					AND sjs.subsystem = N'Snapshot' 
					AND sjs.database_name = db_name()
			END
			
			exec @retcode = sys.sp_MSchange_repl_job @id 							= @job_id,
													@step_uid						= @job_step_uid,
													@name							= @snapshot_job_name,
													@frequency_type 				= @frequency_type,
													@frequency_interval 			= @frequency_interval,
													@frequency_subday				= @frequency_subday,
													@frequency_subday_interval		= @frequency_subday_interval,
													@frequency_relative_interval	= @frequency_relative_interval,
													@frequency_recurrence_factor	= @frequency_recurrence_factor,
													@active_start_date				= @active_start_date,
													@active_end_date				= @active_end_date,
													@active_start_time_of_day		= @active_start_time_of_day,
													@active_end_time_of_day 		= @active_end_time_of_day,
													@login							= @job_login,
													@password						= @job_password,
													@proxy_id                       = @proxy_id OUTPUT
			if @@error <> 0 or @retcode <> 0
				goto FAILED

			FETCH #cursorSnapAgents INTO @snapshot_job_name, @job_id, @job_step_uid
		END 

		CLOSE #cursorSnapAgents
		DEALLOCATE #cursorSnapAgents
	end

	commit transaction tran_sp_MSchange_snapshot

	return 0
FAILED:
	rollback transaction tran_sp_MSchange_snapshot
	commit transaction

	return 1
end
GO
GRANT EXECUTE ON [sys].[sp_MSchange_snapshot_agent_properties] TO [public] AS [dbo]
GO
