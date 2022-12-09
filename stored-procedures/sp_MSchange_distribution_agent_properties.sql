SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSchange_distribution_agent_properties]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSchange_distribution_agent_properties] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSchange_distribution_agent_properties]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname],
	@property [sysname],
	@value [nvarchar](524)
WITH EXECUTE AS CALLER
AS
begin
	set nocount on 

	declare @retcode 		int,
			@publisher_id	int,
			@subscriber_id	int,
			@agent_id		int,
			@security_mode 	smallint,
			@job_id			uniqueidentifier,
			@job_step_uid	uniqueidentifier
	
	-- should only be called by the admin link
	if is_srvrolemember('sysadmin') <> 1
	begin
		raiserror (14126, 16, -1)
		return 1 
	end
	
	 -- Get publisher without port number

	exec sys.sp_MSget_server_portinfo 
		@name = @publisher, 
		@srvname = @publisher OUTPUT

	exec sys.sp_MSget_server_portinfo 
		@name = @subscriber, 
		@srvname = @subscriber OUTPUT

	-- retrieve server ids
	select @publisher_id = srvid
		from MSreplservers
		where upper(srvname) = upper(@publisher)
	
	select @subscriber_id = srvid
		from MSreplservers
		where upper(srvname) = upper(@subscriber)
		
	-- retrieve the agent id
	select @agent_id = id,
			@job_id = convert(uniqueidentifier, job_id),
			@job_step_uid = job_step_uid
		from MSdistribution_agents
		where publisher_id = @publisher_id
			and publisher_db = @publisher_db
			and (publication = @publication
					or lower(publication) = N'all')
			and subscriber_id = @subscriber_id
			and subscriber_db = @subscriber_db

	-- retrieve the job_step_uid if not set
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
			and sjv.category_id = 10
			and sjs.subsystem = 'Distribution' 
			and sjs.database_name = db_name()
	end
	
	-- if the property is not in the list we return an error at the end
	select @property = lower(rtrim(ltrim(@property)))

	begin transaction tr_sp_change_dist_agent
	save transaction tr_sp_change_dist_agent
	
	-- update the agents table
	if @property = N'subscriber_security_mode'
	begin
		if isnumeric(@value) = 0
		begin
			-- '@value' is not a valid value for the 'subscriber_security_mode' parameter. The value must be 0 or 1.
			raiserror (21406, 16, -1, @value, @property)
			goto FAILURE
		end
		
		select @security_mode = cast(@value as smallint)

		if @security_mode = 1
		begin
			select @value = newid()
			
			-- must encrypt it prior to update
			exec @retcode = sys.sp_MSreplencrypt @value OUTPUT
			if @@error <> 0 or @retcode <> 0
				goto FAILURE
				
			update MSdistribution_agents 
				set subscriber_security_mode = 1,
					subscriber_login = N'',
					subscriber_password = @value
				where id = @agent_id
			if @@error <> 0
				goto FAILURE
		end
		else if @security_mode = 0
		begin
			update MSdistribution_agents 
				set subscriber_security_mode = 0
				where id = @agent_id
			if @@error <> 0
				goto FAILURE
		end
		else
		begin
			-- "'@value' is not a valid value for the '@property' parameter. The value must be 0 or 1."
			raiserror (21406, 16, -1, @value, @property)
			goto FAILURE
		end
	end
	else if @property = N'subscriber_login' 
	begin
		update MSdistribution_agents 
			set subscriber_login = @value 
			where id = @agent_id
		if @@error <> 0
			goto FAILURE
	end
	else if @property = N'subscriber_password' 
	begin
		-- must encrypt it prior to update
		exec @retcode = sys.sp_MSreplencrypt @value OUTPUT
		if @@error <> 0 or @retcode <> 0
			goto FAILURE

		-- password provided to this procedure should already be encrypted
		update MSdistribution_agents 
			set subscriber_password = @value
			where id = @agent_id
		if @@error <> 0
			goto FAILURE
	end
	else if @property = N'distrib_job_login'
	begin
		-- Cloud Lifter edition (CL) uses value provided for distrib_job_login
		-- for SQL authentication (Windows authentication and proxies are not supported in CL)
		if sys.fn_MSrepl_editionid() = 32
		begin
			update MSdistribution_agents
				set job_login = @value
				where id = @agent_id
			if @@error <> 0
				goto FAILURE
		end
		else
		begin
		-- update the Proxy Account login
		exec @retcode = sys.sp_MSchange_repl_job @id = @job_id,
												@step_uid = @job_step_uid,
												@login = @value
		if @@error != 0 or @retcode != 0
			goto FAILURE
	end
	end
	else if @property = N'distrib_job_password'
	begin
		-- Cloud Lifter edition (CL) uses value provided for distrib_job_password
		-- for SQL authentication (Windows authentication and proxies are not supported in CL)
		if sys.fn_MSrepl_editionid() = 32
		begin
			-- Encrypt the password before storing
			exec @retcode = sys.sp_MSreplencrypt @value OUTPUT
			if @@error <> 0 or @retcode <> 0
				goto FAILURE

			update MSdistribution_agents 
				set job_password = @value
				where id = @agent_id
			if @@error <> 0
				goto FAILURE
		end
		else
		begin
		-- update the Proxy Account password
		exec @retcode = sys.sp_MSchange_repl_job @id = @job_id,
												@step_uid = @job_step_uid,
												@password = @value
		if @@error != 0 or @retcode != 0
			goto FAILURE
	end
	end
	else if @property = N'subscriptionstreams'
	begin
		declare @subscriptionstreams tinyint
		set @subscriptionstreams = cast (@value as tinyint)
		if (@subscriptionstreams < 1 or @subscriptionstreams > 64)
		begin
			RAISERROR(14198, 16, -1, '@subscriptionstreams', '1..64')
			goto FAILURE
		end
		update MSdistribution_agents 
			set subscriptionstreams = @subscriptionstreams
			where id = @agent_id
		if @@error <> 0
			goto FAILURE
	end
	else if @property = N'subscriber_type'
	begin
		declare @subscriber_type tinyint
		set @subscriber_type = cast (@value as tinyint)
		if @subscriber_type NOT IN ( 0, 1, 3)
		begin
			RAISERROR(14197, 16, -1, '@subscriber_type', '0, 1, 3')
			goto FAILURE
		end
		else if exists (Select subscriber_type from MSdistribution_agents where subscriber_type = 0 and memory_optimized = 1 and id = @agent_id and @subscriber_type <> 0)
		begin
			RAISERROR(21429, 16, -1)
			goto FAILURE
		end
		update MSdistribution_agents 
			set subscriber_type = @subscriber_type
			where id = @agent_id
		if @@error <> 0
			goto FAILURE
	end
	else if @property = N'memory_optimized'
	begin
		declare @memory_optimized tinyint, @type tinyint
		Select @type = ISNULL(subscriber_type,0) from MSdistribution_agents where id = @agent_id
		set @memory_optimized = cast (@value as tinyint)
		if (@type <> 0 and @memory_optimized = 1)
		Begin
			RAISERROR(21428, 16, -1)
			goto FAILURE
		End
		update MSdistribution_agents 
			set memory_optimized = @memory_optimized
			where id = @agent_id
		if @@error <> 0
			goto FAILURE
	end
	else if @property = N'subscriber_provider'
	begin
		update MSdistribution_agents 
			set subscriber_provider = @value 
			where id = @agent_id
		if @@error <> 0
			goto FAILURE
	end
	else if @property = N'subscriber_datasource'
	begin
		update MSdistribution_agents 
			set subscriber_datasrc = @value 
			where id = @agent_id
		if @@error <> 0
			goto FAILURE
	end
	else if @property = N'subscriber_providerstring'
	begin
		update MSdistribution_agents 
			set subscriber_provider_string = @value 
			where id = @agent_id
		if @@error <> 0
			goto FAILURE
	end
	else if @property = N'subscriber_location'
	begin
		update MSdistribution_agents 
			set subscriber_location = @value 
			where id = @agent_id
		if @@error <> 0
			goto FAILURE
	end
	else if @property = N'subscriber_catalog'
	begin
		update MSdistribution_agents 
			set subscriber_catalog = @value 
			where id = @agent_id
		if @@error <> 0
			goto FAILURE
	end
	else
	begin
		-- "Invalid property name '@property'."
		raiserror (21348, 16, -1, @property)
		goto FAILURE
	end

	commit transaction tr_sp_change_dist_agent

	return 0
	
FAILURE:
	rollback transaction tr_sp_change_dist_agent
	commit transaction tr_sp_change_dist_agent

	return 1
end
GO
GRANT EXECUTE ON [sys].[sp_MSchange_distribution_agent_properties] TO [public] AS [dbo]
GO
