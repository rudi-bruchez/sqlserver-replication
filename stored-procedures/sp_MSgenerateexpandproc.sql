SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSgenerateexpandproc]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSgenerateexpandproc] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSgenerateexpandproc]
	@tablenick [int],
	@procname [sysname]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on

    declare @immediate_child_partition_viewname nvarchar(130), @immediate_child_nickname int,
                @join_unique_key int, @child_expand_proc sysname, @child_rgcol nvarchar(270), @child_has_col_tracking int

    declare @partition_view_id int, @partition_view_name nvarchar(270), @pubid uniqueidentifier, @artid uniqueidentifier,
            @retcode int, @artidstr nvarchar(40), @rgcol nvarchar(270), @objid int, @publication_number smallint
    declare @command1 nvarchar(max), @command2 nvarchar(max), @command3 nvarchar(max), @command4 nvarchar(max)
    declare @table_name nvarchar(130), @owner_qualified_table_name nvarchar(270), @immediate_child_table_name nvarchar(130), 
            @owner_qualified_immediate_child_table_name nvarchar(270), @immediate_child_objid int, 
            @join_filterclause nvarchar(2000), @child_join_colname nvarchar(130), @child_cannot_pre_exist bit, @parent_columns_unique bit, 
            @join_filter_id int
    declare @gen_change_threshold int
    declare @replnick binary(6)


    -- Security Check
    exec @retcode= sys.sp_MSreplcheck_publish
    if @@error <> 0 or @retcode <> 0 return (1)
    
    select @parent_columns_unique = 0

    create table #tmpproccmd (phase int NOT NULL, step int identity NOT NULL, cmdtext nvarchar(max) collate database_default null)

    select top 1 @artid=artid, @objid=objid
    from dbo.sysmergearticles 
    where nickname = @tablenick 
    
    select @rgcol = quotename(name) from sys.columns where object_id = @objid and is_rowguidcol = 1
    
    select  @table_name = quotename(object_name(@objid)), 
            @owner_qualified_table_name = quotename(SCHEMA_NAME(schema_id)) + '.' + quotename(object_name(@objid))
    from sys.objects
    where object_id = @objid

    select @gen_change_threshold = min(isnull(generation_leveling_threshold,0)) from dbo.sysmergepublications
        where pubid in (select pubid from dbo.sysmergearticles where nickname = @tablenick)
    select @command1 = '
create procedure dbo.' + quotename(@procname) + ' (@marker uniqueidentifier, @inherit_pastchanges_generation bigint, @parent_being_updated bit = 0, @trigger_type int = 1) as '

    insert into #tmpproccmd (phase, cmdtext) values (1, @command1)

    declare immediate_children CURSOR LOCAL FAST_FORWARD FOR 
    select distinct quotename(object_name(sma.objid)), sma.objid, sma.nickname, 'dbo.' + quotename(object_name(sma.partition_view_id)), 
                    ssf.join_filterid, ssf.join_filterclause, ssf.join_unique_key, sma.expand_proc, sma.pubid, sma.column_tracking
    from dbo.sysmergesubsetfilters ssf, dbo.sysmergepartitioninfoview sma where ssf.join_nickname = @tablenick
    and sma.nickname = ssf.art_nickname
    and sma.pubid = ssf.pubid
    and (ssf.filter_type & 1) = 1
    and sma.partition_view_id is not null
    for read only

    open immediate_children

    fetch next from immediate_children into @immediate_child_table_name, @immediate_child_objid, @immediate_child_nickname, 
                    @immediate_child_partition_viewname, @join_filter_id, @join_filterclause, @join_unique_key, @child_expand_proc, @pubid, @child_has_col_tracking

    if (@@fetch_status <> -1)
    begin
        exec @retcode= sys.sp_MSgetreplnick @replnick = @replnick out
        if @retcode <> 0
        	return 1
        	
        select @command3 = '
    declare @child_marker uniqueidentifier
    declare @child_rowcount int, @child_newgen bigint, @child_oldmaxversion int, @child_metadatarows_updated int, @cv varbinary(1), @replnick binary(6)
    declare @lineage varbinary(311)    
    declare @retcode int
    declare @dt datetime
    declare @nickbin varbinary(8)
    declare @reason bit

    
    select @replnick = ' + sys.fn_varbintohexstr(@replnick) + ' 

    select @nickbin = @replnick + 0xFF
    
    set @child_marker = newid()

    select @dt = getdate()
        '
        insert into #tmpproccmd (phase, cmdtext) values(14, @command3)
    end

    while (@@fetch_status <> -1)
    begin
        --exec @retcode = sys.sp_MSis_joinfilter_based_on_PK_UQ_constraints @pubid = @pubid,
        --                                                            @join_filter_id = @join_filter_id,
        --                                                            @dri_based = @child_cannot_pre_exist output,
		--															  @unique_constraint_based = @parent_columns_unique output
                                                                    
        --if @@error <> 0 or @retcode <> 0
        --    goto FAILURE
            
        --if @child_cannot_pre_exist = 1
        --begin
            --select @command3 = '
    --if @parent_being_updated = 1
    --begin '
        
    --        insert into #tmpproccmd (phase, cmdtext) values(14, @command3)
    --    end
        
        select @owner_qualified_immediate_child_table_name = 
            quotename(SCHEMA_NAME(schema_id)) + '.' + quotename(object_name(object_id))
        from sys.objects with (nolock) where object_id = @immediate_child_objid
        
        select top 1 @publication_number = publication_number from dbo.sysmergepublications where pubid = @pubid

        select  top 1 @child_join_colname = name from sys.columns where object_id = @immediate_child_objid
        and sys.fn_MSisfilteredcolumn(@join_filterclause, name, @immediate_child_objid) = 1 

        select @child_rgcol = quotename(name) from sys.columns where object_id = @immediate_child_objid and is_rowguidcol = 1

        if @join_unique_key = 0 or @parent_columns_unique = 0
        begin
            select @command3 = '
        select @child_rowcount = count(*) from ' + 
        @owner_qualified_immediate_child_table_name + ' ' + @immediate_child_table_name + '  with (rowlock)
        where ' + @child_rgcol + ' in 
        (select ' + @immediate_child_table_name + '.' + @child_rgcol + ' 
        from
        dbo.MSmerge_contents with (rowlock), ' 
        + @owner_qualified_table_name + ' ' + @table_name + ' with (rowlock), ' 
        + @owner_qualified_immediate_child_table_name + ' ' + @immediate_child_table_name + ' with (rowlock) 
        where dbo.MSmerge_contents.marker = @marker
        and dbo.MSmerge_contents.tablenick = ' + convert(nvarchar, @tablenick) + ' 
        and dbo.MSmerge_contents.rowguid = ' + @table_name + '.' + @rgcol + ' 
        and (' + @join_filterclause +'))'
        end
        else
        begin
            select @command3 = '
        select @child_rowcount = count(*) from 
        dbo.MSmerge_contents with (rowlock), ' 
        + @owner_qualified_table_name + ' ' + @table_name + ' with (rowlock), ' 
        + @owner_qualified_immediate_child_table_name + ' ' + @immediate_child_table_name + ' with (rowlock) 
        where dbo.MSmerge_contents.marker = @marker
        and dbo.MSmerge_contents.tablenick = ' + convert(nvarchar, @tablenick) + ' 
        and dbo.MSmerge_contents.rowguid = ' + @table_name + '.' + @rgcol + ' 
        and (' + @join_filterclause + ') ' 
        end

        insert into #tmpproccmd (phase, cmdtext) values(14, @command3)
                        
        -- touch the immediate children of deleted rows
        select @command3 = '
        if @child_rowcount > 0
        begin
            select @child_oldmaxversion= maxversion_at_cleanup from dbo.sysmergearticles
            where nickname = ' + convert(nvarchar, @immediate_child_nickname) + '

            -- the code below will get an open generation for the child article
            select @child_newgen = NULL
            select top 1 @child_newgen = generation from dbo.MSmerge_genhistory with (rowlock, updlock, readpast) 
                where art_nick = ' + convert(nvarchar,@immediate_child_nickname) + ' 
                    and genstatus = 0'
        if @gen_change_threshold > 0
            select @command3 = @command3 + '
                    and changecount <= (' + convert(nvarchar, @gen_change_threshold) + '- isnull(@child_rowcount,0))'
        select @command3 = @command3 + '                    
            if @child_newgen is NULL
            begin
                insert into dbo.MSmerge_genhistory with (rowlock)
                    (guidsrc, genstatus, art_nick, nicknames, coldate, changecount)
                       values (newid(), 0, ' + convert(nvarchar,@immediate_child_nickname) + ', @nickbin, @dt, @child_rowcount)
                select @child_newgen = @@identity    
            end'
        if @gen_change_threshold > 0
            select @command3 = @command3 + '                    
            else
            begin
                -- do the update right away to change the changecount to include the rows that we just put in the generation
                update dbo.MSmerge_genhistory with (rowlock)
                    set changecount = changecount + @child_rowcount
                    where generation = @child_newgen 
            end
'
        insert into #tmpproccmd (phase, cmdtext) values(14, @command3)
        
        select @command3 = '
        if @retcode <> 0
            return @retcode '
            
        insert into #tmpproccmd (phase, cmdtext) values(14, @command3)
                
        if @join_unique_key = 0 or @parent_columns_unique = 0
        begin
            select @command3 = '            
            update MSmerge_contents1 with (rowlock) set generation = @child_newgen, partchangegen = @child_newgen, marker = @child_marker,
            lineage = case when @trigger_type = 0 then lineage else { fn UPDATELINEAGE(MSmerge_contents1.lineage, @replnick, @child_oldmaxversion+1) } end
            from dbo.MSmerge_contents MSmerge_contents1  with (rowlock)
            where MSmerge_contents1.tablenick = ' + convert (nvarchar, @immediate_child_nickname) + ' 
            and MSmerge_contents1.rowguid in 
                (select ' + @immediate_child_table_name + '.' + @child_rgcol + ' 
                from
                dbo.MSmerge_contents MSmerge_contents2 with (rowlock), ' 
                + @owner_qualified_table_name + ' ' + @table_name + ' with (rowlock), ' 
                + @owner_qualified_immediate_child_table_name + ' ' + @immediate_child_table_name + ' with (rowlock) 
                where MSmerge_contents2.marker = @marker
                and MSmerge_contents2.tablenick = ' + convert(nvarchar, @tablenick) + ' 
                and MSmerge_contents2.rowguid = ' + @table_name + '.' + @rgcol + ' 
                and (' + @join_filterclause + '))
                
                select @child_metadatarows_updated = @@rowcount'
        end
        else
        begin
            select @command3 = '
            update MSmerge_contents1 set generation = @child_newgen, partchangegen = @child_newgen, marker = @child_marker,
            lineage = case when @trigger_type = 0 then lineage else { fn UPDATELINEAGE(MSmerge_contents1.lineage, @replnick, @child_oldmaxversion+1) } end
            from 
            dbo.MSmerge_contents MSmerge_contents2 with (rowlock), ' 
            + @owner_qualified_table_name + ' ' + @table_name + ' with (rowlock), '
            + @owner_qualified_immediate_child_table_name + ' ' + @immediate_child_table_name + ' with (rowlock), 
            dbo.MSmerge_contents MSmerge_contents1  with (rowlock) 
            where MSmerge_contents1.tablenick = ' + convert (nvarchar, @immediate_child_nickname) + ' 
            and MSmerge_contents1.rowguid = ' + @immediate_child_table_name + '.' + @child_rgcol + '          
            and MSmerge_contents2.marker = @marker
            and MSmerge_contents2.tablenick = ' + convert(nvarchar, @tablenick) + ' 
            and MSmerge_contents2.rowguid = ' + @table_name + '.' + @rgcol + ' 
            and (' + @join_filterclause + ')
            
            select @child_metadatarows_updated = @@rowcount'            
        end

        insert into #tmpproccmd (phase, cmdtext) values(14, @command3)
                
        select @command3 = '
            if @child_metadatarows_updated < @child_rowcount '
        insert into #tmpproccmd (phase, cmdtext) values(14, @command3)

        set @command3 = '
            begin
                set @lineage = case when @trigger_type = 0 then 0x0 else { fn UPDATELINEAGE(0x0, @replnick, @child_oldmaxversion+1) } end '

        insert into #tmpproccmd (phase, cmdtext) values(14, @command3)

        if @child_has_col_tracking = 1
            set @command3 =  '
                set @cv = 0xFF '
        else 
            set @command3 = ' 
                set @cv = NULL '
            
        set @command3 = @command3 + '
                insert into dbo.MSmerge_contents  with (rowlock) 
                    (tablenick, rowguid, generation, partchangegen, lineage, colv1, marker) 
            '
        insert into #tmpproccmd (phase, cmdtext) values(14, @command3)

        if @join_unique_key = 0 or @parent_columns_unique = 0
        begin
            set @command3 = '
                select ' + convert(nvarchar, @immediate_child_nickname) + ', ' + @immediate_child_table_name + '.' + @child_rgcol + ', @child_newgen, @child_newgen, @lineage, @cv, @child_marker
                from ' 
                + @owner_qualified_immediate_child_table_name + ' ' + @immediate_child_table_name + '  with (rowlock)
                where ' + @child_rgcol + ' in 
                    (
                        select ' + @immediate_child_table_name + '.' + @child_rgcol + '
                        from dbo.MSmerge_contents MSmerge_contents2 with (rowlock), 
                        ' + @owner_qualified_table_name + ' ' + @table_name + ' with (rowlock), 
                        ' + @owner_qualified_immediate_child_table_name + ' ' + @immediate_child_table_name + ' with (rowlock)
                        where MSmerge_contents2.marker = @marker
                        and MSmerge_contents2.tablenick = ' + convert(nvarchar, @tablenick) + ' 
                        and MSmerge_contents2.rowguid = ' + @table_name + '.' + @rgcol + ' 
                        and (' + @join_filterclause + ')
                    )
                and not exists 
                    (select * from dbo.MSmerge_contents with (rowlock)
                        where tablenick = ' + convert(nvarchar, @immediate_child_nickname) +' 
                        and rowguid = ' + @immediate_child_table_name + '.' + @child_rgcol + '
                    ) '
        end
        else
        begin
            set @command3 = '
                select ' + convert(nvarchar, @immediate_child_nickname) + ', ' + @immediate_child_table_name +'.' + @child_rgcol + ', @child_newgen, @child_newgen, @lineage, @cv, @child_marker
                from 
                dbo.MSmerge_contents MSmerge_contents2 with (rowlock), ' 
                + @owner_qualified_table_name + ' ' + @table_name + ' with (rowlock), '
                + @owner_qualified_immediate_child_table_name + ' ' + @immediate_child_table_name + ' with (rowlock)
                where  MSmerge_contents2.marker = @marker
                and MSmerge_contents2.tablenick = ' + convert(nvarchar, @tablenick) + ' 
                and MSmerge_contents2.rowguid = ' + @table_name + '.' + @rgcol + ' 
                and (' + @join_filterclause + ')
                and not exists (select * from dbo.MSmerge_contents with (rowlock)
                    where tablenick = ' + convert(nvarchar, @immediate_child_nickname) + ' 
                    and rowguid = ' + @immediate_child_table_name + '.' + @child_rgcol + ') '
        end

        insert into #tmpproccmd (phase, cmdtext) values(14, @command3)
        
        select @command3 = '
            end    '
        insert into #tmpproccmd (phase, cmdtext) values(14, @command3)
        
        select @command3 = '
            if @trigger_type <> 0
            begin
                delete dbo.MSmerge_current_partition_mappings with (rowlock) from 
                dbo.MSmerge_contents mc with (rowlock)
                join dbo.MSmerge_current_partition_mappings with (rowlock)
                on dbo.MSmerge_current_partition_mappings.tablenick = mc.tablenick
                and mc.tablenick = ' + convert(nvarchar(11), @immediate_child_nickname) + '
                and dbo.MSmerge_current_partition_mappings.tablenick = ' + convert(nvarchar(11), @immediate_child_nickname) + '
                and dbo.MSmerge_current_partition_mappings.rowguid = mc.rowguid
                and dbo.MSmerge_current_partition_mappings.publication_number = ' + convert(nvarchar, @publication_number) + '
                and mc.marker = @child_marker 
            end '
        insert into #tmpproccmd (phase, cmdtext) values(14, @command3)
        
        select @command3 = '
            if @trigger_type <> 0
            begin
                insert into dbo.MSmerge_current_partition_mappings with (rowlock) (publication_number, tablenick, rowguid, partition_id)
                select distinct ' + convert(nvarchar, @publication_number) + ', mc.tablenick, mc.rowguid, v.partition_id
                from dbo.MSmerge_contents mc with (rowlock) 
                JOIN ' + @immediate_child_partition_viewname + ' v with (rowlock) 
                ON mc.tablenick = ' + convert(nvarchar(11), @immediate_child_nickname) + '
                and mc.rowguid = v.' + @child_rgcol + '
                and mc.marker = @child_marker 
            end 
            else
            begin
                insert into dbo.MSmerge_current_partition_mappings with (rowlock) (publication_number, tablenick, rowguid, partition_id)
                select distinct ' + convert(nvarchar, @publication_number) + ', mc.tablenick, mc.rowguid, v.partition_id
                from dbo.MSmerge_contents mc with (rowlock) 
                JOIN ' + @immediate_child_partition_viewname + ' v with (rowlock) 
                ON mc.tablenick = ' + convert(nvarchar(11), @immediate_child_nickname) + '
                and mc.rowguid = v.' + @child_rgcol + '
                and mc.marker = @child_marker 
                JOIN dbo.MSmerge_current_partition_mappings cpm with (rowlock)
                ON cpm.partition_id = v.partition_id
                JOIN dbo.MSmerge_contents mc2 with (rowlock)
                ON cpm.rowguid = mc2.rowguid
                and mc2.marker = @marker
                where not exists (select * from MSmerge_current_partition_mappings with (readcommitted, rowlock, readpast) where 
                    publication_number = ' + convert(nvarchar, @publication_number) + ' and 
                    tablenick = ' + convert(nvarchar(11), @immediate_child_nickname) + ' and
                    rowguid = v.' + @child_rgcol + ' and
                    partition_id = v.partition_id)
            end '

        insert into #tmpproccmd (phase, cmdtext) values(14, @command3)
        
        select @command3 = '
            if @inherit_pastchanges_generation <> -1
            begin
            	if @parent_being_updated = 1
            		set @reason = 0
            	else
            		set @reason = 1 /* expanding for delete. */
            		
                insert into dbo.MSmerge_past_partition_mappings  with (rowlock) (publication_number, tablenick, rowguid, partition_id, generation,reason)
                select distinct ' + convert(nvarchar, @publication_number) + ', ' + convert (nvarchar, @immediate_child_nickname) + ', ' + @immediate_child_table_name + '.' + @child_rgcol + ',  
                        mpcpm.partition_id, @child_newgen, @reason 
                from 
                dbo.MSmerge_contents mc with (rowlock) , 
                dbo.MSmerge_past_partition_mappings mpcpm with (rowlock) , ' 
                + @owner_qualified_table_name + ' ' + @table_name + ' with (rowlock) , ' 
                + @owner_qualified_immediate_child_table_name + ' ' + @immediate_child_table_name +'  with (rowlock) 
                where mc.marker = @marker
                and mc.tablenick = ' + convert(nvarchar, @tablenick) + '
                and mc.rowguid = ' + @table_name + '.' + @rgcol + '
                and mpcpm.publication_number = ' + convert(nvarchar, @publication_number) + '
                and mpcpm.generation = @inherit_pastchanges_generation
                and mc.tablenick = mpcpm.tablenick
                and mpcpm.tablenick = ' + convert(nvarchar, @tablenick) + '
                and mc.rowguid = mpcpm.rowguid
                and (' + @join_filterclause + ')                
            end '

        insert into #tmpproccmd (phase, cmdtext) values(14, @command3)
        
        if @child_expand_proc is not null and @child_expand_proc != ' '
        begin
            set @command3 = '
        exec dbo.' + quotename(@child_expand_proc) + ' @marker = @child_marker, @inherit_pastchanges_generation = @child_newgen, @parent_being_updated = 1, @trigger_type = @trigger_type '
            -- use parent_being_updated = 1 even if the originating parent was being inserted or deleted. this value
            -- simply indicates that the current parent row was found, and we are updating its metadata.
            insert into #tmpproccmd (phase, cmdtext) values(14, @command3)
        end

        select @command3 = '
    end    '
        insert into #tmpproccmd (phase, cmdtext) values(14, @command3)
        
        --if @child_cannot_pre_exist = 1
        --begin
        --    select @command3 = '
    --end '
        
    --        insert into #tmpproccmd (phase, cmdtext) values(14, @command3)
    --    end

        fetch next from immediate_children into @immediate_child_table_name, @immediate_child_objid, @immediate_child_nickname, 
            @immediate_child_partition_viewname, @join_filter_id, @join_filterclause, @join_unique_key, @child_expand_proc, @pubid, @child_has_col_tracking
    end

    close immediate_children
    deallocate immediate_children

    select cmdtext from #tmpproccmd where cmdtext is not null order by phase, step
    drop table #tmpproccmd
    
    return 0
    
FAILURE:
    
    close immediate_children
    deallocate immediate_children

    drop table #tmpproccmd
    
    return 1
end
GO
GRANT EXECUTE ON [sys].[sp_MSgenerateexpandproc] TO [public] AS [dbo]
GO
