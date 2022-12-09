SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSget_agent_names]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSget_agent_names] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSget_agent_names]
	@publication [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname],
	@publisher [sysname],
	@publisher_db [sysname]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	declare @retcode int

	if @publisher is null
	begin
		--
		-- We are at the publisher side
		--
		declare @distributor sysname
		declare @distribdb sysname
		declare @distproc nvarchar(1000), @pubdb sysname
		--
		-- do the publish security check
		--
		exec @retcode = sp_MSreplcheck_publish
		if @retcode <> 0 or @@error <> 0
			return 1
		--
		-- call into the distributor. Get distribution server information 
		-- for remote RPC agent verification.
		--
		select @pubdb = db_name()
		EXEC @retcode = sys.sp_MSrepl_getdistributorinfo @rpcsrvname = @distributor OUTPUT,
			@distribdb = @distribdb OUTPUT
		IF @@error <> 0 OR @retcode <> 0
		BEGIN
			RAISERROR (14071, 16, -1)
			RETURN (1)
		END
		--
		-- Call proc to change the distributor
		--
		select @publisher = publishingservername()
		SELECT @distproc = QUOTENAME(RTRIM(@distributor)) + '.' + QUOTENAME(@distribdb) + 
			'.sys.sp_MSget_agent_names'
		exec @retcode = @distproc 
			@publisher = @publisher,
			@publisher_db = @pubdb,
			@publication = @publication,
			@subscriber = @subscriber,
			@subscriber_db = @subscriber_db
	end
	else
	begin
		--
		-- We are at the distribution db
		--
		declare @publisher_id smallint

		--
		-- Do the security check - should be db_owner()
		--
		if (is_srvrolemember('sysadmin') <> 1  and is_member('db_owner') <> 1)
		begin
			raiserror(21050, 14, -1)
			return (1)
		end

	exec sys.sp_MSget_server_portinfo 
		@name = @publisher, 
		@srvname = @publisher OUTPUT

        --
        -- Get the publisher id
        --
        select @publisher_id = srvid from MSreplservers where UPPER(srvname collate database_default) = UPPER(@publisher) collate database_default
        if @subscriber is null
        -- Returning publication agents if @subscriber is null
        begin
            declare @snapshot_agent sysname, @logreader_agent sysname, @qreader_agent sysname
            
            -- Have to use name in sysjobs table because users may rename
            -- the SQLServerAgent jobs. If users deleted the jobs, DMO scripting will
            -- create new jobs.

			select 
				'snapshot_agent' = (select j.name from MSsnapshot_agents a, msdb.dbo.sysjobs j where
					publisher_id = @publisher_id and
					publisher_db = @publisher_db collate database_default and
					publication = @publication collate database_default and
					a.job_id = j.job_id and a.dynamic_filter_login = NULL and a.dynamic_filter_hostname = NULL),
				'logreader_agent' = (select j.name from MSlogreader_agents a, msdb.dbo.sysjobs j where
					publisher_id = @publisher_id and
					publisher_db = @publisher_db collate database_default and
					a.job_id = j.job_id),
				'qreader_agent' = (select j.name from MSqreader_agents a, msdb.dbo.sysjobs j where
					a.job_id = j.job_id)
		end
		else
		begin
			exec sys.sp_MSget_server_portinfo 
				@name = @subscriber, 
				@srvname = @subscriber OUTPUT

            declare @subscriber_id smallint
            select @subscriber_id = srvid from MSreplservers where UPPER(srvname collate database_default) = UPPER(@subscriber) collate database_default
            declare @publication_type int, @independent_agent bit

			select @publication_type = publication_type, @independent_agent = independent_agent
				from MSpublications where 
					publisher_id = @publisher_id and
					publisher_db = @publisher_db and
					publication = @publication

			if @publication_type = 2
			-- Merge publication, get merge agent name
			begin
				select 'merge_agent' = j.name from dbo.MSmerge_agents a, msdb.dbo.sysjobs j where
					publisher_id = @publisher_id and
					publisher_db = @publisher_db collate database_default and
					publication = @publication collate database_default and
					subscriber_id = @subscriber_id and
					subscriber_db = @subscriber_db collate database_default and
					a.job_id = j.job_id
			end
			else
			begin
				select 'distribution_agent' = j.name from MSdistribution_agents a, msdb.dbo.sysjobs j where
					publisher_id = @publisher_id and
					publisher_db = @publisher_db collate database_default and
					(publication = @publication collate database_default or
					 publication = N'ALL' and @independent_agent = 0) and
					subscriber_id = @subscriber_id and
					subscriber_db = @subscriber_db collate database_default and
					a.job_id = j.job_id
			end
		end
	end -- If @publisher is null
	--
	-- all done
	--
end
GO
GRANT EXECUTE ON [sys].[sp_MSget_agent_names] TO [public] AS [dbo]
GO
