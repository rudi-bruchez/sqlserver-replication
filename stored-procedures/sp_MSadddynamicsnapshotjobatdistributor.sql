SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSadddynamicsnapshotjobatdistributor]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSadddynamicsnapshotjobatdistributor] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSadddynamicsnapshotjobatdistributor]
	@regular_snapshot_jobid [uniqueidentifier],
	@dynamic_filter_login [sysname],
	@dynamic_filter_hostname [sysname],
	@dynamic_snapshot_location [nvarchar](255),
	@dynamic_snapshot_jobname [nvarchar](128) OUTPUT,
	@dynamic_snapshot_jobid [uniqueidentifier] OUTPUT,
	@dynamic_snapshot_job_step_uid [uniqueidentifier] OUTPUT,
	@freqtype [int],
	@freqinterval [int],
	@freqsubtype [int],
	@freqsubinterval [int],
	@freqrelativeinterval [int],
	@freqrecurrencefactor [int],
	@activestartdate [int],
	@activeenddate [int],
	@activestarttimeofday [int],
	@activeendtimeofday [int],
	@dynamic_snapshot_agent_id [int] OUTPUT,
	@partition_id [int]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	declare @retcode int
	declare @agent_command_line nvarchar(4000)
	declare @agent_id int
	declare @db_name sysname    
	declare @category_name sysname
	declare @nullchar nchar(20)
	declare @publisher_id int
	declare @publication sysname
	declare @publisher_db sysname
	declare @publication_type int
	declare @local_job bit
	declare @profile_id int
	declare @dynamicfilterloginparam nvarchar(50)
	declare @dynamicfilterhostnameparam nvarchar(50)
	declare @dynamicsnapshotlocationparam nvarchar(50)
	declare @proxy_id int
	declare @publisher_security_mode int
	declare @publisher_login sysname
	declare @publisher_password nvarchar(524)
	declare @next_agent_id int
	
	--
	-- security check
	-- only db_owner can execute this
	--
	if (is_member ('db_owner') != 1) 
	begin
		raiserror(14260, 16, -1)
		return (1)
	end
	--
	-- security check
	-- Has to be executed from distribution database
	--
	if (sys.fn_MSrepl_isdistdb (db_name()) != 1)
	begin
		raiserror(21482, 16, -1, 'sp_MSadddynamicsnapshotjobatdistributor', 'distribution')
		return (1)
	end

	select @retcode = 0
	select @agent_command_line = null
	select @agent_id = null
	select @db_name = db_name()
	select @category_name = name 
	  from msdb.dbo.syscategories 
	 where category_id = 15
	select @nullchar = null

	select @dynamicfilterloginparam = N' -DynamicFilterLogin '
	select @dynamicfilterhostnameparam = N' -DynamicFilterHostName '
	select @dynamicsnapshotlocationparam = N' -DynamicSnapshotLocation '

	-- Get the regular snapshot agent command line
	select @agent_command_line = command,
			@proxy_id = proxy_id
	  from msdb.dbo.sysjobsteps
	 where job_id = @regular_snapshot_jobid
	   and subsystem = N'Snapshot'
	   and step_id = 2
		
	if @agent_command_line is null
	begin
		raiserror(21319, 11, -1)        
		return 1        
	end  
	
	-- Get the publication details from the agent for regular snapshot  
	select @agent_id = id,
		   @publisher_id = publisher_id,
		   @publication = publication,
		   @publisher_db = publisher_db,
		   @publication_type = publication_type,
		   @local_job = local_job,
		   @profile_id = profile_id,
		   @publisher_security_mode = publisher_security_mode,
		   @publisher_login = publisher_login,
		   @publisher_password = publisher_password
	  from MSsnapshot_agents
	 where job_id = @regular_snapshot_jobid

	if @agent_id is null
	begin
		raiserror(21325, 11, -1)
		return 1
	end

	if @local_job = 0
	begin
		raiserror(21325, 11, -1)
		return 1
	end

	if @publication_type <> 2
	begin
		raiserror(20654, 16, -1)
		return 1
	end

	if @dynamic_filter_login is NULL and @dynamic_filter_hostname is NULL
	begin
		raiserror(20653, 16, -1)
		return 1
	end


	BEGIN TRAN

	-- need to do this so that ident_current does not change after the read and insert
	select @next_agent_id = IDENT_CURRENT('MSsnapshot_agents') + 1

	if @dynamic_snapshot_jobname is null or @dynamic_snapshot_jobname = N''
	begin
		-- Get the job name of the regular snapshot job. This is going to be used
		-- to derive a uniquefied job name for the dynamic snapshot job
		select @dynamic_snapshot_jobname = name 
		  from msdb.dbo.sysjobs 
		 where job_id = @regular_snapshot_jobid
	
		--select @dynamic_snapshot_jobname = N'dyn_' + left(@dynamic_snapshot_jobname,88) + convert(nvarchar(36), newid()) 
		select @dynamic_snapshot_jobname = N'dyn_' + left(@dynamic_snapshot_jobname,80) + '_' +
											left(isnull(@dynamic_filter_login,''), 16) + '_' +
											left(isnull(@dynamic_filter_hostname,''), 16) + '_' +
											convert(nvarchar(11), @next_agent_id)
	end

	-- the dynamic snapshot job should have different agent id other than the regular snapshot job
	-- so create an agent id if one does not exist
	if not exists (select * from MSsnapshot_agents where
		publisher_id = @publisher_id and
		publisher_db = @publisher_db and
		publication = @publication and
		((@dynamic_filter_login is NULL and dynamic_filter_login is NULL) or dynamic_filter_login = @dynamic_filter_login)  and
		((@dynamic_filter_hostname is NULL and dynamic_filter_hostname is NULL) or dynamic_filter_hostname = @dynamic_filter_hostname))
	begin
		/* 
		** Insert row
		*/
		INSERT INTO MSsnapshot_agents (name, publisher_id, publisher_db, publication, publication_type,
										local_job, profile_id, dynamic_filter_login, dynamic_filter_hostname,
										publisher_security_mode, publisher_login, publisher_password)
				VALUES (@dynamic_snapshot_jobname,@publisher_id, @publisher_db, @publication, @publication_type, 
						@local_job, @profile_id, @dynamic_filter_login, @dynamic_filter_hostname,  
						@publisher_security_mode, @publisher_login, @publisher_password)
		IF @@ERROR <> 0
			goto UNDO

		set @dynamic_snapshot_agent_id = @@IDENTITY
	end
	else
		select @dynamic_snapshot_agent_id = id from MSsnapshot_agents where
			publisher_id = @publisher_id and
			publisher_db = @publisher_db and
			publication = @publication and
			((@dynamic_filter_login is NULL and dynamic_filter_login is NULL) or dynamic_filter_login = @dynamic_filter_login)  and
			((@dynamic_filter_hostname is NULL and dynamic_filter_hostname is NULL) or dynamic_filter_hostname = @dynamic_filter_hostname)

	if @dynamic_filter_login is not null and @dynamic_filter_login <> N''
	begin
		select @agent_command_line = @agent_command_line + @dynamicfilterloginparam + QUOTENAME(rtrim(@dynamic_filter_login)) 
	end

	if @dynamic_filter_hostname is not null and @dynamic_filter_hostname <> N''
	begin
		select @agent_command_line = @agent_command_line + @dynamicfilterhostnameparam + QUOTENAME(rtrim(@dynamic_filter_hostname)) 
	end

	-- @dynamic_snapshot_location is assumed to be non-empty
	select @agent_command_line = @agent_command_line + @dynamicsnapshotlocationparam + QUOTENAME(@dynamic_snapshot_location)
	

	-- Add partition id if it is not null
	if @partition_id is not null
	begin
		select @agent_command_line = @agent_command_line + N' -PartitionId ' + convert(nvarchar(10), @partition_id) 
	end

	-- Add the job
	exec @retcode = dbo.sp_MSadd_repl_job
		 @name = @dynamic_snapshot_jobname,
		 @subsystem = 'Snapshot',
		 @server = @@servername,
		 @databasename = @db_name,
		 @enabled = 1,
		 @freqtype = @freqtype,
		 @freqinterval = @freqinterval,
		 @freqsubtype = @freqsubtype,
		 @freqsubinterval = @freqsubinterval,
		 @freqrecurrencefactor = @freqrecurrencefactor,
		 @activestartdate = @activestartdate,
		 @activeenddate = @activeenddate,
		 @activestarttimeofday = @activestarttimeofday,
		 @activeendtimeofday = @activeendtimeofday,
		 @nextrundate = 0,
		 @nextruntime = 0,
		 @runpriority = 0,
		 @emailoperatorname = @nullchar,
		 @retryattempts = 10,
		 @retrydelay = 1,
		 @command = @agent_command_line,
		 @loghistcompletionlevel = 0,
		 @emailcompletionlevel = 0,
		 @description = @nullchar,
		 @tagobjectid = 0,
		 @tagobjecttype = 0,
		 @category_name = @category_name,
		 @failure_detection = 1,
		 @agent_id = @dynamic_snapshot_agent_id,
		 @proxy_id = @proxy_id,
		 @job_id = @dynamic_snapshot_jobid OUTPUT,
		 @job_step_uid = @dynamic_snapshot_job_step_uid OUTPUT

	if @retcode <> 0 or @@error <> 0
		goto UNDO
	
	update MSsnapshot_agents 
		set job_id = @dynamic_snapshot_jobid, 
			name = @dynamic_snapshot_jobname, 
			local_job = @local_job,
			job_step_uid = @dynamic_snapshot_job_step_uid
		where id = @dynamic_snapshot_agent_id
	if @@error <> 0
		goto UNDO
	
	COMMIT TRAN

	RETURN(0)

UNDO:
	if @@TRANCOUNT = 1
		ROLLBACK TRAN
	else
		COMMIT TRAN
	return(1)
end
GO
GRANT EXECUTE ON [sys].[sp_MSadddynamicsnapshotjobatdistributor] TO [public] AS [dbo]
GO
