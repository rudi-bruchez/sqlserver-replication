SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_mergesubscription_cleanup]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_mergesubscription_cleanup] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_mergesubscription_cleanup]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
    set nocount on
    declare @pubid                 uniqueidentifier
    declare @artid                 uniqueidentifier
    declare @retcode            smallint
    declare @subscription_type  int
    declare @objid              int
    declare @objectname         sysname
    declare @objectowner        sysname

    exec @retcode = sys.sp_MSreplcheck_subscribe
    if (@retcode <> 0 or @@error <> 0)
        return 1

    /*
    ** if there is nothing to cleanup, then just return.
    */
    if object_id('sysmergesubscriptions') is NULL
        return (0)

    /* This only gets called after database is enable to subscribe, so dbo.sysmergepublications should exist */
    select @pubid = pubid FROM dbo.sysmergepublications 
        WHERE name = @publication and UPPER(publisher)=UPPER(@publisher) and publisher_db=@publisher_db

    /* Normal case - nothing to cleanup, just return */
    if @pubid is null
        return (1)

    select @subscription_type = subscription_type from dbo.sysmergesubscriptions where pubid=@pubid and subid<>pubid

    /* This procedure is not intended to be used for cleanning-up pull/anonymous subscriptions */
    if @subscription_type > 0
    begin
        raiserror(20091, 16, -1)
        return (1)
    end

    /* make sure that we are not calling this proc on the publisher and publisher database */
    if ((UPPER(@publisher) = UPPER(publishingservername())) and (@publisher_db = db_name()))
    begin
        raiserror(21691, 16, -1)
        return (1)
    end

    /* Clean up the articles for this publication, and delete the row */
    select @artid = artid FROM dbo.sysmergearticles WHERE pubid = @pubid
    while @artid is not null
    begin
        if not exists (select * from dbo.sysmergearticles WHERE artid = @artid and pubid <> @pubid)
            begin
                exec @retcode=sys.sp_MSarticlecleanup @pubid, @artid
                if @retcode<>0 or @@ERROR<>0 return (1)
            end
        delete from dbo.sysmergepartitioninfo where artid = @artid and pubid = @pubid
        delete from dbo.sysmergearticles where artid = @artid and pubid = @pubid
        set @artid = NULL
        select @artid = artid FROM dbo.sysmergearticles WHERE pubid = @pubid
    end
        
    /* Cleanup the schema articles */

    /* Unmark all schema article objects unconditionally */
    if object_id('sysmergeschemaarticles') is not NULL
    begin
        declare hschemaarticle_cur cursor local fast_forward for
            select destination_object, destination_owner from dbo.sysmergeschemaarticles where
            pubid = @pubid 
        for read only
        open hschemaarticle_cur
        fetch hschemaarticle_cur into @objectname, @objectowner
        while (@@fetch_status<>-1)
        begin
                -- Ignore errors
                exec  sys.sp_MSunmarkschemaobject @objectname, @objectowner    
                fetch hschemaarticle_cur into @objectname, @objectowner
        end
        close hschemaarticle_cur
        deallocate hschemaarticle_cur

        /* Delete all schema article rows for this publication*/
        delete from dbo.sysmergeschemaarticles where pubid = @pubid
    end

    exec @retcode = sys.sp_resetsnapshotdeliveryprogress @drop_table = N'true'
    if @retcode <> 0 or @@error <> 0
    begin
        goto UNDO
    end

    /* 
    ** Make sure you NULL out gen_cur for other articles that share this table 
    ** since we are deleting the genhistroy row for that generation 
    */
    update dbo.sysmergearticles set gen_cur=NULL where gen_cur in
        (select generation from dbo.MSmerge_genhistory where pubid = @pubid)
        
    declare @publication_number smallint
    select @publication_number = publication_number from dbo.sysmergepublications where pubid = @pubid
    /* Now clean up any traces in other system tables */
    delete from dbo.MSmerge_generation_partition_mappings where publication_number = @publication_number
    delete from dbo.MSmerge_genhistory where pubid = @pubid 
    delete from dbo.MSmerge_replinfo where repid in (select subid from dbo.sysmergesubscriptions where pubid = @pubid)

    -- delete supportability settings for the subscriptions that we are about to delete.
    delete from dbo.MSmerge_supportability_settings where pubid = @pubid
    delete from dbo.MSmerge_log_files where pubid = @pubid

    delete from dbo.sysmergesubscriptions where pubid = @pubid
    exec sys.sp_MScleanup_subscriber_history
    delete from dbo.MSmerge_current_partition_mappings where publication_number = @publication_number
    delete from dbo.MSmerge_past_partition_mappings where publication_number = @publication_number
    -- drop the partition evaluation proc if it exists
    declare @partition_id_eval_proc nvarchar(260)
    select @partition_id_eval_proc = quotename(partition_id_eval_proc) from dbo.sysmergepublications where pubid = @pubid
    if @partition_id_eval_proc is not null and object_id(N'dbo.' + @partition_id_eval_proc) is not null
    begin
        exec (N'drop procedure dbo.' + @partition_id_eval_proc)
        if @@error <> 0
            return 1
    end

    delete from dbo.MSmerge_partition_groups where publication_number = @publication_number
    delete from dbo.sysmergepublications where pubid = @pubid

    delete from dbo.sysmergeschemachange where pubid = @pubid

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
    ** If last subscription is dropped and the DB is not enabled for publishing,
    ** then remove the merge system tables
    */
    IF (not exists (select * from dbo.sysmergesubscriptions )) 
        AND (select category & 4 FROM master.dbo.sysdatabases WHERE name = DB_NAME() collate database_default )=0
    BEGIN
        execute @retcode = sys.sp_MSdrop_mergesystables @whattodrop=3
        if @@ERROR <> 0 or @retcode <> 0 return (1)

        execute @retcode=sys.sp_MSrepl_ddl_triggers @type='merge', @mode='drop'
        if @@ERROR <> 0 or @retcode <> 0 return (1)         
    END

    return 0
UNDO:
    return(1)
END
GO
GRANT EXECUTE ON [sys].[sp_mergesubscription_cleanup] TO [public] AS [dbo]
GO
