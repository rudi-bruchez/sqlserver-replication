SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSaddmergedynamicsnapshotjob]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSaddmergedynamicsnapshotjob] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSaddmergedynamicsnapshotjob]
	@publication [sysname],
	@dynamic_filter_login [sysname],
	@dynamic_filter_hostname [sysname],
	@dynamic_snapshot_location [nvarchar](255),
	@dynamic_snapshot_jobname [sysname] OUTPUT,
	@dynamic_snapshot_jobid [uniqueidentifier] OUTPUT,
	@dynamic_job_step_uid [uniqueidentifier] OUTPUT,
	@frequency_type [int],
	@frequency_interval [int],
	@frequency_subday [int],
	@frequency_subday_interval [int],
	@frequency_relative_interval [int],
	@frequency_recurrence_factor [int],
	@active_start_date [int],
	@active_end_date [int],
	@active_start_time_of_day [int],
	@active_end_time_of_day [int],
	@dynamic_snapshot_agentid [int] OUTPUT,
	@ignore_select [bit]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on

    declare @retcode int
    declare @pubid uniqueidentifier
    declare @dynamic_filters bit
    declare @snapshot_jobid uniqueidentifier 
    declare @command_line nvarchar(4000)
    declare @publisher sysname
    declare @distribdb sysname
    declare @rpcsrvname sysname
    declare @distributor sysname
    declare @fjobcreated bit
    declare @distproc nvarchar(4000)
    declare @id int 
    declare @partition_id int
    declare @snapshot_ready int
    declare @computed_dynsnap_location bit

    -- Initializations
    select @retcode = 0
    select @pubid = null
    select @dynamic_filters = 0
    select @snapshot_jobid = null
    select @fjobcreated = 0

    if object_id('sysmergepublications') is NULL
    begin
        raiserror (20054, 16, -1)
        return (1)
    end

    -- Make sure that caller is a member of the PAL role if suser_sname is not specified
    -- since this just adds a dynamic snaphsot job and uses the credentials of
    -- the regular snapshot job to do this this is not going to cause problems
    -- the job is added on the distributor and the distributor_admin is the owner
    -- of the job anyway.
    -- PAL users may need to call this when they initiate a snapshot from the client
    -- and the job does not already exist for it.
    -- however we don't want the PAL user to schedule a job with someone else's
    -- suser_sname. We cannot any protect against hostname spoofing
    if (@dynamic_filter_login is NULL) or (suser_sname() = @dynamic_filter_login)
    begin
    	exec @retcode = sys.sp_MSrepl_PAL_rolecheck @publication = @publication
    	if @@error <> 0 or @retcode <> 0
    		return (1)
    end
    else
    begin
    	exec @retcode = sys.sp_MSreplcheck_publish
    	if @@error <> 0 or @retcode <> 0
    		return (1)
    		
    	-- Check that the given dynammic filter login is in the PAL
    	exec @retcode = sys.sp_check_publication_access
    		@publication = @publication,
    		@given_login = @dynamic_filter_login
    	if @retcode <> 0 or @@error <> 0
    		return 1
    end

    -- Verify that the given publication exists and get the pubid at the
    -- same time
    select @pubid = pubid,
           @dynamic_filters = dynamic_filters,
           @snapshot_ready = snapshot_ready
      from dbo.sysmergepublications
     where upper(publisher) = upper(publishingservername())
       and publisher_db = db_name()
       and name = @publication

    if @pubid is null
    begin
        raiserror(20026, 16, -1, @publication) 
        return (1)  
    end

    if @snapshot_ready <> 1
    begin
        raiserror (21075, 11, -1, @publication)
        return (1)
    end

    -- The given publication must be enabled for dynamic filtering
    if @dynamic_filters <> 1
    begin
        raiserror(20674, 16, -1)
        return (1)
    end
   
    exec @retcode = sys.sp_MScheck_dynamic_filtering_information 
                        @pubid = @pubid, 
                        @dynamic_filter_hostname = @dynamic_filter_hostname,
                        @dynamic_filter_login = @dynamic_filter_login
    if @@error <> 0 or @retcode <> 0
    begin
        return 1
    end

    -- A regular snapshot job is required before a dynamic snapshot job
    -- can be scheduled
    select @snapshot_jobid = snapshot_jobid from dbo.sysmergepublications
     where pubid = @pubid
    if @snapshot_jobid is null
    begin
        raiserror(21324, 16, -1)
        return (1)
    end

    -- The given dynamic snapshot job name cannot be '%' and it cannot match
    -- any of the existing dynamic snapshot job name
    if @dynamic_snapshot_jobname = '%'
    begin
    	raiserror(21327, 16, -1)
    	return (1)
    end

    if exists (select * 
                from MSdynamicsnapshotjobs 
                where name = @dynamic_snapshot_jobname)
    begin
        raiserror(21328, 16, -1, @dynamic_snapshot_jobname)
        return (1)
    end	   

    -- check to make sure that the login and hostname map to a valid partition id
    select @partition_id = -1
    exec @retcode = sys.sp_MSget_subscriber_partition_id 
                            @publication = @publication, 
                            @partition_id = @partition_id OUTPUT,
                            @maxgen_whenadded = NULL,
                            @host_name_override = @dynamic_filter_hostname,
                            @suser_sname_override = @dynamic_filter_login
    if @@error <> 0 or @retcode <> 0 or @partition_id is NULL or @partition_id = -1
    begin
        raiserror(20629, 16, -1)
        return 1
    end

    select @dynamic_snapshot_location = ltrim(@dynamic_snapshot_location)
    -- Specified @dynamic_snapshot_location must be non-empty
    if @dynamic_snapshot_location is null or 
       @dynamic_snapshot_location = N''
    begin
        --raiserror(21321, 16, -1)		 
        --return (1)
        -- if the dynamic snapshot location is empty choose the location based on the publication information
        exec @retcode = sys.sp_MSgetpartitionsnapshotfolder 
                                    @publication, 
                                    @dynamic_filter_login, 
                                    @dynamic_filter_hostname,
                                    @partition_id,
                                    @dynamic_snapshot_location output
        if @@error <> 0 or @retcode <> 0
        begin
            raiserror(20631, 16, -1)
            return 1
        end
        select @computed_dynsnap_location = 1
    end
    else
    begin
        select @computed_dynsnap_location = 0
    end


    -- Get distributor information for RPC
    exec @retcode = sys.sp_MSrepl_getdistributorinfo @distributor = @distributor output,
                                           @distribdb = @distribdb output,
                                           @rpcsrvname = @rpcsrvname output
    if @@error <> 0 or @retcode <> 0
        return (1)

    if exists (select * 
                from MSdynamicsnapshotjobs 
                where pubid = @pubid and 
                ((@dynamic_filter_login is NULL and dynamic_filter_login is NULL) or dynamic_filter_login = @dynamic_filter_login)  and
                ((@dynamic_filter_hostname is NULL and dynamic_filter_hostname is NULL) or dynamic_filter_hostname = @dynamic_filter_hostname))
    begin
        declare @dynamic_snap_jobid uniqueidentifier
        declare @publisher_db sysname
        
        select @dynamic_snap_jobid = null
        select @publisher_db = db_name()
        
        select @distproc = QUOTENAME(rtrim(@rpcsrvname)) + N'.' + QUOTENAME(@distribdb) + N'.' + N'dbo.sp_MSdynamicsnapshotjobexistsatdistributor'

        select @publisher = publishingservername()
        exec @retcode = @distproc 
                @publisher = @publisher,
                @publisher_db = @publisher_db,
                @publication = @publication,
                @dynamic_filter_login = @dynamic_filter_login,
                @dynamic_filter_hostname = @dynamic_filter_hostname,
                @dynamic_snapshot_jobid = @dynamic_snap_jobid output

        if @retcode <> 0 or @@error <> 0
            goto Failure

        if (@dynamic_snap_jobid is not null)
        begin
	     raiserror(20630, 16, -1, @publication)
            return (1)
        end

        exec sp_dropdynamicsnapshot_job @publication = @publication,
            @dynamic_snapshot_jobname = '%',
            @dynamic_snapshot_jobid = @dynamic_snap_jobid
    end
    
    select @distproc = QUOTENAME(rtrim(@rpcsrvname)) + N'.' + QUOTENAME(@distribdb) + N'.' + N'dbo.sp_MSadddynamicsnapshotjobatdistributor'

    exec @retcode = @distproc 
        @regular_snapshot_jobid = @snapshot_jobid,
        @dynamic_filter_login = @dynamic_filter_login,
        @dynamic_filter_hostname = @dynamic_filter_hostname,
        @dynamic_snapshot_location = @dynamic_snapshot_location,
        @dynamic_snapshot_jobname = @dynamic_snapshot_jobname output,
        @dynamic_snapshot_jobid = @dynamic_snapshot_jobid output,
        @dynamic_snapshot_job_step_uid = @dynamic_job_step_uid output,
        @freqtype = @frequency_type,
        @freqinterval = @frequency_interval,
        @freqsubtype = @frequency_subday,
        @freqsubinterval = @frequency_subday_interval,
        @freqrelativeinterval = @frequency_relative_interval,
        @freqrecurrencefactor = @frequency_recurrence_factor,
        @activestartdate = @active_start_date,
        @activeenddate = @active_end_date,
        @activestarttimeofday = @active_start_time_of_day,
        @activeendtimeofday = @active_end_time_of_day,
        @dynamic_snapshot_agent_id = @dynamic_snapshot_agentid output,
        @partition_id = @partition_id

    if @retcode <> 0 or @@error <> 0
        goto Failure

    select @fjobcreated = 1

    insert MSdynamicsnapshotjobs 
    (name, pubid, job_id, agent_id, dynamic_filter_login, dynamic_filter_hostname, 
     dynamic_snapshot_location, partition_id, computed_dynsnap_location)
    values
    (@dynamic_snapshot_jobname, @pubid, @dynamic_snapshot_jobid, @dynamic_snapshot_agentid,
     @dynamic_filter_login, @dynamic_filter_hostname, 
     @dynamic_snapshot_location, @partition_id, @computed_dynsnap_location)	

    if @@error <> 0
    begin
        goto Failure
    end

    select @id = @@identity	   

    if @ignore_select = 0
        select 'id'                       = @id,
               'dynamic_snapshot_jobname' = @dynamic_snapshot_jobname,
               'dynamic_snapshot_jobid'   = @dynamic_snapshot_jobid
    return 0

Failure:
    if @fjobcreated = 1
    begin
        select @distproc = quotename(rtrim(@rpcsrvname)) + N'.' + quotename(@distribdb) + N'.' + N'dbo.sp_MSdrop_repl_job'
        exec @distproc @job_id = @dynamic_snapshot_jobid, @job_step_uid = @dynamic_job_step_uid
    end
    return @retcode
end
GO
GRANT EXECUTE ON [sys].[sp_MSaddmergedynamicsnapshotjob] TO [public] AS [dbo]
GO
