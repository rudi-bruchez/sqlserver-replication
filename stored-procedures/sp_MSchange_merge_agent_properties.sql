SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSchange_merge_agent_properties]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSchange_merge_agent_properties] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSchange_merge_agent_properties]
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
			@agent_id		int,
			@security_mode 	smallint,
			@publication_id int,
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
	
	-- retrieve the agent id
	select @agent_id = id,
			@job_id = convert(uniqueidentifier, job_id),
			@job_step_uid = job_step_uid
		from dbo.MSmerge_agents
		where publisher_id = @publisher_id
			and publisher_db = @publisher_db
			and publication = @publication
			and UPPER(subscriber_name) = UPPER(@subscriber)
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
			and sjv.category_id = 14
			and sjs.subsystem = 'Merge' 
			and sjs.database_name = db_name()
	end
	
	-- get publication id
	select @publication_id = publication_id
		from dbo.MSpublications
		where publisher_id = @publisher_id
		and publisher_db = @publisher_db
		and publication = @publication
   
	-- if the property is not in the list we return an error at the end
	select @property = lower(rtrim(ltrim(@property)))
	
	if @property = N'subscriber_security_mode' 
	begin
		if isnumeric(@value) = 0
		begin
			-- '@value' is not a valid value for the 'subscriber_security_mode' parameter. The value must be 0 or 1.
			raiserror (21406, 16, -1, @value, @property)
			return 1
		end
		
		select @security_mode = cast(@value as smallint)

		if @security_mode = 1
		begin
			select @value = newid()

			exec @retcode = sys.sp_MSreplencrypt @value OUTPUT
			if @@error <> 0 or @retcode <> 0
				return 1
				
			update dbo.MSmerge_agents 
				set subscriber_security_mode = 1,
					subscriber_login = N'',
					subscriber_password = @value
				where id = @agent_id
			if @@error <> 0
				return 1
		end
		else if @security_mode = 0
		begin
			update dbo.MSmerge_agents 
				set subscriber_security_mode = 0
				where id = @agent_id
			if @@error <> 0
				return 1
		end
		else
		begin
			-- "'@value' is not a valid value for the '@property' parameter. The value must be 0 or 1."
			raiserror (21406, 16, -1, '@value', '@property')
			return 1
		end
	end
	else if @property = N'subscriber_login' 
	begin
		update dbo.MSmerge_agents 
			set subscriber_login = @value 
			where id = @agent_id
		if @@error <> 0
			return 1
	end
	else if @property = N'subscriber_password' 
	begin
		exec @retcode = sys.sp_MSreplencrypt @value OUTPUT
		if @@error <> 0 or @retcode <> 0
			return 1
				
		update dbo.MSmerge_agents 
			set subscriber_password = @value 
			where id = @agent_id
		if @@error <> 0
			return 1
	end
	else if @property = N'publisher_security_mode' 
	begin
		if isnumeric(@value) = 0
		begin
			-- '@value' is not a valid value for the 'subscriber_security_mode' parameter. The value must be 0 or 1.
			raiserror (21406, 16, -1, @value, @property)
			return 1
		end
		
		select @security_mode = cast(@value as smallint)

		if @security_mode = 1
		begin
			select @value = newid()

			exec @retcode = sys.sp_MSreplencrypt @value OUTPUT
			if @@error <> 0 or @retcode <> 0
				return 1
				
			update dbo.MSmerge_agents 
				set publisher_security_mode = 1,
					publisher_login = N'',
					publisher_password = @value
				where id = @agent_id
			if @@error <> 0
				return 1
		end
		else if @security_mode = 0
		begin
			update dbo.MSmerge_agents 
				set publisher_security_mode = 0
				where id = @agent_id
			if @@error <> 0
				return 1
		end
		else
		begin
			-- "'@value' is not a valid value for the '@property' parameter. The value must be 0 or 1."
			raiserror (21406, 16, -1, '@value', '@property')
			return 1
		end
	end
	else if @property = N'publisher_login' 
	begin
		update dbo.MSmerge_agents 
			set publisher_login = @value 
			where id = @agent_id
		if @@error <> 0
			return 1
	end
	else if @property = N'publisher_password' 
	begin
		exec @retcode = sys.sp_MSreplencrypt @value OUTPUT
		if @@error <> 0 or @retcode <> 0
			return 1
			
		update dbo.MSmerge_agents 
			set publisher_password = @value
			where id = @agent_id
		if @@error <> 0
			return 1
	end
	else if @property = N'merge_job_login'
	begin
		-- update the Proxy Account login
		exec @retcode = sys.sp_MSchange_repl_job @id = @job_id,
												@step_uid = @job_step_uid,
												@login = @value
		if @@error != 0 or @retcode != 0
			return 1
	end
	else if @property = N'merge_job_password'
	begin
		-- update the Proxy Account password
		exec @retcode = sys.sp_MSchange_repl_job @id = @job_id,
												@step_uid = @job_step_uid,
												@password = @value
		if @@error != 0 or @retcode != 0
			return 1
	end
	else if @property = N'description' 
	begin 
		UPDATE dbo.MSmerge_subscriptions
			 SET description = @value
				   where publisher_id = @publisher_id and
						publisher_db = @publisher_db and
						publication_id = @publication_id and
						UPPER(subscriber) = UPPER(@subscriber) and
						subscriber_db = @subscriber_db	
		if @@error <> 0
			return 1
	end 
	else
	begin
		-- "Invalid property name '@property'."
		raiserror (21348, 16, -1, @property)
		return 1
	end
	
	return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSchange_merge_agent_properties] TO [public] AS [dbo]
GO
