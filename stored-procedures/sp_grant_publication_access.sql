SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_grant_publication_access]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_grant_publication_access] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_grant_publication_access]
	@publication [sysname],
	@login [sysname],
	@reserved [nvarchar](10),
	@publisher [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
	set nocount on

	-- This stored procedure can be called repeatedly.
	DECLARE @distribdb  sysname,
				@distproc  nvarchar (300),
				@retcode  int,
				@dist_rpcname sysname,
				@database  sysname,
				@publisher_type sysname,
				@loc_publisher sysname,
				@role    sysname,
				@pubid    uniqueidentifier,
				@pubidtran   int,
				@pubidstr   nvarchar(40),
				@user    sysname,
				@fmergepub   bit,
				@ftranpub   bit,
				@skip   bit,
				@login2   sysname,
				@login_id int,
				@sid varbinary(85),
				@db_name sysname,
				@isloginsysadmin int,
				@issqlpublisher bit,
				@version int,
				@versionyukon int,
				@initinfo nvarchar(max)
				
	-- Security Check
	exec @retcode = sys.sp_MSreplcheck_publish
	if @@ERROR <> 0 or @retcode <> 0
		return(1)
	
	-- Set publisher name if not supplied
	select @loc_publisher = case when (@publisher is null) then publishingservername() 
												else @publisher end
	exec sys.sp_MSget_server_portinfo 
		@name = @loc_publisher, 
		@srvname = @loc_publisher OUTPUT

	-- Get publisher info
	EXEC @retcode = sys.sp_MSrepl_getdistributorinfo  @publisher  = @loc_publisher,
													  @rpcsrvname = @dist_rpcname OUTPUT,
													  @distribdb = @distribdb OUTPUT,
													  @publisher_type = @publisher_type OUTPUT,
													  @version = @version OUTPUT
	IF @@error <> 0
	BEGIN
		 RAISERROR (14071, 16, -1)
		 return (1)
	END

	IF @retcode <> 0 OR @distribdb IS NULL OR @dist_rpcname IS NULL
	BEGIN
		RAISERROR (14071, 16, -1)
		return(1)
	END

	-- Restrict specification of publisher to HREPL only
	select @issqlpublisher = case when (@publisher_type = N'MSSQLSERVER') then 1 else 0 end
	IF @issqlpublisher = 1 AND @publisher IS NOT NULL
	BEGIN
		RAISERROR(21606, 16, -1, '@publisher', 'NULL')
		RETURN (1)
	END
	--
	-- Use current context if @login is null
	-- NOTE: if the login is provisioned (no explicitly created 
	-- using CREATE LOGIN since it may be a member of GROUP) then 
	-- 1)suser_id(@login) will return NULL - the login does not 
	-- have any explicit entry in master.dbo.syslogins
	-- 2)suser_id() will map to login token information
	--
	if @login is null
	begin
		-- if the current user is a member of a NT group and
		-- NT group has access then is_srvrolemember()
		-- and suser_id() will not work properly unless they
		-- are invoked for current user
		select @login = suser_name()
				,@isloginsysadmin = is_srvrolemember(N'sysadmin')
				,@login_id = suser_id()
	end
	else
	begin
		select @isloginsysadmin = is_srvrolemember(N'sysadmin',@login)
				,@login_id = suser_id(@login)
	end
	-- Initialize
	-- Set db context to distributor if HREPL
	select @database = case when (@issqlpublisher = 1) then db_name() else @distribdb end
			,@sid = suser_sid(@login,0)
			,@fmergepub = 0
			,@ftranpub = 0
			,@skip = case when (@reserved = N'init') then 1 else 0 end
			,@versionyukon = 0x900048B
	--
	-- We should always have a valid SID for any kind of login (provisioned or not)
	-- If there is not valid SID then it is a bad login
	--
	if (@sid is null)
	begin
		raiserror(15007, 16, 1, @login)
		return (1)
	end
	-- Existance check of the publication will be done in sp_MSpublication_access
	-- Note, even if the login exists, it may or may not has access
	-- to the server (granted or denied). 
	if @skip = 0
	begin
		-- Check if this database is published
		IF sys.fn_MSrepl_ispublished(@database) != 1
		BEGIN
			-- The database is not published.
			RAISERROR (18757, 16, -1)
			RETURN 1
		END
		--
		-- Permission check for CONNECT SQL
		-- Skip this check when login_id is null
		--
		if @login_id is not null and
		(exists (select * from sys.server_permissions where
					class = 100 and major_id = 0 and minor_id = 0 and type = 'COSQ' and
						grantee_principal_id = @login_id and state = 'D') or
			not exists (select * from sys.server_permissions where
					class = 100 and major_id = 0 and minor_id = 0 and type = 'COSQ' and
						grantee_principal_id = @login_id and state in ('G','W')))
		begin
			raiserror(15007, 16, 2, @login)
			return (1)
		end

		-- Don't do the user check if sysadmin since sysadmin can enter
		-- the database as dbo.
		if @isloginsysadmin = 0 and
			not exists (select * from sys.database_principals u join sys.database_permissions p on u.principal_id = p.grantee_principal_id
						where (u.sid = @sid or u.name = N'guest') and
							p.class = 0 and p.major_id = 0 and p.minor_id = 0 and p.type = 'CO' and p.state in ('G','W') and
			not exists (select * from sys.database_permissions d where d.class = 0 and d.major_id = 0 and d.minor_id = 0 and
						d.grantee_principal_id = p.grantee_principal_id and d.type = 'CO' and d.state = 'D'))
		begin
			raiserror(20619, 16, -1, @login, @database) 
			return (1)          
		end
	end
	--
	-- Get the publication id and see if what kind of publication it is
	--
	if object_id(N'dbo.sysmergepublications') is not NULL
	begin
		select @pubid = pubid from dbo.sysmergepublications where name = @publication and UPPER(publisher) = UPPER(@loc_publisher) and publisher_db = @database
		if (@pubid is not null)
			select @fmergepub = 1
	end
	if @fmergepub = 0 and object_id(N'dbo.syspublications') is not NULL
	begin
		if (@issqlpublisher = 1)
			select @pubidtran = pubid from dbo.syspublications where name = @publication
		else
			select @pubidtran = pubid from sys.fn_IHgetpubid(@publication, @loc_publisher, @publisher_type)
		if (@pubidtran is not null)
			select @ftranpub = 1
	end
	--
	-- publication should exist
	--
	if (@fmergepub = 0 and @ftranpub = 0)
	begin
		raiserror (20026, 16, -1, @publication)
		return (1)
	end
	--
	-- map the login to a user in the current db
	--
	select @user = name from sys.database_principals u where u.sid = @sid and
					exists (select * from sys.database_permissions p where
						p.class = 0 and p.major_id = 0 and p.minor_id = 0 and p.grantee_principal_id = u.principal_id and
						p.type = 'CO' and p.state in ('G','W') and
					not exists (select * from sys.database_permissions d where d.class = 0 and d.major_id = 0 and d.minor_id = 0 and
						d.grantee_principal_id = p.grantee_principal_id and d.type = 'CO' and d.state = 'D'))
	if @user is NULL
	begin
		--
		-- The login is NON provisioned or
		-- no explicit user mapping was found.
		-- Find ways to get the user mapping
		-- 
		if @isloginsysadmin = 1
		begin
			--
			-- the login is a NON provisioned sysadmin account
			-- the user mapping is known
			--
			select @user = N'dbo'
		end
		else if @login_id is null
		begin
			--
			-- NON provisioned non sysadmin account
			-- impersonate the login and get the current user
			-- there is no better way (server should have a better way)
			--
			select @distproc = N'EXECUTE AS LOGIN = N''' + REPLACE(@login, N'''', N'''''') + N''' '
							+ N'select @p1 = user_name() '
							+ N'REVERT '
			exec @retcode = sys.sp_executesql @stmt = @distproc
											,@params = N'@p1 sysname OUTPUT'
											,@p1 = @user OUTPUT
			if @@error <> 0
			begin
				--
				-- could impersonate the non provisioned login
				--
				raiserror(20624, 16, 2, @login, @database) 
				return(1)
			end
			--
			-- Now check if we have valid user
			--
			if @user is NULL
			begin
				--
				-- the non provisioned login has no user access in the current db
				--
				raiserror(20624, 16, 3, @login, @database) 
				return(1)
			end
		end -- if @login_id is null
		else
		begin
			--
			-- the provisioned login has no user access in the current db
			--
			raiserror(20624, 16, 1, @login, @database) 
			return (1)
		end
	end
	-- at this point we know that the login exists and has access to the publishing database
	-- Add role if this SP is not being called from sp_addpublication/sp_addmergepublication
	-- don't add role if 'init' because role cannot be added inside a transaction
	if (@skip = 0)
	begin
		if (@ftranpub = 1)
		begin
			-- Tran specific processing
			-- we will create just the role if needed
			-- and skip fixing the the role
			-- Role fixing should be explicitly done by calling sp_createtranpalrole
			exec @retcode = sys.sp_MSrepl_FixTranPALRole @pubidtran, @publication, @publisher_type, @loc_publisher, @role output
		end
		else
		begin
			-- Merge specific processing
			-- we will create just the role if needed
			-- Fix the database role which represents the users who have access to this publication
			exec @retcode = sys.sp_MSrepl_FixPALRole @pubid, @role output
		end
		if (@retcode<>0 or @@error <> 0)
			return 1
		--
		-- add the user for the given login to the PAL role
		-- we have to skip this in the 'init' stage because we may not have a role 
		-- explicitly call sp_grant_publication_access for any PAL user
		-- no need to add if system dbo user
		--
		if @user != N'dbo'
		begin
			exec @retcode = sys.sp_addrolemember @role, @user
			if (@retcode <> 0 or @@error <> 0)
				return 1
			exec @retcode = sys.sp_MSgrantconnectreplication @user
			if (@retcode <> 0 or @@error <> 0)
				return 1
		end
	end -- if (@skip = 0)
	--
	-- add login(s) to distributor
	--
	if (@skip = 1)
	begin
		--
		-- publication init processing
		-- choose all sysadmin logins + given login  and prepare a info string for init
		-- Skip logins that are not at the distributor without raising error during init
		--
		SELECT @distproc = QUOTENAME(RTRIM(@dist_rpcname)) + N'.' + QUOTENAME(RTRIM(@distribdb)) 
						+ case when (isnull(@version,0) < @versionyukon) then N'.sys.sp_MSpublication_access' 
									else N'.sys.sp_MSinit_publication_access' end
					,@initinfo = N''

		declare #hC CURSOR LOCAL FAST_FORWARD for
			select name from master.sys.syslogins 
			where hasaccess = 1 
				and (sid = @sid or sysadmin = 1)
		for read only

		open #hC
		fetch #hC into @login2
		while (@@fetch_status <> -1)
		begin
			if (isnull(@version,0) < @versionyukon)
			begin
				-- Pre-Yukon distributor
				-- Call RPC to add login
				EXEC @retcode = @distproc
								@publisher  = @loc_publisher,
								@publisher_db = @database,
								@publication = @publication,
								@login   = @login2,
								@operation  = N'add',
								@skip   = @skip
				IF @@error <> 0 OR @retcode <> 0
				return (1)
			end
			else
			begin
				-- Yukon or later version of distributor
				-- build initinfo
				select @initinfo = @initinfo + N'<item\>' + @login2 + N'</item\>'
			end
			fetch #hC into @login2
		end
		close #hC
		deallocate #hC
		--
		-- One RPC call to Yukon or recent distributor with login initinfo
		--
		if (@initinfo != N'')
		begin
			EXEC @retcode = @distproc
							@publisher  = @loc_publisher,
							@publisher_db = @database,
							@publication = @publication,
							@initinfo   = @initinfo,
							@skip   = @skip
			IF @@error <> 0 OR @retcode <> 0
			return (1)
		end
	end
	else
	begin
		--
		-- choose given login for regular processing
		--
		SELECT @distproc = QUOTENAME(@dist_rpcname) + N'.' + QUOTENAME(@distribdb) 
										+ N'.sys.sp_MSpublication_access'
		EXEC @retcode = @distproc
						@publisher  = @loc_publisher,
						@publisher_db = @database,
						@publication = @publication,
						@login   = @login,
						@operation  = N'add',
						@skip   = @skip
		IF @@error <> 0 OR @retcode <> 0
			return (1)
	end
	--
	-- all done
	--
	return 0
END
GO
GRANT EXECUTE ON [sys].[sp_grant_publication_access] TO [public] AS [dbo]
GO
