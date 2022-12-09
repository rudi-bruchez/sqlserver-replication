SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MShelp_repl_agent]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MShelp_repl_agent] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MShelp_repl_agent]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname],
	@agent_type [int]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on
	
	declare @retcode 					int,
			@publisher_id				int,
			@subscriber_id				int,
			@publisher_security_mode 	int,
			@publisher_login 			sysname,
			@publisher_password 		nvarchar(524),
			@subscriber_security_mode 	int,
			@subscriber_login 			sysname,
			@subscriber_password 		nvarchar(524),
			@distributor_login 			sysname,
			@distributor_password 		nvarchar(524)

	-- make sure this is a replication agent.
	if sessionproperty('replication_agent') != 1
	begin
		-- "You do not have sufficient permission to run this command."
		raiserror(14260, 16, -1)
		return 1 
	end

	-- sysadmin or db_owner have access
	if is_srvrolemember('sysadmin') != 1 
		and is_member('db_owner') != 1
	begin
		-- "You do not have sufficient permission to run this command."
		raiserror(14260, 16, -1)
		return 1
	end

	-- Has to be executed from distribution database
	if sys.fn_MSrepl_isdistdb (db_name()) != 1 and sys.fn_MSrepl_editionid() != 32 -- Distribution DB system name will differ from db_name() in CL trusted connection
	begin
		-- "sp_MShelp_repl_agent can only be executed in the distribution database."
		raiserror (21482, 16, -1, 'sp_MShelp_repl_agent', 'distribution')
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

	select @subscriber_security_mode = 1,
			@subscriber_login = NULL,
			@subscriber_password = NULL,
				@publisher_security_mode = 1,
			@publisher_login = NULL,
			@publisher_password = NULL

	-- Distribution and Queued Agent
	if @agent_type in (0, 3)
	begin
		select msda.subscriber_security_mode,
				msda.subscriber_login,
				sys.fn_repldecryptver4(msda.subscriber_password),
				case when serverproperty('EngineEdition') = 8 then msda.job_login else null end,
				case when serverproperty('EngineEdition') = 8 then sys.fn_repldecryptver4(msda.job_password) else null end
			from MSdistribution_agents msda
			where msda.publisher_id = @publisher_id
				and msda.publisher_db = @publisher_db
				and (msda.publication = @publication
						or lower(msda.publication) = N'all')
				and msda.subscriber_id = @subscriber_id
				and msda.subscriber_db = @subscriber_db
		if @@error <> 0 return 1
	end
	-- Merge Agent
	else if @agent_type = 1
	begin
		select msma.subscriber_security_mode,
				msma.subscriber_login,
				sys.fn_repldecryptver4(msma.subscriber_password),
				msma.publisher_security_mode,
				msma.publisher_login,
				sys.fn_repldecryptver4(msma.publisher_password)
			from dbo.MSmerge_agents msma
			where msma.publisher_id = @publisher_id
				and msma.publisher_db = @publisher_db
				and msma.publication = @publication
				and UPPER(msma.subscriber_name) = UPPER(@subscriber)
				and msma.subscriber_db = @subscriber_db
		if @@error <> 0 return 1
	end
	-- Logreader Agent
	else if @agent_type = 2
	begin
		-- retrieve the publisher server and database name
		select @publisher_security_mode = msla.publisher_security_mode,
				@publisher_login = msla.publisher_login,
				@publisher_password = sys.fn_repldecryptver4(msla.publisher_password),
				@distributor_login = case when serverproperty('EngineEdition') = 8 then msla.job_login else null end,
				@distributor_password = case when serverproperty('EngineEdition') = 8 then sys.fn_repldecryptver4(msla.job_password) else null end
			from MSlogreader_agents msla
			where msla.publisher_id = @publisher_id 
				and msla.publisher_db = @publisher_db
		if @@error <> 0 return 1

		select @publisher_security_mode,
				@publisher_login,
				@publisher_password,
				@distributor_login,
				@distributor_password
	end
	
	return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MShelp_repl_agent] TO [public] AS [dbo]
GO
