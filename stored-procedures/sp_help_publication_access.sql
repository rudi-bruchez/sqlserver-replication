SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_help_publication_access]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_help_publication_access] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_help_publication_access]
	@publication [sysname],
	@return_granted [bit],
	@login [sysname],
	@initial_list [bit],
	@publisher [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
	set nocount on
	-- This stored procedure can be called repeatedly.
	DECLARE @distribdb sysname
				,@distproc  nvarchar (300)
				,@retcode  int
				,@dist_rpcname sysname
				,@database  sysname
				,@publisher_type sysname
				,@loc_publisher sysname

	exec @retcode = sys.sp_MSreplcheck_publish
	if @@ERROR <> 0 or @retcode <> 0
		return(1)

	-- Set publisher name if not supplied
	SELECT @loc_publisher = case when (@publisher IS NULL) then publishingservername() else @publisher end

	exec sys.sp_MSget_server_portinfo 
		@name = @loc_publisher, 
		@srvname = @loc_publisher OUTPUT

	-- Get publisher info
	EXEC @retcode = sys.sp_MSrepl_getdistributorinfo @publisher  = @loc_publisher,
																	  @rpcsrvname  = @dist_rpcname   OUTPUT,
																	  @distribdb  = @distribdb      OUTPUT,
																	  @publisher_type = @publisher_type OUTPUT
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
	IF @publisher_type = N'MSSQLSERVER' AND @publisher IS NOT NULL
	BEGIN
		RAISERROR(21606, 16, -1, '@publisher', 'NULL')
		RETURN (1)
	END

	-- Set db context to distributor if HREPL
	SELECT @database = case when (@publisher_type = N'MSSQLSERVER') then db_name() else @distribdb end
				,@distproc = QUOTENAME(RTRIM(@dist_rpcname)) + N'.' + QUOTENAME(RTRIM(@distribdb)) + N'.sys.sp_MSpublication_access'

	-- Do check existense when dropping since the login might be dropped
	-- outside replication already.
	-- Get logins in the PAL if needed
	if @initial_list = 0
	begin
		create table #granted (login sysname null)    

		insert into #granted
		EXEC @retcode = @distproc
									@publisher  = @loc_publisher,
									@publisher_db = @database,
									@publication = @publication,
									@operation  = N'help',
									@login   = @login

		IF @@error <> 0 OR @retcode <> 0
			return (1)
	end

	-- Get distributor valid logins if needed
	if @return_granted = 0 or @initial_list = 1
	begin
		create table #dist_logins(login sysname null)
		
		insert into #dist_logins
		EXEC @retcode = @distproc
										@publisher = @loc_publisher,
										@operation = N'get_logins'
	end

	if @initial_list = 1
	begin
		-- Get the initial list for the publication to be created
		-- by the current user
		-- It contains all the logins sysadmin group and the current user
		-- that have valid login at the distributor.
		select l.loginname, l.isntname, l.isntgroup
		 from master.dbo.syslogins l, #dist_logins d where
			l.sid = suser_sid(d.login, 0) and
			l.hasaccess = 1 and
			(is_srvrolemember('sysadmin',d.login) = 1 or (l.sid = suser_sid())) 
	end
	else if @return_granted = 0
	begin
		-- resultset will have list of logins
		-- that are there on both distributor and publisher
		-- and that currently do not have access to publication
		-- and have publisher db access
		select l.loginname, l.isntname, l.isntgroup
		from master.dbo.syslogins l 
			join #dist_logins d 
				on l.sid = suser_sid(d.login, 0)
					and l.hasaccess = 1
					--
					-- The login should not exist in PAL
					--
					and not exists (select *
									from #granted g 
									where suser_sid(g.login, 0) = l.sid )
					--
					-- The login should have a user mapping in current db
					-- For sysadmins - there may not be a direct user mapping
					--
					and (l.sysadmin = 1
							or exists (select * from dbo.sysusers u
										where u.sid = l.sid
											and u.hasdbaccess = 1))
	end
	else if @return_granted = 1
	begin
		select l.loginname, l.isntname, l.isntgroup from master.dbo.syslogins l,
			#granted g where
			l.sid = suser_sid(g.login, 0)
	end
END
GO
GRANT EXECUTE ON [sys].[sp_help_publication_access] TO [public] AS [dbo]
GO
