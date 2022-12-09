SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSmakedynsnapshotvws]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSmakedynsnapshotvws] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSmakedynsnapshotvws]
	@publication [sysname],
	@dynamic_filter_login [sysname],
	@dynamic_snapshot_views_table_name [sysname]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    declare @retcode int
    declare @string_literalized_dynamic_filter_login nvarchar(4000)
    declare @articles_cursor_allocated bit, 
            @articles_cursor_opened bit
    declare @pubid uniqueidentifier
    declare @partition_id int
    declare @publication_number int
    declare @dynamic_filter_hostname sysname
    declare @get_dynamic_filter_login_fn nvarchar(350)
    declare @get_dynamic_filter_login_value nvarchar(300)
	declare @stmt nvarchar(4000)

    select @articles_cursor_allocated = 0
    select @articles_cursor_opened = 0
    select @retcode = 0
    -- Security check

    exec @retcode = sys.sp_MSreplcheck_publish
    if @retcode <> 0 or @@error <> 0
        return 1

    if @dynamic_filter_login is null or @dynamic_filter_login = N''
    begin
        select @dynamic_filter_login = suser_sname()
    end
    if @@error<>0
    begin
        return 1
    end
    select @string_literalized_dynamic_filter_login = 
        fn_replmakestringliteral(@dynamic_filter_login) collate database_default

    select @dynamic_filter_hostname = host_name()
    
    -- map the dynamic filter longin to a partition id
    select @partition_id = -1
    exec @retcode = sys.sp_MSget_subscriber_partition_id 
                        @publication,
                        @partition_id output,
                        NULL,
                        @dynamic_filter_hostname,
                        @dynamic_filter_login
    if @@error <> 0 or @retcode <> 0 or @partition_id is NULL or @partition_id = -1
    begin
        raiserror(20629, 16, -1)
        return 1
    end    

    -- Compute the proper view creation order, code is copied from sp_MSpublicationview
    declare @progress int
    declare @article_level int
    select @progress = 1
    select @article_level = 0
    select @pubid = pubid, @publication_number = publication_number
      from dbo.sysmergepublications 
    where upper(publisher) = upper(publishingservername())
      and publisher_db = db_name()
      and name = @publication
    if @pubid is null 
    begin
        raiserror(20026,11,-1,@publication)
    end

    select @get_dynamic_filter_login_value = sys.fn_MSget_dynamic_filter_login(@publication_number,@partition_id)
    select @get_dynamic_filter_login_value = 'N''' + replace(@get_dynamic_filter_login_value, '''', '''''') + ''''    

    create table #creation_order
    (
    creation_order int identity not null,
    art_nick int not null,
    article_level int not null    
    )
    if @@error<>0
    begin
        return 1
    end
    
    while @progress > 0
    begin
        insert into #creation_order(art_nick, article_level)
            select nickname, @article_level 
              from dbo.sysmergearticles
             where pubid=@pubid 
               and nickname not in (select art_nick from #creation_order)
               and nickname not in
                    (select art_nickname from dbo.sysmergesubsetfilters
                      where pubid=@pubid and (filter_type & 1) = 1 and join_nickname not in
                        (select art_nick from #creation_order))
        select @progress = @@rowcount
        select @article_level = @article_level + 1
    end

    -- Create temp table for storing the view definitions and 
    -- also for acting as a symbol table for views
    create table #view_defs_and_syms  
    (
        creation_order int identity,
        original_view_name sysname collate database_default,
        dynamic_snapshot_view_name sysname collate database_default,
        dynamic_snapshot_view_definition nvarchar(max) collate database_default
    )      
    if @@error<>0
    begin
        return 1
    end
    -- By the time this procedure is called by the snapshot agent, a regular
    -- snapshot is assumed to have been generated.
    -- The specified publication is assumed to have dynamic filtering enabled        
    -- Open a transaction to make sure that no stale temporary views
    -- can be lying around for longer than they have to.  
    
    begin transaction
    save transaction sp_MSmakedynsnapshotartvws

    -- Create a global temporary table to track the sync-views
    -- that we are about to create here.
    if @dynamic_snapshot_views_table_name is NULL
    begin
        select @dynamic_snapshot_views_table_name = N'##DYN_VIEWS_' + 
            replace(convert(nvarchar(36), newid()), N'-', N'_')
             
        set @stmt = 'create table ' + quotename(@dynamic_snapshot_views_table_name) + '
              (
              artid           uniqueidentifier primary key,
              dynamic_snapshot_view_name sysname not null unique
              )'
		exec(@stmt)
        if @@error<>0
        begin
            goto Failure
        end
    end

    declare hArticles cursor local fast_forward for
    select artid, sync_objid, co.art_nick 
      from dbo.sysmergearticles sma
    inner join #creation_order co 
        on sma.nickname = co.art_nick
     where sma.pubid = @pubid
    order by co.creation_order asc
    if @@error<>0
    begin
        goto Failure
    end
    select @articles_cursor_allocated = 1
    open hArticles    
    if @@error<>0
    begin
        goto Failure
    end
    select @articles_cursor_opened = 1

    declare @sync_objid int
    declare @artid uniqueidentifier
    declare @dynamic_snapshot_view_name sysname
    declare @original_view_name sysname 
    declare @insert_command nvarchar(4000)
    declare @min_id int
    declare @db_name sysname
    declare @original_view_definition nvarchar(max)
    declare @artnick int

    select @db_name = db_name()

    -- Stage 1: Build up the symbol table with 
    -- regular sync view definitions
    fetch hArticles into @artid, @sync_objid, @artnick
    
    while (@@fetch_status<>-1)
    begin
                declare @row_number int, @max_row_number int
                
                select @max_row_number = 1, @row_number = 1
                
        -- Get name of the original sync view
        select @original_view_name = object_name(@sync_objid)

        -- Construct name for the dynamic snapshot view        
        select @dynamic_snapshot_view_name = N'MSmerge_DYN_VIEW_' + 
            replace(convert(nvarchar(20), @artnick), N'-', N'_') + '_' +
            replace(convert(nvarchar(36), newid()), N'-', N'_')
        
                select @max_row_number = max(colid) 
                from dbo.syscomments
        where id = @sync_objid
                
                select @row_number = 1, @original_view_definition = N''
                while @row_number <= @max_row_number
                begin
                        select @original_view_definition = @original_view_definition + text 
                        from dbo.syscomments
                        where id = @sync_objid
                        and colid = @row_number
                        
                        select @row_number = @row_number + 1
                end

                -- Insert a row into the symbol and view def table 
                -- for further processing 
        
		-- Neither original_view_name nor dynamic_snapshot_view_name should be quoted here as both columns
		--  are sysnames and could potentially be truncated				
        insert #view_defs_and_syms 
        values (@original_view_name, 
                @dynamic_snapshot_view_name, 
                @original_view_definition) 
        if @@error<>0
        begin
            goto Failure
        end
    
        select @insert_command = N'insert ' + quotename(@dynamic_snapshot_views_table_name) + ' values (@artid, @dynamic_snapshot_view_name)'
        -- Insert the mapping into the global temp table
        exec @retcode = sys.sp_executesql
            @insert_command,
            N'@artid uniqueidentifier, @dynamic_snapshot_view_name sysname',
            @artid = @artid,
            @dynamic_snapshot_view_name = @dynamic_snapshot_view_name

        if @@error<>0 or @retcode<>0
        begin
            goto Failure
        end

        -- Insert the view name into the global tracking table so it is 
        -- guaranteed to be cleaned up properly 
        insert MSdynamicsnapshotviews values (@dynamic_snapshot_view_name)
        if @@error<>0
        begin
            goto Failure
        end

        fetch hArticles into @artid, @sync_objid, @artnick
    end
    close hArticles
    select @articles_cursor_opened = 0
    deallocate hArticles
    select @articles_cursor_allocated = 0
    -- Stage 2: Fix-up all the internal references to non-dynamic snapshot
    --          views inside the dynamic snapshot view definitions and
    --          create the views along the way.

    -- Cursor state variables for ensuring proper cursor cleanup
    declare @viewdefs_cursor_allocated bit,
            @viewdefs_cursor_opened bit,
            @symbols_cursor_allocated bit,
            @symbols_cursor_opened bit
 
    declare @dynamic_snapshot_view_definition nvarchar(max)
    declare @dynamic_filter_login_fn_definition nvarchar(max)
    declare @dynamic_snapshot_view_name_symbol sysname
    declare @qualified_dynamic_snapshot_view_name nvarchar(4000)

    select @viewdefs_cursor_allocated = 0,
           @viewdefs_cursor_opened = 0,
           @symbols_cursor_allocated = 0,
           @symbols_cursor_opened = 0

    -- Declare a cursor for each dynamic snapshot view definition
    declare hViewDefs cursor local fast_forward for
    select dynamic_snapshot_view_name,
           dynamic_snapshot_view_definition 
      from #view_defs_and_syms
    order by creation_order asc

    if @@error<>0
    begin
        goto Failure
    end
    select @viewdefs_cursor_allocated = 1
    
    -- Declare a static cursor for symbol lookup so we can go back to the 
    -- first row without tearing down the cursor   
    declare hSymbols cursor local static for
    select original_view_name,
           dynamic_snapshot_view_name
      from #view_defs_and_syms
    if @@error<>0
    begin
        goto Failure
    end
    select @symbols_cursor_allocated = 1
    
    open hViewDefs
    if @@error<>0
    begin
        goto Failure
    end
    select @viewdefs_cursor_opened = 1
    open hSymbols
    if @@error<>0
    begin
        goto Failure
    end
    select @symbols_cursor_opened = 1
     
    -- For each view definition...
    fetch hViewDefs into @dynamic_snapshot_view_name, 
                         @dynamic_snapshot_view_definition
    while (@@fetch_status<>-1)
    begin

        select @get_dynamic_filter_login_fn = N'dbo.' + quotename(@dynamic_snapshot_view_name + N'_FN')

        -- For each dynamic snapshot view name to original view name mapping...
        fetch first from hSymbols into @original_view_name,
                                       @dynamic_snapshot_view_name_symbol 
        while (@@fetch_status<>-1)
        begin
            -- Do view name replacement
            select @qualified_dynamic_snapshot_view_name = quotename(@dynamic_snapshot_view_name_symbol)

            select @dynamic_snapshot_view_definition =
                replace(@dynamic_snapshot_view_definition,
                        quotename(@original_view_name),
                        @qualified_dynamic_snapshot_view_name)
            fetch hSymbols into @original_view_name,
                                @dynamic_snapshot_view_name_symbol 
        end
        -- Replace suser_sname() with string literalized version of the given
        -- dynamic filter login 
        select @dynamic_snapshot_view_definition =
            replace(@dynamic_snapshot_view_definition collate SQL_Latin1_General_CP1_CI_AS,
                    N'suser_sname()' collate SQL_Latin1_General_CP1_CI_AS,
                    @get_dynamic_filter_login_fn + N'()' collate SQL_Latin1_General_CP1_CI_AS)

        -- Replace system_user with string literalized version of the given
        -- dynamic filter login 
        select @dynamic_snapshot_view_definition =
            replace(@dynamic_snapshot_view_definition collate SQL_Latin1_General_CP1_CI_AS,
                    N'system_user' collate SQL_Latin1_General_CP1_CI_AS,
                    @get_dynamic_filter_login_fn + N'()' collate SQL_Latin1_General_CP1_CI_AS)
        if datalength(@dynamic_snapshot_view_definition) = 7000
        begin
            raiserror(21387,16,-1)
            goto Failure
        end


        -- Create the function with schema binding and mark it as a system object.
		-- @get_dynamic_filter_login_fn is already quoted, so there is no need to quote it here
        select @dynamic_filter_login_fn_definition = N'
            create function ' + @get_dynamic_filter_login_fn + N'()
            returns sysname
            WITH SCHEMABINDING
            as
            begin
            	return ' + @get_dynamic_filter_login_value + N'
            end'

        exec (@dynamic_filter_login_fn_definition)
        if @@error<>0
        begin
            goto Failure
        end
        exec @retcode = sys.sp_MS_marksystemobject @get_dynamic_filter_login_fn
        if @@error<>0 or @retcode<>0
        begin
            goto Failure
        end
       
        -- Create the view and mark it as a system object
        exec (@dynamic_snapshot_view_definition)
        if @@error<>0
        begin
            goto Failure
        end
        exec @retcode = sys.sp_MS_marksystemobject @dynamic_snapshot_view_name
        if @@error<>0 or @retcode<>0
        begin
            goto Failure
        end
        fetch hViewDefs into @dynamic_snapshot_view_name,
                             @dynamic_snapshot_view_definition
    end

    close hViewDefs
    deallocate hViewDefs
    close hSymbols
    deallocate hSymbols
    drop table #view_defs_and_syms
    drop table #creation_order
    commit transaction     

    -- Construct the result set 
    declare @dynamic_snapshot_view_owner sysname

    -- Since all views will have the same owner, we may as well just 
    -- find it once and then return it in the second row of the result set
    -- (see header)    

    -- Note: Even the cursors are closed, the @dynamic_snapshot_view_name
    -- variable should still contain a valid value

    select @dynamic_snapshot_view_owner = SCHEMA_NAME(schema_id) 
      from sys.objects 
     where name = @dynamic_snapshot_view_name
    declare @result_command nvarchar(4000) 
    select @result_command = '    
    select ''article_name'' = null, 
           ''dynamic_snapshot_view_name'' = ' + 
           fn_replmakestringliteral(@dynamic_snapshot_views_table_name) collate database_default + N'
    union all
    select null, ' +
           coalesce(fn_replmakestringliteral(@dynamic_snapshot_view_owner) collate database_default, N'null') collate database_default + N' 
    union all 
    select sma.name, dsvt.dynamic_snapshot_view_name
      from dbo.sysmergearticles sma
    inner join ' + quotename(@dynamic_snapshot_views_table_name) + N' dsvt
      on sma.artid = dsvt.artid
    where sma.pubid = ''' + convert(nvarchar(128), @pubid) + ''''

    exec (@result_command)
    if @@error<>0 
        return 1

    return 0     
Failure:
    if @articles_cursor_opened = 1
    begin
        close hArticles
    end
    if @articles_cursor_allocated = 1
    begin
        deallocate hArticles
    end
    if @viewdefs_cursor_opened = 1
    begin
        close hViewDefs
    end
    if @viewdefs_cursor_allocated = 1
    begin
        deallocate hViewDefs
    end
    if @symbols_cursor_opened = 1
    begin
        close hSymbols
    end
    if @symbols_cursor_allocated = 1
    begin
        deallocate hSymbols
    end     
    drop table #view_defs_and_syms    
    drop table #creation_order
    rollback transaction sp_MSmakedynsnapshotartvws
    commit transaction    
    return 1
end
GO
GRANT EXECUTE ON [sys].[sp_MSmakedynsnapshotvws] TO [public] AS [dbo]
GO
