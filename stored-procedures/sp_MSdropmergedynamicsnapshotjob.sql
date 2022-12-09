SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdropmergedynamicsnapshotjob]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdropmergedynamicsnapshotjob] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdropmergedynamicsnapshotjob]
	@publication [sysname],
	@dynamic_snapshot_jobname [sysname],
	@dynamic_snapshot_jobid [uniqueidentifier],
	@ignore_distributor [bit]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on

    declare @retcode int
    declare @pubid uniqueidentifier
    declare @dynamic_snapshot_location nvarchar(255)
    declare @guidstr nvarchar(40)
    declare @dynamic_snapshot_jobid_from_cursor uniqueidentifier
    declare @dir nvarchar(4000)

    declare @distributor sysname
    declare @distribdb sysname
    declare @rpcsrvname sysname
    declare @distproc nvarchar(4000)
    declare @publisher sysname
    declare @publisher_db sysname
    declare @agent_id int
    declare @backward_comp_level int
    declare @dynamic_filter_login sysname
    declare @dynamic_filter_hostname sysname
    declare @partition_id int

    select @retcode = 0
    select @pubid = null
    select @dynamic_snapshot_location = null
    select @publisher = publishingservername()
    select @publisher_db = db_name()


    if object_id('sysmergepublications') is NULL
    begin
        raiserror (20054, 16, -1)
        return (1)
    end

    -- Make sure that caller is a member of 'sysadmins' or 'db_owner'
    exec @retcode = sys.sp_MSreplcheck_publish
    if @@error <> 0 or @retcode <> 0
        return (1)

    select @pubid = pubid,
           @backward_comp_level = backward_comp_level 
      from dbo.sysmergepublications 
     where name = @publication
       and upper(publisher) = upper(publishingservername())
       and publisher_db = db_name()

    if @pubid is null
    begin
        raiserror(20026, 16, -1, @publication)
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
        save transaction sp_MSdropdynamicsnapshotjobC

        while (@@fetch_status <> -1)
        begin
            if @dynamic_snapshot_jobid_from_cursor is not null
            begin
                exec @retcode = sys.sp_MSdropmergedynamicsnapshotjob 
                                    @publication = @publication,
                                    @dynamic_snapshot_jobid = @dynamic_snapshot_jobid_from_cursor,
                                    @ignore_distributor = @ignore_distributor
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


        rollback transaction sp_MSdropdynamicsnapshotjobC
        commit transaction
        close hJobsCursor
        deallocate hJobsCursor
        return 1
    end

    select @pubid = pubid 
      from dbo.sysmergepublications 
     where name = @publication
       and upper(publisher) = upper(publishingservername())
       and publisher_db = db_name()

    if @dynamic_snapshot_jobid is null
    begin	
        select @dynamic_snapshot_location = dynamic_snapshot_location,
               @dynamic_snapshot_jobid = job_id,
               @dynamic_filter_login = dynamic_filter_login,
               @dynamic_filter_hostname = dynamic_filter_hostname,
               @partition_id = @partition_id,
               @agent_id = agent_id
          from dbo.MSdynamicsnapshotjobs
         where pubid = @pubid
           and name = @dynamic_snapshot_jobname 
    end
    else 
    begin
        select @dynamic_snapshot_location = dynamic_snapshot_location,
               @dynamic_filter_login = dynamic_filter_login,
               @dynamic_filter_hostname = dynamic_filter_hostname,
               @partition_id = @partition_id,
               @agent_id = agent_id 
          from dbo.MSdynamicsnapshotjobs
         where pubid = @pubid
           and job_id = @dynamic_snapshot_jobid 
    end

    if @dynamic_snapshot_location is null
    begin
        if @dynamic_snapshot_jobid is null
        begin
            raiserror(21326, 16, -1, N'@dynamic_snapshot_jobname', @dynamic_snapshot_jobname)
        end
        else
        begin
            select @guidstr = coalesce(convert(nvarchar(40), @dynamic_snapshot_jobid) collate database_default, '(NULL)' collate database_default)
            raiserror(21326, 16, -1, N'@dynamic_snapshot_jobid', @guidstr)
        end
        return (1)
    end

    -- Get distributor info for RPC
    if @ignore_distributor = 0
    begin
        exec @retcode = sys.sp_helpdistributor @distributor = @distributor output,
                                               @distribdb = @distribdb output,
                                               @rpcsrvname = @rpcsrvname output

        select @rpcsrvname = rtrim(@rpcsrvname)


        select @distproc = QUOTENAME(RTRIM(@rpcsrvname)) + N'.' + QUOTENAME(@distribdb) + N'.dbo.sp_MScleanupdynamicsnapshotfolder'
        exec @retcode = @distproc
               @publisher = @publisher,
               @publisher_db = @publisher_db,
               @publication = @publication,
               @dynamic_filter_login = @dynamic_filter_login,
               @dynamic_filter_hostname = @dynamic_filter_hostname,
               @dynamic_snapshot_location = @dynamic_snapshot_location,
               @partition_id = @partition_id        

        if @backward_comp_level < 90 and isnull(is_srvrolemember('sysadmin'),0) = 1
        begin
            select @distproc = QUOTENAME(RTRIM(@rpcsrvname)) + N'.' + QUOTENAME(@distribdb) + N'.' + N'dbo.sp_MSdeletefoldercontents'
            -- Try to delete the files 
            select @dir = @dynamic_snapshot_location
            exec @retcode = @distproc @dir
            -- Ignore errors
        end 
    end  
    select @retcode = 0

    begin transaction 
    save transaction sp_MSdropmergedynamicsnapshotjob

    -- Delete row from MSdynamicsnapshotjobs
    delete dbo.MSdynamicsnapshotjobs 
     where pubid = @pubid
       and job_id = @dynamic_snapshot_jobid

    if @@error <> 0
        goto Failure

    if @ignore_distributor = 0
    begin
        -- Drop the dynamic snapshot job at the distributor 
        select @distproc = QUOTENAME(RTRIM(@rpcsrvname)) + N'.' + QUOTENAME(@distribdb) + N'.' + N'dbo.sp_MSdrop_dynamic_snapshot_agent'

        exec @retcode = @distproc @publisher, @publisher_db, @publication, @agent_id
        if @retcode <> 0 or @@error <> 0
            goto Failure
    end
    commit transaction
    return 0

Failure:
    rollback transaction sp_MSdropmergedynamicsnapshotjob
    commit transaction
    return 1
end
GO
GRANT EXECUTE ON [sys].[sp_MSdropmergedynamicsnapshotjob] TO [public] AS [dbo]
GO
