SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MScreatemergedynamicsnapshot]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MScreatemergedynamicsnapshot] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MScreatemergedynamicsnapshot]
	@publication [sysname]
WITH EXECUTE AS CALLER
AS
declare @retcode int
    declare @pub_uses_host_name_for_filtering bit
    declare @pub_uses_suser_sname_for_filtering bit
    declare @host_name sysname
    declare @suser_sname sysname
    declare @jobid uniqueidentifier
    declare @pubid uniqueidentifier
    declare @snapshot_location nvarchar(255)
    declare @partition_id int
    declare @when_generated datetime
    declare @got_applock int
    declare @wait_counter int
    declare @agentid int
    declare @timestamp timestamp

    /* 
    ** Security Check and parameter check for @publication
    */
    SELECT @pubid = NULL
    exec @retcode = sys.sp_MSmerge_validate_publication_presence @publication, NULL, NULL, @pubid output
    if @retcode <> 0 or @@error <> 0
        return 1

    set @pub_uses_host_name_for_filtering = 0
    set @pub_uses_suser_sname_for_filtering = 0
    select @host_name = NULL
    select @suser_sname = NULL
    exec sys.sp_MSget_dynamic_filtering_information @pubid = @pubid,
                @uses_host_name = @pub_uses_host_name_for_filtering OUTPUT,
                @uses_suser_sname = @pub_uses_suser_sname_for_filtering OUTPUT
    if @@error <> 0
        goto FAILURE

    if @pub_uses_host_name_for_filtering = 1
        select @host_name = HOST_NAME()

    if @pub_uses_suser_sname_for_filtering = 1
        select @suser_sname = SUSER_SNAME()

    -- find the partition id for the subscriber
    -- deriving the partition id here and not accepting it as a parameter (from the merge agent)
    -- helps in avoiding false identity.
    select @partition_id = -1
    exec @retcode = sys.sp_MSget_subscriber_partition_id 
                            @publication = @publication, 
                            @partition_id = @partition_id OUTPUT,
                            @maxgen_whenadded = NULL,
                            @host_name_override = @host_name,
                            @suser_sname_override = @suser_sname
    if @@error <> 0 or @retcode <> 0 or @partition_id = -1
    begin
        raiserror(20629, 16, -1)
        return 1
    end
    
    -- check if a job already exists for the given dynamic_filter_login and dynamic_filter_hostname
    select @jobid = NULL
    select @jobid = job_id, @agentid = agent_id from dbo.MSdynamicsnapshotjobs 
        where pubid = @pubid and 
              ((@suser_sname is NULL and dynamic_filter_login is NULL) or dynamic_filter_login = @suser_sname)  and
              ((@host_name is NULL and dynamic_filter_hostname is NULL) or dynamic_filter_hostname = @host_name)
    if (@jobid is NULL)
    begin
        -- we need to create the job here
        -- sp_MSaddmergedynamicsnapshotjob will select the location correctly if none is specified.
        select @snapshot_location = NULL
                
        -- set the frequency type of the job to 1 to indicate run on demand
        exec @retcode = sys.sp_MSaddmergedynamicsnapshotjob 
                            @publication = @publication, 
                            @dynamic_filter_login = @suser_sname, 
                            @dynamic_filter_hostname = @host_name, 
                            @dynamic_snapshot_location = @snapshot_location, 
                            @dynamic_snapshot_jobname = NULL, 
                            @dynamic_snapshot_jobid = @jobid OUTPUT, 
                            @frequency_type = 1,
                            @dynamic_snapshot_agentid = @agentid output,
                            @ignore_select = 1
        if @@error <> 0 or @retcode <> 0 or @jobid is NULL
        begin
            raiserror(20632, 16, -1)
            return 1
        end
    end
    else
    begin
        select @got_applock = -1
        -- now that the job exists check if someone else is running the dynamic snapshot now
        -- check this by attempting to obtain the dynamic snapshot applock with zero wait.
        exec @retcode = sys.sp_MSgetdynamicsnapshotapplock @publication, @partition_id, @got_applock OUTPUT, 0
        if @@error <> 0 or @retcode <> 0
            goto FAILURE

        -- if we got the applock it means that the job is not already running and hence we need to start it
        if @got_applock >= 0 
        begin
            exec @retcode = sys.sp_MSreleasedynamicsnapshotapplock @publication, @partition_id
            if @@error <> 0
                goto FAILURE
        end
        else
        begin
            -- if we did not get the applock wait for the applock till 2000. Once we get
            -- the applock check once more to see if the dynamic snapshot location has been updated.
            exec @retcode = sys.sp_MSgetdynamicsnapshotapplock @publication, @partition_id, @got_applock OUTPUT, 2000
            if @@error <> 0 or @retcode <> 0
                goto FAILURE
            if @got_applock >= 0
            begin
                exec @retcode = sys.sp_MSreleasedynamicsnapshotapplock @publication, @partition_id
                if @@error <> 0
                    goto FAILURE
                    
                select @snapshot_location = NULL
                select @snapshot_location = dynamic_snapshot_location from dbo.MSmerge_dynamic_snapshots where partition_id = @partition_id
                if @snapshot_location is not NULL
                begin
                    --select @dynamic_snapshot_location = @snapshot_location
                    select @snapshot_location, 0, 0x00000
                    return 0
                end
            end
        end
    end
    
    -- start the dynamic snapshot job on the distributor
    -- Get distributor information for RPC
    declare @rpcsrvname sysname
    declare @distributor sysname
    declare @distproc nvarchar(300)
    declare @distribdb sysname
    declare @retcode2 int
    declare @command nvarchar(1000)

    exec @retcode = sys.sp_MSrepl_getdistributorinfo @distributor = @distributor output,
                                           @distribdb = @distribdb output,
                                           @rpcsrvname = @rpcsrvname output
    if @@error <> 0 or @retcode <> 0
        goto FAILURE

    -- before starting the job get the max timestamp from the MSsnaphsot_history table so that
    -- we can look for history information higher than that timestamp
    select @distproc = quotename(rtrim(@rpcsrvname)) + '.' + quotename(@distribdb) + '.sys.sp_executesql '
    select @command = N' exec @retcode2 = ' + quotename(@distribdb) + '.sys.sp_MSgetmaxsnapshottimestamp ' + convert(nvarchar(11),@agentid) + ', @timestamp output'
    EXEC @retcode = @distproc @command, N'@timestamp timestamp output, @retcode2 int output', @retcode2=@retcode2 output, @timestamp=@timestamp output
    if @@error <> 0 or @retcode <> 0 or @retcode2 <> 0
    begin
        raiserror(20655, 16, -1)
        goto FAILURE
    end

    select @distproc = rtrim(@rpcsrvname) + N'.msdb.dbo.sp_start_job'    
    exec @retcode = @distproc @job_id = @jobid
    if @@error <> 0 or @retcode <> 0
    begin
        raiserror(20633, 16, -1)
        goto FAILURE
    end

    -- now return the the job id so that the merge agent can monitor the job
    select '', @agentid, @timestamp
    return 0
    
FAILURE:
    raiserror(20628, 16, -1)
    return 1 
GO
GRANT EXECUTE ON [sys].[sp_MScreatemergedynamicsnapshot] TO [public] AS [dbo]
GO
