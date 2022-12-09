SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSpublicationcleanup]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSpublicationcleanup] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSpublicationcleanup]
	@publication [sysname],
	@publisher_db [sysname],
	@publisher [sysname],
	@ignore_merge_metadata [bit],
	@force_preserve_rowguidcol [bit]
WITH EXECUTE AS CALLER
AS
declare @pubid         uniqueidentifier
    declare @artid         uniqueidentifier
    declare @retcode    smallint
    declare @objectname sysname
    declare @objectowner sysname
    declare @progress_token nvarchar(500)
    declare @progress_token_hash int
    declare @lightweight bit

    /*
    ** Security Check
    */
    EXEC @retcode = sys.sp_MSreplcheck_publish
    IF @@ERROR <> 0 or @retcode <> 0
        return (1)

	if @publisher is null
		set @publisher = publishingservername()

    /* This only gets called after database is enable to subscribe, so dbo.sysmergepublications should exist */
    if object_id('dbo.sysmergepublications', 'U') is not null
    begin
        select @pubid = pubid FROM dbo.sysmergepublications 
            WHERE name = @publication and 
                  upper(publisher collate SQL_Latin1_General_CP1_CS_AS) = upper(@publisher collate SQL_Latin1_General_CP1_CS_AS) and 
                  publisher_db = @publisher_db
    end

    /* Normal case - nothing to cleanup, just return */
    if @pubid is null
        return (1)

    select @lightweight = 0

    if exists (select * from dbo.sysmergearticles where pubid=@pubid and lightweight=1)
    begin
        select @lightweight = 1
    end

    /* drop system table views */
    exec @retcode = sys.sp_MSdropsystableviews @pubid
    IF @@ERROR <> 0 or @retcode <> 0
        return (1)

    /* drop per article cts views */
    exec @retcode = sys.sp_MSdropctsviews @pubid
    IF @@ERROR <> 0 or @retcode <> 0
        return (1)


    /*
    ** If we are in the middle of delivering a snapshot for the specified
    ** publication, don't try to do cleanup
    */
    if object_id('dbo.MSsnapshotdeliveryprogress', 'U') is not null
    begin
        
        select @progress_token = N'<MergePubId>:' + convert(nvarchar(100), @pubid)
        select @progress_token_hash = sys.fn_repl32bitstringhash(@progress_token)
        if exists (select * from dbo.MSsnapshotdeliveryprogress 
                    where progress_token_hash = @progress_token_hash
                     and  progress_token = @progress_token)  
        begin
            return (0)
        end
    end 

    /* 
    ** If we are deleting the last publication in the database, ie there are articles in
    ** dbo.sysmergearticles with a different pubid then the one being dropped
    ** then remove all the rows in MSmerge_genhistory, MSmerge_contents and MSmerge_tombstone 
    ** use a truncate table in order to make the operation non logged and hence efficient
    */
    if 0 = @lightweight
    begin
        if not exists (select * from dbo.sysmergearticles where pubid <> @pubid)
        begin
            if object_id('MSmerge_genhistory','U') is not NULL
                truncate table dbo.MSmerge_genhistory
            if object_id('MSmerge_current_partition_mappings','U') is not NULL
                truncate table dbo.MSmerge_current_partition_mappings
            if object_id('MSmerge_past_partition_mappings','U') is not NULL
                truncate table dbo.MSmerge_past_partition_mappings
            if object_id('MSmerge_generation_partition_mappings','U') is not NULL
                truncate table dbo.MSmerge_generation_partition_mappings
            if object_id('MSmerge_contents','U') is not NULL
                truncate table dbo.MSmerge_contents
            if object_id('MSmerge_tombstone','U') is not NULL
                truncate table dbo.MSmerge_tombstone
            exec @retcode= sys.sp_MSdrop_tempgenhistorytable @pubid
            if @@error<>0 or @retcode<>0 goto Error                                            
        end
    end
    else
    begin
        if not exists (select top 1 * from dbo.sysmergearticles 
            where pubid<>@pubid and lightweight=1)
        begin
            if object_id('MSmerge_rowtrack','U') is not NULL
                truncate table dbo.MSmerge_rowtrack
        end
    end

    if not exists (select * from dbo.sysmergearticles where pubid <> @pubid)
    begin
        if object_id('MSmerge_metadataaction_request','U') is not NULL
            truncate table dbo.MSmerge_metadataaction_request
    end

    begin transaction
    save tran MSpublicationcleanup

    -- Clean up the articles for this publication, and delete the row.
    -- For lightweight, this is done in sp_MSdeletelightweightsubscription.
    if 0 = @lightweight
    begin
        select top 1 @artid= artid FROM dbo.sysmergearticles WHERE pubid = @pubid
        while @artid is not null
        begin
            if not exists (select * from dbo.sysmergearticles WHERE artid = @artid and pubid <> @pubid)
            begin
                -- sp_MSpublicationcleanup is either called by sp_dropmergepullsubscription,
                -- or by by CMergeDatasource::CreateInitialPublication.
                -- For the former, we want to remove the rowguidcol if possible.
                -- For the latter, we don't, because we are actually setting up the publication.
                exec @retcode=sys.sp_MSarticlecleanup 
                                       @pubid = @pubid, 
                                       @artid = @artid, 
                                       @ignore_merge_metadata = @ignore_merge_metadata,
                                       @force_preserve_rowguidcol = @force_preserve_rowguidcol
                if @retcode<>0 or @@ERROR<>0 goto Error
            end
            delete from dbo.sysmergepartitioninfo where artid = @artid and pubid = @pubid
            if @@ERROR<>0 goto Error

            delete from dbo.sysmergearticles where artid = @artid and pubid = @pubid
            if @@ERROR<>0 goto Error

            set @artid = NULL
            select top 1 @artid= artid FROM dbo.sysmergearticles WHERE pubid = @pubid
        end
    end
        
    /* Unmark all schema articles in this publication */
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
                exec  sys.sp_MSunmarkschemaobject @objectname, @objectowner    
                if @retcode<>0 or @@ERROR<>0 
                    goto Error
                fetch hschemaarticle_cur into @objectname, @objectowner
        end
        close hschemaarticle_cur
        deallocate hschemaarticle_cur

        /* Delete all schema article rows for this publication*/
        delete from dbo.sysmergeschemaarticles where pubid = @pubid
        if @@ERROR<>0 
            goto Error
    end
    
    /* Now clean up any traces in other system tables */

    if 0 = @lightweight
    begin
        /* 
        ** Make sure you NULL out gen_cur for other articles that share this table 
        ** since we are deleting the genhistroy row for that generation 
        */
        declare @publication_number smallint
        select @publication_number = publication_number from dbo.sysmergepublications where pubid = @pubid
            
        update dbo.sysmergearticles set gen_cur=NULL where gen_cur in
            (select generation from dbo.MSmerge_genhistory where pubid = @pubid)
        if @@ERROR<>0 
            goto Error
        delete from dbo.MSmerge_generation_partition_mappings where publication_number = @publication_number
        if @@ERROR<>0 
            goto Error
        delete from dbo.MSmerge_genhistory where pubid = @pubid
        if @@ERROR<>0 
            goto Error
        delete from dbo.MSmerge_replinfo where repid in (select subid from dbo.sysmergesubscriptions where pubid = @pubid and status <> 2)
        if @@ERROR<>0 
            goto Error
        delete from dbo.sysmergesubsetfilters where pubid = @pubid
        if @@ERROR<>0 
            goto Error

        exec @retcode= sys.sp_MSdrop_tempgenhistorytable @pubid
        if @@error<>0 or @retcode<>0 goto Error

		-- delete supportability settings for the subscriptions that we are about to delete.
        delete from dbo.MSmerge_supportability_settings where pubid = @pubid        	
        delete from dbo.MSmerge_log_files where pubid = @pubid

        delete from dbo.sysmergesubscriptions where pubid = @pubid and status <> 2
        if @@ERROR<>0 
            goto Error
        exec sys.sp_MScleanup_subscriber_history
        if @@ERROR<>0 
            goto Error
        delete from dbo.MSmerge_current_partition_mappings where publication_number = @publication_number
        if @@ERROR<>0 
            goto Error
        delete from dbo.MSmerge_past_partition_mappings where publication_number = @publication_number
        if @@ERROR<>0 
            goto Error
            
        -- drop the partition evaluation proc if it exists
        declare @partition_id_eval_proc nvarchar(258)
        select @partition_id_eval_proc = quotename(partition_id_eval_proc) from dbo.sysmergepublications where pubid = @pubid
        if @partition_id_eval_proc is not null and object_id('dbo.' + @partition_id_eval_proc) is not null
        begin
            exec ('drop procedure dbo.' + @partition_id_eval_proc)
            if @@error <> 0
                goto Error
        end
        
        delete from dbo.MSmerge_partition_groups where publication_number = @publication_number
        if @@ERROR<>0 
            goto Error
        delete from dbo.sysmergepublications where pubid = @pubid
        if @@ERROR<>0 
            goto Error
        delete from dbo.sysmergeschemachange where pubid = @pubid
        if @@ERROR<>0 
            goto Error

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
    end
    else
    begin
        delete from dbo.MSmerge_replinfo 
            where repid in (select subid from dbo.sysmergesubscriptions where pubid = @pubid and status <> 2)
        if @@ERROR<>0 
            goto Error
            
		-- delete supportability settings for the subscriptions that we are about to delete.
        delete from dbo.MSmerge_supportability_settings where pubid = @pubid        	
        delete from dbo.MSmerge_log_files where pubid = @pubid

        delete from dbo.sysmergesubscriptions where pubid = @pubid and status <> 2
        if @@ERROR<>0 
            goto Error
        exec sys.sp_MScleanup_subscriber_history
        if @@ERROR<>0 
            goto Error
        delete from dbo.sysmergepublications where pubid = @pubid
        if @@ERROR<>0 
            goto Error
    end

    commit tran 
    return (0)

Error:
    rollback tran MSpublicationcleanup
    commit tran 
    return (1)
GO
GRANT EXECUTE ON [sys].[sp_MSpublicationcleanup] TO [public] AS [dbo]
GO
