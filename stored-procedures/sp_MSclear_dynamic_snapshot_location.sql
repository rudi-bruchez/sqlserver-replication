SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSclear_dynamic_snapshot_location]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSclear_dynamic_snapshot_location] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSclear_dynamic_snapshot_location]
	@publication [sysname],
	@partition_id [int],
	@deletefolder [bit]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on
	declare @retcode  int
   	declare @pubnumber smallint
   	declare @publisher sysname
   	declare @publisher_db sysname
   	declare @command nvarchar(4000)
   	declare @dynsnap_location nvarchar(260)
    declare @distributor            sysname
    declare @dist_rpcname           sysname
    declare @distribdb              sysname
    declare @distproc               nvarchar(300)
    declare @dir                    nvarchar(260)
    declare @dynamic_filter_login       sysname
    declare @dynamic_filter_hostname    sysname    
   	declare @backward_comp_level        int

   	select @publisher = publishingservername() 
   	select @publisher_db = DB_NAME() 
	
	-- Only a dbo or sysadmin can do this
	exec @retcode = sys.sp_MSreplcheck_publish
	if @retcode<>0 or @@ERROR<>0
	    return 1

	select @pubnumber = publication_number ,
           @backward_comp_level = backward_comp_level
      from dbo.sysmergepublications  
     where name=@publication 
       and upper(publisher)=upper(@publisher) 
       and publisher_db=@publisher_db
    if @pubnumber is NULL or @pubnumber = 0 
    begin
		RAISERROR (20026, 16, -1, @publication)
        return 1
    end

    if (@partition_id is NULL or @deletefolder=1)
    begin

        EXEC @retcode = sys.sp_helpdistributor @distributor = @distributor OUTPUT, 
            @distribdb = @distribdb OUTPUT,
            @rpcsrvname = @dist_rpcname OUTPUT 
            if @@error <> 0 OR @retcode <> 0 or @distributor IS NULL OR @distribdb IS NULL
        BEGIN
            RAISERROR (14071, 16, -1)
            RETURN (1)
        END

        if((@deletefolder=1) and (@partition_id is not null))
        begin
            --the same cursor query but only for one specified partition_id
            declare partitions_cursor cursor local fast_forward for 
            select dynsnaps.partition_id, 
                   dynsnaps.dynamic_snapshot_location,
                   dynsnapjobs.dynamic_filter_login,
                   dynsnapjobs.dynamic_filter_hostname 
              from dbo.MSmerge_dynamic_snapshots dynsnaps
         left join dbo.MSdynamicsnapshotjobs dynsnapjobs
                on dynsnaps.partition_id = dynsnapjobs.partition_id 
                where dynsnaps.partition_id =@partition_id        
        end
        else        
            -- create a cursor and browse through all the partitions
            declare partitions_cursor cursor local fast_forward for 
            select dynsnaps.partition_id, 
                   dynsnaps.dynamic_snapshot_location,
                   dynsnapjobs.dynamic_filter_login,
                   dynsnapjobs.dynamic_filter_hostname 
              from dbo.MSmerge_dynamic_snapshots dynsnaps
         left join dbo.MSdynamicsnapshotjobs dynsnapjobs
                on dynsnaps.partition_id = dynsnapjobs.partition_id 
                where dynsnaps.partition_id in (select partition_id from dbo.MSmerge_partition_groups where publication_number = @pubnumber)
            
        open partitions_cursor 
        fetch next from partitions_cursor into @partition_id, @dynsnap_location, @dynamic_filter_login, @dynamic_filter_hostname
        while (@@fetch_status <> -1)
        begin

            delete from dbo.MSmerge_dynamic_snapshots where partition_id = @partition_id
            
            -- delete the directory on the disk as well
            if @dynsnap_location is not null and @dynsnap_location != ''
            begin
                select @distproc = QUOTENAME(RTRIM(@dist_rpcname)) + N'.' + QUOTENAME(@distribdb) + N'.dbo.sp_MScleanupdynamicsnapshotfolder'
                exec @retcode = @distproc
                    @publisher = @publisher,
                    @publisher_db = @publisher_db,
                    @publication = @publication,
                    @dynamic_filter_login = @dynamic_filter_login,
                    @dynamic_filter_hostname = @dynamic_filter_hostname,
                    @dynamic_snapshot_location = @dynsnap_location,
                    @partition_id = @partition_id        
                if @@error<>0 or @retcode<>0 
                    return 1
            
                if @backward_comp_level < 90 and isnull(is_srvrolemember('sysadmin'),0) = 1
                begin
                    SELECT @distproc = RTRIM(@dist_rpcname) + '.' + QUOTENAME(@distribdb) + '.dbo.sp_MSdeletefoldercontents'
                
                    select @dir = @dynsnap_location
                    EXECUTE @retcode = @distproc @dir
                    if @@error<>0 or @retcode<>0 
                        return 1
                end
            end
            fetch next from partitions_cursor into @partition_id, @dynsnap_location, @dynamic_filter_login, @dynamic_filter_hostname
        end
        close partitions_cursor
        deallocate partitions_cursor
    end
    else    
    begin
        select @dynsnap_location = dynamic_snapshot_location from  dbo.MSmerge_dynamic_snapshots where partition_id = @partition_id

		-- dynamic snapshot calls this proc at the beginning. use this to mark the starting time of the dynamic snapshot. this is 
		-- used in the case of sub-based articles - to invalidate dyn snapshot if it started before a generation was closed for a
		-- sub-based article.
        update dbo.MSmerge_dynamic_snapshots 
            set dynamic_snapshot_location = NULL, last_updated = NULL, last_started = getdate() where partition_id = @partition_id
            
        if @@rowcount = 0
			insert into dbo.MSmerge_dynamic_snapshots (partition_id, dynamic_snapshot_location, last_updated, last_started)
				values (@partition_id, NULL, NULL, getdate()) 
    end

    return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSclear_dynamic_snapshot_location] TO [public] AS [dbo]
GO
