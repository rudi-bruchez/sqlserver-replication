SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSmerge_upgrade_subscriber]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSmerge_upgrade_subscriber] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSmerge_upgrade_subscriber]
	@upgrade_metadata [bit],
	@upgrade_done [bit] OUTPUT
WITH EXECUTE AS CALLER
AS
-- this stored procedure is called every time the merge runs
    -- however we will only do anything if we find that upgrade is in progress
    declare @retcode int
    declare @artid uniqueidentifier
    declare @subid uniqueidentifier
    declare @objid int
    declare @qualified_table_name nvarchar(300)
    declare @pubid uniqueidentifier
    declare @subscriber_type int
    declare @is_republisher bit
    declare @source_owner sysname
    declare @source_object sysname
    declare @procsuffix nvarchar(100)
    declare @range_begin bigint
    declare @range_end bigint

    exec @retcode = sys.sp_MSreplcheck_subscribe
    if @retcode<>0 or @@error<>0
        return 1

    exec @retcode = sys.sp_MSgetMergeUpgradeSubscriberAppLock    
    if @retcode<>0 or @@error<>0
        return 1

    if object_id('MSmerge_upgrade_in_progress', 'U') is NULL
    begin
        select @upgrade_done = 0
        goto success
    end
            
    -- first upgrade the metadata tables
    if @upgrade_metadata = 1
    begin
        exec @retcode = sys.sp_MSmerge_metadataupgrade
        if @retcode<>0 or @@error<>0
            goto error
    end

    if exists (select 1 from dbo.sysmergearticles where sys.fn_MSmerge_islocalpubid(pubid)=1)
        select @is_republisher = 1
    else
        select @is_republisher = 0
        
    -- we will recreate the article procs and article triggers
    -- we will only do for the subscriptions. For the publications the snapshot needs to be run.
    declare #articles cursor LOCAL FORWARD_ONLY for 
        select distinct artid, objid, pubid from dbo.sysmergearticles where sys.fn_MSmerge_islocalpubid(pubid)=0
    open #articles
    fetch #articles into @artid, @objid, @pubid
    while (@@fetch_status<>-1)
    begin
        select @source_owner = schema_name(schema_id), @source_object = name from sys.objects where object_id = @objid
        select @qualified_table_name = quotename(@source_owner) + '.' + quotename(@source_object)
        if @qualified_table_name is NULL 
            goto NextArticle

        -- we really cannot be subscribing to two different publications for the same table.
        -- However there is a possibility that we could be

        -- drop the ins/upd/sel procs which have names like sp_ins_*
        exec @retcode = sys.sp_MSmerge_dropdownlevelprocs @artid, @pubid
        if @retcode<>0 or @@error<>0
            goto error

        select @procsuffix = sys.fn_MSmerge_getartprocsuffix(@artid, @pubid)
        if @procsuffix is NULL
            goto error
            
        -- update the names in sysmergearticles to use ins_sp_*
        update dbo.sysmergearticles
            set insert_proc = 'MSmerge_ins_sp_' + @procsuffix,
                update_proc = 'MSmerge_upd_sp_' + @procsuffix,
                select_proc = 'MSmerge_sel_sp_' + @procsuffix,
                metadata_select_proc = 'MSmerge_sel_sp_' + @procsuffix + '_metadata',
                delete_proc = 'MSmerge_del_sp_' + @procsuffix                
            where artid = @artid and pubid = @pubid
        if @@error<>0
            goto error
            
        exec @retcode = sys.sp_MSmakearticleprocs @pubid, @artid, 1
        if @retcode<>0 or @@error<>0
            goto error

        -- if the article uses auto identity range create the subscription entry in MSmerge_identity_range
        if exists (select 1 from dbo.sysmergearticles where artid=@artid and pubid=@pubid and identity_support=1)
        begin
            select @subid = subid, @subscriber_type = subscriber_type from dbo.sysmergesubscriptions 
                where pubid = @pubid and sys.fn_MSmerge_islocalsubid(subid)=1

            if not exists (select 1 from MSmerge_identity_range where artid=@artid and is_pub_range=0 and sys.fn_MSmerge_islocalsubid(subid)=1)
            begin
                -- get the range that was allocated to this subscriber before upgrade
                if object_id('dbo.MSrepl_identity_range') is not NULL
                    select @range_begin = current_max - range, @range_end = current_max from dbo.MSrepl_identity_range where objid = @objid
                
                insert dbo.MSmerge_identity_range(subid, artid, range_begin, range_end, is_pub_range, max_used)
                    values(@subid, @artid, @range_begin, @range_end, 0, NULL)
                if @@error<>0
                    goto error
            end

            if @subscriber_type = 1 and
                not exists (select 1 from MSmerge_identity_range where artid=@artid and is_pub_range=1 and sys.fn_MSmerge_islocalsubid(subid)=1)
            begin
                insert dbo.MSmerge_identity_range(subid, artid, is_pub_range, max_used)
                    values(@subid, @artid, 1, NULL)
                if @@error<>0
                    goto error
            end
            
            -- cleanup the shiloh entry for the identity range for this article
            if object_id('dbo.MSrepl_identity_range') is not NULL
                delete from dbo.MSrepl_identity_range where objid=@objid
        end


        /* Drop the default constraint on the rowguid column and create a new
        ** one that uses newsequential id. This will help improve performance.
        */
        if @is_republisher = 0
        begin
            exec @retcode = sys.sp_MSaddguidcolumn @source_owner, @source_object
            if @@error <> 0 or @retcode <> 0
                goto error
        end        
        
        exec @retcode = sys.sp_MSaddmergetriggers @qualified_table_name
        if @retcode<>0 or @@error<>0
            goto error

        -- activate the article
        update dbo.sysmergearticles set status = 2 where artid = @artid and pubid = @pubid and status = 1
        update dbo.sysmergearticles set status = 6 where artid = @artid and pubid = @pubid and status = 5
        
NextArticle:
        fetch next from #articles into @artid, @objid, @pubid
    end

    if @is_republisher = 0 and @upgrade_metadata = 1
    begin
        drop table dbo.MSmerge_upgrade_in_progress
        if @@error<>0
            goto error
    end

    select @upgrade_done = 1
 success:
    exec sys.sp_MSreleaseMergeUpgradeSubscriberAppLock 
    return 0
    
error:
    close #articles
    deallocate #articles
    raiserror(20691, 16, -1)
    exec sys.sp_MSreleaseMergeUpgradeSubscriberAppLock 
    return 1
GO
GRANT EXECUTE ON [sys].[sp_MSmerge_upgrade_subscriber] TO [public] AS [dbo]
GO
