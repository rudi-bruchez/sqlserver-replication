SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_addmergefilter]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_addmergefilter] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_addmergefilter]
	@publication [sysname],
	@article [sysname],
	@filtername [sysname],
	@join_articlename [sysname],
	@join_filterclause [nvarchar](1000),
	@join_unique_key [int],
	@force_invalidate_snapshot [bit],
	@force_reinit_subscription [bit],
	@filter_type [tinyint]
WITH EXECUTE AS CALLER
AS
set nocount on

    declare @snapshot_ready     int
    declare @db_name            sysname
    declare @pubid              uniqueidentifier                
    declare @artid              uniqueidentifier
    declare @art_nickname       int
    declare @join_nickname      int
    declare @db                 sysname
    declare @qual_object        nvarchar(517)
    declare @unqual_object      nvarchar(258)
    declare @qual_join_object   nvarchar(517)
    declare @unqual_join_object nvarchar(258)
    declare @qual_object_view   nvarchar(517)
    declare @qual_join_object_view nvarchar(517)
    
    declare @object             sysname
    declare @vertical           int
    declare @join_vertical      int
    declare @join_object        nvarchar(140)
    declare @object_view        nvarchar(140)
    declare @join_object_view   nvarchar(140)
    declare @owner              nvarchar(258)
    declare @join_object_owner  nvarchar(258)
    declare @retcode            int
    declare @join_objid         int
    declare @objid              int
    declare @art_status         int
    declare @joinart_status     int
    declare @column_list        nvarchar(max)
    declare @inactive           int
    declare @new_active         int
    declare @new_inactive       int
    declare @reinit bit
    declare @allow_anonymous bit
    declare @compatlevel int
    declare @automatic_reinitialization_policy bit
    declare @got_merge_admin_applock bit

    select @got_merge_admin_applock = 0

    -- article status below
    select @inactive = 0 
    select @new_inactive = 5 
    select @new_active = 6   
    
    /* make sure current database is enabled for merge replication */
    exec @retcode=sys.sp_MSCheckmergereplication
    if @@ERROR<>0 or @retcode<>0
        return (1)

    /*
    ** Security Check.
    ** Only the System Administrator (SA) or the Database Owner (dbo) can
    ** add an article to a publication.
    */
    exec @retcode = sys.sp_MSreplcheck_publish
    if @@ERROR <> 0 or @retcode <> 0
        return(1)

    /*
    ** Parameter Check: @filtername.
    ** The join_filter_name cannot be NULL 
    */
    if @filtername is NULL
    begin
        raiserror (14043, 11, -1, @filtername, 'sp_addmergefilter')
        return (1)
    end

    if @join_filterclause is NULL or @join_filterclause = ''
    begin
        raiserror (14043, 11, -1, '@join_filterclause', 'sp_addmergefilter')
        return (1)
    end
    
    if @filter_type not in (1,2,3) or @filter_type is null
    begin
        raiserror (21575, 16, -1)
        goto FAILURE
    end
    
    /*
    ** Parameter Check: @publication.
    ** The @publication id cannot be NULL and must conform to the rules
    ** for identifiers.
    */
    if @publication is NULL
    begin
        raiserror (14003, 16, -1)
        return (1)
    end

    
    /*
    ** Get the pubid and make sure the publication exists
    */
    select @pubid = pubid, 
           @snapshot_ready = snapshot_ready, 
           @allow_anonymous = allow_anonymous, 
           @compatlevel = backward_comp_level,
           @automatic_reinitialization_policy = automatic_reinitialization_policy
        from dbo.sysmergepublications 
        where name = @publication and UPPER(publisher)=UPPER(publishingservername()) and publisher_db=db_name()
    if @pubid is NULL
    begin
        raiserror (20026, 16, -1, @publication)
        return (1)
    end

    /*
    ** Check to make sure that the filtername does not already exist in the 
    ** given publication
    */
    if exists (select * from sysmergesubsetfilters where filtername = @filtername and pubid = @pubid)
    begin
        raiserror (20626, 16, -1, @filtername, @publication)
        return (1)
    end
    
    if @article = @join_articlename
    begin
        raiserror(21599, 16, -1)
        return (1)
    end

    select @db_name = db_name from dbo.sysmergesubscriptions
        where (pubid=@pubid) and (subid=@pubid) 
    IF @db_name <> db_name()
    BEGIN
        RAISERROR (20047, 16, -1)
        RETURN (1)
    END           
    /*
    ** Parameter Check: @article.
    ** Check to see that the @article is valid and does exist 
    */
    if @article is NULL
        begin
            raiserror (20045, 16, -1)
            return (1)
        end
        
    select @artid = artid, @objid=objid, @vertical=vertical_partition, @art_nickname = nickname, @art_status = status from dbo.sysmergearticles where name = @article and pubid = @pubid    
    if @artid is NULL
        begin
            raiserror (20027, 16, -1, @article)
            return (1)
        end
        
    /*
    **    Get the id of the @join_articlename
    */
    select @join_objid = objid, @join_vertical= vertical_partition, @joinart_status = status from dbo.sysmergearticles where name=@join_articlename and pubid = @pubid
    
    IF @join_objid is NULL
        BEGIN
            raiserror (14027, 11, -1, @join_articlename)
            return (1)
        END

    -- don't reinit out if this is a new article and we are not adding a logical record relationship
    if (@filter_type & 2) = 2 or (@art_status <> @inactive and @art_status <> @new_inactive)
        select @reinit = 1
    else
        select @reinit = 0

    if @snapshot_ready>0
    begin
        /*
        ** make sure we know we really want to do this.
        */
        if @force_invalidate_snapshot = 0 and @snapshot_ready = 1
        begin
            raiserror(21366, 16, -1, @filtername)
            return 1
        end
        
        if @force_reinit_subscription = 0 and @reinit = 1
        begin
            -- check to see if there are any subscriptions to this publication before erroring out
            if (@allow_anonymous = 1 and @compatlevel < 90) or 
                exists (select * from dbo.sysmergesubscriptions where pubid=@pubid and subid<>pubid and status=1)
            begin
                raiserror(21367, 16, -1, @filtername)
                return 1
            end
        end
    end    
        
    /* check the validity of join_filterclause */
    select @object = object_name(@objid)
    select @owner = quotename(SCHEMA_NAME(schema_id)) from sys.objects where object_id = @objid

    select @join_object = object_name(@join_objid)
    select @join_object_owner = quotename(SCHEMA_NAME(schema_id)) from sys.objects where object_id = @join_objid
    
    select @object_view = @object
    select @join_object_view = @join_object

            
    /* is current article vertically partitioned */
    if @vertical=1
    begin
        select @object_view = 'MSmerge_OBJECT_VIEW_' + @object

        select @qual_object_view=@owner + '.' + QUOTENAME(@object_view)
        select @qual_object= @owner + '.' + QUOTENAME(@object)
        select @unqual_object = QUOTENAME(@object)

        exec @retcode = sys.sp_MSgetcolumnlist @pubid, @column_list OUTPUT, @objid
        exec ('create view ' + @qual_object_view + ' as select ' + @column_list + ' from ' + @qual_object + ' ' + @unqual_object)
        if @@ERROR<>0
        return 1
    end

    /* is join article vertically partitioned */
    if @join_vertical=1
    begin
        select @join_object_view = 'MSmerge_JOIN_OBJECT_VIEW_' + @join_object
        select @qual_join_object_view = @join_object_owner + '.' + QUOTENAME(@join_object_view)
        select @qual_join_object= @join_object_owner + '.' + QUOTENAME(@join_object)
        select @unqual_join_object = QUOTENAME(@join_object)

        exec @retcode = sys.sp_MSgetcolumnlist @pubid, @column_list OUTPUT, @join_objid
        exec ('create view ' + @qual_join_object_view + ' as select ' + @column_list + ' from ' + @qual_join_object+ ' ' + @unqual_join_object)
        if @@ERROR<>0
        begin
          if 1=@vertical
              exec('drop view ' + @qual_object_view)
          return 1
        end
    end

    select @qual_object_view=@owner + '.' + QUOTENAME(@object_view)
    select @qual_join_object_view = @join_object_owner + '.' + QUOTENAME(@join_object_view)
    select @qual_join_object= QUOTENAME(@join_object)
    select @qual_object= QUOTENAME(@object)

    exec ('declare @test int select @test=1 from ' + @qual_object_view + ' ' + @qual_object + ', ' + @qual_join_object_view + ' ' + @qual_join_object + ' where ' + @join_filterclause)
    if @@ERROR<>0
    begin
        if @vertical=1
            exec ('drop view ' + @qual_object_view)
        if @join_vertical=1
            exec ('drop view ' + @qual_join_object_view)
        raiserror(21256, 16, -1, @join_filterclause, @article)
        return (1)
    end
    
    if @vertical=1
        exec ('drop view ' + @qual_object_view)
    if @join_vertical=1
        exec ('drop view ' + @qual_join_object_view)
    
    -- check if the join filter clause contains any column of type that is not supported in
    --  a join filter.

    if exists    (
                    select * from sys.columns 
                    where object_id = @objid and 
                    (
                    --(sys.fn_IsTypeBlob(sc.system_type_id,sc.max_length) = 1) -- Blob type text,ntext,xml
                      (system_type_id in (type_id('image'), type_id('text'), type_id('ntext'), type_id('xml')))
                      or max_length = -1
                      or system_type_id = 240    -- CLR-UDTs
                    )
                    and sys.fn_MSisfilteredcolumn(@join_filterclause, name, @objid) = 1 
                )
    begin
        raiserror(22518, 16, -1, @qual_object)
        return(1)
    end

    select @join_nickname = nickname from dbo.sysmergearticles where pubid = @pubid AND objid = @join_objid 
    if @join_nickname is NULL
    begin
        raiserror (20001, 11, -1, @article, @publication)
        return (1)
    end
        
    if (@filter_type & 2) = 2
    begin
        declare @pubname_lessthan90compat sysname
        declare @owner_qualified_art_name nvarchar(400)
        declare @owner_qualified_join_name nvarchar(400)
        
        select @pubname_lessthan90compat = NULL
        
        -- Only supported with publications that have 90 compatibility level.
        select top 1 @pubname_lessthan90compat = name from dbo.sysmergepublications 
        where backward_comp_level < 90
        and pubid in 
            (select pubid from dbo.sysmergearticles where nickname = @art_nickname)
        
        if @pubname_lessthan90compat is not null
        begin
            raiserror(21574, 16, -1, @article, @pubname_lessthan90compat)
            return 1
        end
        
        select @pubname_lessthan90compat = NULL
        
        -- Only supported with publications that have 90 compatibility level.
        select top 1 @pubname_lessthan90compat = name from dbo.sysmergepublications 
        where backward_comp_level < 90
        and pubid in 
            (select pubid from dbo.sysmergearticles where nickname = @join_nickname)
        
        if @pubname_lessthan90compat is not null
        begin
            raiserror(21574, 16, -1, @join_articlename, @pubname_lessthan90compat)
            return 1
        end

        if @join_unique_key = 0
        begin
            -- logical record relation only supported with join_unique_key=1
            raiserror(21539, 16, -1)
            return 1
        end 
        
        -- Cannot use Logical records and BusinessLogicResolvers at the same time.
        if exists (select * from dbo.sysmergearticles where ((nickname = @art_nickname) or 
                                                            (nickname = @join_nickname)) and 
                                                            (resolver_clsid = '00000000-0000-0000-0000-000000000000'))
        begin
            raiserror(20708, 16, -1)
            return 1
        end

        if exists (select * from dbo.sysmergepublications where pubid = @pubid and allow_web_synchronization = 1)
        begin
            raiserror(22545, 16, -1, @publication)
            return 1
        end
                        
        if exists (select * from dbo.sysmergepublications where pubid = @pubid and sync_mode = 1)
        begin
            raiserror(22541, 16, -1, @publication)
            return 1
        end
        
        if exists (select * from dbo.sysmergesubsetfilters 
                                                where art_nickname = @art_nickname
                                                and join_nickname <> @join_nickname
                                                and (filter_type & 2) = 2)
        begin
            -- there cannot be two parents of a child in a logical record relationship
            raiserror (21538, 16, -1, @object, @join_object)
            return 1
        end
        
        if @filter_type & 1 = 1 and exists (select * from dbo.sysmergepublications 
                                            where pubid = @pubid and use_partition_groups <= 0)
        begin
            raiserror(21571, 16, -1, @publication)
            return 1
        end


        -- We do not allow logical records to be used if the articles involved in a join filter
        -- have cascading constraints defined on them
        if exists (select * from sys.foreign_keys fks
        		where fks.parent_object_id in (@join_objid, @objid) and
			        (ObjectProperty(fks.object_id, 'CnstIsDeleteCascade') = 1 
		           or ObjectProperty(fks.object_id, 'CnstIsUpdateCascade') = 1
		           or fks.delete_referential_action = 2 -- on delete set null
		           or fks.delete_referential_action = 3 -- on delete set default
		           or fks.update_referential_action = 2  -- on update set null
		           or fks.update_referential_action = 3 -- on update set default
		           )
         )
        begin
            select @owner_qualified_art_name = quotename(SCHEMA_NAME(schema_id)) + '.' + quotename(name)
            from sys.objects
            where object_id = @objid
            
            select @owner_qualified_join_name = quotename(SCHEMA_NAME(schema_id)) + '.' + quotename(name)
            from sys.objects
            where object_id = @join_objid
            
            raiserror(25019, 16, -1, @owner_qualified_art_name, @owner_qualified_join_name)
            return 1
        end        

        
        -- Enforce DRI relation
        exec @retcode = sys.sp_MScheck_joinfilter_using_dri @publication,
                                                            @article,
                                                            @objid,
                                                            @join_objid,
                                                            1,
                                                            @join_filterclause
        if @@error <> 0 or @retcode <> 0
            return 1
            
        -- based on usability feeback, we should set the allow_subscriber_initiated_snapshot
        -- option to 1 rather than raise an error.
        update dbo.sysmergepublications set allow_subscriber_initiated_snapshot = 1
            where pubid = @pubid
    end
    
    IF NOT EXISTS (select * from dbo.sysmergearticles where pubid=@pubid AND nickname = @join_nickname)
    BEGIN
        RAISERROR (20046, 16, -1) /* Only the original publisher can do so */
        RETURN (1)
    END
    
    /*
    ** Make sure that the table name specified is a table and not a view.
    */
    
    if NOT exists (select * from sys.objects
        where object_id = @join_objid AND type = 'U')
    begin
        raiserror (14028, 16, -1)
        return (1)
    end

    -- We do not allow cycles between join filters.  When trying to make article a1 a child
    -- of parent article a2, we must make sure that article a1 is not a parent of a2 in 
    -- our existing filters, either directly or indirectly.  This test inserts the nodes
    -- currently reachable by the proposed child into a temporary table, 
    -- and makes sure the proposed parent is not contained in that list.
    create table #reachable (article int)
    insert into #reachable values (@art_nickname)
    while (@@ROWCOUNT > 0)
    begin
        insert into #reachable (article)
            select distinct art_nickname from sysmergesubsetfilters where join_nickname in (select article from #reachable) 
                                                                   and art_nickname not in (select article from #reachable)
                                                                   and pubid = @pubid
    end
    if exists (select null from #reachable where article = @join_nickname)
    begin
        drop table #reachable
        raiserror(21869, 16, -1, @join_articlename, @article)
        return 1
    end

    drop table #reachable

    begin tran
    save tran addmergefilter
        
    exec @retcode = sys.sp_MSgetmergeadminapplock @timeout = 0, -- no wait
                                                  @lockowner = N'Transaction'
    if @retcode<>0 or @@error<>0
    begin
        raiserror(20713, 16, -1, 'sp_addmergefilter', @publication)
        goto FAILURE            
    end

    select @got_merge_admin_applock = 1
        
    if @snapshot_ready>0
    begin
        update dbo.sysmergepublications set snapshot_ready=2, 
            use_partition_groups = case when use_partition_groups = 1 then 2 else use_partition_groups end
        where pubid=@pubid
        if @@ERROR<>0
            goto FAILURE

        if @reinit = 1
        begin
            exec @retcode = sys.sp_MSreinitmergepublication
                                @publication = @publication,
                                @upload_first = @automatic_reinitialization_policy
            if @retcode<>0 or @@ERROR<>0
                goto FAILURE
        end
    end

    /*
    **    Add the join filter to dbo.sysmergesubsetfilters if it is not already there
    */

    IF exists (select * from dbo.sysmergesubsetfilters 
    where filtername=@filtername and  pubid=@pubid and artid=@artid) 
        begin
            raiserror (20002, 16, -1, @filtername, @article, @publication)
            goto FAILURE
        end
    
    insert INTO dbo.sysmergesubsetfilters(filtername, pubid, artid, art_nickname, join_articlename, join_nickname, join_unique_key, join_filterclause, filter_type)
        values(@filtername, @pubid, @artid, @art_nickname, @join_articlename, @join_nickname, @join_unique_key, @join_filterclause, @filter_type)                  
    if @@error <> 0
        begin
            goto FAILURE
        end
        
    exec @retcode = sys.sp_MSvalidate_wellpartitioned_articles @publication
    if @@error <> 0 or @retcode <> 0
        goto FAILURE

    execute @retcode = sys.sp_MSsubsetpublication @publication
    if @@ERROR <> 0 or @retcode <>0
        goto FAILURE
        
    exec sys.sp_MSreleasemergeadminapplock @lockowner = N'Transaction'
    commit tran
    
    return (0)
    
FAILURE:
    if @@trancount > 0
    begin
        if @got_merge_admin_applock=1
            exec sys.sp_MSreleasemergeadminapplock @lockowner = N'Transaction'
        rollback tran addmergefilter
        commit tran
    end
    RAISERROR (20038, 16, -1, @article, @publication)
    return (1)

GO
GRANT EXECUTE ON [sys].[sp_addmergefilter] TO [public] AS [dbo]
GO
