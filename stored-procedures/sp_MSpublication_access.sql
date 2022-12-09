SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSpublication_access]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSpublication_access] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSpublication_access]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@login [sysname],
	@operation [nvarchar](20),
	@has_access [bit] OUTPUT,
	@skip [bit]
WITH EXECUTE AS CALLER
AS
begin
	-- This sp can be called repeatedly.
	set nocount on
	declare @publisher_id smallint
			,@retcode int
			,@publication_id int
			,@isntuser bit
			,@server_access bit
			,@privilege nchar(21)
			,@rowcount int
			,@sid varbinary(85)
			,@cmd nvarchar(500)

	--
	-- validate @operation
	--
	if (@operation not in (N'add', N'drop', N'check', N'help', N'get_logins', N'get_publications'))
	begin
		raiserror(21402, 16, 1, '@operation')
		return(1)
	end
	--
	-- If @operation is not N'check' or N'get_publications', restrict access to db_owner
	-- Security Note: For N'check' and N'get_publications' operations - implicit PAL check
	-- is done.
	--
	if @operation not in (N'check', N'get_publications')
	begin
		exec @retcode = sys.sp_MSreplcheck_publish
		if @@ERROR <> 0 or @retcode <> 0
			return(1)
	end

	exec sys.sp_MSget_server_portinfo 
		@name = @publisher, 
		@srvname = @publisher OUTPUT

	--
	-- Check if publisher is a defined as a distribution publisher in the current database
	--
	exec @retcode = sys.sp_MSvalidate_distpublisher @publisher, @publisher_id OUTPUT
	if @retcode <> 0
		return(1)
	--
	-- Get the publication id 
	--
	select @publication_id = publication_id 
	from dbo.MSpublications 
	where 
		publisher_id = @publisher_id and
		publisher_db = @publisher_db and
		publication = @publication
	--
	-- Publication does not exist
	--
	if @publication_id is null and @operation in (N'add',N'drop',N'check',N'help')
	begin
		raiserror (20026, 16, -1, @publication)
		return (1)
	end
	--
	-- Check to see if the login exists and if the login is NT user (not a group)
	--
	if (@login is null)
		select @login = suser_name()
	select @sid = suser_sid(@login,0)
	select @isntuser = null
	select @isntuser = isntuser    
	from master.dbo.syslogins 
	where sid = @sid and hasaccess = 1
	--
	-- Avoid EXECUTE AS LOGIN failure and cover the case of that 
	-- the NT user is not in syslogins (unprovisioned login)
	--
	if @isntuser is null and @sid is not null
	begin
		exec @retcode = master.dbo.xp_logininfo
					@login, N'all', @privilege output
		if @privilege is not null
			select @isntuser = 1
	end
	--
	-- we will need temp table for storing group SIDs for NT user 
	-- for certain operations
	--
	if (@isntuser = 1 and @operation in (N'check', N'get_publications'))
	begin
		--
		-- Using temp table instead of local table variable to avoid 
		-- INSERT EXEC nested problem. This SP is called with INSERT EXEC
		-- when used with get_publications
		--
		create table #groupsids (sid varbinary(85) null)
		-- 
		-- Check if the user is part of any group
		-- For this - impersonate the login and collect the GROUP SIDs
		-- to which the given login belongs to (there may be zero or more)
		--
		-- Security Note: EXECUTE AS LOGIN will need the SQL Server startup account to
		-- have at least Read access to the @login authentication information
		-- in AD for impersonation. This should be documented
		--
		select @cmd = N'EXECUTE AS LOGIN = N''' + REPLACE(@login, N'''', N'''''') + N''' '
						+ N'insert into #groupsids(sid) '
						+ N'select sid from master.dbo.syslogins '
						+ N'where isntgroup = 1 and is_member(name) = 1 '
						+ N'REVERT '
		exec @retcode = sys.sp_executesql @stmt = @cmd
		if  @retcode != 0 or @@error <> 0
		begin
			raiserror (21142, 16, -1, @@servername, @login)
			return(1)
		end
	end
	--
	-- process according to @operation
	--
	if @operation = N'add'
	begin
		-- Login does not have access
		if @sid is null
		begin
			if @skip = 0
			begin
				raiserror(21048, 16, 2, @login, @@servername) 
				return (1)
			end
			else
				return (0)
		end
		-- Add login to the access list if it does not exist
		if not exists (select * from dbo.MSpublication_access 
							where publication_id = @publication_id and
									sid = @sid)
		begin
			insert dbo.MSpublication_access (publication_id, login, sid)
				values (@publication_id,@login,@sid)
			if  @@error <> 0
				return(1)
		end
	end -- end add operation
	else if @operation = N'drop'
	begin
		if not exists (select * from dbo.MSpublication_access 
							where publication_id = @publication_id 
							and sid = @sid) 
		begin
			raiserror(15007,10,-1,@login)
			return 1
		end
		-- Do check existense when dropping since the login might be dropped
		-- outside replication already.
		delete dbo.MSpublication_access where
				publication_id = @publication_id and
				sid = @sid
		select @rowcount = @@rowcount

		-- We will also perform some extra cleanup for any PAL items that are
		-- no longer valid. PAL Items can become invalid if a user is dropped
		delete dbo.MSpublication_access 
		where sid != suser_sid(login,0) or suser_sid(login,0) is NULL
		select @rowcount = @@rowcount + @rowcount

		if isnull(@rowcount, 0) > 0
		begin
			-- Flush the cache for this publication id
			if object_id(N'tempdb.dbo.MSdistributor_access') is not null
			begin
				delete tempdb.dbo.MSdistributor_access
				 where (publication_id = @publication_id 
						or (agent_type = 0 -- Distribution agents 
							and agent_id in 
							(select agent_id from dbo.MSsubscriptions s
							  where s.publication_id = @publication_id)))
				   and db_id = db_id()
				if @@error <> 0
					return(1)
			end
		end
	end -- end drop operation
	else if @operation = N'check'
	begin
		--
		-- We should always have a valid SID for any kind of login (provisioned or not)
		-- If there is not valid SID then it is a bad login
		--
		if (@sid is null)
		begin
			raiserror(15007, 16, -1, @login)
			return (1)
		end
		--
		-- Check the access list for this login
		-- The query below does the PAL check implicitly
		-- so there is no security hole
		-- Check if the login is NT user
		--
		if @isntuser = 1
		begin
			--
			-- PAL check using SID or #groupsids
			--
			if exists (select * from dbo.MSpublication_access l 
							where publication_id = @publication_id 
							-- Either the SID of @login exists
							and (l.sid = @sid 
							-- Or there exists a group SID of which @login is a member of
								or exists (select g.sid 
													from #groupsids as g 
														join dbo.MSpublication_access as pa
															on g.sid = pa.sid
													where pa.publication_id = @publication_id)))
			begin
				-- the given login has PAL access
				set @has_access = 1 
			end
			else
			begin
				-- No PAL access
				set @has_access = 0            
			end
			-- drop temp table
			drop table #groupsids
		end -- if @isntuser = 1
		else
		begin
			--
			-- PAL check using SID
			--
			if exists (select * from dbo.MSpublication_access where publication_id = @publication_id and sid = @sid)
				set @has_access = 1 
			else
				set @has_access = 0
		end
	end -- end check operation
	else if @operation = N'help'
	begin
		select login 
		from dbo.MSpublication_access 
		where publication_id = @publication_id 
			and login is not null
			and suser_sid(login, 0) is not NULL
			and sid = suser_sid(login, 0)
			and (sid = @sid 
					OR @login = N'%'
					OR @login is NULL)
	end -- end help operation
	else if @operation = N'get_publications'
	begin
		--
		-- We should always have a valid SID for any kind of login (provisioned or not)
		-- If there is not valid SID then it is a bad login
		--
		if (@sid is null)
		begin
			raiserror(15007, 16, -1, @login)
			return (1)
		end
		--
		-- The query is doing PAL check implicitly
		-- Only the publications that have this login in the 
		-- access list will be returned. So there is no
		-- security hole here
		-- Check if the login is valid NT user
		--
		if @isntuser = 1
		begin
			--
			-- query using SID or #groupsids
			--
			select p.publisher_db, p.publication 
			from dbo.MSpublication_access as l
				join dbo.MSpublications as p
					on l.publication_id = p.publication_id
			where p.publisher_id = @publisher_id 
				-- Either the SID of @login exists
				and (l.sid = @sid 
							-- Or there exists a group SID of which @login is a member of
								or exists (select g.sid 
													from #groupsids as g 
														join dbo.MSpublication_access as pa
															on g.sid = pa.sid
														join dbo.MSpublications as pp
															on pa.publication_id = pp.publication_id
													where pp.publisher_id = @publisher_id))                    
			-- drop temp table
			drop table #groupsids
		end
		else
		begin
			--
			-- query using SID
			--
			select p.publisher_db, p.publication 
			from dbo.MSpublication_access as l
				join dbo.MSpublications as p
					on l.publication_id = p.publication_id
			where p.publisher_id = @publisher_id and l.sid = @sid
		end
	end -- end get_publications operation
	else if @operation = N'get_logins'
	begin
		select loginname from master.dbo.syslogins where hasaccess = 1
	end -- end get_logins operation
	--
	-- all done
	--
	return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSpublication_access] TO [public] AS [dbo]
GO
