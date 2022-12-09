SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSarticlecleanup]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSarticlecleanup] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSarticlecleanup]
	@pubid [uniqueidentifier],
	@artid [uniqueidentifier],
	@ignore_merge_metadata [bit],
	@force_preserve_rowguidcol [bit]
WITH EXECUTE AS CALLER
AS
set nocount on
    declare @source_table   nvarchar(517)
    declare @ownername      sysname
    declare @objectname     sysname
    declare @tablenick      int
    declare @objid          int
    declare @sync_objid     int
    declare @view_type      int
    declare @tsview         nvarchar(50)
    declare @guidstr        nvarchar(50)
    declare @csview         nvarchar(50)
    declare @viewname       nvarchar(517)
    declare @retcode        smallint
    declare @qualified_name nvarchar(270)
    declare @bi_tablename   nvarchar(258)
    declare @bi_viewname    nvarchar(258)
    declare @bi_procname    nvarchar(258)
    declare @before_table_view sysname
    declare @merge_pub_markcolumn_bit int
    declare @merge_pub_unmarkcolumn_bit int
    declare @current_mappings_viewname sysname
    declare @past_mappings_viewname sysname
    declare @partition_view_name sysname
    declare @repl_view_name nvarchar(258)
    declare @before_upd_viewname nvarchar(258)
    declare @preserve_rowguidcol bit
    declare @constraintname nvarchar(258)
    declare @genview sysname


    -- to be called after article is set up in a subscriber

    /*
    ** Security Check
    */
    EXEC @retcode = sys.sp_MSreplcheck_publish
    IF @@ERROR <> 0 or @retcode <> 0
        return (1)

    select @merge_pub_markcolumn_bit = 0x4000
    select @merge_pub_unmarkcolumn_bit = ~@merge_pub_markcolumn_bit

    select @objid = max(objid) from dbo.sysmergearticles where artid = @artid

    if @objid is NULL 
        return 0

    -- get owner name, and table name
    select @objectname = name, @ownername = schema_name(schema_id)
        from sys.objects where object_id = @objid

    -- construct the qualified table name
    select @source_table = QUOTENAME(@ownername) + '.' + QUOTENAME(@objectname)

    exec @retcode=sys.sp_MSguidtostr @artid, @guidstr out
    if @retcode<>0 or @@ERROR<>0 return (1)

    -- get the insert, update and conflict proc names from dbo.sysmergearticles
    select  @sync_objid = sync_objid, 
            @view_type = view_type, 
            @tablenick = nickname,
            @bi_tablename = object_name(before_image_objid),
            @bi_viewname = object_name(before_view_objid),
            @before_upd_viewname = object_name(before_upd_view_objid),
            @preserve_rowguidcol = preserve_rowguidcol
        from dbo.sysmergearticles where
            pubid = @pubid and artid = @artid

    -- set the article status to indicate it is in no other publication,
    -- and it is about to be removed.
    update dbo.sysmergearticles set status= 7
        where pubid = @pubid and artid = @artid

    -- drop the per article contents view for this article
    exec @retcode= sys.sp_MSdropctsviews @pubid, @artid
    if @@error<>0 or @retcode<>0 
        return 1

    /* If there is a before image table, drop it and its cleanup proc */
    if (@bi_tablename is not null)
    begin
        set @bi_procname = @bi_tablename + '_clean'
        if exists (select * from sys.objects where
                        name = @bi_procname and type = 'P')
        begin
            select @bi_procname = QUOTENAME(@bi_procname) 
            exec ('drop proc ' + @bi_procname)
            if @@ERROR<>0 return (1)
        end

        select @bi_tablename = QUOTENAME(@bi_tablename)
        exec ('drop table ' + @bi_tablename)
        if @@ERROR<>0 return (1)

        -- delete the before table view created for access in the trigger
        set @before_table_view = 'MSmerge_bivw_' + @guidstr
        if exists (select * from sys.objects where type = 'V' and name = @before_table_view)
        begin
            exec (' drop view ' + @before_table_view)
            if @@ERROR<>0 return (1)                    
        end
    end
    
    /* If there is a before image view, drop it */
    if (@bi_viewname is not null)
    begin
        select @bi_viewname = QUOTENAME(@bi_viewname)
        
        exec ('drop view ' + @bi_viewname)
        if @@ERROR<>0 return (1)
    end

    if (@before_upd_viewname is not null)
    begin
        select @before_upd_viewname = QUOTENAME(@before_upd_viewname)
        
        exec ('drop view ' + @before_upd_viewname)
        if @@ERROR<>0 return (1)
    end

    /* Drop the article procs */
    exec @retcode=sys.sp_MSdroparticleprocs @pubid, @artid
    if @@ERROR<>0 or @retcode<>0 return (1)

    -- Drop the article-specific conflict table.
    exec @retcode= sys.sp_MSdrop_article_conflict_table @pubid=@pubid, @artid=@artid
    if @@error<>0 or @retcode<>0 return 1

    /* Drop the article triggers */
    exec @retcode=sys.sp_MSdroparticletriggers @objectname, @ownername
	if @@ERROR<>0 or @retcode<>0 return (1)

    exec @retcode=sys.sp_MSunmarkreplinfo @object=@objectname, @owner=@ownername
    if @@ERROR<>0 or @retcode<>0 return (1)

    /* If the article's has a temporary ( view type = 2) or a permanent view (view_type = 1 ) drop the sync object */
    if (@objid <> @sync_objid)
    begin
        select @viewname = name from sys.objects where type='V' and is_ms_shipped = 1 and object_id = @sync_objid
        if @viewname IS NOT NULL
        begin
            select @ownername = schema_name(schema_id) from sys.objects where name=@viewname
            set @viewname = QUOTENAME(@ownername) + '.' + QUOTENAME(@viewname)
            exec ('drop view ' + @viewname)
            if @@ERROR<>0 return (1)
        end
    end

    -- Drop repl_view_
    select @repl_view_name = NULL
    if object_id('dbo.sysmergepartitioninfo', 'U') is not NULL
    begin
        select @repl_view_name = QUOTENAME(object_name(repl_view_id)) from dbo.sysmergepartitioninfo WHERE artid = @artid AND pubid = @pubid
        if object_id(@repl_view_name) is not NULL
        begin
            exec ('drop view ' + @repl_view_name)
        end

        select @repl_view_name = NULL
        select @repl_view_name = QUOTENAME(object_name(logical_record_view)) from dbo.sysmergepartitioninfo WHERE artid = @artid AND pubid = @pubid
        if @repl_view_name is not NULL
        begin
            exec ('drop view ' + @repl_view_name)
        end        
    end

    /*
    ** Drop the views created for MSmerge_contents and MSmerge_tombstone before dropping these two tables
    */
    set @csview = 'MSmerge_ctsv_' + @guidstr
    set @tsview = 'MSmerge_tsvw_' + @guidstr
    set @genview = 'MSmerge_genvw_' + @guidstr

    if EXISTS (select * from sys.objects where name=@csview and type='V')
    BEGIN
        select @ownername = schema_name(schema_id) from sys.objects where  name=@csview
        select @viewname = QUOTENAME(@ownername) + '.' + QUOTENAME(@csview)
        exec ('drop view ' + @viewname)
            if @@ERROR<>0 return (1)
    END
        
    if EXISTS (select * from sys.objects where name=@tsview and type='V')
    BEGIN
        select @ownername = schema_name(schema_id) from sys.objects where  name=@tsview
        select @viewname = QUOTENAME(@ownername) + '.' + QUOTENAME(@tsview)
        exec ('drop view ' + @viewname)
            if @@ERROR<>0 return (1)
    END

    if EXISTS (select * from sys.objects where name=@genview and type='V')
    BEGIN
        select @ownername = schema_name(schema_id) from sys.objects where  name=@genview
        select @viewname = QUOTENAME(@ownername) + '.' + QUOTENAME(@genview)
        exec ('drop view ' + @viewname)
            if @@ERROR<>0 return (1)
    END

    /*
    ** Drop the views created for MSmerge_past_partition_mappings and MSmerge_past_current_mappings as well for this article
    */
    set @current_mappings_viewname = 'MSmerge_cpmv_' + @guidstr
    set @past_mappings_viewname = 'MSmerge_ppmv_' + @guidstr
    if EXISTS (select * from sys.objects where name=@current_mappings_viewname and type='V')
    BEGIN
        select @ownername = schema_name(schema_id) from sys.objects where  name=@current_mappings_viewname
        select @viewname = QUOTENAME(@ownername) + '.' + QUOTENAME(@current_mappings_viewname)
        exec ('drop view ' + @viewname)
            if @@ERROR<>0 return (1)
    END
        
    if EXISTS (select * from sys.objects where name=@past_mappings_viewname and type='V')
    BEGIN
        select @ownername = schema_name(schema_id) from sys.objects where  name=@past_mappings_viewname
        select @viewname = QUOTENAME(@ownername) + '.' + QUOTENAME(@past_mappings_viewname)
        exec ('drop view ' + @viewname)
            if @@ERROR<>0 return (1)
    END
    

    /* drop article specific partition views created by sp_MSpublicationview
       doing it here since this is where we cleanup article specific views */
    if object_id('dbo.sysmergepartitioninfoview', 'V') is not NULL
    begin
        select @partition_view_name = OBJECT_NAME(partition_view_id)
            from dbo.sysmergepartitioninfoview where
            pubid = @pubid and nickname = @tablenick
        if @partition_view_name is not null
        begin
            select @ownername = schema_name(schema_id) from sys.objects where  name=@partition_view_name
            select @viewname = QUOTENAME(@ownername) + '.' + QUOTENAME(@partition_view_name)
            exec ('drop view ' + @viewname)
            if @@ERROR<>0 return (1)
        end
    end

    -- if this article is published in another publication do not drop the identity constraint
    -- do not delete the publisher entry from MSmerge_identity_range. Update the pubid
    -- with the other pubid that exists
    if object_id('dbo.MSmerge_identity_range', 'U') is not NULL
    begin
        exec @retcode = sys.sp_MSremoveidrangesupport @pubid, @artid, 0 /* @propagate_ddl_change */ 
        IF @@ERROR <> 0 or @retcode <> 0
            return 1
    end

    -- this code is to remove the old style identity range check constraints
    if object_id('dbo.MSrepl_identity_range', 'U') is not NULL
    begin
        -- the following is needed bacause the schema of MSrepl_identity_range on distribution and subscribing
        -- or publishing databases is different in shiloh
        if exists (select 1 from sys.columns where object_id = object_id('dbo.MSrepl_identity_range', 'U') and name = 'objid')
        begin
            if exists (select 1 from dbo.MSrepl_identity_range where objid = @objid)
            begin
                -- drop the identity range check constraint. The % is here because in shiloh
                -- we used either 'pub' or 'sub' or 'repub' to indicate the role of the replica.
                -- here we only care about dropping the constraint
                select @constraintname = 'repl_identity_range_%' + convert(nvarchar(36), @artid)
                select @constraintname = REPLACE(@constraintname, '-', '_')
                if exists (select 1 from sys.objects where type ='C' and name like @constraintname)
                begin
                    select @constraintname = quotename(name) from sys.objects where name like @constraintname and type = 'C'
                    EXEC sys.sp_MSsetcontext_merge_identityrangeddlbit @onoff=1
                    exec ('alter table '+ @source_table + ' drop constraint ' + @constraintname)
                    -- don't worry about the error here
                    --IF @@ERROR <> 0 return 1
                    EXEC sys.sp_MSsetcontext_merge_identityrangeddlbit @onoff=0
                end
                delete from dbo.MSrepl_identity_range where objid = @objid
            end
        end
    end

    /* Delete from contents, tombstone, delete conflicts; Ignore errors that occur */
    if @ignore_merge_metadata = 0
    begin
        if object_id('dbo.MSmerge_current_partition_mappings') is not NULL
            delete from dbo.MSmerge_current_partition_mappings where tablenick = @tablenick

        if object_id('dbo.MSmerge_past_partition_mappings') is not NULL
            delete from dbo.MSmerge_past_partition_mappings where tablenick = @tablenick

        if object_id('MSmerge_contents') is not NULL
            delete from dbo.MSmerge_contents where tablenick = @tablenick

        if object_id('MSmerge_tombstone') is not NULL      
            delete from dbo.MSmerge_tombstone where tablenick = @tablenick

        /* Delete rows from MSmerge_genhistory - if this is the last table that refers to them */
        if not exists (select * from dbo.sysmergearticles where nickname = @tablenick and pubid <> @pubid)
        begin
            if object_id('MSmerge_generation_partition_mappings') is not NULL     
                delete from dbo.MSmerge_generation_partition_mappings 
                    where generation in (select generation from dbo.MSmerge_genhistory where art_nick = @tablenick)

            if object_id('MSmerge_genhistory') is not NULL
                delete from dbo.MSmerge_genhistory where art_nick = @tablenick
        end

        if object_id('MSmerge_conflicts_info') is not NULL
            delete from MSmerge_conflicts_info where tablenick = @tablenick
        else if object_id('MSmerge_delete_conflicts') is not NULL
            delete from MSmerge_delete_conflicts where tablenick = @tablenick
    end

    -- drop the rowguidcol if it was created by replication, and if there is no
    -- other article on this table.
    if 0=@preserve_rowguidcol and
       0 = @force_preserve_rowguidcol and
       not exists (select * from dbo.sysmergearticles where artid = @artid and pubid <> @pubid and status <> 7) 
       -- preseves rowguidcol if the table has filestream column
     and not exists (select * from sys.columns where object_id = @objid and is_filestream = 1)       
    begin
        select @ownername = schema_name(schema_id) from sys.objects where object_id = @objid       
        exec @retcode= sys.sp_MSdropguidcolumn @schemaname=@ownername, @tablename=@objectname
        if @@error<>0 or @retcode<>0 return 1
    end

    -- reset sync tran bit if present. Do it here instead of just before applying bcp
    if (object_id(@source_table, 'U') is not null)
    begin
		-- do not use @ownername in the following call because the @ownername has changed by this time. We use
		-- this variable for saving owner names of several views that we drop, mostly owned by dbo. Thankfully,
		-- we have the @source_table param that has the right value, and the proc does the right thing when @owner is N''
		exec sys.sp_MSreset_synctran_bit @owner=N'', @table=@source_table
	end

GO
GRANT EXECUTE ON [sys].[sp_MSarticlecleanup] TO [public] AS [dbo]
GO
