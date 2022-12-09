SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_dropmergepublication]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_dropmergepublication] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_dropmergepublication]
	@publication [sysname],
	@ignore_distributor [bit],
	@reserved [bit],
	@ignore_merge_metadata [bit]
WITH EXECUTE AS CALLER
AS
set nocount on
    /*
    ** Declarations.
    */
    declare @ad_guidname        sysname
    declare @pubid                uniqueidentifier
    declare @article            sysname
    declare @cmd                nvarchar(255)
    declare @retcode            int
    declare @distproc            nvarchar(300)
    declare @distributor        sysname
    declare @distribdb            sysname
    declare @working_dir        varchar(255)
    declare @working_dir_drive    varchar(255)
    declare @pub_dir            nvarchar(255)
    declare @db_name            sysname
    declare @implicit_transaction    int
    declare @close_cursor_at_commit int
    declare @dynamic_filters        bit
    declare @alt_snapshot_folder nvarchar(255)
    declare @pub_alt_snapshot_folder nvarchar(255)
    			,@publishingservername sysname

    select @close_cursor_at_commit = 0
    select @implicit_transaction = 0
    		,@publishingservername = publishingservername()
    declare @got_merge_admin_applock bit

    select @got_merge_admin_applock = 0
    /*
    ** Save setting values first before changing them
    */
    IF (@reserved = 0)
    BEGIN
        SELECT @implicit_transaction = @@options & 2
        SELECT @close_cursor_at_commit = @@options & 4
        SET IMPLICIT_TRANSACTIONS OFF
        SET CURSOR_CLOSE_ON_COMMIT OFF
    END

    set @ad_guidname = NULL
    /*
    ** Initializations.
    */    
    select @db_name = db_name()

    /*
    ** Security Check
    */
    EXEC @retcode = sys.sp_MSreplcheck_publish
    IF @@ERROR <> 0 or @retcode <> 0
        return (1)

    /* make sure current database is enabled for merge replication */
    exec @retcode=sys.sp_MSCheckmergereplication
    if @@ERROR<>0 or @retcode<>0
        return (1)

    if LOWER(@publication) = 'all'
    BEGIN
        declare hC1 CURSOR LOCAL FAST_FORWARD FOR select name 
            FROM dbo.sysmergepublications where UPPER(publisher)=UPPER(publishingservername()) and publisher_db=db_name() 
                FOR READ ONLY
        
        OPEN hC1
        FETCH hC1 INTO @publication
        WHILE (@@fetch_status <> -1)
        BEGIN
            EXECUTE sys.sp_dropmergepublication @publication=@publication,
                @ignore_distributor = @ignore_distributor,
                @reserved = 1,
                @ignore_merge_metadata = @ignore_merge_metadata

            FETCH hC1 INTO @publication
        END
        CLOSE hC1
        DEALLOCATE hC1
        RETURN (0)
    END

    if @publication IS NULL
        BEGIN
            RAISERROR (14003, 16, -1)
            RETURN (1)
        END
    /*
    ** Get the @pubid.
    */
    if NOT EXISTS (select * FROM dbo.sysmergepublications 
        WHERE name = @publication  and UPPER(publisher)=UPPER(publishingservername()) and publisher_db=db_name())
    BEGIN
        RAISERROR (20026, 16, -1, @publication)
        RETURN (1)
    END
    
    select @pubid = pubid,
           @dynamic_filters = @dynamic_filters,
           @alt_snapshot_folder = alt_snapshot_folder,
           @ad_guidname=ad_guidname
      FROM dbo.sysmergepublications 
        WHERE name = @publication  and UPPER(publisher)=UPPER(publishingservername()) and publisher_db=db_name()

    /* 
    ** Ignore external publications
    */
    if exists (select * from dbo.sysmergesubscriptions where subid=@pubid 
        and pubid=@pubid and db_name<>db_name())
        RETURN (0)

    /*
    ** Check to make sure that there are push or pull subscriptions on the publication.
    */
    if EXISTS (select * FROM dbo.sysmergesubscriptions    subs, 
                    dbo.sysmergepublications                pubs, 
                    dbo.MSmerge_replinfo                    repinfo
                WHERE    pubs.name = @publication
                    AND UPPER(pubs.publisher)=UPPER(publishingservername()) 
                    AND pubs.publisher_db=db_name()
                    AND subs.pubid = pubs.pubid
                    AND subs.status <> 2  -- Having a deleted subscription row is fine
                    AND repinfo.repid <> @pubid
                    AND repinfo.repid = subs.subid
                    AND subs.subid <> subs.pubid
                    AND subs.subscriber_type <> 3 and subs.subscriber_type <> 2)
    BEGIN
        RAISERROR (14005, 16, -1)
        RETURN (1)
    END

    exec @retcode = sys.sp_MSdropmergepalrole @pubid
    if @retcode<>0 or @@error<>0
    begin
        return 1
    end

    begin tran
    save TRANSACTION dropmergepublication

    exec @retcode = sys.sp_MSgetmergeadminapplock @timeout = 0, -- no wait
                                                  @lockowner = N'Transaction'
    if @retcode<>0 or @@error<>0
    begin
        raiserror(20713, 16, -1, 'sp_dropmergepublication', @publication)
        goto FAILURE            

    end

    select @got_merge_admin_applock = 1

    -- if this is the last publication and there are no other subscriptions set the ignore_merge_metadata to 1
    if not exists (select 1 from dbo.sysmergesubscriptions where subid<>@pubid and sys.fn_MSmerge_islocalsubid(subid)=1)
    begin
        select @ignore_merge_metadata = 1
    end


    /*
    ** Delete all articles from the publication.
    */

    update dbo.sysmergepublications set snapshot_ready=0 where pubid=@pubid --so that articles can be dropped
    if @@ERROR<>0
        goto FAILURE

    EXECUTE @retcode = sys.sp_dropmergearticle @publication = @publication, @article = 'all',
        @ignore_distributor = @ignore_distributor, @ignore_merge_metadata = @ignore_merge_metadata
    if @@ERROR <> 0 OR @retcode <> 0
    begin
        RAISERROR (20040, 16, -1, @publication)
        goto FAILURE
    end

    /*
    ** Delete sync task of Publication.
    */
    execute @retcode = sys.sp_MSdropmergepub_snapshot @publication = @publication,
        @ignore_distributor = @ignore_distributor
    if @@ERROR <> 0 OR @retcode <> 0
    begin
        RAISERROR (20010, 16, -1, @publication)
        goto FAILURE
    end

    -- delete supportability settings for the subscriptions that we are about to delete.
    delete from dbo.MSmerge_supportability_settings where pubid = @pubid            
    delete from dbo.MSmerge_log_files where pubid = @pubid

    /*
    ** Remove my subscription entries from dbo.sysmergesubscriptions and dbo.MSmerge_replinfo
    */
    if exists (select * from dbo.sysmergesubscriptions where pubid = @pubid and subid <> @pubid)
    begin
        DELETE from dbo.MSmerge_replinfo 
            WHERE repid in (select subid from dbo.sysmergesubscriptions where pubid = @pubid and subid <> @pubid)
        if @@ERROR <> 0
            goto FAILURE
            
        DELETE from dbo.sysmergesubscriptions WHERE pubid = @pubid and subid <> @pubid
        if @@ERROR <> 0
            goto FAILURE
        exec sys.sp_MScleanup_subscriber_history
        if @@ERROR<>0 
            goto FAILURE    
    end            

    /*
    ** Remove my own subscription from dbo.sysmergesubscriptions.
    */
    if exists (select * from dbo.sysmergesubscriptions where subid = @pubid)
    begin
        DELETE from dbo.sysmergesubscriptions WHERE subid = @pubid
        if @@ERROR <> 0
            goto FAILURE
            
        exec sys.sp_MScleanup_subscriber_history @subid = @pubid
        if @@ERROR<>0 
            goto FAILURE    
    end            

    if exists (select * from dbo.MSmerge_replinfo where repid = @pubid)
    begin
        DELETE from dbo.MSmerge_replinfo WHERE repid = @pubid
        if @@ERROR <> 0
            goto FAILURE
    end                

    -- If the only remaining subscriptions are old entries (before restore),
    -- we remove them now.
    if not exists (select * from dbo.sysmergesubscriptions 
                        where status <> 7) -- REPLICA_STATUS_BeforeRestore
    begin
        delete from dbo.sysmergesubscriptions
        truncate table dbo.MSmerge_supportability_settings
        truncate table dbo.MSmerge_log_files
        truncate table dbo.MSrepl_errors
        truncate table dbo.MSmerge_history
        truncate table dbo.MSmerge_articlehistory
        truncate table dbo.MSmerge_sessions
        delete from dbo.MSmerge_replinfo
    end

    
    /*
    ** if @ignore_distributor = 1, we are in bruteforce cleanup mode, don't do RPC.
    */
    if @ignore_distributor = 0
    begin
        /*
        ** Get distribution server information for remote RPC call.
        */
        EXEC @retcode = sys.sp_helpdistributor @rpcsrvname = @distributor OUTPUT,
                                           @distribdb = @distribdb OUTPUT,
                                           @directory = @working_dir OUTPUT
        IF @@ERROR <> 0 OR    @retcode <> 0
        BEGIN
            RAISERROR (14071, 16, -1)
            goto FAILURE
        END

        /*
        ** Drop the publication info from the distributor
        */
        select @distproc = RTRIM(@distributor) + '.' + QUOTENAME(@distribdb) + 
            '.dbo.sp_MSdrop_publication'
        EXECUTE @retcode = @distproc
            @publisher = @publishingservername,
            @publisher_db = @db_name,
            @publication = @publication,
            @alt_snapshot_folder = @alt_snapshot_folder
            
        if @@ERROR <> 0 OR @retcode <> 0
        begin
            goto FAILURE
        end
    end

    
    /* Remove all dynamic snapshot jobs of this publication */
    exec @retcode = sys.sp_MSdropmergedynamicsnapshotjob 
        @publication = @publication,
        @ignore_distributor = @ignore_distributor

    if @@ERROR <> 0 OR @retcode <> 0
    begin
        goto FAILURE
    end

    /*
    ** Execute the cleanup routine for the publication
    */
    exec sys.sp_MSpublicationcleanup @publisher=@publishingservername, 
            @publisher_db = @db_name,
            @publication = @publication, @ignore_merge_metadata = @ignore_merge_metadata
    
    if @@ERROR <> 0
        goto FAILURE

    -- delete supportability settings for the subscriptions that we are about to delete.
    delete from dbo.MSmerge_supportability_settings where pubid = @pubid            
    delete from dbo.MSmerge_log_files where pubid = @pubid

    delete from dbo.sysmergesubscriptions where pubid=@pubid
    if @@ERROR<>0
        goto FAILURE
        
    exec sys.sp_MScleanup_subscriber_history
    if @@ERROR<>0
        goto FAILURE

    -- If the only remaining subscriptions are old entries (before restore),
    -- we remove them now.
    if not exists (select * from dbo.sysmergesubscriptions 
                        where status <> 7) -- REPLICA_STATUS_BeforeRestore
    begin
        delete from dbo.sysmergesubscriptions
        truncate table dbo.MSmerge_supportability_settings
        truncate table dbo.MSmerge_log_files
        truncate table dbo.MSrepl_errors
        truncate table dbo.MSmerge_history
        truncate table dbo.MSmerge_articlehistory
        truncate table dbo.MSmerge_sessions
        delete from dbo.MSmerge_replinfo
    end

    exec sys.sp_MSreleasemergeadminapplock @lockowner = N'Transaction'
    COMMIT TRANSACTION
    
    /*
    ** Set back original settings
    */    
    IF @reserved = 0
    BEGIN
        IF @implicit_transaction <>0 
            SET IMPLICIT_TRANSACTIONS ON
        IF @close_cursor_at_commit <>0 
            SET CURSOR_CLOSE_ON_COMMIT ON
    END
    
    return (0)

FAILURE:            
    RAISERROR (14006, 16, -1)
    /* UNDONE : This code is specific to 6.X nested transaction semantics */
    if @@TRANCOUNT > 0
    begin
        if @got_merge_admin_applock=1
            exec sys.sp_MSreleasemergeadminapplock @lockowner = N'Transaction'
        ROLLBACK TRANSACTION dropmergepublication
        COMMIT TRANSACTION
    end
    /*
    ** Set back original settings
    */    
    IF @reserved = 0
    BEGIN
        IF @implicit_transaction <>0 
            SET IMPLICIT_TRANSACTIONS ON
        IF @close_cursor_at_commit <>0 
            SET CURSOR_CLOSE_ON_COMMIT ON
    END           
    RETURN (1)
GO
GRANT EXECUTE ON [sys].[sp_dropmergepublication] TO [public] AS [dbo]
GO
