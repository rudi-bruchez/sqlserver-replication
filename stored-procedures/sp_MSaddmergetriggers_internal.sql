SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSaddmergetriggers_internal]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSaddmergetriggers_internal] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSaddmergetriggers_internal]
	@source_table [sysname],
	@table_owner [sysname],
	@column_tracking [int],
	@trigger_type [tinyint],
	@viewname [sysname],
	@tsview [sysname],
	@trigname [sysname],
	@current_mappings_viewname [sysname],
	@past_mappings_viewname [sysname],
	@genhistory_viewname [sysname]
WITH EXECUTE AS CALLER
AS
set nocount on
    declare @command        nvarchar(max)
    declare @command2        nvarchar(max)
    declare @command3       nvarchar(max)
    declare @command4       nvarchar(max)
    declare @command5       nvarchar(max)
    declare @inscommand nvarchar(2000)
    declare @ifcoltracking     nvarchar(255)
    declare @tablenick         int    
    declare @replnick         binary(6)
    declare @artid             uniqueidentifier
    declare @owner             sysname
    declare @site             sysname
    declare @db             sysname
    declare @object         sysname
    declare @tablenickchar     nvarchar(11)
    declare @retcode         int
    declare @bitmap         varbinary(40)
    declare @objid            int
    declare @notforrepl_str1    nvarchar(400)
    declare @notforrepl_str2    nvarchar(400)
    declare @notforrepl_bit bit
    declare @rgcol            sysname
    declare @UnqualName    sysname  --rightmost name node
    declare @QualName1     sysname  
    declare @immediate_child_table_name nvarchar(258), @owner_qualified_immediate_child_table_name nvarchar(517), @immediate_child_objid int,
			@join_filter_id int, @join_filterclause nvarchar(1000), @child_join_colname nvarchar(130)
    declare @child_rgcol nvarchar(270)
    declare @immediate_child_nickname int, @join_unique_key int, @child_expand_proc sysname, @immediate_child_partition_viewname nvarchar(258), @partition_deleted_view_rule nvarchar(max), @child_has_col_tracking int
    declare @logical_record_view int, @logical_record_deleted_view_rule nvarchar(max), @logical_record_parent_nickname int
    declare @lrp_partition_view_id int, @lrp_partition_view_name nvarchar(270), @lrp_pubid uniqueidentifier,
                    @lrp_publication_number smallint, @lrp_rgcol nvarchar(270), @lrp_objid int, @partition_options tinyint,
                    @is_top_level_logical_record_parent bit

    declare @str_objid nvarchar(15)

    declare @quoted_db_source_table_name nvarchar(776)
    declare @quoted_source_table_name nvarchar(517)
    declare @dbname nvarchar(258)
    declare @delete_tracking bit
    declare @max_colv_size_in_bytes int
    declare @child_cannot_pre_exist bit
    declare @parent_columns_unique bit
    declare @gen_change_threshold int

    -- the following is needed for auto identity range support
    declare @identity_support int
    declare @ident_increment numeric(38,0)
    declare @is_publisher bit
    declare @subid uniqueidentifier
    declare @subidstr nvarchar(40)
    declare @artidstr nvarchar(40)
    declare @article_published bit
    declare @level_generations_in_trigger bit
    -- end auto identity range support variables

	declare @quoted_trigname nvarchar(258)
	declare @quoted_genhistory_viewname nvarchar(517)
	declare @quoted_tsview nvarchar(517)
	declare @quoted_viewname nvarchar(517)
	declare @quoted_rgcol nvarchar(258)
	declare @quoted_current_mappings_viewname nvarchar(517)
	declare @quoted_past_mappings_viewname nvarchar(517)

    /* Security check */
    EXEC @retcode = dbo.sp_MSreplcheck_subscribe
    if @@ERROR <> 0 or @retcode <> 0
        return(1)
    
    create table #tmptriggercmd (phase int NOT NULL, step int identity NOT NULL, cmdtext nvarchar(max) collate database_default null)

    set @notforrepl_bit = 1
    set @bitmap = 0x0
	select @parent_columns_unique = 0 
	
    if @table_owner is NULL
         select @table_owner = SCHEMA_NAME(schema_id) from sys.objects where object_id = object_id(@source_table)

    select @quoted_source_table_name=QUOTENAME(@table_owner) + N'.' + QUOTENAME(@source_table)

    set @objid =  OBJECT_ID(@quoted_source_table_name)
    set @str_objid = convert(nvarchar, @objid)
    
    if exists (select * from dbo.sysmergearticles where objid = @objid and column_tracking = 1)
    begin
        declare @current_col_count int, @missing_col_count int
        select @current_col_count = count(*) 
            from sys.columns where object_id = @objid
        select @missing_col_count = coalesce((select max(missing_col_count) 
            from dbo.sysmergearticles where objid = @objid), 0)
        -- 12 bytes per column in table + 1 trailing byte for colv.
        select @max_colv_size_in_bytes = 12 * (@current_col_count + @missing_col_count) + 1
        if @max_colv_size_in_bytes > 2953
            select @max_colv_size_in_bytes = 2953
    end
    else
        select @max_colv_size_in_bytes = 1

    select @rgcol = name from sys.columns where object_id = @objid and is_rowguidcol = 1

    if @source_table IS NULL
         return 1

    select @dbname = DB_NAME() 

	set @quoted_db_source_table_name=QUOTENAME(@dbname)+ N'.' + @quoted_source_table_name

    select @owner = @table_owner
    select @object = @source_table

	select @quoted_trigname = quotename(@trigname)
	select @quoted_genhistory_viewname = N'[dbo].' + quotename(@genhistory_viewname)
	select @quoted_tsview = N'[dbo].' + quotename(@tsview)
	select @quoted_viewname = N'[dbo].' + quotename(@viewname)
	select @quoted_rgcol = quotename(@rgcol)
	select @quoted_current_mappings_viewname = N'[dbo].' + quotename(@current_mappings_viewname)
	select @quoted_past_mappings_viewname = N'[dbo].' + quotename(@past_mappings_viewname)

    -- Initialize string for inserting to before_image table
    exec sys.sp_MSgetbeforetableinsert @objid, @inscommand output
    
    execute @retcode=sys.sp_MStablenickname @owner, @object, @tablenick output
    if @retcode<>0 or @@ERROR<>0 return (1)

    if exists (select * from dbo.sysmergearticles where nickname = @tablenick
                        and sys.fn_MSmerge_islocalpubid(pubid) = 1)
        select @article_published = 1
    else
        select @article_published = 0

    select @gen_change_threshold = min(isnull(generation_leveling_threshold,0)) from dbo.sysmergepublications
        where pubid in (select pubid from dbo.sysmergearticles where nickname = @tablenick)
    if @gen_change_threshold = 0 or @article_published = 0
        select @level_generations_in_trigger = 0
    else
        select @level_generations_in_trigger = 1
        
    exec @retcode= sys.sp_MSgetreplnick @replnick = @replnick out
    if @retcode<>0 or @@error<>0 
        return 1

        
    select @artid = artid, @delete_tracking = delete_tracking, @identity_support=identity_support,
    @partition_options = partition_options
    from dbo.sysmergepartitioninfoview where objid = @objid
    
    -- check if this is the publisher or subscriber. Republishers are also considered as subscribers
    if @identity_support = 1
    begin
        if exists (select a.artid, p.pubid from dbo.sysmergearticles a, dbo.sysmergepublications p
                    where a.artid=@artid and a.pubid=p.pubid and (sys.fn_MSmerge_islocalpubid(p.pubid)=0))
        begin
            -- the current db is either a republisher or a subscriber
            select @is_publisher=0
            -- the follow query attempts to get the subid and not the republished pubid or the republished publication's subids
            select @subid=subid from dbo.MSmerge_identity_range 
                where is_pub_range=0 and artid=@artid and sys.fn_MSmerge_islocalsubid(subid)=1
        end
        else
        begin
            select @is_publisher=1
            select @subid=subid from dbo.MSmerge_identity_range
                where is_pub_range=0 and artid=@artid and sys.fn_MSmerge_islocalpubid(subid)=1
        end
        select @subidstr = N'''' + convert(nvarchar(36), @subid) + N''''
        select @artidstr = N'''' + convert(nvarchar(36), @artid) + N''''
    end
    
    select @logical_record_view = logical_record_view, @logical_record_deleted_view_rule = logical_record_deleted_view_rule
    from dbo.sysmergepartitioninfo where artid = @artid and logical_record_parent_nickname is not null
        
    /* If column tracking wasn't passed in, just figure it out */
    if @column_tracking is null
        select @column_tracking = column_tracking from dbo.sysmergearticles where artid = @artid
        
    select @tablenickchar = convert(nchar, @tablenick)
    
    -- Check if the triggers can be made NOT FOR REPLICATION
    if exists (select * from dbo.sysmergearticles 
               where nickname = @tablenick 
               and
               (before_image_objid is not null or
                before_view_objid is not null or
                datalength (subset_filterclause) > 1
               ))
    begin
        select @notforrepl_bit = 0
    end
    else if exists (select * from dbo.sysmergesubsetfilters where art_nickname = @tablenick or join_nickname = @tablenick)
    begin
        select @notforrepl_bit = 0
    end
    else if exists (select * from dbo.sysmergearticles where nickname = @tablenick and pubid in (select pubid from dbo.sysmergepublications where use_partition_groups = 1))
    begin
        select @notforrepl_bit = 0
    end
    else
    begin
        select @notforrepl_bit = 1
    end
    
    if exists (select * from dbo.sysmergepartitioninfoview 
                            where artid = @artid
                            and partition_options = 2 
                            and sys.fn_MSmerge_islocalpubid(pubid) = 0)
                and exists (select * from dbo.sysmergepartitioninfoview 
                            where artid = @artid
                            and partition_options = 2 
                            and sys.fn_MSmerge_islocalpubid(pubid) = 1)
    begin
        --republisher of multiple-hop well-partitioned articles (partition based filtering)
        select @notforrepl_str1 = ' '
        select @notforrepl_str2 = ' 
    if (select trigger_nestlevel()) = 1 and @is_mergeagent = 1
        return '
    end
    else if @partition_options = 2 or @partition_options = 3
    begin
        select @notforrepl_bit = 1
        select @notforrepl_str1 = ' not for replication '
        select @notforrepl_str2 = ' '
    end
    else
    begin
        select @notforrepl_str1 = ' '
        select @notforrepl_str2 = '
    if (select trigger_nestlevel()) = 1 and @is_mergeagent = 1
        return '
    end

    -- If column tracking is on, construct the string to initialize colv's
    if (@column_tracking <> 0)
        select @ifcoltracking = '    set @colv1 = 0xFF'
    else
        select @ifcoltracking = '    set @colv1 = NULL'
        
    select @is_top_level_logical_record_parent = 0
    
    if @logical_record_view is not null
    begin
        select top 1 @logical_record_parent_nickname = logical_record_parent_nickname 
        from dbo.sysmergepartitioninfo 
        where artid = @artid
        and logical_record_parent_nickname is not null
        
        if @logical_record_parent_nickname = @tablenick
            select @is_top_level_logical_record_parent = 1
    end

-- ins_ trigger generation
if @trigger_type = 0
begin
    -- UNDONE maybe remove null guid checks in SQL SERVER 7.0
    select @command = '
create trigger ' + @quoted_trigname + ' on ' + @quoted_db_source_table_name + 
    ' for insert ' + @notforrepl_str1 + ' as 
    declare @is_mergeagent bit, @at_publisher bit, @retcode smallint 

    set rowcount 0
    set transaction isolation level read committed
'
    
    if exists (select * from dbo.sysmergearticles where nickname = @tablenick 
                and (pubid in (select pubid from dbo.sysmergepublications where use_partition_groups = 1)
                        or published_in_tran_pub = 1))
    begin
        select @command = @command + '
        exec @retcode = sys.sp_MSisreplmergeagent @is_mergeagent output, @at_publisher output
        if @@error <> 0 or @retcode <> 0
        begin
            rollback tran
            return
        end '
    end
    else
    begin
        select @command = @command + '
        select @is_mergeagent = convert(bit, sessionproperty(''replication_agent''))
        select @at_publisher = 0 '
    end
    
    if not exists (select * from dbo.sysmergearticles where nickname = @tablenick and pubid in (select pubid from dbo.sysmergepublications where use_partition_groups = 1))
        and not exists (select * from dbo.sysmergepartitioninfo where artid = @artid and logical_record_view is not null)
        select @command = @command + @notforrepl_str2
        
    if @partition_options = 2 or @partition_options = 3
        select @command = @command + '
        if @is_mergeagent = 1 and @at_publisher = 1
            return '

    insert into #tmptriggercmd (phase, cmdtext) values (1, @command)
    select @command=''

    -- perform identity range check here.
    if @identity_support = 1
    begin
        select @ident_increment = IDENT_INCR(@quoted_source_table_name)
        select @command = '
    if is_member(''db_owner'') = 1
    begin
        -- select the range values from the MSmerge_identity_range table
        -- this can be hardcoded if performance is a problem
        declare @range_begin numeric(38,0)
        declare @range_end numeric(38,0)
        declare @next_range_begin numeric(38,0)
        declare @next_range_end numeric(38,0)

        select @range_begin = range_begin,
               @range_end = range_end,
               @next_range_begin = next_range_begin,
               @next_range_end = next_range_end
            from dbo.MSmerge_identity_range where artid=' + @artidstr + ' and subid=' + @subidstr + ' and is_pub_range=0

        if @range_begin is not null and @range_end is not NULL and @next_range_begin is not null and @next_range_end is not NULL
        begin'
    
        if @is_publisher=1
        begin
            -- if it is the publisher when both current range and next range are full we will
            -- call a proc to refresh the range
            select @command = @command + '
            if IDENT_CURRENT(''' + sys.fn_replreplacesinglequote(@quoted_source_table_name) + ''') = @range_end
            begin
                DBCC CHECKIDENT (''' + sys.fn_replreplacesinglequote(@quoted_source_table_name) + ''', RESEED, @next_range_begin) with no_infomsgs
            end'
            
            if @ident_increment > 0
                select @command = @command + '
            else if IDENT_CURRENT(''' + sys.fn_replreplacesinglequote(@quoted_source_table_name) + ''') >= @next_range_end'
            else
                select @command = @command + '
            else if IDENT_CURRENT(''' + sys.fn_replreplacesinglequote(@quoted_source_table_name) + ''') <= @next_range_end'
            
            select @command = @command + '
            begin
                exec sys.sp_MSrefresh_publisher_idrange ''' + sys.fn_replreplacesinglequote(@quoted_source_table_name) + ''', ' + @subidstr + ', ' + @artidstr + ', 2, 1
                if @@error<>0 or @retcode<>0
                    goto FAILURE
            end'
        end
        else
        begin
            -- on the subscriber when both ranges are full we cannot do anything. so only do a
            -- reseed when range_end is reached.
            select @command = @command + '
            if IDENT_CURRENT(''' + sys.fn_replreplacesinglequote(@quoted_source_table_name) + ''') = @range_end
            begin
                DBCC CHECKIDENT (''' + sys.fn_replreplacesinglequote(@quoted_source_table_name) + ''', RESEED, @next_range_begin) with no_infomsgs
            end'
        end
        select @command = @command + '
        end
    end'
        insert into #tmptriggercmd (phase, cmdtext) values (1, @command)
        select @command=''
    end


    select @command = @command + '
    declare @article_rows_inserted int
    select @article_rows_inserted =  count(*) from inserted 
    if @article_rows_inserted = 0 
        return
    declare @tablenick int, @rowguid uniqueidentifier
    , @replnick binary(6), @lineage varbinary(311), @colv1 varbinary(' + convert(nvarchar(13), @max_colv_size_in_bytes) + '), @cv varbinary(1)
    , @ccols int, @newgen bigint, @version int, @curversion int
    , @oldmaxversion int, @child_newgen bigint, @child_oldmaxversion int, @child_metadatarows_updated int 
    , @logical_record_parent_rowguid uniqueidentifier 
    , @num_parent_rows int, @parent_row_inserted bit, @ts_rows_exist bit, @marker uniqueidentifier 
    declare @dt datetime
    declare @nickbin varbinary(8)
    declare @error int'
        
    if @logical_record_view is not null and @is_top_level_logical_record_parent = 0
        select @command = @command + '
    declare @logical_record_distinct_parent_rowguids table (logical_record_parent_rowguid uniqueidentifier unique) '
        
    insert into #tmptriggercmd (phase, cmdtext) values (1, @command)
    
    select @command = '
    set nocount on
    set @tablenick = ' + @tablenickchar + '
    set @lineage = 0x0
    set @retcode = 0
    select @oldmaxversion= maxversion_at_cleanup from dbo.sysmergearticles where nickname = @tablenick
    select @dt = getdate()

    select @replnick = ' + sys.fn_varbintohexstr(@replnick) + ' 
    set @nickbin= @replnick + 0xFF

    select @newgen = NULL
        select top 1 @newgen = generation from ' + @quoted_genhistory_viewname + ' with (rowlock, updlock, readpast) 
        where art_nick = ' + @tablenickchar + ' and genstatus = 0'
    if @level_generations_in_trigger = 1
        select @command = @command + '
            and  changecount <= (' + convert(nvarchar, @gen_change_threshold) + ' - isnull(@article_rows_inserted,0))'
    select @command = @command + '
    if @newgen is NULL
    begin
        insert into ' + @quoted_genhistory_viewname + ' with (rowlock)
            (guidsrc, genstatus, art_nick, nicknames, coldate, changecount)
             values   (newid(), 0, @tablenick, @nickbin, @dt, @article_rows_inserted)
        select @error = @@error, @newgen = @@identity    
        if @error<>0 or @newgen is NULL
            goto FAILURE
    end'
    if @level_generations_in_trigger = 1
        select @command = @command + '
    else
    begin
        -- now update the changecount of the generation we go to reflect the number of rows we put in this generation
        update ' + @quoted_genhistory_viewname + '  with (rowlock)
            set changecount = changecount + @article_rows_inserted
            where generation = @newgen
        if @@error<>0 goto FAILURE
    end'

    select @command = @command + '
    set @lineage = { fn UPDATELINEAGE (0x0, @replnick, 1) }
        ' + @ifcoltracking + '
    if (@@error <> 0)
    begin
        goto FAILURE
    end

    select @ts_rows_exist = 0'
    insert into #tmptriggercmd (phase, cmdtext) values (1, @command)

    if @logical_record_view is not null 
    select @command ='
    if @article_rows_inserted = 1
    begin
        select @rowguid = rowguidcol from inserted
        select @ts_rows_exist = 1 where exists (select rowguid from ' + @quoted_tsview + ' where tablenick = @tablenick and rowguid = @rowguid)
    end
    else
    begin
        select @ts_rows_exist = 1 where exists (select ts.rowguid from inserted i, ' + @quoted_tsview + ' ts with (rowlock) where ts.tablenick = @tablenick and ts.rowguid = i.rowguidcol)
    end'
    else
    select @command ='
        select @ts_rows_exist = 1 where exists (select ts.rowguid from inserted i, ' + @quoted_tsview + ' ts with (rowlock) where ts.tablenick = @tablenick and ts.rowguid = i.rowguidcol)'        
    insert into #tmptriggercmd (phase, cmdtext) values (1, @command)

    select @command = '    
    if @ts_rows_exist = 1
    begin'
    if @logical_record_view is not null 
        select @command = @command + '    
        if @article_rows_inserted = 1
            select @version = max({fn GETMAXVERSION(lineage)}) from ' + @quoted_tsview + ' where 
                tablenick = @tablenick and rowguid = @rowguid
        else'
    select @command = @command + '    
        select @version = max({fn GETMAXVERSION(lineage)}) from ' + @quoted_tsview + ' where 
            tablenick = @tablenick and rowguid in (select rowguidcol from inserted) 

        if @version is not null
        begin
            -- reset lineage and colv to higher version...
            set @curversion = 0
            while (@curversion <= @version)
            begin
                set @lineage = { fn UPDATELINEAGE (@lineage, @replnick, @oldmaxversion+1) }
                set @curversion= { fn GETMAXVERSION(@lineage) }
            end

            if (@colv1 IS NOT NULL)
                set @colv1 = { fn UPDATECOLVBM(@colv1, @replnick, 0x01, 0x00, { fn GETMAXVERSION(@lineage) }) }'
            
    if @logical_record_view is not null 
        select @command = @command + '    
            if @article_rows_inserted = 1
                delete from ' + @quoted_tsview + ' with (rowlock) where tablenick = @tablenick and rowguid = @rowguid
            else'
    
        select @command = @command + '    
                delete from ' + @quoted_tsview + ' with (rowlock) where tablenick = @tablenick and rowguid in
                    (select rowguidcol from inserted) 
        end
    end 
    select @marker = newid() '
    insert into #tmptriggercmd (phase, cmdtext) values (1, @command)
            
    if @logical_record_view is not null
    begin
        select @command = ' 
    if (@article_rows_inserted = 1)
    begin
        declare @contents_row_exists bit
                
        select @contents_row_exists = 0
                
        select @contents_row_exists = 1 where exists (select rowguid from ' + @quoted_viewname + ' with (rowlock) where tablenick = @tablenick and rowguid = @rowguid)  '
        
        insert into #tmptriggercmd (phase, cmdtext) values (1, @command)
            
        if @is_top_level_logical_record_parent = 0
        begin
        
            select @command = '
        
        select @logical_record_parent_rowguid = logical_record_parent_rowguid 
        from ' + quotename(object_name(@logical_record_view)) + ' where ' + @quoted_rgcol + ' = @rowguid '
        
            select @command = @command + '        
        if @contents_row_exists = 0
        begin '

            select @command = @command + '
            insert into ' + @quoted_viewname + ' with (rowlock) (tablenick, rowguid, lineage, colv1, generation, partchangegen, logical_record_parent_rowguid, marker) 
            values (@tablenick, @rowguid, @lineage, @colv1, @newgen, (-@newgen), @logical_record_parent_rowguid, @marker) '
    
            insert into #tmptriggercmd (phase, cmdtext) values (1, @command)
    
            select @command = '
        end 
        else
        begin
            update ' + @quoted_viewname + ' set logical_record_parent_rowguid = @logical_record_parent_rowguid
                where tablenick = @tablenick and rowguid = @rowguid

        end 
        exec @retcode = sys.sp_MSupdate_singlelogicalrecordmetadata ' + convert(nvarchar, @logical_record_parent_nickname) + ', @logical_record_parent_rowguid, @replnick, @parent_row_inserted output
        if @@error <> 0 or @retcode <> 0
            goto FAILURE
    end
    else
    begin '
            insert into #tmptriggercmd (phase, cmdtext) values (1, @command)
        end        -- @is_top_level_logical_record_parent = 1
        else 
        begin
            select @command = '        
        if @contents_row_exists = 0
        begin 
            insert into ' + @quoted_viewname + ' with (rowlock) (tablenick, rowguid, lineage, colv1, generation, partchangegen, logical_record_parent_rowguid, marker, logical_record_lineage) 
            values (@tablenick, @rowguid, @lineage, @colv1, @newgen, (-@newgen), @rowguid, @marker, @lineage) '
    
            insert into #tmptriggercmd (phase, cmdtext) values (1, @command)
    
            select @command = '
        end 
        else
        begin
            update ' + @quoted_viewname + ' set logical_record_parent_rowguid = @rowguid,
                logical_record_lineage = { fn UPDATELINEAGE(logical_record_lineage, @replnick, @oldmaxversion+1) }
                where tablenick = @tablenick and rowguid = @rowguid
        end 
    end
    else
    begin '
            insert into #tmptriggercmd (phase, cmdtext) values (1, @command)
        end
    end    
        
    if @logical_record_view is null
    begin
        select @command = '
        insert into ' + @quoted_viewname + ' with (rowlock) (tablenick, rowguid, lineage, colv1, generation, partchangegen, marker) 
        select @tablenick, rowguidcol, @lineage, @colv1, @newgen, (-@newgen), @marker
        from inserted i where not exists
        (select rowguid from ' + @quoted_viewname + ' with (readcommitted, rowlock, readpast) where tablenick = @tablenick and rowguid = i.rowguidcol) '

    end
    else
    begin
        if @is_top_level_logical_record_parent = 0
            select @command = '
        insert into ' + @quoted_viewname + ' with (rowlock) (tablenick, rowguid, lineage, colv1, generation, partchangegen, logical_record_parent_rowguid, marker) 
        select @tablenick, i.rowguidcol, @lineage, @colv1, @newgen, (-@newgen), logical_record_parent_rowguid, @marker
        from inserted i, ' + quotename(object_name(@logical_record_view)) + ' lrv with (rowlock)
        where i.rowguidcol = lrv.' + @quoted_rgcol + '
        and not exists
            (select rowguid from ' + @quoted_viewname + ' with (readcommitted, rowlock, readpast) where tablenick = @tablenick and rowguid = i.rowguidcol)
        
    end'
       else -- @is_top_level_logical_record_parent = 1
            select @command = '
        insert into ' + @quoted_viewname + ' with (rowlock) (tablenick, rowguid, lineage, colv1, generation, partchangegen, logical_record_parent_rowguid, marker, logical_record_lineage) 
        select @tablenick, i.rowguidcol, @lineage, @colv1, @newgen, (-@newgen), i.rowguidcol, @marker,@lineage
        from inserted i
        where not exists
            (select rowguid from ' + @quoted_viewname + ' with (readcommitted, rowlock, readpast) where tablenick = @tablenick and rowguid = i.rowguidcol) 
    end'
    end
    
    insert into #tmptriggercmd (phase, cmdtext) values (1, @command)
    
    select @command = '
    if @@rowcount = 0
    begin
        select top 1 @marker = mc.marker 
        from inserted i, ' + @quoted_viewname + ' mc with (rowlock)
        where mc.tablenick = @tablenick
        and mc.rowguid = i.rowguidcol
        
    end '
    
    -- uncomment for compplan size test
    --insert into #tmptriggercmd (phase, cmdtext) values (1, @command)

    if @logical_record_view is not null and @is_top_level_logical_record_parent = 0
    begin
        select @command = '        
    if @article_rows_inserted > 1
        begin
        insert into @logical_record_distinct_parent_rowguids
            select distinct lrv.logical_record_parent_rowguid 
            from inserted i, ' 
            + quotename(object_name(@logical_record_view)) + ' lrv with (rowlock)
            where i.rowguidcol = lrv.' + @quoted_rgcol + '
            and lrv.logical_record_parent_rowguid is not null
        
        select @num_parent_rows = @@rowcount
        
        if @num_parent_rows = 1
        begin
            -- this could happen when all rows being inserted are the children of the same parent row.
            select @logical_record_parent_rowguid = logical_record_parent_rowguid from @logical_record_distinct_parent_rowguids
            exec @retcode = sys.sp_MSupdate_singlelogicalrecordmetadata ' + convert(nvarchar, @logical_record_parent_nickname) + ', @logical_record_parent_rowguid, @replnick, @parent_row_inserted output
            if @@error <> 0 or @retcode <> 0
                goto FAILURE
        end
        else if @num_parent_rows > 1
        begin
            declare @logical_record_parent_oldmaxversion int, @logical_record_lineage varbinary(311), @logical_record_parent_regular_lineage varbinary(311), @logical_record_parent_gencur bigint
            
            select top 1 @logical_record_parent_oldmaxversion = maxversion_at_cleanup
            from dbo.sysmergearticles 
            where nickname = ' + convert(nvarchar,@logical_record_parent_nickname) + '

            -- the code below will get an open generation for the parent
            select @logical_record_parent_gencur = NULL
            select top 1 @logical_record_parent_gencur = generation from ' + @quoted_genhistory_viewname + ' with (rowlock, updlock, readpast) 
                where art_nick = ' + convert(nvarchar,@logical_record_parent_nickname) + ' 
                    and genstatus = 0'
        if @level_generations_in_trigger = 1
            select @command = @command + '        
                    and changecount <= (' + convert(nvarchar, @gen_change_threshold) + '-isnull(@num_parent_rows,0))'
        select @command = @command + '        
            if @logical_record_parent_gencur is NULL
            begin
                insert into ' + @quoted_genhistory_viewname + ' with (rowlock)
                (guidsrc, genstatus, art_nick, nicknames, coldate, changecount)
                       values (newid(), 0, ' + convert(nvarchar,@logical_record_parent_nickname) + ', @nickbin, @dt, @num_parent_rows)
                select @error= @@error, @logical_record_parent_gencur = @@identity   
                if @error<>0 or @logical_record_parent_gencur is NULL
                    goto FAILURE
            end'
        if @level_generations_in_trigger = 1
            select @command = @command + '        
            else
            begin
                -- do the update right away to change the changecount to include the rows that we just put in the generation
                update ' + @quoted_genhistory_viewname + ' with (rowlock)
                set changecount = changecount + @num_parent_rows
                where generation = @logical_record_parent_gencur 
                if @@error<>0 goto FAILURE
            end'
            
            insert into #tmptriggercmd (phase, cmdtext) values (1, @command)
        
            select @command = '    
            update ' + @quoted_viewname + ' with (rowlock)
            set logical_record_lineage = { fn UPDATELINEAGE(logical_record_lineage, @replnick, @logical_record_parent_oldmaxversion+1) },
            generation = @logical_record_parent_gencur
            from @logical_record_distinct_parent_rowguids lrpg join ' + @quoted_viewname + ' with (rowlock)
            on tablenick = ' + convert(nvarchar, @logical_record_parent_nickname) + '
            and rowguid = lrpg.logical_record_parent_rowguid
            option (force order, loop join)
        
            delete from @logical_record_distinct_parent_rowguids
            where logical_record_parent_rowguid in (select rowguid from ' + @quoted_viewname + '
                where tablenick = ' + convert(nvarchar, @logical_record_parent_nickname) + ')
                
            -- Now @logical_record_distinct_parent_rowguids is left with parent rowguids that are not present in MSmerge_contents.
            if exists (select * from @logical_record_distinct_parent_rowguids)
            begin
                select @logical_record_lineage = { fn UPDATELINEAGE(0x0, @replnick, @logical_record_parent_oldmaxversion+1) }
                
                -- if no cleanup done yet, use 1 as the version.
                if @logical_record_parent_oldmaxversion = 1
                    select @logical_record_parent_regular_lineage = { fn UPDATELINEAGE(0x0, @replnick, 1) }
                else 
                    select @logical_record_parent_regular_lineage = @logical_record_lineage
                        
                insert into ' + @quoted_viewname + ' with (rowlock) (tablenick, rowguid, lineage, colv1, generation, partchangegen,                                             
                    logical_record_parent_rowguid, logical_record_lineage) 
                select distinct ' + convert(nvarchar, @logical_record_parent_nickname) + ', lrpg.logical_record_parent_rowguid, 
                    @logical_record_parent_regular_lineage, 0x00, @logical_record_parent_gencur, NULL, lrpg.logical_record_parent_rowguid, 
                    @logical_record_lineage
                from @logical_record_distinct_parent_rowguids lrpg
                where not exists (select rowguid from ' + @quoted_viewname + ' with (rowlock) where tablenick = ' + convert(nvarchar, @logical_record_parent_nickname) + '
                                    and rowguid = lrpg.logical_record_parent_rowguid)
            end
        end 
    end'
        insert into #tmptriggercmd (phase, cmdtext) values (1, @command)
    end
    
    select @command = '
    if @@error <> 0 
        goto FAILURE '

    insert into #tmptriggercmd (phase, cmdtext) values (1, @command)
        
    -- if partition groups functionality is being used, we need to insert the partition ids for these 
    -- newly inserted contents rows. 
    
    if @logical_record_view is not null and @is_top_level_logical_record_parent = 0
    begin    
        declare lrp_partition_view_ids CURSOR LOCAL FAST_FORWARD FOR 
        select partition_view_id, pubid, objid
        from dbo.sysmergepartitioninfoview where nickname = @logical_record_parent_nickname
        and partition_view_id is not null
        for read only

        open lrp_partition_view_ids

        fetch next from lrp_partition_view_ids into @lrp_partition_view_id, @lrp_pubid, @lrp_objid

        while (@@fetch_status <> -1)
        begin
                
            select top 1 @lrp_publication_number = publication_number from dbo.sysmergepublications where pubid = @lrp_pubid
            select @lrp_rgcol = quotename(name) from sys.columns where object_id = @lrp_objid and is_rowguidcol = 1
            select @lrp_partition_view_name = 'dbo.' + quotename(object_name(@lrp_partition_view_id))
            if @lrp_partition_view_name is not null
            begin

                select @command = NULL
                select @command = '
    
    if @article_rows_inserted = 1 or @num_parent_rows = 1
    begin
        -- if we did not insert the parent row, we have no business inserting the mapping row.
        if @parent_row_inserted = 1
        begin
            insert into ' + @quoted_current_mappings_viewname + ' with (rowlock) (publication_number, tablenick, rowguid, partition_id)
            select distinct ' + convert(nvarchar, @lrp_publication_number) + ', ' 
            + convert(nvarchar,@logical_record_parent_nickname) + ', v.' + @lrp_rgcol + ', v.partition_id
            from ' + @lrp_partition_view_name + ' as v with (rowlock)
            where v.' + @lrp_rgcol + ' = @logical_record_parent_rowguid 
        end
    end
    else
        insert into ' + @quoted_current_mappings_viewname + ' with (rowlock) (publication_number, tablenick, rowguid, partition_id)
        select distinct ' + convert(nvarchar, @lrp_publication_number) + ', ' 
        + convert(nvarchar,@logical_record_parent_nickname) + ', v.' + @lrp_rgcol + ', v.partition_id
        from @logical_record_distinct_parent_rowguids as lrpg, ' 
        + @lrp_partition_view_name + ' as v with (rowlock)
        where v.' + @lrp_rgcol + ' = lrpg.logical_record_parent_rowguid 
        and not exists (select * from ' + @quoted_current_mappings_viewname + ' mcpg with (readcommitted, rowlock, readpast)
                            where mcpg.tablenick = ' + convert(nvarchar,@logical_record_parent_nickname) + '
                            and mcpg.rowguid = v.' + @lrp_rgcol + ')
        '
        
                insert into #tmptriggercmd (phase, cmdtext) values (1, @command)
            end
            
            fetch next from lrp_partition_view_ids into @lrp_partition_view_id, @lrp_pubid, @lrp_objid
        end

        close lrp_partition_view_ids
        deallocate lrp_partition_view_ids
    end

    declare @partition_view_id int, @partition_view_name nvarchar(270), @pubid uniqueidentifier, @partition_inserted_view_rule nvarchar(max),
            @publication_number smallint, @basetable_ownerqualified_replviewname nvarchar(517)

    if @article_published = 1
    begin
        declare partition_view_ids CURSOR LOCAL FAST_FORWARD FOR 
        select partition_view_id, pubid, partition_inserted_view_rule, partition_options
        from dbo.sysmergepartitioninfoview where nickname = @tablenick
        and partition_view_id is not null
        for read only

        open partition_view_ids

        fetch next from partition_view_ids into @partition_view_id, @pubid, @partition_inserted_view_rule, @partition_options

        while (@@fetch_status <> -1)
        begin
                
            select top 1 @publication_number = publication_number from dbo.sysmergepublications where pubid = @pubid
            
            select @basetable_ownerqualified_replviewname = 
                quotename(SCHEMA_NAME(schema_id)) + N'.' + quotename(object_name(object_id))
            from sys.objects with (nolock) where object_id =
                (select top 1 repl_view_id from dbo.sysmergepartitioninfoview
                    where pubid = @pubid and objid = @objid)
            
            select @partition_view_name = 'dbo.' + quotename(object_name(@partition_view_id))
            if @partition_view_name is not null
            begin

                select @command3 = NULL
                if @partition_options = 2 or @partition_options = 3
                    select @command3 = '
                if @is_mergeagent = 0 or @at_publisher = 0 '

                select @command3 = isnull(@command3, ' ')
                
                if @logical_record_view is not null
                    select @command3 = @command3 + '
            if @article_rows_inserted = 1
                insert into ' + @quoted_current_mappings_viewname + ' with (rowlock) (publication_number, tablenick, rowguid, partition_id)
                select distinct ' + convert(nvarchar, @publication_number) + ', @tablenick, @rowguid, v.partition_id
                from ' + @partition_view_name + ' as v with (rowlock)
                where v.' + @quoted_rgcol + ' = @rowguid
            else'
            
                select @command3 = @command3 + '
            insert into ' + @quoted_current_mappings_viewname + ' with (rowlock) (publication_number, tablenick, rowguid, partition_id)
            select distinct ' + convert(nvarchar, @publication_number) + ', @tablenick, v.' + @quoted_rgcol + ', v.partition_id
            from ( ' + @partition_inserted_view_rule + ' ) as v '
                
                insert into #tmptriggercmd (phase, cmdtext) values (3, @command3)
            end
            
            fetch next from partition_view_ids into @partition_view_id, @pubid, @partition_inserted_view_rule, @partition_options
        end

        close partition_view_ids
        deallocate partition_view_ids
        
        -- Logical records are based on PK-FK relationships. So when a parent row is inserted, it can be safely
        -- assumed that none of the child rows would pre-exist. As a result, the following expansion code will not
        -- find any children if logical records are in use. So, don't need to worry about determining the 
        -- logical_record_parent_rowguid for the child rows brought in via expansion below.
        
        declare @expand_proc nvarchar(255)
        
        declare expand_procs CURSOR LOCAL FAST_FORWARD FOR 
        select distinct expand_proc from dbo.sysmergepartitioninfoview 
        where nickname = @tablenick
        and expand_proc is not null
        and exists -- at least one non-LR child exists
            (select * from dbo.sysmergesubsetfilters
                where join_nickname = @tablenick
                and filter_type = 1)
                
        open expand_procs
        
        fetch next from expand_procs into @expand_proc
        
        while @@fetch_status <> -1
        begin
            set @command3 = '
            
        exec @retcode = dbo.' + quotename(@expand_proc) + ' @marker = @marker, @inherit_pastchanges_generation = -1, @trigger_type = 0
        if @retcode <> 0 goto FAILURE '
            -- uncomment for compplan size tests
            --insert into #tmptriggercmd (phase, cmdtext) values(14, @command3)
                
            fetch next from expand_procs into @expand_proc
        end
        
        close expand_procs
        deallocate expand_procs

        declare immediate_children CURSOR LOCAL FAST_FORWARD FOR 
        select distinct quotename(object_name(sma.objid)), sma.objid, sma.nickname, 'dbo.' + quotename(object_name(sma.partition_view_id)), 
                    ssf.join_filterid, ssf.join_filterclause, ssf.join_unique_key, sma.expand_proc, sma.pubid, sma.column_tracking
        from dbo.sysmergesubsetfilters ssf, dbo.sysmergepartitioninfoview sma where ssf.join_nickname = @tablenick
        and sma.nickname = ssf.art_nickname
        and sma.pubid = ssf.pubid
        and ssf.filter_type = 1    
        and sma.partition_view_id is not null
        for read only
            
        open immediate_children

        fetch next from immediate_children into @immediate_child_table_name, @immediate_child_objid, @immediate_child_nickname, 
                @immediate_child_partition_viewname, @join_filter_id, @join_filterclause, @join_unique_key, @child_expand_proc, @pubid, @child_has_col_tracking

        if (@@fetch_status <> -1)
        begin
            select @command3 = '

        declare @child_marker uniqueidentifier
        declare @child_rowcount int
        set @child_marker = newid()    '
            insert into #tmptriggercmd (phase, cmdtext) values(14, @command3)
        end

        while (@@fetch_status <> -1)
        begin
        
            exec @retcode = sys.sp_MSis_joinfilter_based_on_PK_UQ_constraints @pubid = @pubid,
                                                                        @join_filter_id = @join_filter_id,
                                                                        @dri_based = @child_cannot_pre_exist output,
                                                                        @unique_constraint_based = @parent_columns_unique output
                                                                        
            if @@error <> 0 or @retcode <> 0
                return 1
                
            if @child_cannot_pre_exist = 1
                goto InsertTriggerGetNextChild
        
            select @owner_qualified_immediate_child_table_name = 
                quotename(SCHEMA_NAME(schema_id)) + '.' + quotename(object_name(object_id))
            from sys.objects with (nolock) where object_id =
                (select top 1 repl_view_id from dbo.sysmergepartitioninfoview
                    where pubid = @pubid and objid = @immediate_child_objid)
            
            select top 1 @publication_number = publication_number from dbo.sysmergepublications where pubid = @pubid

            -- Fix for VSTS 217316
            select top 1 @partition_inserted_view_rule = partition_inserted_view_rule from dbo.sysmergepartitioninfoview where pubid = @pubid and artid = @artid

            select  top 1 @child_join_colname = name from sys.columns where object_id = @immediate_child_objid
            and sys.fn_MSisfilteredcolumn(@join_filterclause, name, @immediate_child_objid) = 1 

            select @child_rgcol = quotename(name) from sys.columns where object_id = @immediate_child_objid and is_rowguidcol = 1

            if @join_unique_key = 0 or @parent_columns_unique = 0
            begin
                if @logical_record_view is not null
                    select @command3 = '
        if @article_rows_inserted = 1
            select @child_rowcount = count(*) from ' 
            + @owner_qualified_immediate_child_table_name + ' ' + @immediate_child_table_name + ' with (rowlock)
            where ' + @child_rgcol + ' in 
            (select ' + @immediate_child_table_name + '.' + @child_rgcol + ' from ' 
                + @basetable_ownerqualified_replviewname + ' ' + quotename(object_name(@objid)) + ' with (rowlock), '
                + @owner_qualified_immediate_child_table_name + ' ' + @immediate_child_table_name + ' with (rowlock)
            where ' + quotename(object_name(@objid)) + '.' + @quoted_rgcol + ' = @rowguid and ' + '(' + @join_filterclause + ')' + ')
        else'
                else
                    select @command3 = ''
                select @command3 = @command3 + '
            select @child_rowcount = count(*) from ' 
            + @owner_qualified_immediate_child_table_name + ' ' + @immediate_child_table_name + ' with (rowlock)
            where ' + @child_rgcol + ' in 
            (select ' + @immediate_child_table_name + '.' + @child_rgcol + ' from ' 
                + ' inserted ' + quotename(object_name(@objid)) + ', '
                + @owner_qualified_immediate_child_table_name + ' ' + @immediate_child_table_name + ' with (rowlock)
            where ' + '(' + @join_filterclause + ')' + ')
            '
            end
            else
            begin
                if @logical_record_view is not null
                    select @command3 = '
        if @article_rows_inserted = 1
            select @child_rowcount = count(*) from ' 
                + @basetable_ownerqualified_replviewname + ' ' + quotename(object_name(@objid)) + ' with (rowlock), '
                + @owner_qualified_immediate_child_table_name + ' ' + @immediate_child_table_name + ' with (rowlock) 
            where ' + quotename(object_name(@objid)) + '.' + @quoted_rgcol + ' = @rowguid and ' + '(' + @join_filterclause + ')
        else'
                else
                    select @command3 = ''
                select @command3 = @command3 + '
            select @child_rowcount = count(*) from ' 
                + ' inserted ' + quotename(object_name(@objid)) + ', '
                + @owner_qualified_immediate_child_table_name + ' ' + @immediate_child_table_name + ' with (rowlock)
                where ' + '(' + @join_filterclause + ')
                '
            end
            insert into #tmptriggercmd (phase, cmdtext) values(14, @command3)
                        
            -- touch the immediate children of deleted rows
            select @command3 = '
        if @child_rowcount > 0
        begin
            select @child_oldmaxversion= maxversion_at_cleanup 
                from dbo.sysmergearticles 
                where nickname = ' + convert(nvarchar, @immediate_child_nickname) + '
                
            -- the code below will get an open generation for the child article
            select @child_newgen = NULL
            select top 1 @child_newgen = generation from ' + @quoted_genhistory_viewname + ' with (rowlock, updlock, readpast) 
                where art_nick = ' + convert(nvarchar,@immediate_child_nickname) + ' 
                    and genstatus = 0'
            if @level_generations_in_trigger = 1
                select @command3 = @command3 + '
                    and changecount <= (' + convert(nvarchar, @gen_change_threshold) + '- isnull(@child_rowcount,0))'
            select @command3 = @command3 + '
            if @child_newgen is NULL
            begin
                insert into ' + @quoted_genhistory_viewname + ' with (rowlock)
                    (guidsrc, genstatus, art_nick, nicknames, coldate, changecount)
                       values (newid(), 0, ' + convert(nvarchar,@immediate_child_nickname) + ', @nickbin, @dt, @child_rowcount)
                select @error=@@error, @child_newgen = @@identity    
                if @error<>0 or @child_newgen is NULL
                    goto FAILURE
            end'
            if @level_generations_in_trigger = 1
                select @command3 = @command3 + '
            else
            begin
                -- do the update right away to change the changecount to include the rows that we just put in the generation
                update ' + @quoted_genhistory_viewname + ' with (rowlock)
                set changecount = changecount + @child_rowcount
                where generation = @child_newgen 
                if @@error<>0 goto FAILURE
            end'
            insert into #tmptriggercmd (phase, cmdtext) values(14, @command3)
                        
            if @join_unique_key = 0 or @parent_columns_unique = 0
            begin
                if @logical_record_view is not null
                begin
                    select @command3 = '            
            if @article_rows_inserted = 1
                update ' + @quoted_viewname + ' with (rowlock) set generation = @child_newgen, partchangegen = @child_newgen, marker = @child_marker
                from ' + @quoted_viewname + ' mc with (rowlock)
                where mc.tablenick = ' + convert (nvarchar, @immediate_child_nickname) + ' 
                and mc.rowguid in 
                    (select ' + @immediate_child_table_name + '.' + @child_rgcol + ' from ' 
                        + @basetable_ownerqualified_replviewname + ' ' + quotename(object_name(@objid)) + ' with (rowlock), ' 
                        + @owner_qualified_immediate_child_table_name + ' ' + @immediate_child_table_name + ' with (rowlock)
                       where ' + quotename(object_name(@objid)) + '.' 
                       + @quoted_rgcol + ' = @rowguid and ' 
                       + '(' + @join_filterclause + ')' + ')
            else'
                    insert into #tmptriggercmd (phase, cmdtext) values(14, @command3)
                end
                else
                    select @command3 = ''
                    
                select @command3 = '
                update ' + @quoted_viewname + ' with (rowlock) set generation = @child_newgen, partchangegen = @child_newgen, marker = @child_marker
                from ' + @quoted_viewname + ' mc with (rowlock)
                where mc.tablenick = ' + convert (nvarchar, @immediate_child_nickname) + ' 
                and mc.rowguid in 
                    (select ' + @immediate_child_table_name + '.' + @child_rgcol + ' from  
                    inserted ' + quotename(object_name(@objid)) + ', '
                    + @owner_qualified_immediate_child_table_name + ' ' + @immediate_child_table_name + ' with (rowlock)
                    where ' + '(' + @join_filterclause + ')' + ') '
            end
            else
            begin
                if @logical_record_view is not null
                begin
                    select @command3 = '
            if @article_rows_inserted = 1
                update ' + @quoted_viewname + ' with (rowlock) set generation = @child_newgen, partchangegen = @child_newgen, marker = @child_marker
                from ' 
                + @basetable_ownerqualified_replviewname + ' ' + quotename(object_name(@objid)) + ' with (rowlock), '
                + @owner_qualified_immediate_child_table_name + ' ' + @immediate_child_table_name + ' with (rowlock), '
                + @quoted_viewname + ' mc with (rowlock) 
                where ' + quotename(object_name(@objid)) + '.' + @quoted_rgcol + ' = @rowguid and (' + @join_filterclause + ') and
                mc.tablenick = ' + convert (nvarchar, @immediate_child_nickname) + ' 
                and mc.rowguid = ' + @immediate_child_table_name + '.' + @child_rgcol + '  
            else'
                    insert into #tmptriggercmd (phase, cmdtext) values(14, @command3)
                end
                else
                    select @command3 = ''
                select @command3 = '
                update ' + @quoted_viewname + ' with (rowlock) set generation = @child_newgen, partchangegen = @child_newgen, marker = @child_marker
                from 
                inserted ' + quotename(object_name(@objid)) + ', '
                + @owner_qualified_immediate_child_table_name + ' ' + @immediate_child_table_name + ' with (rowlock), '
                + @quoted_viewname + ' mc with (rowlock) 
                where mc.tablenick = ' + convert (nvarchar, @immediate_child_nickname) + ' 
                and mc.rowguid = ' + @immediate_child_table_name + '.' + @child_rgcol + '          
                and ' + '(' + @join_filterclause + ') '
            end

            insert into #tmptriggercmd (phase, cmdtext) values(14, @command3)
                    
            select @command3 = '

            select @child_metadatarows_updated = @@rowcount '
            insert into #tmptriggercmd (phase, cmdtext) values(14, @command3)

            select @command3 = '
            if @child_metadatarows_updated < @child_rowcount '
            insert into #tmptriggercmd (phase, cmdtext) values(14, @command3)

            set @command3 = '
            begin
                    set @lineage = 0x00 '

            insert into #tmptriggercmd (phase, cmdtext) values(14, @command3)

            if @child_has_col_tracking = 1
                set @command3 =  '
                    set @cv = 0xFF '
            else 
                set @command3 = ' 
                    set @cv = NULL '
                
            insert into #tmptriggercmd (phase, cmdtext) values(14, @command3)

            if @join_unique_key = 0 or @parent_columns_unique = 0
            begin
                if @logical_record_view is not null
                    set @command3 = '
                if @article_rows_inserted = 1
                    insert into ' + @quoted_viewname + ' with (rowlock) (tablenick, rowguid, generation, lineage, colv1, marker) 
                    select ' + convert(nvarchar, @immediate_child_nickname) + ', ' + @immediate_child_table_name + '.' + @child_rgcol + ', @child_newgen, @lineage, @cv, @child_marker
                    from ' + @owner_qualified_immediate_child_table_name + ' ' + @immediate_child_table_name + ' with (rowlock)
                    where ' + @child_rgcol + ' in 
                        (select  ' + @immediate_child_table_name + '.' + @child_rgcol + ' from ' 
                        + @basetable_ownerqualified_replviewname + ' ' + quotename(object_name(@objid)) + ' with (rowlock), '
                        + @owner_qualified_immediate_child_table_name + ' ' + @immediate_child_table_name + ' with (rowlock)
                        where ' + quotename(object_name(@objid)) + '.' + @quoted_rgcol + ' = @rowguid and ' + '(' + @join_filterclause + ')' + ')
                    and not exists 
                            (select * from ' + @quoted_viewname + ' mc with (rowlock)
                            where mc.tablenick = ' + convert(nvarchar, @immediate_child_nickname) + ' 
                            and rowguid = ' + @immediate_child_table_name + '.' + @child_rgcol + ')
                else'
                else
                    select @command3 = ''
                select @command3 = @command3 + '
                    insert into ' + @quoted_viewname + ' with (rowlock) (tablenick, rowguid, generation, lineage, colv1, marker) 
                    select ' + convert(nvarchar, @immediate_child_nickname) + ', ' + @immediate_child_table_name + '.' + @child_rgcol + ', 0, @lineage, @cv, @child_marker
                    from ' 
                    + @owner_qualified_immediate_child_table_name + ' ' + @immediate_child_table_name + ' with (rowlock)
                    where ' + @child_rgcol + ' in 
                        (select  ' + @immediate_child_table_name + '.' + @child_rgcol + ' from 
                        inserted ' + quotename(object_name(@objid)) + ', '
                        + @owner_qualified_immediate_child_table_name + ' ' + @immediate_child_table_name + ' with (rowlock)
                        where ' + '(' + @join_filterclause + ')' + ')
                    and not exists 
                            (select * from ' + @quoted_viewname + ' mc with (rowlock)
                            where mc.tablenick = ' + convert(nvarchar, @immediate_child_nickname) + ' 
                            and rowguid = ' + @immediate_child_table_name + '.' + @child_rgcol + ')
                    '
            end
            else
            begin
                if @logical_record_view is not null
                    set @command3 = '
                if @article_rows_inserted = 1
                    insert into ' + @quoted_viewname + ' with (rowlock) (tablenick, rowguid, generation, lineage, colv1, marker) 
                    select ' + convert(nvarchar, @immediate_child_nickname) + ', ' + @immediate_child_table_name + '.' + @child_rgcol + ', 0, @lineage, @cv, @child_marker
                    from ' 
                    + @basetable_ownerqualified_replviewname + ' ' + quotename(object_name(@objid)) + ' with (rowlock), '
                    + @owner_qualified_immediate_child_table_name + ' ' + @immediate_child_table_name  + ' with (rowlock) 
                    where ' + quotename(object_name(@objid)) + '.' + @quoted_rgcol + ' = @rowguid and ' + '(' + @join_filterclause + ')' + '
                    and not exists 
                        (select * from ' + @quoted_viewname + ' mc with (rowlock)
                        where mc.tablenick = ' + convert(nvarchar, @immediate_child_nickname) + ' 
                        and rowguid = ' + @immediate_child_table_name + '.' + @child_rgcol + ')
                else'
                else
                    select @command3 = ''
                select @command3 = @command3 + '
                    insert into ' + @quoted_viewname + ' with (rowlock) (tablenick, rowguid, generation, lineage, colv1, marker) 
                    select ' + convert(nvarchar, @immediate_child_nickname) + ', ' + @immediate_child_table_name + '.' + @child_rgcol + ', 0, @lineage, @cv, @child_marker
                    from
                    inserted ' + quotename(object_name(@objid)) + ', ' 
                    + @owner_qualified_immediate_child_table_name + ' ' + @immediate_child_table_name  + ' with (rowlock)
                    where ' + '(' + @join_filterclause + ')' + '
                    and not exists 
                        (select * from ' + @quoted_viewname + ' mc with (rowlock)
                        where mc.tablenick = ' + convert(nvarchar, @immediate_child_nickname) + ' 
                        and rowguid = ' + @immediate_child_table_name + '.' + @child_rgcol + ')
                    '
            end

            insert into #tmptriggercmd (phase, cmdtext) values(14, @command3)

            select @command3 = '
            end    '
            insert into #tmptriggercmd (phase, cmdtext) values(14, @command3)

            --select @command3 = '
            --delete ' + @current_mappings_viewname + ' from 
            --' + @current_mappings_viewname + ' cpmv join ' + @viewname + ' mc
            --on cpmv.tablenick = mc.tablenick
            --and mc.tablenick = ' + convert(nvarchar(11), @immediate_child_nickname) + '
            --and cpmv.tablenick = ' + convert(nvarchar(11), @immediate_child_nickname) + '
            --and cpmv.rowguid = mc.rowguid
            --and cpmv.publication_number = ' + convert(nvarchar, @publication_number) + '
            --and mc.marker = @child_marker '
            --insert into #tmptriggercmd (phase, cmdtext) values(14, @command3)
            select @command3 = '
            insert into ' + @quoted_current_mappings_viewname + ' with (rowlock) (publication_number, tablenick, rowguid, partition_id)
            select distinct ' + convert(nvarchar, @publication_number) + ', ' + convert (nvarchar(11), @immediate_child_nickname) + ', ' + @immediate_child_table_name + '.' + @child_rgcol + ', ' + quotename(object_name(@objid)) + '.partition_id
            from ( ' + @partition_inserted_view_rule + ' ) as ' + quotename(object_name(@objid))
            + ' JOIN ' + @owner_qualified_immediate_child_table_name + ' ' + @immediate_child_table_name + ' with (rowlock)
            ON ' + '(' + @join_filterclause + ')
            WHERE not exists
            (select * from ' + @quoted_current_mappings_viewname + ' where publication_number = ' + convert(nvarchar, @publication_number) + '
                and tablenick = ' + convert(nvarchar(11), @immediate_child_nickname) + ' 
                and rowguid = ' + @immediate_child_table_name + '.' + @child_rgcol + '
                and partition_id = ' + quotename(object_name(@objid)) + '.partition_id)
            '

            insert into #tmptriggercmd (phase, cmdtext) values(14, @command3)

            if @child_expand_proc is not null and @child_expand_proc != ' '
            begin
                set @command3 = '
            exec dbo.' + quotename(@child_expand_proc) + ' @marker = @child_marker, @inherit_pastchanges_generation = -1, @parent_being_updated = 0, @trigger_type = 0 '
                insert into #tmptriggercmd (phase, cmdtext) values(14, @command3)
            end

            select @command3 = '
        end    '
            insert into #tmptriggercmd (phase, cmdtext) values(14, @command3)

    InsertTriggerGetNextChild:

            fetch next from immediate_children into @immediate_child_table_name, @immediate_child_objid, @immediate_child_nickname, 
                    @immediate_child_partition_viewname, @join_filter_id, @join_filterclause, @join_unique_key, @child_expand_proc, 
                    @pubid, @child_has_col_tracking
        end

        close immediate_children
        deallocate immediate_children

    end -- end @article_published = 1
    
    select @command4 = ' 

    return
FAILURE:
    if @@trancount > 0
        rollback tran
    raiserror (20041, 16, -1)
    return    '
        insert into #tmptriggercmd (phase, cmdtext) values (20, @command4)
end

    -- upd_ trigger generation
    /* Call separate routine to add update trigger */
    if @trigger_type = 1
    begin
        exec @retcode=sys.sp_MSaddupdatetrigger @quoted_source_table_name, @owner, @object, @artid, @column_tracking, @viewname, @trigname, @current_mappings_viewname, @past_mappings_viewname, @genhistory_viewname
        if @retcode<>0 or @@ERROR<>0 return (1)
    end

    -- del_ trigger generation
    /* Now make the delete trigger */
    -- NOTE: owner name removed

    if @trigger_type = 2
    begin
        select @command=NULL, @command2=NULL, @command3=NULL, @command4=NULL

        set @command = '
create trigger ' + @quoted_trigname + ' on ' + @quoted_db_source_table_name + ' FOR DELETE ' + @notforrepl_str1 + ' AS 
    declare @is_mergeagent bit, @at_publisher bit, @retcode smallint 

    set rowcount 0
    set transaction isolation level read committed
'
    
        if exists (select * from dbo.sysmergearticles where nickname = @tablenick 
                    and (pubid in (select pubid from dbo.sysmergepublications where use_partition_groups = 1)
                            or published_in_tran_pub = 1 ))
        begin
            select @command = @command + '
            exec @retcode = sys.sp_MSisreplmergeagent @is_mergeagent output, @at_publisher output
            if @@error <> 0 or @retcode <> 0
            begin
                rollback tran
                return
            end '
        end
        else
        begin
            select @command = @command + '
            select @is_mergeagent = convert(bit, sessionproperty(''replication_agent''))
            select @at_publisher = 0 '
        end

        if (@notforrepl_bit = 1)
            select @command = @command + @notforrepl_str2
            
        if @partition_options = 2 or @partition_options = 3
        select @command = @command + '
        if @is_mergeagent = 1 and @at_publisher = 1
            return '

        select @command = @command + '
    declare @article_rows_deleted int
    declare @xe_message varbinary(1000)
    select @article_rows_deleted = count(*) from deleted
    if @article_rows_deleted=0
        return
    declare @tablenick int, @replnick binary(6), 
            @lineage varbinary(311), @newgen bigint, @oldmaxversion int, @child_newgen bigint, 
            @child_oldmaxversion int, @child_metadatarows_updated int, @cv varbinary(1),
            @logical_record_parent_oldmaxversion int, @logical_record_lineage varbinary(311), @logical_record_parent_regular_lineage varbinary(311), @logical_record_parent_gencur bigint,
            @num_parent_rows int, @logical_record_parent_rowguid uniqueidentifier, @parent_row_inserted bit, @rowguid uniqueidentifier 
    declare @dt datetime, @nickbin varbinary(8), @error int
    '
    
    if @logical_record_view is not null and @is_top_level_logical_record_parent = 0
        select @command = @command + '
    declare @logical_record_distinct_parent_rowguids table (logical_record_parent_rowguid uniqueidentifier unique) '
    insert into #tmptriggercmd (phase, cmdtext) values (1, @command)
    
    select @command = '
    set nocount on
    select @tablenick = ' + @tablenickchar + '
    if @article_rows_deleted = 1 select @rowguid = rowguidcol from deleted
    select @oldmaxversion= maxversion_at_cleanup from dbo.sysmergearticles where nickname = @tablenick
    select @dt = getdate()

    select @replnick = ' + sys.fn_varbintohexstr(@replnick) + '
    set @nickbin= @replnick + 0xFF

    select @newgen = NULL
        select top 1 @newgen = generation from ' + @quoted_genhistory_viewname + ' with (rowlock, updlock, readpast) 
        where art_nick = ' + @tablenickchar + '  and genstatus = 0    
        '
    if @level_generations_in_trigger = 1
        select @command = @command + '
            and  changecount <= (' + convert(nvarchar, @gen_change_threshold) + ' - isnull(@article_rows_deleted,0))'
    select @command = @command + '
    if @newgen is NULL
    begin
        insert into ' + @quoted_genhistory_viewname + '  with (rowlock)
            (guidsrc, genstatus, art_nick, nicknames, coldate, changecount)
               values (newid(), 0, @tablenick, @nickbin, @dt, @article_rows_deleted)
        select @error = @@error, @newgen = @@identity    
        if @error<>0 or @newgen is NULL
            goto FAILURE
    end'
    if @level_generations_in_trigger = 1
        select @command = @command + '
    else
    begin
        -- now update the changecount of the generation we go to reflect the number of rows we put in this generation
        update ' + @quoted_genhistory_viewname + '  with (rowlock)
            set changecount = changecount + @article_rows_deleted
            where generation = @newgen
        if @@error<>0 goto FAILURE
    end
'
    insert into #tmptriggercmd (phase, cmdtext) values (1, @command)
    
    if @logical_record_view is not null 
    begin    
        select top 1 @logical_record_parent_nickname = logical_record_parent_nickname 
        from dbo.sysmergepartitioninfo
        where artid = @artid
        and logical_record_parent_nickname is not null
    end
    
    -- Do not update the tombstone table if the delete_tracking property is set to false on the article.
    -- This property when set blocks replication of deletes. Note: It causes non-convergence.
    if @delete_tracking = 0
    begin
        set @command2 = '
        set @lineage = { fn UPDATELINEAGE(0x0, @replnick, @oldmaxversion+1) }'
    end
    else
    begin
        set @command2 = '
    set @lineage = { fn UPDATELINEAGE(0x0, @replnick, @oldmaxversion+1) } '
    
        insert into #tmptriggercmd (phase, cmdtext) values (3, @command2)
    
        if @logical_record_view is null or @is_top_level_logical_record_parent = 0
            set @command2 = '
    if @article_rows_deleted = 1
        insert into ' + @quoted_tsview + ' with (rowlock) (rowguid, tablenick, type, lineage, generation)
            select @rowguid, @tablenick, 1, isnull((select { fn UPDATELINEAGE(COALESCE(c.lineage, @lineage), @replnick, @oldmaxversion+1) } from 
            ' + @quoted_viewname + ' c with (rowlock) where c.tablenick = @tablenick and c.rowguid = @rowguid),@lineage), @newgen
    else
        insert into ' + @quoted_tsview + ' with (rowlock) (rowguid, tablenick, type, lineage, generation)
            select d.rowguidcol, @tablenick, 1, { fn UPDATELINEAGE(COALESCE(c.lineage, @lineage), @replnick, @oldmaxversion+1) }, @newgen from 
            deleted d left outer join ' + @quoted_viewname + ' c with (rowlock) on c.tablenick = @tablenick and c.rowguid = d.rowguidcol 
            '
        else
            set @command2 = '
    if @article_rows_deleted = 1
        insert into ' + @quoted_tsview + ' with (rowlock) (rowguid, tablenick, type, lineage, generation, logical_record_parent_rowguid, logical_record_lineage)
            select @rowguid, @tablenick, 1, isnull((select { fn UPDATELINEAGE(COALESCE(c.lineage, @lineage), @replnick, @oldmaxversion+1) } from 
            ' + @quoted_viewname + ' c with (rowlock) where c.tablenick = @tablenick and c.rowguid = @rowguid),@lineage), @newgen,
            @rowguid, isnull((select { fn UPDATELINEAGE(COALESCE(c.logical_record_lineage, @lineage), @replnick, @oldmaxversion+1) } from 
            ' + @quoted_viewname + ' c with (rowlock) where c.tablenick = @tablenick and c.rowguid = @rowguid),@lineage)
    else
        insert into ' + @quoted_tsview + ' with (rowlock) (rowguid, tablenick, type, lineage, generation, logical_record_parent_rowguid, logical_record_lineage)
            select d.rowguidcol, @tablenick, 1, { fn UPDATELINEAGE(COALESCE(c.lineage, @lineage), @replnick, @oldmaxversion+1) }, @newgen,
            d.rowguidcol, { fn UPDATELINEAGE(COALESCE(c.logical_record_lineage, @lineage), @replnick, @oldmaxversion+1) }
            from deleted d left outer join ' + @quoted_viewname + ' c with (rowlock) on c.tablenick = @tablenick and c.rowguid = d.rowguidcol 
            '
            
            insert into #tmptriggercmd (phase, cmdtext) values (3, @command2)
            
            set @command2 = '
    if @@error <> 0
        GOTO FAILURE '
        end
        insert into #tmptriggercmd (phase, cmdtext) values (3, @command2)

        if exists (select * from dbo.sysmergepartitioninfoview 
                    where nickname = @tablenick and partition_view_id is not null)
        begin
            if @logical_record_view is not null
                set @command2 =  '    
    if @article_rows_deleted = 1
        delete from ' + @quoted_current_mappings_viewname + ' with (rowlock)
        where tablenick = @tablenick
        and rowguid = @rowguid
    else'
            else
                select @command2 = ''
            select @command2 = @command2 + '
        delete from ' + @quoted_current_mappings_viewname + ' with (rowlock)
        from deleted d
        JOIN ' + @quoted_current_mappings_viewname + ' cpm with (rowlock)
        ON cpm.tablenick = @tablenick
        and cpm.rowguid = d.' + @quoted_rgcol + '
        option (force order, loop join) ' 
    
            insert into #tmptriggercmd (phase, cmdtext) values (3, @command2)
    
            declare partition_view_ids CURSOR LOCAL FAST_FORWARD FOR 
            select partition_view_id, pubid, partition_deleted_view_rule
            from dbo.sysmergepartitioninfoview 
            where nickname = @tablenick
            and partition_view_id is not null -- if partition_view_id is NULL, this publication is not using partition groups
            for read only

            open partition_view_ids

            fetch next from partition_view_ids into @partition_view_id, @pubid, @partition_deleted_view_rule
            while (@@fetch_status <> -1)
            begin

                select top 1 @publication_number = publication_number from dbo.sysmergepublications where pubid = @pubid

                select @partition_view_name = 'dbo.' + quotename(object_name(@partition_view_id))
                
                if @partition_view_name is not null
                begin

                --handle the case when there is a delete cascade constraint. When the following conditions are satisfied, we 
                -- need to delete the rows from all partitions:
                --		(1) the ON DELETE CASCADE constraint is set
                --		(2) the rows in the parent table do not exist
                -- (yiche)

               declare   @join_table_name nvarchar(270),   -- the parent table name
                		@join_filter_clause nvarchar(270),
                		@parent_partition_view_name nvarchar(517) -- the partition view name for the parent table

		declare @jt nvarchar(270) -- the unquoted name for the join_table_name
		select @jt = join_articlename, @join_filter_clause  = join_filterclause  
		from dbo.sysmergesubsetfilters
		where pubid = @pubid and artid = @artid  -- note that an article might belongs to multiple publication

		select @join_table_name = QUOTENAME(@jt)

		select @parent_partition_view_name = 'dbo.' + QUOTENAME(object_name(partition_view_id))
		from dbo.sysmergepartitioninfoview, sys.objects
		where object_name(objid) = @jt	and object_id = @objid and pubid = @pubid

		if ( not exists (select * 
					from sys.foreign_keys fks JOIN dbo.sysmergearticles art
					on fks.parent_object_id = art.objid
					where fks.delete_referential_action = 1 --on delete cascade
						and art.nickname = @tablenick )
		    OR ( @join_filter_clause IS NULL )
		) --endif
		begin
		                     

    
                    select @command2 = '
         -- update any ppm row that already exist with this gen
         update ppm set ppm.generation = case when @is_mergeagent = 1 then 0 else @newgen end
         from ' + @quoted_past_mappings_viewname + ' ppm with (rowlock) inner join deleted v
         on ppm.tablenick =@tablenick  and ppm.rowguid = v.' + @quoted_rgcol + '
         -- insert the past partition mapping into gen 0 if this is the merge agent 
        insert into ' + @quoted_past_mappings_viewname + ' with (rowlock) (publication_number, tablenick, rowguid, partition_id, generation,reason)
        select distinct ' + convert(nvarchar(100), @publication_number) + ', @tablenick, v.' + @quoted_rgcol + ', v.partition_id, case when @is_mergeagent = 1 then 0 else @newgen end, 1
        from ( ' + @partition_deleted_view_rule + ' ) as v   
        if (@@ROWCOUNT <= 0)
        begin
             select @xe_message = CAST(''replica_id: '' + convert(nvarchar(100), @replnick) + '', article_id: '' + convert(nvarchar(100), @tablenick) + '', rowguid: '' + case when @article_rows_deleted = 1 then convert(nvarchar(100), @rowguid) else N''0'' end + '', generation: '' + case when @is_mergeagent = 1 then N''0'' else convert(nvarchar(100), @newgen) end + '', Reason: -1'' AS varbinary(1000));
            exec master..sp_repl_generateevent 1, N''Event : ppm_insert'', @xe_message
        end
        '

        	end 
        	else
        	begin

			select @command2 = '
				-- update any ppm row that already exist with this gen
				update ppm set ppm.generation = case when @is_mergeagent = 1 then 0 else @newgen end
				from ' + @quoted_past_mappings_viewname + ' ppm with (rowlock) inner join deleted v
				on ppm.tablenick =@tablenick  and ppm.rowguid = v.' + @quoted_rgcol + '
				if ( not exists (select *
						from deleted ' + QUOTENAME(@source_table) + '  JOIN  ' + @parent_partition_view_name + '  ' + @join_table_name + '
						  on ( '+ @join_filter_clause+' ) )) 
				begin
					insert into ' + @quoted_past_mappings_viewname + ' with (rowlock) ( publication_number, tablenick, rowguid, partition_id, generation, reason)
					select distinct ' + convert( nvarchar(100), @publication_number)+', @tablenick, v.' + @quoted_rgcol +', -1, case when @is_mergeagent = 1 then 0 else @newgen end, 1
					from deleted as v
				end 
				else
				begin
				        insert into ' + @quoted_past_mappings_viewname + ' with (rowlock) (publication_number, tablenick, rowguid, partition_id, generation,reason)
				        select distinct ' + convert(nvarchar(100), @publication_number) + ', @tablenick, v.' + @quoted_rgcol + ', v.partition_id, case when @is_mergeagent = 1 then 0 else @newgen end, 1
				        from ( ' + @partition_deleted_view_rule + ' ) as v 				
				end
				if (@@ROWCOUNT <= 0)
				begin
				    select @xe_message = CAST(''replica_id: '' + convert(nvarchar(100), @replnick) + '', article_id: '' + convert(nvarchar(100), @tablenick) + '', rowguid: '' + case when @article_rows_deleted = 1 then convert(nvarchar(100), @rowguid) else N''0'' end + '', generation: '' + case when @is_mergeagent = 1 then N''0'' else convert(nvarchar(100), @newgen) end + '', Reason: -1'' AS varbinary(1000));
				    exec master..sp_repl_generateevent 1, N''Event : ppm_insert'', @xe_message
				end
			'

        	end
        
                    insert into #tmptriggercmd (phase, cmdtext) values (3, @command2)
                end
            
                fetch next from partition_view_ids into @partition_view_id, @pubid, @partition_deleted_view_rule
            end
        end

        if @logical_record_view is not null and @is_top_level_logical_record_parent = 0
        begin
            select @command = '
            declare @logical_record_rowguid_parent_rowguid_mapping table (rowguid uniqueidentifier, logical_record_parent_rowguid uniqueidentifier) '
            
            insert into #tmptriggercmd (phase, cmdtext) values (1, @command)
            
            if @is_top_level_logical_record_parent = 0
            begin
                select @command = '        
    insert into @logical_record_rowguid_parent_rowguid_mapping
    select ' + @quoted_rgcol + ', logical_record_parent_rowguid from (' + @logical_record_deleted_view_rule + ') as lrdvr
    where lrdvr.logical_record_parent_rowguid is not null
    
    insert into @logical_record_distinct_parent_rowguids 
    select distinct logical_record_parent_rowguid from @logical_record_rowguid_parent_rowguid_mapping
        
    select @num_parent_rows = @@rowcount
        
    if @num_parent_rows = 1
    begin
        -- this could happen when all rows being inserted are the children of the same parent row.
        select @logical_record_parent_rowguid = logical_record_parent_rowguid from @logical_record_distinct_parent_rowguids
        exec @retcode = sys.sp_MSupdate_singlelogicalrecordmetadata ' + convert(nvarchar, @logical_record_parent_nickname) + ', @logical_record_parent_rowguid, @replnick, @parent_row_inserted output
        if @@error <> 0 or @retcode <> 0
            goto FAILURE
    end
    else if @num_parent_rows > 1
    begin
        select top 1 @logical_record_parent_oldmaxversion = maxversion_at_cleanup
        from dbo.sysmergearticles
        where nickname = ' + convert(nvarchar,@logical_record_parent_nickname) + '
        
        -- the code below will get an open generation for the parent
        select @logical_record_parent_gencur = NULL
        select top 1 @logical_record_parent_gencur = generation from ' + @quoted_genhistory_viewname + ' with (rowlock, updlock, readpast) 
            where art_nick = ' + convert(nvarchar,@logical_record_parent_nickname) + ' 
                and genstatus = 0'
                if @level_generations_in_trigger = 1
                    select @command = @command + '
                and changecount <= (' + convert(nvarchar, @gen_change_threshold) + '-isnull(@num_parent_rows,0))'
                select @command = @command + '
        if @logical_record_parent_gencur is NULL
        begin
            insert into ' + @quoted_genhistory_viewname + '  with (rowlock)
                (guidsrc, genstatus, art_nick, nicknames, coldate, changecount)
                   values (newid(), 0, ' + convert(nvarchar,@logical_record_parent_nickname) + ', @nickbin, @dt, @num_parent_rows)
            select @error = @@error, @logical_record_parent_gencur = @@identity    
            if @error<>0 or @logical_record_parent_gencur is NULL
                goto FAILURE
        end'
                if @level_generations_in_trigger = 1
                    select @command = @command + '
        else
        begin
            -- do the update right away to change the changecount to include the rows that we just put in the generation
            update ' + @quoted_genhistory_viewname + '  with (rowlock)
            set changecount = changecount + @num_parent_rows
            where generation = @logical_record_parent_gencur 
            if @@error<>0 goto FAILURE
        end'
                insert into #tmptriggercmd (phase, cmdtext) values (1, @command)
            
                select @command = '
        update ' + @quoted_viewname + '  with (rowlock)
        set logical_record_lineage = { fn UPDATELINEAGE(logical_record_lineage, @replnick, @logical_record_parent_oldmaxversion+1) },
        generation = @logical_record_parent_gencur
        from @logical_record_distinct_parent_rowguids lrpg join ' + @quoted_viewname + ' with (rowlock)
        on tablenick = ' + convert(nvarchar, @logical_record_parent_nickname) + '
        and rowguid = lrpg.logical_record_parent_rowguid
        option (force order, loop join)
            
        delete from @logical_record_distinct_parent_rowguids
        where logical_record_parent_rowguid in (select rowguid from ' + @quoted_viewname + '
            where tablenick = ' + convert(nvarchar, @logical_record_parent_nickname) + ')
                
        -- Now @logical_record_distinct_parent_rowguids is left with parent rowguids that are not present in MSmerge_contents.
        if exists (select * from @logical_record_distinct_parent_rowguids)
        begin
            select @logical_record_lineage = { fn UPDATELINEAGE(0x0, @replnick, @logical_record_parent_oldmaxversion+1) }
            
            -- if no cleanup done yet, use 1 as the version.
            if @logical_record_parent_oldmaxversion = 1
                select @logical_record_parent_regular_lineage = { fn UPDATELINEAGE(0x0, @replnick, 1) }
            else 
                select @logical_record_parent_regular_lineage = @logical_record_lineage
            
            insert into ' + @quoted_viewname + ' with (rowlock) (tablenick, rowguid, lineage, colv1, generation, partchangegen,                                             
                logical_record_parent_rowguid, logical_record_lineage) 
            select distinct ' + convert(nvarchar, @logical_record_parent_nickname) + ', lrpg.logical_record_parent_rowguid, 
                @logical_record_lineage, 0x00, @logical_record_parent_gencur, NULL, lrpg.logical_record_parent_rowguid, 
                @logical_record_lineage
            from @logical_record_distinct_parent_rowguids lrpg
            where not exists (select rowguid from ' + @quoted_viewname + ' with (rowlock) where tablenick = ' + convert(nvarchar, @logical_record_parent_nickname) + '
                                and rowguid = lrpg.logical_record_parent_rowguid)
        end
    end '
        
                insert into #tmptriggercmd (phase, cmdtext) values (1, @command)
                                            
                -- if partition groups functionality is being used, we need to insert the partition ids for these 
                -- newly inserted contents rows. 
            
                declare lrp_partition_view_ids CURSOR LOCAL FAST_FORWARD FOR 
                select partition_view_id, pubid, objid
                from dbo.sysmergepartitioninfoview where nickname = @logical_record_parent_nickname
                and partition_view_id is not null
                for read only

                open lrp_partition_view_ids

                fetch next from lrp_partition_view_ids into @lrp_partition_view_id, @lrp_pubid, @lrp_objid

                while (@@fetch_status <> -1)
                begin
                    
                    select top 1 @lrp_publication_number = publication_number from dbo.sysmergepublications where pubid = @lrp_pubid
                    select @lrp_rgcol = quotename(name) from sys.columns where object_id = @lrp_objid and is_rowguidcol = 1
                    select @lrp_partition_view_name = 'dbo.' + quotename(object_name(@lrp_partition_view_id))
                    if @lrp_partition_view_name is not null
                    begin

                        select @command = NULL
                        select @command = '
        if @num_parent_rows = 1
        begin
        -- if we did not insert the parent row, we have no business inserting the mapping row.
            if @parent_row_inserted = 1
            begin
                insert into ' + @quoted_current_mappings_viewname + ' with (rowlock) (publication_number, tablenick, rowguid, partition_id)
                select distinct ' + convert(nvarchar, @lrp_publication_number) + ', ' 
                + convert(nvarchar,@logical_record_parent_nickname) + ', v.' + @lrp_rgcol + ', v.partition_id
                from ' + @lrp_partition_view_name + ' as v  with (rowlock)
                where v.' + @lrp_rgcol + ' = @logical_record_parent_rowguid 
            end
        end
        else
        insert into ' + @quoted_current_mappings_viewname + ' with (rowlock) (publication_number, tablenick, rowguid, partition_id)
        select distinct ' + convert(nvarchar, @lrp_publication_number) + ', ' 
        + convert(nvarchar,@logical_record_parent_nickname) + ', v.' + @lrp_rgcol + ', v.partition_id
            from @logical_record_distinct_parent_rowguids as lrpg, ' + @lrp_partition_view_name + ' as v with (rowlock)
            where v.' + @lrp_rgcol + ' = lrpg.logical_record_parent_rowguid 
            and not exists (select * from ' + @quoted_current_mappings_viewname + ' mcpg with (rowlock)
                    where mcpg.tablenick = ' + convert(nvarchar,@logical_record_parent_nickname) + '
                    and mcpg.rowguid = v.' + @lrp_rgcol + ')
            '
            
                        insert into #tmptriggercmd (phase, cmdtext) values (1, @command)
                    end
                
                    fetch next from lrp_partition_view_ids into @lrp_partition_view_id, @lrp_pubid, @lrp_objid
                end

                close lrp_partition_view_ids
                deallocate lrp_partition_view_ids
            end
        end
        
        if @logical_record_view is not null and @is_top_level_logical_record_parent = 0
        begin
            select @command = ' 
            update ts with (rowlock) set ts.logical_record_parent_rowguid = lrrprm.logical_record_parent_rowguid
            from @logical_record_rowguid_parent_rowguid_mapping lrrprm, ' + @quoted_tsview + ' ts with (rowlock)
            where ts.tablenick = @tablenick 
            and ts.rowguid = lrrprm.rowguid 
            option (force order, loop join) '
        
            insert into #tmptriggercmd (phase, cmdtext) values (3, @command)
        end


        -- this expansion code is only needed on the publisher
        if @article_published = 1
        begin
        
            -- Logical records are based on PK-FK relationships. So when a parent row is deleted, it can be safely
            -- assumed that none of the child rows exist (they should have been deleted beforehand). 
            -- As a result, the following expansion code will not
            -- find any children if logical records are in use. So, don't need to worry about determining the 
            -- logical_record_parent_rowguid for the child rows brought in via expansion below.

            declare immediate_children CURSOR LOCAL FAST_FORWARD FOR 
            select distinct quotename(object_name(sma.objid)), sma.objid, sma.nickname, 'dbo.' + quotename(object_name(sma.partition_view_id)), 
                        ssf.join_filterid, ssf.join_filterclause, ssf.join_unique_key, sma.expand_proc, sma.pubid, sma.column_tracking
            from dbo.sysmergesubsetfilters ssf, dbo.sysmergepartitioninfoview sma 
            where ssf.join_nickname = @tablenick
            and sma.nickname = ssf.art_nickname
            and sma.pubid = ssf.pubid
            and ssf.filter_type = 1
            and sma.partition_view_id is not null
            for read only

            open immediate_children

            fetch next from immediate_children into @immediate_child_table_name, @immediate_child_objid, @immediate_child_nickname, 
                @immediate_child_partition_viewname, @join_filter_id, @join_filterclause, @join_unique_key, @child_expand_proc, @pubid, @child_has_col_tracking

            if (@@fetch_status <> -1)
            begin
                select @command3 = '
    declare @child_marker uniqueidentifier
    declare @child_rowcount int
    set @child_marker = newid()    '
                insert into #tmptriggercmd (phase, cmdtext) values(14, @command3)
            end

            while (@@fetch_status <> -1)
            begin
            
                exec @retcode = sys.sp_MSis_joinfilter_based_on_PK_UQ_constraints @pubid = @pubid,
                                                                        @join_filter_id = @join_filter_id,
                                                                        @dri_based = @child_cannot_pre_exist output,
    																	@unique_constraint_based = @parent_columns_unique output
                                                                        
                if @@error <> 0 or @retcode <> 0
                    return 1
                    
                if @child_cannot_pre_exist = 1
                    goto DeleteTriggerGetNextChild
                
                select @owner_qualified_immediate_child_table_name = 
                    quotename(SCHEMA_NAME(schema_id)) + '.' + quotename(object_name(object_id))
                from sys.objects with (nolock) where object_id =
                    (select top 1 repl_view_id from dbo.sysmergepartitioninfoview
                    where pubid = @pubid and objid = @immediate_child_objid)
            
                select top 1 @publication_number = publication_number from dbo.sysmergepublications where pubid = @pubid

                select  top 1 @child_join_colname = name from sys.columns where object_id = @immediate_child_objid
                and sys.fn_MSisfilteredcolumn(@join_filterclause, name, @immediate_child_objid) = 1 

                select @child_rgcol = quotename(name) from sys.columns where object_id = @immediate_child_objid and is_rowguidcol = 1

                if @join_unique_key = 0 or @parent_columns_unique = 0
                begin
                    select @command3 = '
    select @child_rowcount = count(*) from ' 
    + @owner_qualified_immediate_child_table_name + ' ' + @immediate_child_table_name + ' with (rowlock)
    where ' + @child_rgcol + ' in 
        (select ' + @immediate_child_table_name + '.' + @child_rgcol + ' from 
        deleted ' + quotename(object_name(@objid)) + ', '
        + @owner_qualified_immediate_child_table_name + ' ' + @immediate_child_table_name + ' with (rowlock)
        where ' + '(' + @join_filterclause + ')' + ')
    '
                end
                else
                begin
                    select @command3 = '
    select @child_rowcount = count(*) from 
        deleted ' + quotename(object_name(@objid)) + ', '
        + @owner_qualified_immediate_child_table_name + ' ' + @immediate_child_table_name + ' with (rowlock)
    where ' + '(' + @join_filterclause + ')
    '
                end
                insert into #tmptriggercmd (phase, cmdtext) values(14, @command3)
                            
                -- touch the immediate children of deleted rows
                select @command3 = '
    if @child_rowcount > 0
    begin
        select @child_oldmaxversion= maxversion_at_cleanup 
            from dbo.sysmergearticles 
            where nickname = ' + convert(nvarchar, @immediate_child_nickname) + '
            
        -- the code below will get an open generation for the child article
        select @child_newgen = NULL
        select top 1 @child_newgen = generation from ' + @quoted_genhistory_viewname + ' with (rowlock, updlock, readpast) 
            where art_nick = ' + convert(nvarchar,@immediate_child_nickname) + ' 
                and genstatus = 0'
                if @level_generations_in_trigger = 1
                    select @command3 = @command3 + '
                and changecount <= (' + convert(nvarchar, @gen_change_threshold) + '- isnull(@child_rowcount,0))'
                select @command3 = @command3 + '
        if @child_newgen is NULL
        begin
            insert into ' + @quoted_genhistory_viewname + '  with (rowlock)
                (guidsrc, genstatus, art_nick, nicknames, coldate, changecount)
                   values (newid(), 0, ' + convert(nvarchar,@immediate_child_nickname) + ', @nickbin, @dt, @child_rowcount)
            select @error=@@error, @child_newgen = @@identity    
            if @error<>0 or @child_newgen is NULL
                goto FAILURE
        end'
                if @level_generations_in_trigger = 1
                    select @command3 = @command3 + '
        else
        begin
            -- do the update right away to change the changecount to include the rows that we just put in the generation
            update ' + @quoted_genhistory_viewname + '  with (rowlock)
            set changecount = changecount + @child_rowcount
            where generation = @child_newgen 
            if @@error<>0 goto FAILURE
        end'


                insert into #tmptriggercmd (phase, cmdtext) values(14, @command3)
                            
                if @join_unique_key = 0 or @parent_columns_unique = 0
                begin
                    select @command3 = '
        update ' + @quoted_viewname + ' with (rowlock) set generation = @child_newgen, partchangegen = @child_newgen, marker = @child_marker
        from ' + @quoted_viewname + ' mc with (rowlock)
        where mc.tablenick = ' + convert (nvarchar, @immediate_child_nickname) + ' 
        and mc.rowguid in 
            (select ' + @immediate_child_table_name + '.' + @child_rgcol + ' from 
            deleted ' + quotename(object_name(@objid)) + ', '
            + @owner_qualified_immediate_child_table_name + ' ' + @immediate_child_table_name + ' with (rowlock)
            where ' + '(' + @join_filterclause + ')' + ') '
                end
                else
                begin
                    select @command3 = '
        update ' + @quoted_viewname + ' with (rowlock) set generation = @child_newgen, partchangegen = @child_newgen, marker = @child_marker
        from 
        deleted ' + quotename(object_name(@objid)) + ', '
        + @owner_qualified_immediate_child_table_name + ' ' + @immediate_child_table_name + ' with (rowlock), '
        + @quoted_viewname + ' mc with (rowlock) 
        where mc.tablenick = ' + convert (nvarchar, @immediate_child_nickname) + ' 
        and mc.rowguid = ' + @immediate_child_table_name + '.' + @child_rgcol + '          
        and ' + '(' + @join_filterclause + ') '
                end

                insert into #tmptriggercmd (phase, cmdtext) values(14, @command3)
                    
                select @command3 = '
        select @child_metadatarows_updated = @@rowcount '
                insert into #tmptriggercmd (phase, cmdtext) values(14, @command3)

                select @command3 = '
        if @child_metadatarows_updated < @child_rowcount '
                insert into #tmptriggercmd (phase, cmdtext) values(14, @command3)

                set @command3 = '
        begin
            set @lineage = { fn UPDATELINEAGE(0x0, @replnick, @child_oldmaxversion+1) } '

                insert into #tmptriggercmd (phase, cmdtext) values(14, @command3)

                if @child_has_col_tracking = 1
                    set @command3 =  '
                set @cv = 0xFF '
                else 
                    set @command3 = ' 
                set @cv = NULL '
            
                set @command3 = @command3 + '
                insert into ' + @quoted_viewname + ' with (rowlock) (tablenick, rowguid, generation, lineage, colv1, marker)  '
                insert into #tmptriggercmd (phase, cmdtext) values(14, @command3)

                if @join_unique_key = 0 or @parent_columns_unique = 0
                begin
                    set @command3 = '
            select ' + convert(nvarchar, @immediate_child_nickname) + ', ' + @immediate_child_table_name + '.' + @child_rgcol + ', @child_newgen, @lineage, @cv, @child_marker
            from ' 
            + @owner_qualified_immediate_child_table_name + ' ' + @immediate_child_table_name + ' with (rowlock)
            where ' + @child_rgcol + ' in 
                (select  ' + @immediate_child_table_name + '.' + @child_rgcol + ' from 
                deleted ' + quotename(object_name(@objid)) + ', '
                + @owner_qualified_immediate_child_table_name + ' ' + @immediate_child_table_name + ' with (rowlock)
                where ' + '(' + @join_filterclause + ')' + ')
            and not exists 
                (select * from ' + @quoted_viewname + ' mc with (rowlock)
                where mc.tablenick = ' + convert(nvarchar, @immediate_child_nickname) + ' 
                and rowguid = ' + @immediate_child_table_name + '.' + @child_rgcol + ')
                '
                end
                else
                begin
                    set @command3 = '
            select ' + convert(nvarchar, @immediate_child_nickname) + ', ' + @immediate_child_table_name + '.' + @child_rgcol + ', 0, @lineage, @cv, @child_marker
            from
                deleted ' + quotename(object_name(@objid)) + ', '
                + @owner_qualified_immediate_child_table_name + ' ' + @immediate_child_table_name + ' with (rowlock)
            where ' + '(' + @join_filterclause + ')' + '
            and not exists 
                (select * from ' + @quoted_viewname + ' mc with (rowlock)
                where mc.tablenick = ' + convert(nvarchar, @immediate_child_nickname) + ' 
                and rowguid = ' + @immediate_child_table_name + '.' + @child_rgcol + ')
                '
                end

                insert into #tmptriggercmd (phase, cmdtext) values(14, @command3)

                select @command3 = '
        end    '
                insert into #tmptriggercmd (phase, cmdtext) values(14, @command3)

                select @command3 = '
        delete ' + @quoted_current_mappings_viewname + ' with (rowlock) from 
        ' + @quoted_viewname + ' mc with (rowlock) join ' + @quoted_current_mappings_viewname + ' cpmv with (rowlock)
        on cpmv.tablenick = mc.tablenick
        and mc.tablenick = ' + convert(nvarchar(11), @immediate_child_nickname) + '
        and cpmv.tablenick = ' + convert(nvarchar(11), @immediate_child_nickname) + '
        and cpmv.rowguid = mc.rowguid
        and cpmv.publication_number = ' + convert(nvarchar, @publication_number) + '
        and mc.marker = @child_marker '
                insert into #tmptriggercmd (phase, cmdtext) values(14, @command3)

                select @command3 = '
        insert into ' + @quoted_current_mappings_viewname + ' with (rowlock) (publication_number, tablenick, rowguid, partition_id)
        select distinct ' + convert(nvarchar, @publication_number) + ', mc.tablenick, mc.rowguid, v.partition_id
        from ' + @quoted_viewname + ' mc with (rowlock)
        JOIN ' + @immediate_child_partition_viewname + ' v with (rowlock)
        ON mc.tablenick = ' + convert(nvarchar(11), @immediate_child_nickname) + '
        and mc.rowguid = v.' + @child_rgcol + '
        and mc.marker = @child_marker 
        '

                insert into #tmptriggercmd (phase, cmdtext) values(14, @command3)

                select top 1 @partition_deleted_view_rule = partition_deleted_view_rule 
                from dbo.sysmergepartitioninfoview 
                where pubid = @pubid 
                and nickname = @tablenick

                if @partition_deleted_view_rule is not null and @partition_deleted_view_rule <> ' '
                begin

                    select @command3 = '
        insert into ' + @quoted_past_mappings_viewname + ' with (rowlock) (publication_number, tablenick, rowguid, partition_id, generation, reason)
        select distinct ' + convert(nvarchar, @publication_number) + ', ' + convert (nvarchar, @immediate_child_nickname) + ', ' + @immediate_child_table_name + '.' + @child_rgcol + ', ' + 
                    quotename(object_name(@objid)) + '.partition_id, @child_newgen, 1
        from ( ' + @partition_deleted_view_rule + ' ) as ' + quotename(object_name(@objid)) 
        + ', ' + @owner_qualified_immediate_child_table_name + ' ' + @immediate_child_table_name + ' with (rowlock)
        where ' + '(' + @join_filterclause + ')
        '

                    insert into #tmptriggercmd (phase, cmdtext) values(14, @command3)
                end
            
                if @child_expand_proc is not null and @child_expand_proc != ' '
                begin
                    set @command3 = '
        exec dbo.' + quotename(@child_expand_proc) + ' @marker = @child_marker, @inherit_pastchanges_generation = @child_newgen, @parent_being_updated = 0, @trigger_type = 2 '
                insert into #tmptriggercmd (phase, cmdtext) values(14, @command3)
                end

                select @command3 = '
    end    '
                insert into #tmptriggercmd (phase, cmdtext) values(14, @command3)

DeleteTriggerGetNextChild:

                fetch next from immediate_children into @immediate_child_table_name, @immediate_child_objid, @immediate_child_nickname, 
                    @immediate_child_partition_viewname, @join_filter_id, @join_filterclause, @join_unique_key, @child_expand_proc, @pubid, @child_has_col_tracking
            end

            close immediate_children
            deallocate immediate_children
            
    end --  if @article_published = 1

    if @logical_record_view is not null
        set @command4 = '
    if @article_rows_deleted = 1
        delete from ' + @quoted_viewname + ' with (rowlock) where tablenick = @tablenick and rowguid = @rowguid
    else'
    else
        set @command4 = ''
    set @command4 = @command4 + '
        delete ' + @quoted_viewname + '  with (rowlock)
        from deleted d, ' + @quoted_viewname + ' cont with (rowlock)
        where cont.tablenick = @tablenick and cont.rowguid = d.rowguidcol
        option (force order, loop join)'
        
    set @command4 = @command4+'

    if @@error <> 0
        GOTO FAILURE'

    -- Do not update the tombstone table if the delete_tracking property is set to false on the article.
    -- This property when set blocks replication of deletes. Note: It causes non-convergence.
    if @delete_tracking = 1
    begin
        set @command4 = @command4 + '

    -- DEBUG    insert into MSmerge_debug (okay,artnick,generation_old,twhen,comment) values
    -- DEBUG        (0, @tablenick, @newgen, getdate(), ''del_trg'')
    '
    end
    
    set @command4 = @command4+'
    return
FAILURE:
    if @@trancount > 0
        rollback tran
    raiserror (20041, 16, -1)
    return '
        insert into #tmptriggercmd (phase, cmdtext) values (20, @command4)
        insert into #tmptriggercmd (phase, cmdtext) values (2, @inscommand)
    end

    select cmdtext from #tmptriggercmd where cmdtext is not null order by phase, step
    drop table #tmptriggercmd
GO
GRANT EXECUTE ON [sys].[sp_MSaddmergetriggers_internal] TO [public] AS [dbo]
GO
