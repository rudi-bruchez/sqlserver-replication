SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSchange_logreader_agent_properties]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSchange_logreader_agent_properties] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSchange_logreader_agent_properties]
	@publisher [sysname],
	@publisher_db [sysname],
	@publisher_security_mode [int],
	@publisher_login [sysname],
	@publisher_password [nvarchar](524),
	@job_login [nvarchar](257),
	@job_password [sysname],
	@publisher_type [sysname]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on
	
	declare @retcode 		bit,
			@publisher_id 	int,
			@agent_id		int,
			@agent_exists	bit,
			@job_id			uniqueidentifier,
			@job_step_uid	uniqueidentifier,
			@pubsecmode		int

	-- security: Has to be executed by SA of dist db
	if is_srvrolemember('sysadmin') != 1
	begin
		-- You do not have the required permissions to complete the operation.
		raiserror (20604, 16, -1)
		return 1
	end

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
		return 1
	end

	select @agent_id = id
		from MSlogreader_agents
		where publisher_id = @publisher_id
			and publisher_db = @publisher_db
	if @agent_id is NULL
	begin
		-- The logreader agent job for publisher (@publisher), database (@publisher_db), publication (@publication) could not be found.
		raiserror (21799, 16, -1, N'logreader', @publisher, @publisher_db, 'all')
		return 1
	end 
	
	begin transaction tran_sp_MSchange_logreader
	save transaction tran_sp_MSchange_logreader

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
		
		update MSlogreader_agents
			set publisher_security_mode = isnull(@publisher_security_mode, publisher_security_mode),
				publisher_login = isnull(@publisher_login, publisher_login),
				publisher_password = isnull(@publisher_password, publisher_password)
			where id = @agent_id
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
		update MSlogreader_agents
			set job_login = isnull(@cl_login, job_login),
				job_password = isnull(@cl_password, job_password)
			where id = @agent_id
		if @@error <> 0
			goto FAILED
	end

	if @job_login is not NULL
		or @job_password is not NULL
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
		
		exec @retcode = sys.sp_MSreplagentjobexists @type			= 2,
													@exists 		= @agent_exists output,
													@job_id			= @job_id output,
													@job_step_uid	= @job_step_uid output,
													@publisher		= @publisher,
													@publisher_db	= @publisher_db
		if @@error <> 0 or @retcode <> 0
			goto FAILED

		if @agent_exists = 0
		begin
			-- The logreader agent job for publisher (@publisher), database (@publisher_db), publication (@publication) could not be found.
			raiserror (21799, 16, -1, N'logreader', @publisher, @publisher_db, 'all')
			goto FAILED
		end
		
		exec @retcode = sys.sp_MSchange_repl_job @id = @job_id,
												@step_uid = @job_step_uid,
												@login = @job_login,
												@password = @job_password
		if @@error <> 0 or @retcode <> 0
			goto FAILED
	end

	commit transaction tran_sp_MSchange_logreader

	return 0
FAILED:
	rollback transaction tran_sp_MSchange_logreader
	commit transaction

	return 1
end
GO
GRANT EXECUTE ON [sys].[sp_MSchange_logreader_agent_properties] TO [public] AS [dbo]
GO
