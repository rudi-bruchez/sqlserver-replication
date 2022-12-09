SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MShelp_snapshot_agentid]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MShelp_snapshot_agentid] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MShelp_snapshot_agentid]
	@publisher_id [smallint],
	@publisher_db [sysname],
	@publication [sysname],
	@job_id [binary](16),
	@dynamic_snapshot_location [nvarchar](255),
	@dynamic_filter_login [sysname],
	@dynamic_filter_hostname [sysname]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on
	declare @retcode int
				,@publisher sysname
				,@description nvarchar(255)
				,@new_password nvarchar(524)

	--
	-- security check
	-- only db_owner can execute this
	--
	if (is_member ('db_owner') != 1) 
	begin
		raiserror(14260, 16, -1)
		return (1)
	end
	if @dynamic_filter_login = N''
		select @dynamic_filter_login = NULL

	if @dynamic_filter_hostname = N''
		select @dynamic_filter_hostname = NULL

    if @dynamic_filter_login is NULL and @dynamic_filter_hostname is NULL
    begin
        -- Check if agent exists, if not and there is an 6.x tasks then create one
        if @publication is not null and @publication <> '' and not exists (select * from MSsnapshot_agents where
                publisher_id = @publisher_id and
                publisher_db = @publisher_db and
                publication = @publication and
                dynamic_filter_login is NULL  and
                dynamic_filter_hostname is NULL)
        begin
            -- Do it only if the agent name is valid. It will be the case if
            -- the agent is launched by SQL Server Agent
            if exists (select * from msdb.dbo.sysjobs_view where
                job_id = @job_id)
            begin
                select @publisher = srvname from MSreplservers where srvid = @publisher_id
                begin tran
                exec @retcode = sys.sp_MSadd_snapshot_agent
                    @publisher = @publisher, 
                    @publisher_db = @publisher_db,
                    @publication = @publication,
                    @local_job = 1,
                    @job_existing = 1,
                    @snapshot_jobid = @job_id,
                    @internal = N'YUKON'
                if @@ERROR<> 0 or @retcode <> 0
                    goto UNDO

				-- Add a publication definition so it shows up in monitoring procs
				set @description = formatmessage(20555)
				exec @retcode = sys.sp_MSadd_publication
					@publisher = @publisher,
					@publisher_db = @publisher_db,
					@publication = @publication,
					@publication_type = 1,              -- Make all 6.x pubs transactional
					@description = @description       -- 6.x publication description

				if @@ERROR<> 0 or @retcode <> 0
					goto UNDO
				commit tran
			end
		end

		select id, name from MSsnapshot_agents  where 
			publisher_id = @publisher_id and
			publisher_db = @publisher_db and
			publication = @publication and
			dynamic_filter_login is NULL and
			dynamic_filter_hostname is NULL
	end
	else
	begin
		if @publication is not null and 
		   @publication <> '' and 
		   not exists (select * from MSsnapshot_agents where
						publisher_id = @publisher_id and
						publisher_db = @publisher_db and
						publication = @publication and
						((@dynamic_filter_login is NULL and dynamic_filter_login is NULL) or dynamic_filter_login = @dynamic_filter_login)  and
						((@dynamic_filter_hostname is NULL and dynamic_filter_hostname is NULL) or dynamic_filter_hostname = @dynamic_filter_hostname))
		begin
			-- add an agent for the dynamic snapshot
			declare @regular_snapshot_jobid uniqueidentifier
			declare @dynamic_jobname sysname
			declare @dynamic_jobid uniqueidentifier
			declare @dynamic_job_step_uid uniqueidentifier
			declare @local_job bit
			declare @publication_type int
			declare @profile_id int
			
			select @regular_snapshot_jobid = job_id, 
				   @local_job = local_job, 
				   @publication_type = publication_type, 
				   @profile_id = profile_id from MSsnapshot_agents 
				  where publisher_id = @publisher_id and
						publisher_db = @publisher_db and
						publication = @publication and
						dynamic_filter_login is NULL and
						dynamic_filter_hostname is NULL

			if (@local_job = 1)
			begin
				exec @retcode = sys.sp_MSadddynamicsnapshotjobatdistributor @regular_snapshot_jobid, @dynamic_filter_login, @dynamic_filter_hostname, @dynamic_snapshot_location, @dynamic_jobname output, @dynamic_jobid output, @dynamic_job_step_uid output
				if @retcode <> 0 or @@error <> 0
					return 1
			end
			else
			begin
				SELECT @new_password = newid()

				EXEC @retcode = sys.sp_MSreplencrypt @new_password OUTPUT
				IF @@error <> 0 or @retcode <> 0
					RETURN (1)

				if @publication_type is NULL
				begin
					raiserror(20678, 16, -1)
					return (1)
				end
				select @dynamic_jobname = N'No job yet'
				INSERT INTO MSsnapshot_agents (name, publisher_id, publisher_db, publication, publication_type,
										local_job, profile_id, dynamic_filter_login, dynamic_filter_hostname,
										publisher_security_mode, publisher_login, publisher_password)
					 VALUES (@dynamic_jobname,@publisher_id, @publisher_db, @publication, @publication_type, 
								@local_job, @profile_id, @dynamic_filter_login, @dynamic_filter_hostname,
								1, NULL, @new_password)
				if @@error <> 0
					return 1
			end
		end
		select id, name from MSsnapshot_agents  where 
			publisher_id = @publisher_id and
			publisher_db = @publisher_db and
			publication = @publication and
			((@dynamic_filter_login is NULL and dynamic_filter_login is NULL) or dynamic_filter_login = @dynamic_filter_login)  and
			((@dynamic_filter_hostname is NULL and dynamic_filter_hostname is NULL) or dynamic_filter_hostname = @dynamic_filter_hostname)
	end
	
	return(0)

UNDO:
	if @@TRANCOUNT = 1
		ROLLBACK TRAN
	else
		COMMIT TRAN
	return(1)
end
GO
GRANT EXECUTE ON [sys].[sp_MShelp_snapshot_agentid] TO [public] AS [dbo]
GO
