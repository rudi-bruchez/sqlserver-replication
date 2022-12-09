SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSscript_article_view]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSscript_article_view] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSscript_article_view]
	@artid [int],
	@view_name [sysname],
	@include_timestamps [bit]
WITH EXECUTE AS CALLER
AS
begin
    declare @base_objid int
                ,@user_name sysname
                ,@table_name sysname
                ,@qualified_table_name nvarchar(520)
                ,@filter_clause nvarchar(4000)
                ,@cmdfrag nvarchar(4000)
                ,@separator nvarchar(1)
                ,@colname sysname
                ,@colid int
                ,@fallowupdatingsubscriber bit
                ,@retcode int
                ,@schema_option bigint
                ,@rowguid_column_id int
                ,@has_filestream_column bit
                ,@is_filestream bit
                ,@is_rowguidcol bit
    declare @tempcmd table( c1 int identity NOT NULL, cmdfrag nvarchar(4000) collate database_default )

    --
    -- security check
    --
    exec @retcode = sys.sp_MSreplcheck_publish
    if @@error <> 0 or @retcode <> 0
        return(1)

    --
    -- initialize the metadata
    --
    select @table_name = so.name
           ,@base_objid = art.objid
           ,@user_name = schema_name(so.schema_id)
           ,@table_name = so.name
           ,@qualified_table_name = QUOTENAME(schema_name(so.schema_id)) + N'.' + QUOTENAME(so.name)
           ,@filter_clause = art.filter_clause
           ,@fallowupdatingsubscriber = case when (pub.allow_sync_tran = 0 and pub.allow_queued_tran = 0) then 0 else 1 end
           ,@schema_option = convert(bigint, art.schema_option)
       from sysarticles art, sys.objects so, syspublications pub
       where art.artid = @artid
           and art.objid = so.object_id
           and art.pubid = pub.pubid


    select @rowguid_column_id = null
           ,@has_filestream_column = 0

    --
    -- sp_articleview will strip out owner qualifications on @view_name so we will
    -- just prepend dbo.
    --
    insert into @tempcmd (cmdfrag) values ( N'create view [dbo].' + QUOTENAME(@view_name) + N'as select ' )
    --
    -- script the column list in the select statement
    --
    declare #hc  CURSOR LOCAL FAST_FORWARD FOR 
        select distinct sc.name, sc.column_id, sc.is_filestream, sc.is_rowguidcol
          from sys.columns sc
         where sc.object_id = @base_objid 
           and (exists (select * from dbo.sysarticlecolumns sac
                         where sac.artid = @artid
                           and sac.colid = sc.column_id)
                or 
                (@include_timestamps = 1 and sc.system_type_id = 189))
        order by sc.column_id ASC
    select @cmdfrag = N''
            ,@separator = N''
    open #hc
    fetch #hc into @colname, @colid, @is_filestream, @is_rowguidcol
    while (@@fetch_status <> -1)
    begin
        if datalength( @cmdfrag ) > 3500 
        begin
            insert into @tempcmd(cmdfrag) values (@cmdfrag)
            select @cmdfrag = N''
        end
        select @cmdfrag = @cmdfrag + @separator + quotename(@colname)
        select @separator = N','
        if @is_filestream = 1
        begin
            set @has_filestream_column = 1
        end
        if @is_rowguidcol = 1
        begin   
            set @rowguid_column_id = @colid
        end
        fetch #hc into @colname, @colid, @is_filestream, @is_rowguidcol
    end            
    close #hc
    deallocate #hc
    insert into @tempcmd( cmdfrag ) values (@cmdfrag) 
    --
    -- continue scripting
    --
    insert into @tempcmd( cmdfrag ) values (N' from ')
    insert into @tempcmd( cmdfrag ) values (@qualified_table_name)

    --
    -- Script index hint to use rowguid index for un-filtered articles
    -- containing filestream and rowguid columns. The QO can guarantee that 
    -- rowguid column values are unique during a simple select * scan (BCP out
    -- especially) through the rowguid index without having to take out a 
    -- shared table lock under the default read-committed isolation level.
    -- 
    if ((@filter_clause is null or datalength(@filter_clause) = 0) 
        and @has_filestream_column = 1
        and @rowguid_column_id is not null)
    begin
        declare @rowguid_index_name sysname
        set @rowguid_index_name = null

        select @rowguid_index_name = si.name
          from sys.indexes si
    inner join sys.index_columns sic
            on si.index_id = sic.index_id
           and si.object_id = sic.object_id
         where si.object_id = object_id(@qualified_table_name)
           and sic.column_id = @rowguid_column_id
           and si.is_unique = 1
           and (si.is_unique_constraint = 1 or si.is_primary_key = 1)
           and si.index_id in
            (select sic2.index_id
               from sys.index_columns sic2
              where object_id = object_id(@qualified_table_name)
           group by index_id, object_id
             having count(index_id) = 1)
    
        if (@rowguid_index_name is not null)
        begin
            insert into @tempcmd( cmdfrag ) values (N' with (index(' + quotename(@rowguid_index_name) + N'))') 
        end        
    end

    insert into @tempcmd( cmdfrag ) values (N' where HAS_PERMS_BY_NAME(''' + 
        sys.fn_replreplacesinglequote(@qualified_table_name)  + N''', ''OBJECT'', ''SELECT'')= 1 ')
        
    --
    --add filter clause
    --
    if( @filter_clause is not null and datalength( @filter_clause ) > 0 )
    begin
        --
        -- we have a horizontal filter - apply it to the view
        --
        exec @retcode = sys.sp_MSsubst_filter_names @user_name, @table_name, @filter_clause output
        if @retcode <> 0 or @@error <> 0
            return 1        
        insert into @tempcmd( cmdfrag ) values (N'and (' + @filter_clause + N')')
        --
        -- Add check option for updating subscriber publications
        --
        if (@fallowupdatingsubscriber = 1)
        begin
            insert into @tempcmd( cmdfrag ) values (N' with check option ')
        end
    end
    --
    -- prepare the resultset for creating the view
    --
    select cmdfrag from @tempcmd order by c1 asc
    --
    -- all done
    --
    return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSscript_article_view] TO [public] AS [dbo]
GO
