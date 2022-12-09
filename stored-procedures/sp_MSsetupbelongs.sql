SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSsetupbelongs]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSsetupbelongs] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSsetupbelongs]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@genlist [varchar](8000),
	@commongen [bigint],
	@subissql [int],
	@articlesoption [int],
	@tablenickname [int],
	@handle_null_tables [bit],
	@nicknamelist [varchar](8000),
	@mingen [bigint],
	@maxgen [bigint],
	@skipgenlist [varchar](8000),
	@belongsname [sysname],
	@notbelongsname [sysname],
	@compatlevel [int],
	@enumentirerowmetadata [bit]
WITH EXECUTE AS CALLER
AS
declare @pubid uniqueidentifier
        declare @start_processing_time datetime
        declare @complete_processing_time datetime
    declare @pubidstr nvarchar(40)
    declare @article_statistics_table nvarchar(400)
    declare @quoted_article_statistics_table nvarchar(400)
    declare @retval int
    declare @rowguid uniqueidentifier
    declare @cmd nvarchar(4000)
    declare @rowguidstr nvarchar(40)
    declare @artnick_to_process int
    declare @before_view_objid int
    declare @before_table_objid int
    declare @procname nvarchar(270)
    declare @artbaseobjid int
    declare @art_name sysname
    declare @rgcol nvarchar(270)
    declare @maxfilterid int
    declare @retcode smallint
    declare @setupbelong_time int
    declare @dynamic_join_cnt int
    declare @contents_subset_rowcount int
    declare @tombstone_subset_rowcount int
    declare @belongsempty bit
    declare @notbelongsempty bit
    declare @allow_partition_realignment bit
    --declare @belongsname sysname
    --declare @notbelongsname sysname
    
    -- trim spaces from the generation lists so that we don't have to use functions ltrim 
    -- and rtrim again and again later on.
    select @genlist = ltrim(rtrim(@genlist))
    select @skipgenlist = ltrim(rtrim(@skipgenlist))
    
    exec sys.sp_MSget_server_portinfo 
        @name = @publisher, 
        @srvname = @publisher OUTPUT

    select @pubid = pubid, @allow_partition_realignment = allow_partition_realignment  from dbo.sysmergepublications where name = @publication and UPPER(publisher)=UPPER(@publisher) and publisher_db=@publisher_db 
    
    -- check permissions
    if ({ fn ISPALUSER(@pubid) } <> 1)
    begin   
            RAISERROR (14126, 11, -1)
            return (1)
    end
    
    select @pubidstr = replace( convert( nvarchar(36), @pubid ), '-', '' )
    
    set @rowguid = newid()
    select @rowguidstr = replace( convert( nvarchar(36), @rowguid ), '-', '' )

    -- since the belongsname and notbelongsname names have guids appended to them generated using newid(), we can safely assume
    -- that the names are unique.
    set @article_statistics_table = NULL
    create table #genlist (generation bigint)

    create table #temp_cont (temp_id int identity NOT NULL, tablenick int NOT NULL, rowguid uniqueidentifier NOT NULL,
            partchangegen bigint)

    create table #contents_subset(tablenick int NOT NULL, rowguid uniqueidentifier NOT NULL, generation bigint NOT NULL,
            partchangegen bigint NULL)

    create table #tombstone_subset(tablenick int NOT NULL, rowguid uniqueidentifier NOT NULL, type tinyint NOT NULL, 
            generation bigint NOT NULL)

    create table #belong (tablenick int NOT NULL, rowguid uniqueidentifier NOT NULL, flag int NOT NULL,
        partchangegen bigint null, skipexpand bit NOT NULL)

    create table #notbelong (tablenick int NOT NULL, rowguid uniqueidentifier NOT NULL,
        flag int NOT NULL, partchangegen bigint null, type tinyint default 5)
    create table #nicknames_to_process (nickname int)
    create index #indbelong on #belong (rowguid, tablenick)
    create index #indnbelong on #notbelong (tablenick, rowguid)

    if (@belongsname is NULL)
        begin
        set @belongsname = '##belong' + @rowguidstr
        set @cmd = 'create table ' + quotename(@belongsname) + ' (tablenick int NOT NULL, rowguid uniqueidentifier NOT NULL,
            generation bigint NULL, lineage varbinary(311) NULL, colv varbinary(2953) NULL)'
		exec( @cmd )
        if @@ERROR <>0 return (1)
    end

    if (@notbelongsname is NULL)
    begin
        set @notbelongsname = '##notbelong' + @rowguidstr
		set @cmd = 'create table ' + quotename(@notbelongsname) + ' (bookmark int identity unique NOT NULL, tablenick int NOT NULL, rowguid uniqueidentifier NOT NULL,
            generation bigint NULL, lineage varbinary(311) NULL, type tinyint NOT NULL)'
		exec( @cmd )
        if @@ERROR <>0 return (1)
    end
    
    exec @retcode = sys.sp_MSsetupworktables @pubid, @genlist, @articlesoption, @tablenickname, @nicknamelist,
                                        @mingen, @maxgen, @skipgenlist,
                                        @contents_subset_rowcount OUTPUT, @tombstone_subset_rowcount OUTPUT

    IF @@ERROR<>0 OR @retcode<>0 return (1) 

    if (@contents_subset_rowcount = 0 and @tombstone_subset_rowcount = 0)
        goto EXITPROC

    if (@articlesoption <> 1 and @articlesoption <> 3 and @articlesoption <> 4)
    begin
        select @dynamic_join_cnt = count(*) from 
            (select join_filterclause_spaces_stripped = 
            REPLACE(REPLACE(REPLACE(REPLACE(UPPER(join_filterclause collate SQL_Latin1_General_CP1_CS_AS), char(0x20),''), char(0x09),''), char(0x0D),''), char(0x0A),'')
            from dbo.sysmergesubsetfilters 
            where pubid = @pubid and (filter_type & 1) = 1) 
            as sysmergesubsetfilters_temp
        where 
        sysmergesubsetfilters_temp.join_filterclause_spaces_stripped like '%USER[_]%NAME()%' or
        sysmergesubsetfilters_temp.join_filterclause_spaces_stripped like '%USER[_]%ID()%' or
        sysmergesubsetfilters_temp.join_filterclause_spaces_stripped like '%SESSION[_]USER%' or
        sysmergesubsetfilters_temp.join_filterclause_spaces_stripped like '%SYSTEM[_]USER%'
    end
    
    /* step 2 setup pass through dbo.MSmerge_contents */
    /* article with permanent views can be handled with bulk inserts */
    set @artnick_to_process = NULL
    set rowcount 0
    
    /* Get first article, go into loop */
    select @artnick_to_process = min(nickname) from #nicknames_to_process 
    
    -- if the article statistics table does not exist do not update article 
    -- statistics. For article statistics to work the AGENT MUST create this temp table.
    -- also with the security fixes for global temp table, setupbelongs is going to
    -- be run only on one connection. Hence if the table is not already there it
    -- would be OK to not report article statistics.
        select @article_statistics_table = '#setupbelongs_article_statistics_table'
        if OBJECT_ID('tempdb..' + @article_statistics_table) is NULL
        begin
            select @article_statistics_table = NULL
                select @quoted_article_statistics_table = NULL
    end
        else
        begin
                select @quoted_article_statistics_table = QUOTENAME(@article_statistics_table)
        end

    while (@artnick_to_process is not null)
    begin
        select @start_processing_time = getdate()

        select  @artbaseobjid = objid, @procname = view_sel_proc, @before_view_objid = before_view_objid,
                @before_table_objid = before_image_objid, @art_name=sys.fn_getvalidname(name)
                from dbo.sysmergearticles 
                where pubid = @pubid 
                and nickname = @artnick_to_process
                if @article_statistics_table is not NULL
                begin
                -- @art_name has all ' and " removed by fn_getvalidname
				select @cmd = 'insert ' + @quoted_article_statistics_table + ' (article_name) values (''' + @art_name + ''')'
                exec(@cmd)
                if @@ERROR<>0
                        return (1)
        end
        /* Get name of rowguidcol. Aliasing doesn't work through a view. */
        select @rgcol = name from sys.columns where object_id = @artbaseobjid and is_rowguidcol = 1

        if (@procname is not null)
        begin
            -- Fully qualifying the proc avoids recompiles
            select @procname = 'dbo.' + quotename(@procname)
            exec @retcode = @procname @tablenick=@artnick_to_process, @compatlevel=@compatlevel, @pubid=@pubid
            if @@ERROR <>0 or @retcode <> 0
                begin
-- DEBUG        insert into MSmerge_debug 
-- DEBUG            (okay, artnick, successcode, twhen, comment)
-- DEBUG            values (1, @artnick_to_process, @retcode, getdate(), 'sp_MSsetupbelongs: could not exec sel_GUID')
                return (1)
                end
        end
        else
        begin
            exec @retcode = sys.sp_MSsetupbelongs_withoutviewproc @publisher, @publisher_db, @publication, @artnick_to_process      
            if @@ERROR <>0 or @retcode <> 0
                return (1)
        end

        exec @retcode = sys.sp_MSsetupnotbelongs @artnick_to_process, @before_view_objid, @before_table_objid, @rgcol, @commongen, @allow_partition_realignment
        if @@ERROR <>0 or @retcode <> 0
                return (1)

        /* Move on to next article, repeat while loop */
        select @complete_processing_time = getdate()
        if @article_statistics_table is not NULL
        begin
                        select @setupbelong_time=datediff(millisecond, @start_processing_time, @complete_processing_time)               
                select @cmd = 'update ' + @quoted_article_statistics_table + ' set setupbelong_time = setupbelong_time + ' + convert(nvarchar, @setupbelong_time)
                                + ' where article_name = ''' + @art_name + ''''
                exec(@cmd)
                if @@ERROR<>0
                        return (1)
        end
        select @artnick_to_process = min(nickname) from #nicknames_to_process where nickname > @artnick_to_process 
    end

    if (@articlesoption <> 1 and @articlesoption <> 3 and @articlesoption <> 4)
    begin
        /* Optimization: If partchange is null or < common gen BUT NOT =1,
        ** it is not necessary to expand #belong for that particular row.
        */
        
        select @maxfilterid = max(join_filterid) from dbo.sysmergesubsetfilters where (filter_type & 1) = 1

        if @maxfilterid is not null
        begin
            update #belong set flag = @maxfilterid, skipexpand = 1 
            where isnull(partchangegen,0) <= @commongen and isnull((-partchangegen),0) <= @commongen

            /* Expand the #belong temptable */
            exec @retcode = sys.sp_MSexpandbelongs @pubid

            if @@ERROR<>0 OR @retcode<>0
                begin
-- DEBUG        insert into MSmerge_debug 
-- DEBUG            (okay, twhen, comment)
-- DEBUG            values (9, getdate(), 'sp_MSsetupbelongs: could not exec sp_MSexpandbelongs')
                return (1)
                end
        end
    end

    -- If subscriber is not sql server, we have to expand notbelongs
    if (@articlesoption <> 1 and @articlesoption <> 3 and @articlesoption <> 4) and (@subissql = 0 or @dynamic_join_cnt > 0)
    begin
        /* Expand the #notbelong temptable */
        exec sys.sp_MSexpandnotbelongs @pubid
        if @@error<>0 return(1)
    end

EXITPROC:
        
    /* transfer rows from local temp to global temp */

    -- Could have used if not exists instead of the following but want to use the KEEP PLAN option which is not supported in the IF EXISTS 
    select @belongsempty = 0
    select @belongsempty = 1 where not exists (select * from #belong) OPTION(KEEP PLAN)
    
    select @notbelongsempty = 0
    select @notbelongsempty = 1 where not exists (select * from #notbelong) OPTION(KEEP PLAN)

        declare @belongmetadatacols nvarchar(200)
        declare @notbelongmetadatacols nvarchar(200)

        if 1 = @enumentirerowmetadata
        begin
                set @belongmetadatacols= 'c.generation, c.lineage, c.colv1'
                set @notbelongmetadatacols= 'coalesce (c.generation, t.generation), coalesce(c.lineage, t.lineage)'
        end
        else
        begin
                set @belongmetadatacols= 'sys.fn_MSgeneration_downloadonly(c.generation, c.tablenick), sys.fn_MSvector_downloadonly(c.lineage, c.tablenick), sys.fn_MSvector_downloadonly(c.colv1, c.tablenick)'
                set @notbelongmetadatacols= 'sys.fn_MSgeneration_downloadonly(coalesce (c.generation, t.generation), c.tablenick), sys.fn_MSvector_downloadonly(coalesce(c.lineage, t.lineage), c.tablenick)'
        end

    /* If there are no rows in #belong, then drop the global ##belongs so that we do not call sp_MSenumpartialchanges */
    if (@belongsempty = 1)
    begin
        /* Post SQL 8.0 Beta 2 agents pass this flag with value 1 since they can handle NULL belongs table name */
        if @handle_null_tables = 1
            begin
				set @cmd = 'drop table ' + quotename(@belongsname)
				exec(@cmd)
                select @belongsname = NULL
            end
    end
    else
    begin
        set @cmd = 'insert into ' + quotename(@belongsname) + ' (tablenick, rowguid, generation, lineage, colv) 
                select distinct b.tablenick, b.rowguid, ' + @belongmetadatacols + ' from
                #belong b left outer join dbo.MSmerge_contents c  
                on  c.tablenick = b.tablenick and c.rowguid = b.rowguid '
		exec(@cmd)
                
        if @@ERROR <>0  
        begin
        -- DEBUG    insert into MSmerge_debug 
        -- DEBUG        (okay, twhen, comment)
        -- DEBUG        values (10, getdate(), 'sp_MSsetupbelongs: could not transfer from #belong to global belong')
                    return (1)
        end

        -- DEBUG    exec ('insert into MSmerge_debug (okay, artnick, rowguid, generation_new, lineage_new, twhen, comment)
        -- DEBUG        select 0, tablenick, rowguid, generation, lineage, getdate(), ''sp_MSsetupbelongs: belong-content'' from ' + @belongsname)
        -- this index will be useful in sp_MSenumpartialchanges
        set @cmd = 'create index nc1belongstable on ' + quotename(@belongsname) + ' (tablenick, rowguid) with FILLFACTOR = 100'
		exec(@cmd)
        if @@ERROR <>0  
            return (1)
    end
            
    /* If there are no rows in #notbelong, then drop the global ##notbelongs so that we do not call sp_MSenumpartialchanges */
    if (@notbelongsempty = 1)
    begin
        /* Post SQL 8.0 Beta 2 agents pass this flag with value 1 since they can handle NULL notbelongs table name */
        if @handle_null_tables = 1
            begin
                set @cmd = 'drop table ' + quotename(@notbelongsname)
				exec(@cmd)
                select @notbelongsname = NULL
            end
    end
    else
    begin
        /* transfer rows from local temp to global temp */
        set @cmd = 'insert into ' + quotename(@notbelongsname) + ' (tablenick, rowguid, generation, lineage, type) 
               select distinct b.tablenick, b.rowguid, ' + @notbelongmetadatacols + ', b.type from
               #notbelong b left outer join dbo.MSmerge_contents c  
               on  c.tablenick = b.tablenick 
                           and c.rowguid = b.rowguid
               left outer join dbo.MSmerge_tombstone t 
                           on t.tablenick = b.tablenick 
                           and t.rowguid = b.rowguid 
                           order by b.tablenick DESC, b.rowguid ASC '
		exec(@cmd)
        if @@ERROR <>0  
        begin
-- DEBUG            insert into MSmerge_debug (okay, twhen, comment)
-- DEBUG            values (11, getdate(), 'sp_MSsetupbelongs: could not transfer from #notbelong to global notbelong')
            return (1)
        end

        -- this index will be useful in sp_MSenumpartialdeletes
        set @cmd = 'create index nc1notbelongstable on ' + quotename(@notbelongsname) + ' (tablenick DESC, rowguid) with FILLFACTOR = 100'
		exec(@cmd)
        if @@ERROR <>0  
            return (1)
        
-- DEBUG        exec ('insert into MSmerge_debug (okay, artnick, rowguid, generation_new, lineage_new, twhen, comment)
-- DEBUG            select 0, tablenick, rowguid, generation, lineage, getdate(), ''sp_MSsetupbelongs: notbelong-content'' from ' + @notbelongsname)

    end

    if (@belongsempty = 1)
        select @belongsname, @notbelongsname, -1
    else
    begin
        if (@articlesoption = 1)
        begin
            select @belongsname, @notbelongsname, @tablenickname
        end
        else
        begin
            select distinct @belongsname, @notbelongsname, tablenick from #belong 
        end
    end

    drop table #notbelong
    drop table #belong
    drop table #contents_subset
    drop table #tombstone_subset
    drop table #temp_cont 
    drop table #nicknames_to_process
    
    return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSsetupbelongs] TO [public] AS [dbo]
GO
