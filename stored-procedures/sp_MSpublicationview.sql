SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSpublicationview]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSpublicationview] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSpublicationview]
	@publication [sysname],
	@force_flag [int],
	@max_network_optimization [bit],
	@articlename [sysname]
WITH EXECUTE AS CALLER
AS
declare @pubid  uniqueidentifier
    declare @artid  uniqueidentifier
    declare @join_articlename   nvarchar(270)
    declare @join_viewname nvarchar(270)
    declare @join_before_view	nvarchar(270)
    declare @before_name nvarchar(270)
    declare @before_viewname	nvarchar(270)
    declare @unqual_sourcename	nvarchar(270)
    declare @unqual_sourcename2	nvarchar(540)
    declare @article 	nvarchar(270)
    declare @art_nick 	int
    declare @join_nick 	int
    declare @join_filterclause	nvarchar(1000)
    declare @bool_filterclause	nvarchar(4000)
    declare @bool_filterclause_modified	 nvarchar(4000)
    declare @view_rule 	nvarchar(max)
    declare @before_view_rule	nvarchar(max)
    declare @partition_view_rule nvarchar(max)
    declare @partition_deleted_view_rule nvarchar(max)
    declare @partition_inserted_view_rule nvarchar(max)
    declare @before_objid int
    declare @article_level int
    declare @progress 	int
    declare @art  int
    declare @viewname 	nvarchar(270)
    declare @procname 	nvarchar(300)
    declare @source_objid int
    declare @source_object nvarchar(270)
    declare @sync_objid 	int
    declare @bitset  int
    declare @permanent 	int
    declare @temporary 	int
    declare @filter_id 	int
    declare @filter_id_str nvarchar(10)
    declare @guidstr nvarchar(40)
    declare @pubidstr nvarchar(40)
    declare @rgcol  nvarchar(270)
    declare @view_type 	int
    declare @belongsname nvarchar(270)
    declare @join_nickstr nvarchar(10)
    declare @unqual_jointable	nvarchar(270)  
    declare @retcode 	smallint
    declare @hasguid 	int
    declare @vertical_partition int
    declare @join_unique_key	int
    declare @simple_join_view	int
    declare @join_filterid int
    declare @allhaveguids int
    declare @command 	nvarchar(max)
    declare @objid  int
    declare @owner  nvarchar(270)
    declare @table  nvarchar(270)
    declare @quoted_obj 	nvarchar(290)
    declare @quoted_rowguid nvarchar(290)
    declare @quoted_partition_view	nvarchar(290)
    declare @before_rowguidname sysname
    declare @snapshot_ready int
    declare @columns 	varbinary(128)
    declare @column_list nvarchar(max)
    declare @colname 	nvarchar(270)
    declare @colid  int
    declare @dynamic_filters	bit
    declare @alias_for_sourceobject sysname
    declare @prefixed_column_list	nvarchar(max)
    declare @partition_view_id	int
    declare @partition_view_name nvarchar(270), @logical_record_view nvarchar(270)
    declare @joinart_partition_view_name nvarchar(270)
    declare @use_partition_groups smallint, @dynamic_filters_function_list nvarchar(500)
    declare @partition_column_list nvarchar(max)
    declare @join_view_id int, @joinart_partition_view_id int, @join_before_view_id int
    declare @publication_number smallint

    -- Security check
    exec @retcode= sys.sp_MSreplcheck_publish
    if @@error <> 0 or @retcode <> 0 return (1)

    set @progress        = 1
    set @article_level    = 0
    set @permanent        = 1
    set @temporary        = 2
    set @allhaveguids    = 1
    set @before_rowguidname = NULL

    /*
    ** Only legal publisher can run this stored procedure
    */
    set nocount on
    /* make sure current database is enabled for merge replication */
    exec @retcode=sys.sp_MSCheckmergereplication
    if @@ERROR<>0 or @retcode<>0
        return (1)

    select @pubid = pubid, @snapshot_ready = snapshot_ready, @dynamic_filters = dynamic_filters,
    @use_partition_groups = use_partition_groups, @dynamic_filters_function_list = dynamic_filters_function_list,
    @publication_number = publication_number
    FROM dbo.sysmergepublications 
    WHERE name = @publication and UPPER(publisher)=UPPER(publishingservername()) and publisher_db=db_name() 
    
    IF @pubid IS NULL
    BEGIN
        RAISERROR (20026, 11, -1, @publication)
        RETURN (1)
    END

    select @table=object_name(objid) from dbo.sysmergearticles where pubid=@pubid and (columns is NULL or columns = 0x00)
    if @table is not NULL
    begin
        raiserror(21318, 16, -1, @table)
        return (1)
    end

    -- If snapshot is already ready, views are good.  Don't drop and recreate as someone
    -- might be using them.
    
    if @snapshot_ready = 1 and @force_flag = 0
        return (0)

    -- If the snapshot is not ready and calling code is running sp_MSpublication_view in article mode and not pub-wide mode
    -- then force the behaviour to the pub-wide mode 
    if @snapshot_ready <> 1 and @force_flag = 2
        set @force_flag = 1
        
    exec @retcode = sys.sp_MSguidtostr @pubid, @pubidstr out
    if @@ERROR <>0 OR @retcode <>0 return (1)

    create table #art(indexcol int identity NOT NULL, art_nick int NOT NULL, article_level int NOT NULL)
    if @@ERROR <> 0
    begin
        goto FAILURE
    end


    begin tran
    save tran sp_MSpublicationview
    
    while @progress > 0
    BEGIN
        /*
        ** Select articles that have either a boolean_filter or at least one join filter 
        ** into a temp table in an optimized order.
        */

        -- This inserts into #art the article levels of all articles.
        insert into #art(art_nick, article_level) select nickname, @article_level from dbo.sysmergearticles 
            where pubid=@pubid and nickname not in (select art_nick from #art)
                and nickname not in 
                (select     art_nickname from dbo.sysmergesubsetfilters
                    where pubid=@pubid and (filter_type & 1) = 1 and join_nickname not in 
                        (select art_nick from #art))
        /*
        ** NOTENOTE: add error checking here.
        */

        set @progress = @@rowcount
        select @article_level = @article_level + 1
    END

    /* 
    ** When the force_flag is 2, sp_MSpublicationview is being invoked from code paths such as DDL - ADD/DROP/ALTER COLUMN 
    ** and sp_repladdcolumn/sp_repldropcolumn - In that case - prune the #art table by removing nicknames that are not related
    ** to the article name that is passed int
    */
    if (@force_flag = 2)
    begin
    	select @art_nick = nickname from dbo.sysmergearticles 
            where pubid=@pubid and name = @articlename
        delete from #art where art_nick not in (select distinct nickname from sys.fn_MSdetermine_related_articles(@art_nick))        
    end
    select @art_nick = NULL

    -- Views for a particular article are being recreated only.
    if (@force_flag = 2)
    begin
        select @art_nick = nickname, @artid = artid from dbo.sysmergearticles where pubid=@pubid and name = @articlename 
        if (@art_nick is NOT NULL)
        begin
            /* Drop the old view */
            select @viewname = OBJECT_NAME (sync_objid), 
                    @before_viewname = OBJECT_NAME(before_view_objid),
                    @partition_view_name = OBJECT_NAME(partition_view_id),
                    @logical_record_view = object_name(logical_record_view)
                from dbo.sysmergepartitioninfoview where
                pubid = @pubid and nickname = @art_nick
                
            if @viewname IS NOT NULL
            begin
                select @quoted_obj = QUOTENAME(@viewname)
                exec ('drop view ' + @quoted_obj)
            end
            if @before_viewname IS NOT NULL
            begin
                select @quoted_obj = QUOTENAME(@before_viewname)
                exec ('drop view ' + @quoted_obj)
            end

            if @partition_view_name is not null
            begin
                select @quoted_partition_view = QUOTENAME(@partition_view_name)
                exec ('drop view ' + @quoted_partition_view)
            end

            if object_id(@logical_record_view) is not NULL
				and not exists (select * from sysmergepartitioninfo where logical_record_view = object_id(@logical_record_view)
					and pubid <> @pubid)
            begin
                select @quoted_obj = QUOTENAME(@logical_record_view)
                exec ('drop view ' + @quoted_obj)
            end

            /* Update the row in dbo.sysmergearticles */
            update dbo.sysmergearticles set view_type = 0, 
                sync_objid = objid,
                before_view_objid = NULL
                where pubid = @pubid and nickname = @art_nick
            if @@ERROR <> 0 goto FAILURE
            
            update dbo.sysmergepartitioninfo 
                set partition_view_id = NULL,
                partition_deleted_view_rule = NULL,
                partition_inserted_view_rule = NULL,
                logical_record_view = NULL,
                logical_record_parent_nickname = NULL,
                logical_record_deleted_view_rule = NULL
                where pubid = @pubid and artid = @artid
            if @@ERROR <> 0 goto FAILURE
        end
    end
    else
    begin 
        /* Drop the old views and reset sync_objid */
        select top 1 @art_nick = nickname, @artid = artid from dbo.sysmergearticles 
            where pubid = @pubid and objid<>sync_objid
            order by nickname
        while @art_nick is not null
        begin
            /* Drop the old view */
            select @viewname = OBJECT_NAME (sync_objid), 
                    @before_viewname = OBJECT_NAME(before_view_objid),
                    @partition_view_name = OBJECT_NAME(partition_view_id),
                    @logical_record_view = object_name(logical_record_view)
                from dbo.sysmergepartitioninfoview where
                pubid = @pubid and nickname = @art_nick
                
            if @viewname IS NOT NULL
            begin
                select @quoted_obj = QUOTENAME(@viewname)
                exec ('drop view ' + @quoted_obj)
            end
            if @before_viewname IS NOT NULL
            begin
                select @quoted_obj = QUOTENAME(@before_viewname)
                exec ('drop view ' + @quoted_obj)
            end

            if @partition_view_name is not null
            begin
                select @quoted_partition_view = QUOTENAME(@partition_view_name)
                exec ('drop view ' + @quoted_partition_view)
            end

            if object_id(@logical_record_view) is not NULL
                and not exists (select * from sysmergepartitioninfo where logical_record_view = object_id(@logical_record_view)
                    and pubid <> @pubid)
            begin
                select @quoted_obj = QUOTENAME(@logical_record_view)
                exec ('drop view ' + @quoted_obj)
            end

            /* Update the row in dbo.sysmergearticles */
            update dbo.sysmergearticles set view_type = 0, 
                sync_objid = objid,
                before_view_objid = NULL
                where pubid = @pubid and nickname = @art_nick
            if @@ERROR <> 0 goto FAILURE
            
            update dbo.sysmergepartitioninfo 
                set partition_view_id = NULL,
                partition_deleted_view_rule = NULL,
                partition_inserted_view_rule = NULL,
                logical_record_view = NULL,
                logical_record_parent_nickname = NULL,
                logical_record_deleted_view_rule = NULL
                where pubid = @pubid and artid = @artid
            if @@ERROR <> 0 goto FAILURE

            select @art_nick = NULL, @artid = NULL
            /* Find the next one */
            select top 1 @art_nick = nickname, @artid = artid from dbo.sysmergearticles 
            where pubid = @pubid and objid<>sync_objid
            order by nickname
        end
    end

    -- do the following only after all tables have been "activated" i.e. rowguid column has been added
    -- basically this proc gets calls twice from the snapshot agent. Once before rowguidcols are present
    -- and once after the rowguid columns have been created. We want the partition groups related setup
    -- to happen only afte rowguidcols have been established.
    select @art_nick = min(nickname) from dbo.sysmergearticles where pubid = @pubid
    while @art_nick is not null
    begin
        select @objid = objid from dbo.sysmergearticles where pubid = @pubid and nickname = @art_nick
        if not exists (select name from sys.columns where object_id=@objid and is_rowguidcol=1)
            set @allhaveguids    = 0
        select @art_nick = min(nickname) from dbo.sysmergearticles where pubid = @pubid and nickname > @art_nick
    end
    if @allhaveguids = 1
    begin
        exec @retcode = sys.sp_MSsetup_use_partition_groups @publication
        if @retcode <> 0 or @@error <> 0 
            goto FAILURE
        select @use_partition_groups = use_partition_groups from dbo.sysmergepublications where pubid = @pubid
    end
    
    if (@use_partition_groups = 1)
    begin
        create table #list_of_functions (function_name_with_parens nvarchar(500), function_name_without_parens sysname)
        exec @retcode = sp_MSsetup_function_list_table @pubid
        if @retcode <> 0 or @@error <> 0 goto FAILURE
    end

    set @art = 0
    select @art=min(indexcol) from #art where indexcol>@art

    while (@art is not null)
    begin
        select @art_nick=art_nick, @article_level = article_level from #art 
                where indexcol = @art
        select @article = name, @artid = artid, @columns = columns, @source_objid = objid,
            @sync_objid = sync_objid, @procname = view_sel_proc, 
            @partition_view_id = partition_view_id
            from dbo.sysmergepartitioninfoview 
            where nickname=@art_nick and pubid = @pubid

        -- first create the before image table if one is needed
        exec @retcode = sys.sp_MScreatebeforetable @source_objid
        if @@error <> 0 or @retcode <> 0
            goto FAILURE
        select @before_objid = before_image_objid
            from dbo.sysmergepartitioninfoview 
            where nickname=@art_nick and pubid = @pubid
                
        exec @retcode = sys.sp_MSgetcolumnlist @pubid, @column_list OUTPUT, @source_objid
        
        exec @retcode = sys.sp_MSgetfiltercolumnlist @pubid, @partition_column_list OUTPUT, @source_objid
        if @@error <> 0 or @retcode <> 0
            goto FAILURE
        
        set @before_name = OBJECT_NAME(@before_objid)
        if @before_name is not null
        begin
            select @before_rowguidname=name from sys.columns where object_id=@source_objid and is_rowguidcol=1
            exec @retcode = sys.sp_MSguidtostr @pubid, @guidstr out
            set @before_viewname = @before_name + '_v_' + @guidstr
        end
        else
            set @before_viewname = NULL
        
        -- Owner-qualify the name for perf (less recompiles). 
        select @before_name = QUOTENAME(SCHEMA_NAME(schema_id)) + '.' + QUOTENAME(OBJECT_NAME(@before_objid))
            from sys.objects where object_id = @before_objid
            
        exec @retcode = sys.sp_MSguidtostr @artid, @guidstr out
        if @@ERROR <>0 OR @retcode <>0 goto FAILURE

        select @source_object = QUOTENAME(SCHEMA_NAME(schema_id)) + '.' + QUOTENAME(name) from sys.objects 
                where object_id = @source_objid 
        select @unqual_sourcename = QUOTENAME(OBJECT_NAME(@source_objid))
        select @unqual_sourcename2 = sys.fn_replreplacesinglequote(@source_object)
        
        select @bool_filterclause=subset_filterclause, @vertical_partition=vertical_partition 
            from dbo.sysmergearticles where name = @article and pubid = @pubid

        -- verify the syntax of boolean filter, if added with vertical-partition to true
        -- in this case, the filter clause can contain columns that do not exist in the partition.
        if len(@bool_filterclause) > 0
        begin
            select @bool_filterclause = ' (' + @bool_filterclause + ') '
            
        end
                
        set @rgcol = NULL
        select @rgcol = QUOTENAME(name) from sys.columns where object_id = @source_objid and
                is_rowguidcol = 1
        if @rgcol is not NULL
            set @hasguid = 1
        else 
        begin
            set @hasguid = 0
            set @allhaveguids = 0
        end

        /*
        ** Process non looping articles that have either a boolean or a join_filter.
        */
        if ( @article_level > 0 OR (len(@bool_filterclause) > 0) ) 
        begin
            /*
            ** If the article has a previously generated view, then drop the view before 
            ** creating the new one.
            */
            set @partition_view_name = NULL
            select @partition_view_name = name from sys.objects where object_id = @partition_view_id and type = 'V' and is_ms_shipped = 1 
            if @partition_view_name IS NOT NULL
            begin
                select @quoted_partition_view = QUOTENAME(@partition_view_name)
                exec ('drop view ' + @quoted_partition_view)
                if @@ERROR<>0 goto FAILURE
            end

            set @viewname = NULL
            select @viewname = name from sys.objects where object_id = @sync_objid and type='V' and is_ms_shipped = 1 
            if @viewname IS NOT NULL
            begin
                select @quoted_obj = QUOTENAME(@viewname)
                exec ('drop view ' + @quoted_obj)
                if @@ERROR<>0 goto FAILURE
            end
            
            /*
            ** Any join filter(s)? If any, process join filter(s)
            */
            if (@article_level > 0) 
            begin
                declare pub1 CURSOR LOCAL FAST_FORWARD FOR select join_filterclause, join_nickname, join_articlename,
                    join_unique_key, join_filterid from dbo.sysmergesubsetfilters where pubid=@pubid and artid=@artid and (filter_type & 1)=1
                    FOR READ ONLY
                open pub1                                        
                fetch pub1 into @join_filterclause, @join_nick, @join_articlename, @join_unique_key, @join_filterid
                select @join_filterclause=' ( ' + @join_filterclause + ') '
                select @unqual_jointable = QUOTENAME(name) from sys.objects 
                    where object_id = (select objid from dbo.sysmergearticles where name=@join_articlename and pubid=@pubid) 

                select @join_viewname = NULL, @joinart_partition_view_name = NULL, @join_before_view = NULL
                
                if @max_network_optimization = 0
                    select @join_view_id = sync_objid,
                        @join_before_view_id = before_image_objid,
                        @joinart_partition_view_id = partition_view_id
                        from dbo.sysmergepartitioninfoview where nickname = @join_nick and pubid = @pubid
                else
                    select @join_view_id = sync_objid,
                        @join_before_view_id = case when before_view_objid is null then before_image_objid else before_view_objid end,
                        @joinart_partition_view_id = partition_view_id
                        from dbo.sysmergepartitioninfoview where nickname = @join_nick and pubid = @pubid
                    
                -- Owner qualify the names for perf (less recompilations).
                select @join_viewname = QUOTENAME(SCHEMA_NAME(schema_id)) + '.' + QUOTENAME(object_name(@join_view_id))
                    from sys.objects where object_id = @join_view_id
                    
                select @joinart_partition_view_name = QUOTENAME(SCHEMA_NAME(schema_id)) + '.' + QUOTENAME(object_name(@joinart_partition_view_id))
                    from sys.objects where object_id = @joinart_partition_view_id
                    
                select @join_before_view = QUOTENAME(SCHEMA_NAME(schema_id)) + '.' + QUOTENAME(object_name(@join_before_view_id))
                    from sys.objects where object_id = @join_before_view_id
                    
                -- if the parent-child relationship is one-many, AND there is only one parent, and if the child
                -- itself doesn't have any boolean filters, then use the simple view.
                if (@join_unique_key = 1 and (@bool_filterclause is null or len(@bool_filterclause) = 0) and
                    not exists (select * from dbo.sysmergesubsetfilters where pubid=@pubid and artid=@artid and join_filterid <> @join_filterid and (filter_type & 1) = 1))
                begin
                    set @simple_join_view = 1
                    
                    if @column_list = ' * '
                        select @column_list = ' ' + @unqual_sourcename + '.* '
                    
                    set @view_rule = 'select ' + @column_list + ' from ' + @source_object + ' ' + @unqual_sourcename + ' , ' +    @join_viewname + ' ' + @unqual_jointable + ' where ' + @join_filterclause + 
                                     ' and ({fn ISPALUSER(''' + convert(nvarchar(36), @pubid) + ''')} = 1)'
                                     
                    if @joinart_partition_view_name is not null and @use_partition_groups = 1
                    begin
                        set @partition_view_rule = 'select ' + @partition_column_list + ', ' + @unqual_jointable + '.' + 'partition_id from ' + @source_object + ' ' + @unqual_sourcename + ' , ' +  @joinart_partition_view_name + ' ' + @unqual_jointable + ' where (' + @join_filterclause +    
                                                    ') and ({fn ISPALUSER(''' + convert(nvarchar(36), @pubid) + ''')} = 1 
                                                    or (HAS_PERMS_BY_NAME(''' + @unqual_sourcename2+''', ''OBJECT'', ''SELECT'')
                                                    | HAS_PERMS_BY_NAME(''' + @unqual_sourcename2+''', ''OBJECT'', ''UPDATE'')
                                                    | HAS_PERMS_BY_NAME(''' + @unqual_sourcename2+''', ''OBJECT'', ''INSERT'')
                                                    | HAS_PERMS_BY_NAME(''' + @unqual_sourcename2+''', ''OBJECT'', ''DELETE''))=1)'
                        set @partition_deleted_view_rule = 'select ' + @partition_column_list + ', ' + @unqual_jointable + '.' + 'partition_id from deleted ' + @unqual_sourcename + ' , ' +  @joinart_partition_view_name + ' ' + @unqual_jointable + ' where (' + @join_filterclause + ')'
                        set @partition_inserted_view_rule = 'select ' + @partition_column_list + ', ' + @unqual_jointable + '.' + 'partition_id from inserted ' + @unqual_sourcename + ' , ' +     @joinart_partition_view_name + ' ' + @unqual_jointable + ' where  (' + @join_filterclause + ')'
                    end
                end
                else
                begin
                    set @simple_join_view = 0
                    
                    /* Alias the source object with the unqualified name and use that to select the rowguidcol */                    
                    set @view_rule = 'select ' + @unqual_sourcename + '.rowguidcol from ' + @source_object    + ' ' + @unqual_sourcename + ' , ' +  @join_viewname + ' ' + @unqual_jointable + ' where ' + @join_filterclause +
                                     ' and ({fn ISPALUSER(''' + convert(nvarchar(36), @pubid) + ''')} = 1)'

                    if @column_list = ' * '
                        select @column_list = ' ' + @unqual_sourcename + '.* '

                    if @joinart_partition_view_name is not null and @use_partition_groups = 1
                    begin
                        set @partition_view_rule = 'select ' + @partition_column_list + ', ' + @unqual_jointable + '.' + 'partition_id from ' + @source_object + ' ' + @unqual_sourcename + ' , ' +  @joinart_partition_view_name + ' ' + @unqual_jointable + ' where (' + @join_filterclause + 
                                                    ') and ({fn ISPALUSER(''' + convert(nvarchar(36), @pubid) + ''')} = 1  
							   or (HAS_PERMS_BY_NAME(''' + @unqual_sourcename2+''', ''OBJECT'', ''SELECT'')
                                                    | HAS_PERMS_BY_NAME(''' + @unqual_sourcename2+''', ''OBJECT'', ''UPDATE'')
                                                    | HAS_PERMS_BY_NAME(''' + @unqual_sourcename2+''', ''OBJECT'', ''INSERT'')
                                                    | HAS_PERMS_BY_NAME(''' + @unqual_sourcename2+''', ''OBJECT'', ''DELETE''))=1)'
                        set @partition_deleted_view_rule = 'select ' + @partition_column_list + ', ' + @unqual_jointable + '.' + 'partition_id from deleted ' + @unqual_sourcename + ' , ' +  @joinart_partition_view_name + ' ' + @unqual_jointable + ' where (' + @join_filterclause + ')'
                        set @partition_inserted_view_rule = 'select ' + @partition_column_list + ', ' + @unqual_jointable + '.' + 'partition_id from inserted ' + @unqual_sourcename + ' , ' +     @joinart_partition_view_name + ' ' + @unqual_jointable + ' where  (' + @join_filterclause + ')'
                    end
                end
                
                if @before_name is not null
                begin
                    set @before_view_rule = 'select * from ' + @before_name + ' ' +     @unqual_sourcename + ' where (exists (select * from ' +
                        @join_viewname + ' ' + @unqual_jointable + ' where ' + @join_filterclause + ') ' 
                    if @join_before_view is not NULL
                        set @before_view_rule = @before_view_rule + ' or exists (select * from ' +
                                @join_before_view + ' ' + @unqual_jointable + ' where ' + @join_filterclause + ')'
                end
                                
                fetch next from pub1 into @join_filterclause, @join_nick, @join_articlename, @join_unique_key, @join_filterid
                WHILE (@@fetch_status <> -1)
                begin
                    select @join_filterclause=' ( ' + @join_filterclause + ') '
                    
                    select @unqual_jointable= quotename(name)
                                                from sys.objects 
                                                where object_id = (select objid from dbo.sysmergearticles where name=@join_articlename and pubid=@pubid) 
                
                    select @join_viewname = NULL, @joinart_partition_view_name = NULL, @join_before_view = NULL
                    
                    if @max_network_optimization = 0
                        select @join_view_id = sync_objid,
                            @join_before_view_id = before_image_objid,
                            @joinart_partition_view_id = partition_view_id
                            from dbo.sysmergepartitioninfoview 
                            where nickname = @join_nick and pubid = @pubid
                    else
                        select @join_view_id = sync_objid,
                            @join_before_view_id = case when before_view_objid is null then before_image_objid else before_view_objid end,
                            @joinart_partition_view_id = partition_view_id
                            from dbo.sysmergepartitioninfoview 
                            where nickname = @join_nick and pubid = @pubid
                        
                    -- Owner qualify the names for perf (less recompilations).
                    select @join_viewname = QUOTENAME(SCHEMA_NAME(schema_id)) + '.' + QUOTENAME(object_name(@join_view_id))
                        from sys.objects where object_id = @join_view_id
                        
                    select @joinart_partition_view_name = QUOTENAME(SCHEMA_NAME(schema_id)) + '.' + QUOTENAME(object_name(@joinart_partition_view_id))
                        from sys.objects where object_id = @joinart_partition_view_id
                        
                    select @join_before_view = QUOTENAME(SCHEMA_NAME(schema_id)) + '.' + QUOTENAME(object_name(@join_before_view_id))
                        from sys.objects where object_id = @join_before_view_id
                
                    set @view_rule = @view_rule + ' union select ' + @unqual_sourcename + '.rowguidcol from ' + @source_object + ' ' + @unqual_sourcename + ', ' +     @join_viewname + ' ' + @unqual_jointable + ' where ' + @join_filterclause +
                                    ' and ({fn ISPALUSER(''' + convert(nvarchar(36), @pubid) + ''')} = 1)'
                                    
                    if @before_name is not null
                    begin
                        set @before_view_rule = @before_view_rule + ' or exists (select * from ' +
                                @join_viewname + ' ' + @unqual_jointable + ' where ' + @join_filterclause + ') '
                        if @join_before_view is not NULL
                            select @before_view_rule = @before_view_rule + ' or exists (select * from ' +
                                    @join_before_view + ' ' + @unqual_jointable + ' where ' + @join_filterclause + ') '
                    end

                    if @column_list = ' * '
                        select @column_list = ' ' + @unqual_sourcename + '.* '
                    
                    if @joinart_partition_view_name is not null and @use_partition_groups = 1
                    begin
                        set @partition_view_rule = @partition_view_rule + ' union select ' + @partition_column_list + ', ' + @unqual_jointable + '.' + 'partition_id from ' + @source_object + ' ' + @unqual_sourcename + ' , ' +    @joinart_partition_view_name + ' ' + @unqual_jointable + ' where (' + @join_filterclause +
                                                    ') and ({fn ISPALUSER(''' + convert(nvarchar(36), @pubid) + ''')} = 1 or 
							   (HAS_PERMS_BY_NAME(''' + @unqual_sourcename2+''', ''OBJECT'', ''SELECT'')
                                                    | HAS_PERMS_BY_NAME(''' + @unqual_sourcename2+''', ''OBJECT'', ''UPDATE'')
                                                    | HAS_PERMS_BY_NAME(''' + @unqual_sourcename2+''', ''OBJECT'', ''INSERT'')
                                                    | HAS_PERMS_BY_NAME(''' + @unqual_sourcename2+''', ''OBJECT'', ''DELETE''))=1)'

                        set @partition_deleted_view_rule = @partition_deleted_view_rule + ' union select ' + @partition_column_list + ', ' + @unqual_jointable + '.' + 'partition_id from deleted ' + @unqual_sourcename + ' , ' +     @joinart_partition_view_name + ' ' + @unqual_jointable + ' where (' + @join_filterclause + ')'
                        set @partition_inserted_view_rule = @partition_inserted_view_rule + ' union select ' + @partition_column_list + ', ' + @unqual_jointable + '.' + 'partition_id from inserted ' + @unqual_sourcename + ' , ' +    @joinart_partition_view_name + ' ' + @unqual_jointable + ' where  (' + @join_filterclause + ')'
                    end
                 
                    fetch next from pub1 into @join_filterclause, @join_nick, @join_articlename, @join_unique_key, @join_filterid
                end 
                
                close pub1
                deallocate pub1
                        
                if len(@bool_filterclause) > 0
                begin
                    set @view_rule = @view_rule + ' union select ' + @unqual_sourcename + '.rowguidcol from ' + @source_object + ' ' + @unqual_sourcename + ' where '+ @bool_filterclause +
                                    ' and ({fn ISPALUSER(''' + convert(nvarchar(36), @pubid) + ''')} = 1)'
                  
                    if @before_name is not null
                        set @before_view_rule = @before_view_rule + ' or ' + @bool_filterclause

                    -- Determine if this boolean filter on this article in this publication has a dynamic filter in it.
                    -- If it does, then join with dbo.dbo.MSmerge_partition_groups with the WHERE boolean filter clause replacing 
                    -- all instances of function calls with msp.<column name>. If it doesn't, use a hard-coded -1 for the partition id,
                    -- e.g. select <column list>, -1 from table where bool filter clause.                 
                    if @use_partition_groups = 1
                    begin
                        if @column_list = ' * '
                            select @column_list = ' ' + @unqual_sourcename + '.* '

                        if exists (select * from #list_of_functions 
                                    where REPLACE(REPLACE(REPLACE(REPLACE(UPPER(@bool_filterclause collate SQL_Latin1_General_CP1_CS_AS), char(0x20),''), char(0x09),''), char(0x0D),''), char(0x0A),'')
                                    like '%' + UPPER(function_name_with_parens) + '%'
                                    and sys.fn_MSisfilteredcolumn(UPPER(@bool_filterclause), UPPER(function_name_without_parens), NULL) = 1)
                        begin
                            set @partition_view_rule = @partition_view_rule + ' union select ' + @partition_column_list + ', msp.partition_id from ' + @source_object + ' ' + @unqual_sourcename + ' , dbo.MSmerge_partition_groups msp where (msp.publication_number = ' + convert(nvarchar, @publication_number) + ' and ' 
                            set @partition_deleted_view_rule = @partition_deleted_view_rule + ' union select ' + @partition_column_list + ', msp.partition_id from deleted ' + @unqual_sourcename + ' , dbo.MSmerge_partition_groups msp where (msp.publication_number = ' + convert(nvarchar, @publication_number) + ' and ' 
                            set @partition_inserted_view_rule = @partition_inserted_view_rule + ' union select ' + @partition_column_list + ', msp.partition_id from inserted ' + @unqual_sourcename + ' , dbo.MSmerge_partition_groups msp where  (msp.publication_number = ' + convert(nvarchar, @publication_number) + ' and ' 
                            exec @retcode = sys.sp_MSmodify_boolfilterclause @bool_filterclause, @bool_filterclause_modified OUTPUT
                            set @bool_filterclause_modified= '(' + @bool_filterclause_modified + ')'
                            if @retcode <> 0 or @@error <> 0
                                goto FAILURE
                            set @partition_view_rule = @partition_view_rule + @bool_filterclause_modified +
                                                    ') and ({fn ISPALUSER(''' + convert(nvarchar(36), @pubid) + ''')} = 1 							   
                                                    or (HAS_PERMS_BY_NAME(''' + @unqual_sourcename2+''', ''OBJECT'', ''SELECT'')
                                                    | HAS_PERMS_BY_NAME(''' + @unqual_sourcename2+''', ''OBJECT'', ''UPDATE'')
                                                    | HAS_PERMS_BY_NAME(''' + @unqual_sourcename2+''', ''OBJECT'', ''INSERT'')
                                                    | HAS_PERMS_BY_NAME(''' + @unqual_sourcename2+''', ''OBJECT'', ''DELETE''))=1)'
                            set @partition_deleted_view_rule = @partition_deleted_view_rule + @bool_filterclause_modified + ')'
                            set @partition_inserted_view_rule = @partition_inserted_view_rule + @bool_filterclause_modified + ')'
                        end
                        else
                        begin
                            set @partition_view_rule = @partition_view_rule + ' union select ' + @partition_column_list + ', partition_id = -1 from ' + @source_object + ' ' + @unqual_sourcename + ' where ('+ @bool_filterclause +
                                                    ') and ({fn ISPALUSER(''' + convert(nvarchar(36), @pubid) + ''')} = 1 
							   or (HAS_PERMS_BY_NAME(''' + @unqual_sourcename2+''', ''OBJECT'', ''SELECT'')
                                                    | HAS_PERMS_BY_NAME(''' + @unqual_sourcename2+''', ''OBJECT'', ''UPDATE'')
                                                    | HAS_PERMS_BY_NAME(''' + @unqual_sourcename2+''', ''OBJECT'', ''INSERT'')
                                                    | HAS_PERMS_BY_NAME(''' + @unqual_sourcename2+''', ''OBJECT'', ''DELETE''))=1)'

                            set @partition_deleted_view_rule = @partition_deleted_view_rule + ' union select ' + @partition_column_list + ', partition_id = -1 from deleted ' + @unqual_sourcename + ' where ('+ @bool_filterclause + ')'
                            set @partition_inserted_view_rule = @partition_inserted_view_rule + ' union select ' + @partition_column_list + ', partition_id = -1 from inserted ' + @unqual_sourcename + ' where  ('+ @bool_filterclause + ')'
                        end 
                    end
                end     
                -- Now do the actual view rule as a semi-join, if not a simple join on unique key
                if (@simple_join_view = 0)
                begin
                    /* 
                    ** Generate a unique alias for the outer select to make sure that it does not generate an
                    ** ambiguous reference with table names used in the join_filter clause 
                    */
                    set @alias_for_sourceobject = 'alias_' + @guidstr
                    exec @retcode = sys.sp_MSgetcolumnlist @pubid, @prefixed_column_list OUTPUT, @source_objid, @alias_for_sourceobject
                    set @view_rule = 'select ' + @prefixed_column_list + ' from ' + @source_object + ' ' + @alias_for_sourceobject + ' where rowguidcol in (' + @view_rule + ')' +
                                    ' and ({fn ISPALUSER(''' + convert(nvarchar(36), @pubid) + ''')} = 1)'
                    
                end
            end
            else  /* boolean filter only */
            begin
                select @view_rule = ' select ' + @column_list + ' from '+ @source_object + ' ' + @unqual_sourcename + ' where '+ @bool_filterclause +
                                        ' and ({fn ISPALUSER(''' + convert(nvarchar(36), @pubid) + ''')} = 1)'

                if @before_name is not null
                    set @before_view_rule = ' select * from ' + @before_name + ' ' + @unqual_sourcename + ' where (' + @bool_filterclause

                -- Determine if this boolean filter on this article in this publication has a dynamic filter in it.
                -- If it does, then join with dbo.MSmerge_partition_groups with the WHERE boolean filter clause replacing 
                -- all instances of function calls with msp.<column name>. If it doesn't, use a hard-coded -1 for the partition id,
                -- e.g. select <column list>, -1 from table where bool filter clause.
                if @use_partition_groups = 1
                begin
                    if @column_list = ' * '
                        select @column_list = ' ' + @unqual_sourcename + '.* '

                    if exists (select * from #list_of_functions 
                                where REPLACE(REPLACE(REPLACE(REPLACE(UPPER(@bool_filterclause collate SQL_Latin1_General_CP1_CS_AS), char(0x20),''), char(0x09),''), char(0x0D),''), char(0x0A),'')
                                like '%' + UPPER(function_name_with_parens) + '%'
                                and sys.fn_MSisfilteredcolumn(UPPER(@bool_filterclause), UPPER(function_name_without_parens), NULL) = 1 )
                                
                    begin
                        set @partition_view_rule = ' select ' + @partition_column_list + ', msp.partition_id from ' + @source_object + ' ' + @unqual_sourcename + ' , dbo.MSmerge_partition_groups msp where (msp.publication_number = ' + convert(nvarchar, @publication_number) + ' and ' 
                        set @partition_deleted_view_rule = ' select ' + @partition_column_list + ', msp.partition_id from deleted ' + @unqual_sourcename + ' , dbo.MSmerge_partition_groups msp where (msp.publication_number = ' + convert(nvarchar, @publication_number) + ' and ' 
                        set @partition_inserted_view_rule = ' select ' + @partition_column_list + ', msp.partition_id from inserted ' + @unqual_sourcename + ' , dbo.MSmerge_partition_groups msp where  (msp.publication_number = ' + convert(nvarchar, @publication_number) + ' and ' 
                        exec @retcode = sys.sp_MSmodify_boolfilterclause @bool_filterclause, @bool_filterclause_modified OUTPUT
                        set @bool_filterclause_modified= '(' + @bool_filterclause_modified + ')'
                        if @retcode <> 0 or @@error <> 0
                            goto FAILURE
                        set @partition_view_rule = @partition_view_rule + @bool_filterclause_modified +
                                                    ') and ({fn ISPALUSER(''' + convert(nvarchar(36), @pubid) + ''')} = 1 
							   or (HAS_PERMS_BY_NAME(''' + @unqual_sourcename2+''', ''OBJECT'', ''SELECT'')
                                                    | HAS_PERMS_BY_NAME(''' + @unqual_sourcename2+''', ''OBJECT'', ''UPDATE'')
                                                    | HAS_PERMS_BY_NAME(''' + @unqual_sourcename2+''', ''OBJECT'', ''INSERT'')
                                                    | HAS_PERMS_BY_NAME(''' + @unqual_sourcename2+''', ''OBJECT'', ''DELETE''))=1)'                                                    
                        set @partition_deleted_view_rule = @partition_deleted_view_rule + @bool_filterclause_modified +  ')'
                        set @partition_inserted_view_rule = @partition_inserted_view_rule + @bool_filterclause_modified + ')'
                    end
                    else
                    begin
                        set @partition_view_rule = ' select ' + @partition_column_list + ', partition_id = -1 from ' + @source_object + ' ' + @unqual_sourcename + ' where ('+ @bool_filterclause +
                                                    ') and ({fn ISPALUSER(''' + convert(nvarchar(36), @pubid) + ''')} = 1
							   or (HAS_PERMS_BY_NAME(''' + @unqual_sourcename2+''', ''OBJECT'', ''SELECT'')
                                                    | HAS_PERMS_BY_NAME(''' + @unqual_sourcename2+''', ''OBJECT'', ''UPDATE'')
                                                    | HAS_PERMS_BY_NAME(''' + @unqual_sourcename2+''', ''OBJECT'', ''INSERT'')
                                                    | HAS_PERMS_BY_NAME(''' + @unqual_sourcename2+''', ''OBJECT'', ''DELETE''))=1)'
                        set @partition_inserted_view_rule = ' select ' + @partition_column_list + ', partition_id = -1 from inserted ' + @unqual_sourcename + ' where  ('+ @bool_filterclause + ')'
                        set @partition_deleted_view_rule = ' select ' + @partition_column_list + ', partition_id = -1 from deleted ' + @unqual_sourcename + ' where ('+ @bool_filterclause + ')'
                    end        
                end
            end
                           
            select @viewname = 'MSmerge_' + @publication + '_' + @article + '_VIEW'
            if (len(@viewname) > 128)
            begin
                select @viewname = sys.fn_MSmerge_get_syncview_name (@publication, @article, @pubid, @artid)
            end
            select @quoted_obj = QUOTENAME(@viewname)

            -- drop the view if it already exists
            if object_id(@quoted_obj) is not NULL
            begin
                exec('drop view ' + @quoted_obj)
                if @@ERROR <> 0 
                    goto FAILURE 
            end
                        
            /* If we havent generated rowguidcol yet, use dummy rule that doesnt refer to it */
            if @hasguid = 0
                set @view_rule = ' select ' + @column_list + ' from '+ @source_object + ' ' + @unqual_sourcename +
                                            ' where ({fn ISPALUSER(''' + convert(nvarchar(36), @pubid) + ''')} = 1)'
            exec ('create view dbo.'+ @quoted_obj + ' as '+ @view_rule)
            if @@ERROR<>0
                goto FAILURE

            /* grant select permission on sync view to public - security check is performed inside the view */ 
            exec ('grant select on ' + @quoted_obj + ' to public')
            if @@ERROR<>0
                goto FAILURE
            /* Mark view as system object */                        
            execute dbo.sp_MS_marksystemobject @quoted_obj
            if @@ERROR<>0
                goto FAILURE

            /* done in setartprocs no need to repeat it here
            if @hasguid = 1
            begin
                select @procname=view_sel_proc from dbo.sysmergearticles where pubid=@pubid and artid=@artid
                if object_id(@procname) is not NULL
                begin
                    set @quoted_obj= quotename(@procname)
                    exec ('drop procedure ' + @quoted_obj)
                    update dbo.sysmergearticles set view_sel_proc = NULL where artid = @artid and pubid = @pubid 
                end
                else
                begin
                    set @procname = 'MSmerge_sel_' + sys.fn_MSmerge_getartprocsuffix(@artid, @pubid)
                end

                select @owner = SCHEMA_NAME(schema_id) from sys.objects 
                    where name = @viewname 
                exec sys.sp_MSmakeviewproc @viewname, @owner, @procname, @rgcol, @pubid, @artid
                if @retcode<>0 or @@ERROR<>0
                    goto FAILURE
                update dbo.sysmergearticles set view_sel_proc = @procname where pubid=@pubid and artid=@artid
            end*/

            select @quoted_obj = QUOTENAME(@viewname)
            
            update dbo.sysmergearticles set sync_objid = OBJECT_ID (@quoted_obj), view_type = @permanent
                where artid = @artid and pubid = @pubid 
            
            if @before_name is not null and @before_view_rule is not null
            begin
                exec @retcode = sys.sp_MScreatebeforetable @source_objid
                if @@ERROR <>0 OR @retcode <>0 goto FAILURE

                set @quoted_obj= quotename(@before_viewname)
            
                if object_id(@before_viewname) is not NULL
                    exec ('drop view ' + @quoted_obj)                
            
                set @before_view_rule= @before_view_rule + ') and ({ fn ISPALUSER(''' + convert(nvarchar(36), @pubid) + ''') } = 1)'
                
                exec ('create view dbo.' + @quoted_obj + ' as ' + @before_view_rule)
                if @@ERROR<>0
                    goto FAILURE

                if @before_rowguidname is not NULL
                begin
                    set @quoted_rowguid= quotename(@before_rowguidname)
                    exec ('grant select (' + @quoted_rowguid + ') on '+ @quoted_obj + ' to public')
                    if @@ERROR<>0
                        goto FAILURE
                end

                exec ('grant select (generation) on '+ @quoted_obj + ' to public')
                if @@ERROR<>0
                    goto FAILURE
                
                execute dbo.sp_MS_marksystemobject @before_viewname
                if @@ERROR<>0
                    goto FAILURE
                update dbo.sysmergearticles set before_view_objid = OBJECT_ID (@before_viewname)
                    where artid = @artid and pubid = @pubid
            end
        end
        else 
        begin
            -- All rows qualify from this table. We still create a view that shows -1 as the partition id. This helps us conveniently
            -- join child table rows if there are join filters, and find the part id's (-1 in this case) for only the qualifying child rows.
            if @use_partition_groups = 1
            begin
                if @column_list = ' * '
                        select @column_list = ' ' + @unqual_sourcename + '.* '
                
                set @partition_view_rule = ' select ' + @partition_column_list + ', partition_id = -1 from ' + @source_object + ' ' + @unqual_sourcename +
                                                    ' where ({fn ISPALUSER(''' + convert(nvarchar(36), @pubid) + ''')} = 1 
							   or (HAS_PERMS_BY_NAME(''' + @unqual_sourcename2+''', ''OBJECT'', ''SELECT'')
                                                    | HAS_PERMS_BY_NAME(''' + @unqual_sourcename2+''', ''OBJECT'', ''UPDATE'')
                                                    | HAS_PERMS_BY_NAME(''' + @unqual_sourcename2+''', ''OBJECT'', ''INSERT'')
                                                    | HAS_PERMS_BY_NAME(''' + @unqual_sourcename2+''', ''OBJECT'', ''DELETE''))=1)'
                                                    
                set @partition_inserted_view_rule = ' select ' + @partition_column_list + ', partition_id = -1 from inserted ' + @unqual_sourcename + '  '
                set @partition_deleted_view_rule = ' select ' + @partition_column_list + ', partition_id = -1 from deleted ' + @unqual_sourcename
            end

            select @sync_objid = @source_objid
            if @vertical_partition=1 and @column_list<> ' * '
            begin
                select @viewname = 'MSmerge_' + @publication + '_' + @article + '_VIEW'
                if (len(@viewname) > 128)
                begin
                    select @viewname = sys.fn_MSmerge_get_syncview_name (@publication, @article, @pubid, @artid)
                end
                select @quoted_obj = QUOTENAME(@viewname)
                
                -- drop the view if it already exists
                if object_id(@quoted_obj) is not NULL
                begin
                    exec ('drop view ' + @quoted_obj)
                    if @retcode <> 0 or @@ERROR <> 0 
                        goto FAILURE 
                end
                set @view_rule = ' select ' + @column_list + ' from '+ @source_object + ' ' + @unqual_sourcename + 
                            ' where ({fn ISPALUSER(''' + convert(nvarchar(36), @pubid) + ''')} = 1)'

                exec ('create view dbo.'+ @quoted_obj + ' as '+ @view_rule)
                if @@ERROR<>0
                    goto FAILURE
                execute dbo.sp_MS_marksystemobject @quoted_obj
                if @@ERROR<>0
                    goto FAILURE

                /* grant select permission on sync view to public - security check is performed inside the view */ 
                exec ('grant select on ' + @quoted_obj + ' to public')
                if @@ERROR<>0
                    goto FAILURE
                select @sync_objid=object_id(@quoted_obj)
                update dbo.sysmergearticles set view_sel_proc = @procname, sync_objid=@sync_objid
                    where artid = @artid and pubid = @pubid 
            end
            else -- if @dynamic_filters = 1
            begin
                /* This article doesn't have any vertical or horizontal filters but if the publication is enabled for dynamic filtering, 
                        we still want to generate a dummy view so that logins in the publication access list can generate a dynamic snapshot. */
                /* do this even for publications without dynamic filtering so that this view can be used for validation */
                select @viewname = 'MSmerge_' + @publication + '_' + @article + '_VIEW'
                if (len(@viewname) > 128)
                begin
                    select @viewname = sys.fn_MSmerge_get_syncview_name (@publication, @article, @pubid, @artid)
                end
                select @quoted_obj = QUOTENAME(@viewname)

                -- drop the view if it already exists
                if object_id(@quoted_obj) is not NULL
                begin
                    exec ('drop view ' + @quoted_obj)
                    if @@ERROR <> 0 
                        goto FAILURE 
                end
                set @view_rule = ' select  * from ' + @source_object  + ' where ({fn ISPALUSER(''' + convert(nvarchar(36), @pubid) + ''')} = 1)'     
                exec ('create view dbo.'+ @quoted_obj + ' as '+ @view_rule)
                if @@ERROR<>0
                    goto FAILURE
                execute dbo.sp_MS_marksystemobject @quoted_obj
                if @@ERROR<>0
                    goto FAILURE
                exec ('grant select on ' + @quoted_obj + ' to public')
                if @@ERROR<>0
                    goto FAILURE
                select @sync_objid=object_id(@quoted_obj)
                update dbo.sysmergearticles set view_sel_proc = @procname, sync_objid=@sync_objid, view_type = @permanent
                   where artid = @artid and pubid = @pubid 
            end

            /* done in sp_MSsetartprocs. No need to repeat it here
            if @hasguid = 1
            begin
                -- still make the select proc, although it selects directly from table
                if object_id(@procname) is not NULL
                begin
                    set @quoted_obj= quotename(@procname)
                    exec ('drop proc ' + @quoted_obj)
                    update dbo.sysmergearticles set view_sel_proc = NULL where artid = @artid and pubid = @pubid 
                end
            
                set @procname = 'MSmerge_sel_' + sys.fn_MSmerge_getartprocsuffix(@artid, @pubid)
                select @owner = SCHEMA_NAME(schema_id), @viewname = name from sys.objects 
                    where object_id = @sync_objid
                exec sys.sp_MSmakeviewproc @viewname, @owner, @procname, @rgcol, @pubid, @artid
                update dbo.sysmergearticles set view_sel_proc = @procname where pubid=@pubid and artid=@artid
            end*/
        end

        if @use_partition_groups = 1
        begin
                
            select @partition_view_name = 'MSmerge_' + @publication + '_' + @article + '_PARTITION_VIEW'
            if (len(@partition_view_name) > 128)
            begin
                select @partition_view_name = 'MSmerge_' + sys.fn_MSguidtostr(@pubid) + '_' + sys.fn_MSguidtostr(@artid) + '_PARTITION_VIEW'
            end
            select @quoted_partition_view = QUOTENAME(@partition_view_name)

            if object_id(@quoted_partition_view) is not NULL
            begin
                exec ('drop view ' + @quoted_partition_view)
                if @@error<>0 
                    goto FAILURE
            end
                   
            if @allhaveguids = 1
            begin
                exec ('create view dbo.'+ @quoted_partition_view + ' as '+ @partition_view_rule)
                if @@ERROR<>0
                    goto FAILURE
                /* grant select permission on sync view to public - security check is performed inside the view */ 
                exec ('grant select on ' + @quoted_partition_view + ' to public')
                if @@ERROR<>0
                    goto FAILURE
                /* Mark view as system object */                        
                execute dbo.sp_MS_marksystemobject @quoted_partition_view
                if @@ERROR<>0
                    goto FAILURE
                update dbo.sysmergepartitioninfo 
                    set partition_view_id = OBJECT_ID(@quoted_partition_view), 
                        partition_deleted_view_rule = @partition_deleted_view_rule,
                        partition_inserted_view_rule = @partition_inserted_view_rule
                    where artid = @artid and pubid = @pubid 
            end
            else
            begin
                update dbo.sysmergepartitioninfo 
                    set partition_view_id = NULL, 
                        partition_deleted_view_rule = NULL,
                        partition_inserted_view_rule = NULL
                    where artid = @artid and pubid = @pubid 
            end
        end
        
        select @art=min(indexcol) from #art where indexcol>@art
    end

    drop table #art
    if @allhaveguids = 1
    begin
        declare @dbname sysname
        set @dbname = db_name()
        /* create the filter expand procs now */
        set @filter_id = 0
        select @filter_id = min(join_filterid) from dbo.sysmergesubsetfilters where
                pubid = @pubid and join_filterid > @filter_id and (filter_type & 1) = 1
        while @filter_id is not null
        begin
            set @filter_id_str = convert(nvarchar(10), @filter_id)
            select @procname = expand_proc
                from dbo.sysmergesubsetfilters where pubid = @pubid and join_filterid = @filter_id and (filter_type & 1) = 1
            /* drop old proc, or generate a new procname */
            if object_id(@procname) is not NULL
            begin
                set @quoted_obj= quotename(@procname)
                exec ('drop procedure ' + @quoted_obj)
            end
            else
            begin
                set @procname = 'MSmerge_expand_' + @filter_id_str
                set @quoted_obj= quotename(@procname)
                if object_id(@procname) is not NULL
                begin
                    exec ('drop procedure ' + @quoted_obj)
                    if @@error<>0 
                        goto FAILURE
                end
                update dbo.sysmergesubsetfilters set expand_proc = @procname 
                    where pubid = @pubid and join_filterid = @filter_id and (filter_type & 1) = 1
            end

            
            set @command = 'exec sys.sp_MSmakeexpandproc ' + quotename(@publication) + ' , ' + @filter_id_str + ', ' + @quoted_obj
            exec @retcode = sys.xp_execresultset @command, @dbname
            if @retcode <> 0 goto FAILURE

            exec dbo.sp_MS_marksystemobject @quoted_obj
            if @@ERROR<>0
                goto FAILURE

            exec ('grant execute on ' + @quoted_obj + ' to public ')
            select @filter_id = min(join_filterid) from dbo.sysmergesubsetfilters where
                pubid = @pubid and join_filterid > @filter_id and (filter_type & 1) = 1
        end
    end
    
    exec @retcode = sys.sp_MScreate_logical_record_views @pubid
    if @@error <> 0 or @retcode <> 0
        goto FAILURE

    commit tran
    return (0)

FAILURE: 
    rollback tran sp_MSpublicationview
    commit tran
    return (1)
GO
GRANT EXECUTE ON [sys].[sp_MSpublicationview] TO [public] AS [dbo]
GO
