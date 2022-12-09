SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_changedynamicsnapshot_job]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_changedynamicsnapshot_job] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_changedynamicsnapshot_job]
	@publication [sysname],
	@dynamic_snapshot_jobname [sysname],
	@dynamic_snapshot_jobid [uniqueidentifier],
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
	@job_login [nvarchar](257),
	@job_password [sysname]
WITH EXECUTE AS CALLER
AS
set nocount on

    declare @retcode int
    declare @pubid uniqueidentifier
    declare @dynamic_filters bit
    declare @command_line nvarchar(4000)
    declare @distribdb sysname
    declare @rpcsrvname sysname
    declare @distributor sysname
    declare @distproc nvarchar(4000)
    declare @id int 
    declare @partition_id int
    declare @snapshot_ready int
    declare @agent_id int
    declare @dynamic_snapshot_jobid_from_cursor uniqueidentifier

    -- Initializations
    select @retcode = 0
    select @pubid = null
    select @dynamic_filters = 0

    
    exec @retcode = sys.sp_MSreplcheck_publish
    if @@error <> 0 or @retcode <> 0
        return (1)


    if object_id('sysmergepublications') is NULL
    begin
        raiserror (20054, 16, -1)
        return (1)
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
    
    -- At most one of @dynamic_snapshot_jobid and @dynamic_snapshot_jobname
    -- can be specified with a non-default value
    if @dynamic_snapshot_jobid is not null and
       @dynamic_snapshot_jobname <> N'%'
    begin
        raiserror(21329, 16, -1)
        return (1)
    end

    if @dynamic_snapshot_jobid is null and @dynamic_snapshot_jobname = N'%'
    begin

        declare hJobsCursor cursor local fast_forward for
            select job_id 
              from MSdynamicsnapshotjobs 
              where pubid = @pubid
        if @@error <> 0
            return 1

        open hJobsCursor 
        if @@error <> 0
            return 1


        fetch hJobsCursor into @dynamic_snapshot_jobid_from_cursor 
          
        begin transaction
        save transaction sp_MSchangedynamicsnapshotjobC

        while (@@fetch_status <> -1)
        begin
            if @dynamic_snapshot_jobid_from_cursor is not null
            begin
                exec @retcode = sys.sp_MSchangemergedynamicsnapshotjob 
                                    @publication = @publication,
                                    @dynamic_snapshot_jobid = @dynamic_snapshot_jobid_from_cursor,
                                    @frequency_type = @frequency_type,
                                    @frequency_interval = @frequency_interval,
                                    @frequency_subday = @frequency_subday,
                                    @frequency_subday_interval = @frequency_subday_interval,
                                    @frequency_relative_interval = @frequency_relative_interval,
                                    @frequency_recurrence_factor = @frequency_recurrence_factor,
                                    @active_start_date = @active_start_date,
                                    @active_end_date = @active_end_date,
                                    @active_start_time_of_day = @active_start_time_of_day,
                                    @active_end_time_of_day = @active_end_time_of_day,
                                    @job_login = @job_login,
                                    @job_password = @job_password
                if @@error <> 0 or @retcode <> 0
                    goto CursorFailure
            end
            fetch hJobsCursor into @dynamic_snapshot_jobid_from_cursor
        end

        commit transaction
        close hJobsCursor
        deallocate hJobsCursor		  
        return 0
    CursorFailure:


        rollback transaction sp_MSchangedynamicsnapshotjobC
        commit transaction
        close hJobsCursor
        deallocate hJobsCursor
        return 1
    end
    else
    begin
        exec @retcode = sys.sp_MSchangemergedynamicsnapshotjob 
                            @publication = @publication,
                            @dynamic_snapshot_jobid = @dynamic_snapshot_jobid,
                            @dynamic_snapshot_jobname = @dynamic_snapshot_jobname,
                            @frequency_type = @frequency_type,
                            @frequency_interval = @frequency_interval,
                            @frequency_subday = @frequency_subday,
                            @frequency_subday_interval = @frequency_subday_interval,
                            @frequency_relative_interval = @frequency_relative_interval,
                            @frequency_recurrence_factor = @frequency_recurrence_factor,
                            @active_start_date = @active_start_date,
                            @active_end_date = @active_end_date,
                            @active_start_time_of_day = @active_start_time_of_day,
                            @active_end_time_of_day = @active_end_time_of_day,
                            @job_login = @job_login,
                            @job_password = @job_password
        if @@error <> 0 or @retcode <> 0
            goto Failure
    end

    return 0
    
Failure:
    raiserror(20702, 16, -1)
    return 1

GO
GRANT EXECUTE ON [sys].[sp_changedynamicsnapshot_job] TO [public] AS [dbo]
GO
