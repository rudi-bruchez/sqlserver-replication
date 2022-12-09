SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_helpdynamicsnapshot_job]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_helpdynamicsnapshot_job] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_helpdynamicsnapshot_job]
	@publication [sysname],
	@dynamic_snapshot_jobname [sysname],
	@dynamic_snapshot_jobid [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
declare @retcode int


    exec @retcode = sys.sp_MSreplcheck_publish
    if @@error <> 0 or @retcode <> 0
        return (1)

    declare @dynamic_snapshot_jobs table
    (   id int,
        agent_id int,
        job_name sysname,
        job_id uniqueidentifier,
        suser_sname sysname NULL,
        host_name sysname NULL,
        dynamic_snapshot_location nvarchar(255),
        frequency_type int,
        frequency_interval int,
        frequency_subday int,
        frequency_subday_interval int,
        frequency_relative_interval int, 
        frequency_recurrence_factor int,
        active_start_date int,
        active_end_date int,
        active_start_time_of_day int, 
        active_end_time_of_day int,
        pubid uniqueidentifier
    )
    declare @frequency_type                 int
    declare @frequency_interval             int
    declare @frequency_subday               int
    declare @frequency_subday_interval      int
    declare @frequency_relative_interval    int
    declare @frequency_recurrence_factor    int
    declare @active_start_date              int
    declare @active_end_date                int
    declare @active_start_time_of_day       int
    declare @active_end_time_of_day         int
    declare @publisher sysname
    declare @publisher_db sysname
    declare @suser_sname sysname
    declare @host_name sysname
    declare @id int
    declare @distributor sysname
    declare @distribdb sysname
    declare @rpcsrvname sysname
    declare @distproc nvarchar(4000)
    declare @publication_cursor sysname
    declare @pubid uniqueidentifier

    select @publisher = publishingservername()
    select @publisher_db = db_name()

    insert @dynamic_snapshot_jobs
    (id, agent_id, job_name, job_id, suser_sname, host_name, dynamic_snapshot_location, pubid)
    select j.id,
           j.agent_id,
           j.name,
           j.job_id, 
           j.dynamic_filter_login,
           j.dynamic_filter_hostname,
           j.dynamic_snapshot_location,
           j.pubid
      from dbo.sysmergepublications p
     inner join MSdynamicsnapshotjobs j
        on p.pubid = j.pubid
     where (p.name = @publication or @publication = N'%')
       and (j.name = @dynamic_snapshot_jobname or @dynamic_snapshot_jobname = N'%')
       and (j.job_id = @dynamic_snapshot_jobid or @dynamic_snapshot_jobid is null)     

    -- Get distributor information for RPC
    exec @retcode = sys.sp_MSrepl_getdistributorinfo @distributor = @distributor output,
                                           @distribdb = @distribdb output,
                                           @rpcsrvname = @rpcsrvname output
    if @@error <> 0 or @retcode <> 0
        return (1)

    select @distproc = quotename(rtrim(@rpcsrvname)) + N'.' + quotename(@distribdb) + N'.' + N'dbo.sp_MShelpdynamicsnapshotjobatdistributor'

    declare hJobsCursor cursor local fast_forward for
        select id, suser_sname, host_name, pubid
          from @dynamic_snapshot_jobs 
    open hJobsCursor
    fetch hJobsCursor into @id, @suser_sname, @host_name, @pubid
    while (@@fetch_status <> -1)
    begin
        if @suser_sname is not null or @host_name is not NULL
        begin
            select @publication_cursor = name from dbo.sysmergepublications where pubid = @pubid
            exec @retcode = @distproc 
                @publisher = @publisher,
                @publisher_db = @publisher_db,
                @publication = @publication_cursor,
                @dynamic_filter_login = @suser_sname,
                @dynamic_filter_hostname = @host_name,
                @frequency_type = @frequency_type output,
                @frequency_interval = @frequency_interval output,
                @frequency_subday = @frequency_subday output,
                @frequency_subday_interval = @frequency_subday_interval output,
                @frequency_relative_interval = @frequency_relative_interval output,
                @frequency_recurrence_factor = @frequency_recurrence_factor output,
                @active_start_date = @active_start_date output,
                @active_end_date = @active_end_date output,
                @active_start_time_of_day = @active_start_time_of_day output,
                @active_end_time_of_day = @active_end_time_of_day output
            if @@error <> 0 or @retcode <> 0
                goto Failure

            update @dynamic_snapshot_jobs
            set frequency_type = @frequency_type,
                frequency_interval = @frequency_interval,
                frequency_subday = @frequency_subday,
                frequency_subday_interval = @frequency_subday_interval,
                frequency_relative_interval = @frequency_relative_interval, 
                frequency_recurrence_factor = @frequency_recurrence_factor,
                active_start_date = @active_start_date,
                active_end_date = @active_end_date,
                active_start_time_of_day = @active_start_time_of_day, 
                active_end_time_of_day = @active_end_time_of_day
            where id = @id
            if @@error <> 0
                goto Failure
        end
        fetch hJobsCursor into @id, @suser_sname, @host_name, @pubid
    end
    close hJobsCursor
    deallocate hJobsCursor

    select id, job_name, job_id, suser_sname, host_name, dynamic_snapshot_location,
           frequency_type,
           frequency_interval,
           frequency_subday,
           frequency_subday_interval,
           frequency_relative_interval, 
           frequency_recurrence_factor,
           active_start_date,
           active_end_date,
           active_start_time_of_day, 
           active_end_time_of_day 
    from @dynamic_snapshot_jobs

    return 0
    
Failure:
    close hJobsCursor
    deallocate hJobsCursor

    return 1
    
GO
GRANT EXECUTE ON [sys].[sp_helpdynamicsnapshot_job] TO [public] AS [dbo]
GO
