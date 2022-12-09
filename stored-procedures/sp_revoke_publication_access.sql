SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_revoke_publication_access]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_revoke_publication_access] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_revoke_publication_access]
	@publication [sysname],
	@login [sysname],
	@publisher [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
	set nocount on
	
	-- This stored procedure can be called repeatedly.
	DECLARE @distribdb		sysname,
				@distproc		nvarchar (300),
				@retcode		int,
				@dist_rpcname	sysname,
				@database		sysname,
				@publisher_type	sysname,
				@loc_publisher	sysname,
				@role 			sysname,
				@pubid 			uniqueidentifier,
				@pubidtran 		int,
				@pubidstr 		nvarchar(40),
				@user 			sysname

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
	EXEC @retcode = sys.sp_MSrepl_getdistributorinfo	@publisher		= @loc_publisher,
														@rpcsrvname		= @dist_rpcname   OUTPUT,
														@distribdb		= @distribdb      OUTPUT,
														@publisher_type	= @publisher_type OUTPUT
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
	select @database = case when (@publisher_type = N'MSSQLSERVER') then db_name() else @distribdb end

	-- remove the user from the PAL role in the publishing database
	-- added for role based security
	if object_id('sysmergepublications') is not NULL
	begin
		select @pubid = pubid from dbo.sysmergepublications where name = @publication and UPPER(publisher) = UPPER(@loc_publisher) collate database_default and publisher_db = db_name()
		if (@pubid is not null)
		begin
			select @role = sys.fn_MSmerge_GetPALRole(@pubid)

			if exists (select * from sys.database_principals where name=@role and type = 'R')
			begin
				select @user = name from sys.database_principals where sid = suser_sid(@login, 0) and name <> 'dbo'
				if @user is not NULL
				begin
					exec @retcode = sp_droprolemember @role, @user
					if (@retcode <> 0 or @@error <> 0)
						return 1
					exec @retcode = sys.sp_MSrevokeconnectreplication @loc_publisher, @database, @login, @user
					if (@retcode <> 0 or @@error <> 0)
						return 1
				end
			end
		end
	end
	if object_id('syspublications') is not NULL
	begin
		if (@publisher_type = N'MSSQLSERVER')
			select @pubidtran = pubid from dbo.syspublications where name = @publication
		else
			select @pubidtran = pubid from sys.fn_IHgetpubid(@publication, @loc_publisher, @publisher_type)
		if (@pubidtran is not null)
		begin
			select @role = N'MSReplPAL_' + cast(db_id() as nvarchar(10)) + N'_' + cast(@pubidtran as nvarchar(10))

			if exists (select * from sys.database_principals where name=@role and type = 'R')
			begin
				select @user = name from sys.database_principals where sid = suser_sid(@login, 0) and name <> 'dbo'
				if @user is not NULL
				begin
					exec @retcode = sp_droprolemember @role, @user
					if (@retcode <> 0 or @@error <> 0)
						return 1                        
					exec @retcode = sys.sp_MSrevokeconnectreplication @loc_publisher, @database, @login, @user
					if (@retcode <> 0 or @@error <> 0)
						return 1
				end
			end
		end
	end

	-- Do check existense when dropping since the login might be dropped
	-- outside replication already.
	SELECT @distproc = QUOTENAME(RTRIM(@dist_rpcname)) + '.' + QUOTENAME(RTRIM(@distribdb)) + '.sys.sp_MSpublication_access'

	EXEC @retcode = @distproc
					@publisher  = @loc_publisher,
					@publisher_db = @database,
					@publication = @publication,
					@login   = @login,
					@operation  = 'drop'

	IF @@error <> 0 OR @retcode <> 0
		return (1)
	--
	-- all done
	--
END
GO
GRANT EXECUTE ON [sys].[sp_revoke_publication_access] TO [public] AS [dbo]
GO
