SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSmakeupdateproc]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSmakeupdateproc] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSmakeupdateproc]
	@tablename [sysname],
	@ownername [sysname],
	@procname [sysname],
	@pubid [uniqueidentifier],
	@artid [uniqueidentifier],
	@generate_downlevel_procs [bit],
	@generate_subscriber_proc [bit],
	@destination_owner [sysname]
WITH EXECUTE AS CALLER
AS
declare @retcode            int
declare @argname            nvarchar(10)
declare @varname            nvarchar(10)
declare @cmdpiece           nvarchar(4000)
declare @qualified_name     nvarchar(270)
declare @qualified_name2    nvarchar(270)
declare @littlecomp         nvarchar(300)
declare @id                 int
declare @sync_objid         int
declare @idstr              nvarchar(100) 
declare @fast_multicol_updateproc_bit bit
declare @permissions_str    nvarchar(10)
declare @permissions        int
declare @partition_options  tinyint
declare @maintainsmetadata  bit
declare @escaped_qualified_name     nvarchar(270)
declare @rgcol nvarchar(140)
declare @logical_record_parent_nickname int
declare @publication_number smallint
declare @atpublisher            bit
declare @maxschemaguid          uniqueidentifier
declare @max_colv_size_in_bytes int
declare @rgcolname          nvarchar(140)

declare @colname nvarchar(140)
declare @typename nvarchar(258)
declare @base_typename nvarchar(140)
declare @schname nvarchar(140)   --track type owner name when the type is CLR UDT
declare @system_type_id int
declare @colid smallint -- index in sys.columns, used to iterate through sys.columns
declare @colordinal smallint -- index in @setbm, used to interate actual data sent across
declare @colordstr nvarchar(4) -- @colordinal stringification
declare @xtype      int
declare @iscomputed tinyint
declare @isrowguidcol tinyint
declare @separate_update_needed tinyint
declare @update_stmt_started tinyint
declare @isidentitycolumn bit
declare @len smallint
declare @blen smallint
declare @prec int
declare @scale int
declare @tablenick int
declare @tablenickstr nvarchar(12)
declare @bytestr      nvarchar(10)
declare @byteordinal  smallint
declare @numbytes     smallint
declare @bitstr       nvarchar(10)
declare @has_updateable_columns_in_select_list bit
declare @columnsetbitvarname sysname
declare @is_indexing_column bit 
declare @indexing_columns_update_stmt_started bit
declare @schema_option varbinary(8)

set nocount on

/*
** Check for dbo permission
*/
exec @retcode=sys.sp_MSreplcheck_subscribe
if @retcode<>0 or @@ERROR<>0 return (1)

if @ownername is NULL or @ownername=''
    select @qualified_name = QUOTENAME(@tablename)
else    
    select @qualified_name = QUOTENAME(@ownername) + '.' + QUOTENAME(@tablename)

select @escaped_qualified_name = sys.fn_replreplacesinglequote(@qualified_name)


select @id = object_id(@qualified_name)
if @id is NULL return (1)

if exists (select 1 from dbo.sysmergearticles where objid = @id and column_tracking = 1)
begin
    declare @current_col_count int, @missing_col_count int
    select @current_col_count = count(*) 
            from sys.columns where object_id = @id
    select @missing_col_count = coalesce((select max(missing_col_count) 
            from dbo.sysmergearticles where objid = @id), 0)
    -- 12 bytes per column in table + 1 trailing byte for colv.
    select @max_colv_size_in_bytes = 12 * (@current_col_count + @missing_col_count) + 1
    if @max_colv_size_in_bytes > 2953
            select @max_colv_size_in_bytes = 2953
end
else
    select @max_colv_size_in_bytes = 1
        
select @rgcol = QUOTENAME(name) from sys.columns where object_id = @id and is_rowguidcol = 1
if @rgcol is null
    set @rgcol = 'rowguid'


select @sync_objid = sync_objid, @fast_multicol_updateproc_bit = fast_multicol_updateproc, @permissions=check_permissions,
    @permissions_str=convert(nvarchar(10), check_permissions), @schema_option=schema_option,
    @tablenick=nickname
    from dbo.sysmergearticles 
    where artid = @artid and pubid = @pubid
if @tablenick is NULL
    return (1)

set @tablenickstr = rtrim(convert(nchar, @tablenick))

select @partition_options = partition_options, @logical_record_parent_nickname = logical_record_parent_nickname
from dbo.sysmergepartitioninfo
where pubid = @pubid and artid = @artid

select @maxschemaguid = sys.fn_GetArticleSchemaVersionGuid(@artid, @pubid)

if @partition_options = 2
begin
    -- if this is a republisher of this article, and we are currently
    -- downloading from the top-level publisher, then pretend that this is 
    -- not a well-partitioned article. This is done such that the partition evaluation
    -- and setrowmetadata is done appropriately.
    if sys.fn_MSmerge_islocalpubid(@pubid) = 0 
        and exists (select * from dbo.sysmergearticles 
                    where artid = @artid
                    and sys.fn_MSmerge_islocalpubid(pubid) = 1)
        select @partition_options = 0
end

set @idstr = rtrim(convert(nchar, @id)) 

select @is_indexing_column = 0
select @separate_update_needed = 0
select @update_stmt_started = 0
select @has_updateable_columns_in_select_list = 0
select @indexing_columns_update_stmt_started = 0

select @qualified_name2 = @qualified_name

if @generate_subscriber_proc = 1
begin
    select @atpublisher = 0
    select @qualified_name = quotename(@destination_owner) + '.' + quotename(@tablename)
    select @escaped_qualified_name = sys.fn_replreplacesinglequote(@qualified_name)
    if exists (select 1 from dbo.sysmergearticles where artid=@artid and pubid=@pubid and upload_options in (1,2))
        select @maintainsmetadata = 0
    else
        select @maintainsmetadata = 1
end
else
begin
    set @maintainsmetadata= sys.fn_MSarticle_allows_DML_at_this_replica(@artid, default)
    select @atpublisher = sys.fn_MSmerge_islocalpubid(@pubid)
end

select top 1 @publication_number = publication_number 
from dbo.sysmergepublications 
where pubid = @pubid

-- create temp table to select the command text out of
create table #tempcmd (phase int NOT NULL, step int identity NOT NULL, cmdtext nvarchar(4000) collate database_default null)
create table #coltab (colname nvarchar(140), paramname nvarchar(10))

-- insert text pieces that don''t repeat for each column

-- phase 0 : create procedure and fixed part of argument list

/* For Yukon version of this proc, add the @maxschemaguidforarticle as the first parameter */
if 0 = @generate_downlevel_procs AND @atpublisher = 1
begin
    if 1 = @maintainsmetadata
    begin
        set @cmdpiece = 'Create procedure dbo.' + quotename(@procname) + ' (@maxschemaguidforarticle uniqueidentifier, @rowguid uniqueidentifier, @setbm varbinary(125) = NULL,
        @metadata_type tinyint, @lineage_old varbinary(311), @generation bigint,
        @lineage_new varbinary(311), @colv varbinary(' + convert(nvarchar(13), @max_colv_size_in_bytes) + ') '
    end
    else
    begin
        set @cmdpiece = 'Create procedure dbo.' + @procname + ' (@maxschemaguidforarticle uniqueidentifier, @rowguid uniqueidentifier, @setbm varbinary(125) = NULL'
    end
end
else
begin
    if 1 = @maintainsmetadata
    begin
        set @cmdpiece = 'Create procedure dbo.' + quotename(@procname) + ' (@rowguid uniqueidentifier, @setbm varbinary(125) = NULL,
        @metadata_type tinyint, @lineage_old varbinary(311), @generation bigint,
        @lineage_new varbinary(311), @colv varbinary(' + convert(nvarchar(13), @max_colv_size_in_bytes) + ') '
    end
    else
    begin
        set @cmdpiece = 'Create procedure dbo.' + @procname + ' (@rowguid uniqueidentifier, @setbm varbinary(125) = NULL'
    end
end

insert into #tempcmd (phase, cmdtext) values (0, @cmdpiece)

-- phase 1 is rest of argument list; goes in during loop over columns
-- phase 2 paren to close argument list and fixed variable declarations
if 1 = @maintainsmetadata
begin
    set @cmdpiece = ')
as
    declare @match int '
end
else
begin
    set @cmdpiece = ')
as
'
end

insert into #tempcmd (phase, cmdtext) values (2, @cmdpiece)

select @cmdpiece = '
    declare @fset int
    declare @errcode int
    declare @retcode smallint
    declare @rowcount int
    declare @error int
    declare @hasperm bit
    declare @tablenick int
    declare @started_transaction bit
    declare @indexing_column_updated bit
    declare @publication_number smallint

    set nocount on

    if ({ fn ISPALUSER(''' + convert(nvarchar(36),@pubid) + ''') } <> 1)
    begin
        RAISERROR (14126, 11, -1)
        return 4
    end

    select @started_transaction = 0
    select @publication_number = ' + convert(nvarchar(10), @publication_number)+ '
    select @tablenick = ' + @tablenickstr + '

    if is_member(''db_owner'') = 1
        select @hasperm = 1
    else
        select @hasperm = 0

    select @indexing_column_updated = 0'

insert into #tempcmd (phase, cmdtext) values (2, @cmdpiece)

if @permissions>0
begin
    select @cmdpiece = '
    exec @retcode = sys.sp_MSreplcheck_permission @objid = ' + @idstr + ', @type=2, @permissions = ' + @permissions_str + '
    if @retcode<>0 or @@ERROR<>0 return (4)'
    insert into #tempcmd (phase, cmdtext) values (2, @cmdpiece)
end

-- phase 2 - check the max schema guid for article and error out if they do not match
if 0 = @generate_downlevel_procs AND @atpublisher = 1
begin
    set @cmdpiece= '
    declare @maxschemaguid      uniqueidentifier
    select @maxschemaguid = ''' + convert(nvarchar(36),@maxschemaguid) + '''
    if ((@maxschemaguidforarticle IS NOT NULL) and (@maxschemaguid <> @maxschemaguidforarticle))
    begin
        RAISERROR (25007, 11, -1)
        return 5
    end'
    insert into #tempcmd (phase, cmdtext) values (2, @cmdpiece)
end


-- phase 3 is rest of variable declarations; goes in during loop over columns
-- phase 4 begin a transaction, set savepoint in case we roll back, begin select to get current values
set @cmdpiece = '
    if @@trancount = 0
    begin
        begin transaction sub
        select @started_transaction = 1
    end
'
insert into #tempcmd (phase, cmdtext) values (4, @cmdpiece)

/*
** Do not allow out of partition updates at the publisher.
** Check to see if the row being updated is in the partition
** before updating it.
*/
if @atpublisher = 1 AND @partition_options > 0
begin
    -- Get the column name for the rowguid column.
    select @rgcolname = QUOTENAME(name) from sys.columns where object_id = @id and is_rowguidcol = 1
    if @rgcolname is null
        set @rgcolname = 'rowguid'
    -- for > 0 partition_options we will not allow out of partition inserts
    if exists (select * from dbo.sysmergearticles where pubid = @pubid and objid = @id
                                            and len(subset_filterclause) > 0)
                                    or exists (select * from dbo.sysmergesubsetfilters where pubid = @pubid and 
                                                    (art_nickname = @tablenick or join_nickname = @tablenick))
    begin        
        select @cmdpiece = '
    if not exists (select 1 from ' + QUOTENAME(OBJECT_NAME(sync_objid))
            from dbo.sysmergearticles where pubid = @pubid and objid = @id
        set @cmdpiece = @cmdpiece + ' where ' + @rgcolname + ' = @rowguid) 
    begin
        raiserror(20733, 16, -1, ''' + sys.fn_replreplacesinglequote(@tablename) + ''', ' + convert(char(3), @partition_options) + ')
        set @errcode= 3
        goto Failure
    end'
        insert into #tempcmd (phase, cmdtext) values (4, @cmdpiece)
    end
end

set @cmdpiece = '
    select '
insert into #tempcmd (phase, cmdtext) values (4, @cmdpiece)


-- phase 5 is middle part of select assigning column values to local variables -- goes in loop
-- we will only select columns that are part of a clustering/nonclustering index or is a partitioning column
-- phase 10 -- finish the select, check that metadata matches
set @cmdpiece= '        from ' + @qualified_name + ' where rowguidcol = @rowguid'

if 1 = @maintainsmetadata
begin
    set @cmdpiece= @cmdpiece + '
    set @match = NULL
'
end

insert into #tempcmd (phase, cmdtext) values (10, @cmdpiece)

-- If we are generating downlevel procs then convert lineage from 80 to 90 format.
if (1 = @generate_downlevel_procs )
begin
    set @cmdpiece= '
    if @compatlevel < 90 and @lineage_old is not null
        set @lineage_old = {fn LINEAGE_80_TO_90(@lineage_old)}
'
    insert into #tempcmd (phase, cmdtext) values (10, @cmdpiece)
end

-- now do the loop over all columns and insert the missing pieces

-- do not script out computed columns or timestamp columns
-- we will not select the row from the base table if this article is column tracked.
-- we will only rely on the @setbm parameter then. In the case that it is not column tracked
-- we will only select out columns which are part of a clustered or NC index.
-- ignore the computed, timestamp and identity colums since they cannot be updated.

if @sync_objid = @id
    select @colid = min (column_id) from sys.columns where object_id = @id and is_computed=0 and user_type_id<>type_id('timestamp') 
else
    select @colid = min(cs.column_id) 
        from sys.columns cs inner join sys.columns co on co.object_id=@id and co.name = cs.name
    where cs.object_id = @sync_objid and 
          co.is_computed=0 and co.user_type_id<>type_id('timestamp') 

select @colname = NULL
select top 1 @colname = C.name, 
    @typename = type_name(C.user_type_id), 
    @base_typename = type_name(C.system_type_id), 
    @schname=case when S.name<>'sys' and S.name<>'dbo'
                            then QUOTENAME(S.name)+'.' else '' end,     
    @system_type_id = C.system_type_id,
    @blen = C.max_length,
    @prec = C.precision, 
    @scale = C.scale
    from sys.columns C  
            INNER JOIN sys.types T ON C.user_type_id = T.user_type_id
            INNER JOIN sys.schemas S ON T.schema_id = S.schema_id            
    where C.object_id = @sync_objid and C.column_id = @colid
    
select @isidentitycolumn = is_identity, @iscomputed=is_computed, 
    @xtype=user_type_id,
    @isrowguidcol = is_rowguidcol
    from sys.columns 
    where object_id = @id and name = @colname
    
if ((@base_typename='nvarchar' or @base_typename='nchar') and @blen <> -1)  -- a unit of nchar takes 2 bytes
    set @len = @blen/2
else
    set @len = @blen
    
set @colordinal = 1
declare @firstCol tinyint
set @firstCol = 1
declare @firstSelCol tinyint
set @firstSelCol = 1
declare @firstUpdCol tinyint
set @firstUpdCol = 1
declare @maplen smallint

while (@colname is not null)
begin  
    if @isidentitycolumn = 1 OR @iscomputed=1 OR type_name(@xtype)='timestamp'
        goto Next_Column

    set @colordstr = convert(nvarchar(4), @colordinal)

    if @generate_subscriber_proc = 0
        exec @retcode = sys.sp_MSmaptype @typename out, @len, @prec, @scale
    else
    begin
        exec @retcode = sys.sp_MSmap_subscriber_type @xtype, @len, @prec, @scale, @schema_option, @typename out, @schname out, @maplen out
        if (@maplen<>0) select @blen = @maplen
    end
        
    if @@ERROR <>0 OR @retcode <>0 
        return (1)

    -- check if separate update statement is needed only if article supports fast multi-column updates.
    -- reset @separate_update_needed
    set @separate_update_needed = 0

    --check if this column is part of the filter or join filter clause.
    -- if so, use a separater update statement for it rather than setting bitmask for the one cumulative update statement.
    
    -- does updating this column change membership in a partial replica? 
    if exists (select * from dbo.sysmergearticles where objid = @id and sys.fn_MSisfilteredcolumn(subset_filterclause, @colname, @id) = 1)
        set @separate_update_needed = 1
    else if exists (select * from dbo.sysmergesubsetfilters where art_nickname = @tablenick and sys.fn_MSisfilteredcolumn(join_filterclause, @colname, @id) = 1)
        set @separate_update_needed = 1
    else if exists (select * from dbo.sysmergesubsetfilters where join_nickname = @tablenick and sys.fn_MSisfilteredcolumn(join_filterclause, @colname, @id) = 1)
        set @separate_update_needed = 1
    
    set @colname = QUOTENAME(@colname)

    -- put in argument list element (phase 1)
    set @argname = '@p' + rtrim(@colordstr)
    set @cmdpiece = ',
        ' + @argname + ' ' + @schname + @typename + ' = NULL '
    insert into #tempcmd (phase, cmdtext) values (1, @cmdpiece)
    insert into #coltab (colname, paramname) values (@colname, @argname)

    if (@isrowguidcol = 1)
        goto Next_Column

    -- check if the current column is an indexing column
    if exists (select * from sys.index_columns 
                where object_id = @id and 
                      column_id=@colid and 
                      index_id >= 1 and 
                      (partition_ordinal > 0 or key_ordinal > 0))
        select @is_indexing_column = 1
    else
        select @is_indexing_column = 0


    -- since blob columns cannot be used in indexing, it is ok to do just the seperate update statement in case of
    -- blob columns and not worry about anything after that. we will do the blob column updates in phase 12
    -- Filtering columns also need to get their separate updates, otherwise we cause a whole bunch of
    -- false and unnecessary partition movements.
    if (sys.fn_IsTypeBlob(@system_type_id,@len) <> 1) and (@separate_update_needed = 1 or @is_indexing_column = 1)
    begin
        set @varname = '@l' + rtrim(@colordstr)
        if @firstSelCol=1
        begin
            set @firstSelCol= 0
            set @cmdpiece= ''
        end
        else
        begin
            set @cmdpiece= ', '
        end
        set @cmdpiece = @cmdpiece + '
        ' + @varname + ' = ' + @colname
        insert into #tempcmd (phase, cmdtext) values (5, @cmdpiece)
        select @has_updateable_columns_in_select_list = 1
        set @cmdpiece = '
    declare ' + @varname + ' ' + @schname + @typename
        insert into #tempcmd (phase, cmdtext) values (3, @cmdpiece)
    end

    -- in phase 15 we will add comparison of old and new values
    if (@typename like '%char%' or @base_typename like '%char%')
    begin
        -- Compare binaries instead of variables so that case changes are caught as different
        set @littlecomp = 'convert(varbinary(' + rtrim(convert(nchar, @blen)) + '), ' + @argname + ')
            = convert(varbinary(' + rtrim(convert(nchar, @blen)) + '), ' + @varname + ')'
    end
    else
    begin
        set @littlecomp = @argname + ' = ' + @varname
    end
        
    if (sys.fn_IsTypeBlob(@system_type_id,@len) = 1) or @separate_update_needed = 1 
    begin
        if sys.fn_IsTypeBlob(@system_type_id,@len) = 1
        begin
            -- for text and image, we just test if argument is null and whether bit is set
            select @cmdpiece =  '
    if ' + @argname + ' is not null
        set @fset = 1
    else    
        exec @fset = sys.sp_MStestbit @setbm, ' + @colordstr
        end
        else
        begin
            set @cmdpiece = '
    if ' + @littlecomp + '
        set @fset = 0
    else if ( ' + @varname + ' is null and ' + @argname + ' is null) 
        set @fset = 0
    else if ' + @argname + ' is not null
        set @fset = 1
    else if @setbm = 0x0
        set @fset = 0
    else
        exec @fset = sys.sp_MStestbit @setbm, ' + @colordstr        
        end
        
        select @cmdpiece = @cmdpiece + '
    if @fset <> 0
    begin'
        insert into #tempcmd (phase, cmdtext) values (12, @cmdpiece) 
        
        if @maintainsmetadata = 1 and @tablenick != @logical_record_parent_nickname
            select @cmdpiece = '
        if @match is NULL
        begin
            if @metadata_type = 3
            begin
                update ' + @qualified_name + ' set ' + @colname + ' = ' + @argname + ' 
                from ' + @qualified_name + ' t 
                where t.' + @rgcol + ' = @rowguid and
                   not exists (select 1 from dbo.MSmerge_contents c with (rowlock)
                                where c.rowguid = @rowguid and 
                                      c.tablenick = ' + @tablenickstr + ')
            end
            else if @metadata_type = 2
            begin
                update ' + @qualified_name + ' set ' + @colname + ' = ' + @argname + ' 
                from ' + @qualified_name + ' t 
                where t.' + @rgcol + ' = @rowguid and
                      exists (select 1 from dbo.MSmerge_contents c with (rowlock)
                                where c.rowguid = @rowguid and 
                                      c.tablenick = ' + @tablenickstr + ' and
                                      c.lineage = @lineage_old)
            end
            else
            begin
                set @errcode=2
                goto Failure
            end
        end
        else
        begin
            update ' + @qualified_name + ' set ' + @colname + ' = ' + @argname + ' 
                where rowguidcol = @rowguid
        end
        select @rowcount= @@rowcount, @error= @@error
        if (@rowcount <> 1)
        begin
            set @errcode= 3
            goto Failure
        end
        select @match = 1
    end '
        else
            select @cmdpiece = '
        update ' + @qualified_name + ' set ' + @colname + ' = ' + @argname + ' where rowguidcol = @rowguid 
        select @rowcount= @@rowcount, @error= @@error
        if (@rowcount <> 1)
        begin
            set @errcode= 3
            goto Failure
        end
    end'
        -- Now insert the command to temp table
        insert into #tempcmd (phase, cmdtext) values (12, @cmdpiece) 
        goto Next_Column
    end

    if @is_indexing_column = 1
    begin
        -- we will add this column to the select statement.
        -- we will also add the variable declaration for this
        if @is_indexing_column = 1
        begin    
            select @columnsetbitvarname = '@iscol' + rtrim(@colordstr) + 'set'
            set @cmdpiece = '
    declare ' + @columnsetbitvarname + ' bit'
            insert into #tempcmd (phase, cmdtext) values (3, @cmdpiece)
        
            if @firstCol=1
            begin
                set @firstCol= 0
                -- the following is added when we see the first indexing column. This is needed to build the 
                -- dynamic sql statement
                select @cmdpiece = '       
    declare @firstUpdStmtCol bit
    declare @nUpdateCols int
    declare @updatestmt nvarchar(4000) 
    
    select @firstUpdStmtCol = 1
    select @nUpdateCols = 0
    select @updatestmt = ''update '' + ''' +  @escaped_qualified_name + ''' + '' set ''
            '
                insert into #tempcmd (phase, cmdtext) values (10, @cmdpiece)
            end
        end
        
        set @cmdpiece = '
    if ' + @littlecomp + '
        set @fset = 0
    else if ( ' + @varname + ' is null and ' + @argname + ' is null) 
        set @fset = 0
    else if ' + @argname + ' is not null
        set @fset = 1
    else if @setbm = 0x0
        set @fset = 0
    else
        exec @fset = sys.sp_MStestbit @setbm, ' + @colordstr + '
    if @fset <> 0
    begin'
        insert into #tempcmd (phase, cmdtext) values (15, @cmdpiece)
        
        declare @escaped_colname nvarchar(256)
        select @escaped_colname = sys.fn_replreplacesinglequote(@colname)
        set @cmdpiece = '
        select @indexing_column_updated = 1
        select ' + @columnsetbitvarname + ' = 1'
        select @cmdpiece = @cmdpiece + '
        if @firstUpdStmtCol = 1
            select @firstUpdStmtCol = 0
        else
            select @updatestmt = @updatestmt + '','''
        select @cmdpiece = @cmdpiece + '
        select @updatestmt = @updatestmt + '''
                + @escaped_colname + ' = ' + @argname + '''
        select @nUpdateCols = @nUpdateCols + 1'
        select @cmdpiece = @cmdpiece + '
    end
    else
    begin
        select ' + @columnsetbitvarname + ' = 0
    end'
        insert into #tempcmd (phase, cmdtext) values (15, @cmdpiece)

        -- we need to construct the dynamic sql statement that we will be using incase the user has
        -- permissions and we have to update an indexing column
        if @indexing_columns_update_stmt_started = 0
        begin
            select @cmdpiece = '
    if @indexing_column_updated = 1
    begin
        if @hasperm = 0
        begin
            update ' + @qualified_name + ' set '
            insert into #tempcmd (phase, cmdtext) values (20, @cmdpiece) 

            -- phase 25 is all individual column updates

            -- phase 30 below is end of non-dynamic sql update for non-indexing columns
            if @maintainsmetadata = 1 and @tablenick != @logical_record_parent_nickname
            begin
                select @cmdpiece = ' 
             from ' + @qualified_name + ' t 
                left outer join dbo.MSmerge_contents c with (rowlock)
                    on c.rowguid = t.' + @rgcol + ' and 
                       c.tablenick = ' + @tablenickstr + ' and
                       t.' + @rgcol + ' = @rowguid
             where t.' + @rgcol + ' = @rowguid and
             ((@match is not NULL and @match = 1) or 
              ((@metadata_type = 3 and c.rowguid is NULL) or
               (@metadata_type = 2 and c.rowguid is not NULL and c.lineage = @lineage_old)))

            select @rowcount= @@rowcount, @error= @@error'
            end
            else
            begin
                select @cmdpiece = ' where rowguidcol = @rowguid
            select @rowcount= @@rowcount, @error= @@error'
            end
            insert into #tempcmd (phase, cmdtext) values (30, @cmdpiece) 

            -- now add the sp_executesql part            
            select @cmdpiece = '
        end
        else -- we can do sp_executesql since the current user has permissions to update the table
        begin '
            if @maintainsmetadata = 1 and @tablenick != @logical_record_parent_nickname
                select @cmdpiece = @cmdpiece + '
            if @match is NULL
            begin
                if @metadata_type = 3
                begin
                    select @updatestmt = @updatestmt + ''
                       from ' + @escaped_qualified_name + ' t 
                       where t.' + @rgcol + ' = @rowguid and
                             not exists (select 1 from dbo.MSmerge_contents c with (rowlock)
                                         where c.rowguid = @rowguid and 
                                               c.tablenick = ' + @tablenickstr + ')''
                end
                else if @metadata_type = 2
                begin
                    select @updatestmt = @updatestmt + ''
                       from ' + @escaped_qualified_name + ' t 
                       where t.' + @rgcol + ' = @rowguid and
                             exists (select 1 from dbo.MSmerge_contents c with (rowlock)
                                     where c.rowguid = @rowguid and 
                                           c.tablenick = ' + @tablenickstr + ' and
                                           c.lineage = @lineage_old)''
                end
            end
            else
            begin
                select @updatestmt = @updatestmt + ''
                    where rowguidcol = @rowguid ''
            end
            select @updatestmt = @updatestmt + ''
                select @rowcount = @@rowcount, @error = @@error''
            exec sys.sp_executesql @stmt = @updatestmt, @parameters = N'''
            else
                select @cmdpiece = @cmdpiece + '
            select @updatestmt = @updatestmt + ''
                where rowguidcol = @rowguid
                select @rowcount = @@rowcount, @error = @@error''
            exec sys.sp_executesql @stmt = @updatestmt, @parameters = N'''
                
            insert into #tempcmd (phase, cmdtext) values (30, @cmdpiece) 

            -- phase 35 will be all the 'parameters' for sp_executesql

            -- end of @parameters to sp_executesql
            if @maintainsmetadata = 1 and @tablenick != @logical_record_parent_nickname
                select @cmdpiece = ', @rowguid uniqueidentifier = ''''00000000-0000-0000-0000-000000000000'''', @lineage_old varbinary(311), @rowcount int output, @error int output'','
            else
                select @cmdpiece = ', @rowguid uniqueidentifier = ''''00000000-0000-0000-0000-000000000000'''', @rowcount int output, @error int output'','
            insert into #tempcmd (phase, cmdtext) values (40, @cmdpiece) 
            
            -- phase 45 will be the actual parameters to sp_executesql

            -- phase 50 is the end of actual parameters to sp_executesql
            if @maintainsmetadata = 1 and @tablenick != @logical_record_parent_nickname
                select @cmdpiece = '
                    , @rowguid = @rowguid, @lineage_old = @lineage_old, @rowcount = @rowcount OUTPUT, @error = @error OUTPUT '
            else
                select @cmdpiece = '
                    , @rowguid = @rowguid, @rowcount = @rowcount OUTPUT, @error = @error OUTPUT '
            select @cmdpiece = @cmdpiece + '
        end  -- end if @hasperm
        if (@rowcount <> 1)
        begin
            set @errcode= 3
            goto Failure
        end'             

            if @maintainsmetadata = 1 and @tablenick != @logical_record_parent_nickname
                select @cmdpiece = @cmdpiece + '    
        select @match = 1'
        
            select @cmdpiece = @cmdpiece + '    
    end -- end if @indexing_column_updated '
            insert into #tempcmd (phase, cmdtext) values (50, @cmdpiece) 
            select @indexing_columns_update_stmt_started = 1
        end -- end if @indexing_columns_update_stmt_started
        else
        begin
            select @cmdpiece = ','
            insert into #tempcmd (phase, cmdtext) values (35, @cmdpiece)
            select @cmdpiece = ','
            insert into #tempcmd (phase, cmdtext) values (45, @cmdpiece)
        end
        
        -- add all the values in @parameters to the sp_executesql call
        select @cmdpiece = '
                    ' + @argname + ' ' + @schname + @typename
        insert into #tempcmd (phase, cmdtext) values (35, @cmdpiece)

        -- add all the @params for the sp_executesql call 
        select @cmdpiece = '
                    ' + @argname + ' = ' + @argname
        insert into #tempcmd (phase, cmdtext) values (45, @cmdpiece)

        -- insert the part that goes into the update statement in the case we are not using execsql
        -- this update statement is the one that updates all indexing columns.
        if @firstUpdCol=1
        begin
            select @firstUpdCol = 0
            select @cmdpiece = ''
        end
        else 
            select @cmdpiece = ','
        
        if @maintainsmetadata = 1 and @tablenick != @logical_record_parent_nickname
            select @cmdpiece = @cmdpiece + '
                ' + @colname + ' = case ' + @columnsetbitvarname + ' when 1 then ' + @argname + ' else t.' + @colname + ' end'
        else
            select @cmdpiece = @cmdpiece + '
                ' + @colname + ' = case ' + @columnsetbitvarname + ' when 1 then ' + @argname + ' else ' + @colname + ' end'
        insert into #tempcmd (phase, cmdtext) values (25, @cmdpiece)
    end
    else
    begin
        -- if this is not an indexing column we can update the column as part of the general update column
        if (@update_stmt_started = 0)
        begin
            select @update_stmt_started = 1
            if @maintainsmetadata = 1 and @tablenick != @logical_record_parent_nickname
            begin
                select @cmdpiece = '
    if @match is NULL
    begin
        update ' + @qualified_name + ' set '
                insert into #tempcmd (phase, cmdtext) values (60, @cmdpiece) 

                -- phase 65 is the list of column updates
                
                select @cmdpiece = ' 
         from ' + @qualified_name + ' t 
            left outer join dbo.MSmerge_contents c with (rowlock)
                on c.rowguid = t.' + @rgcol + ' and 
                   c.tablenick = ' + @tablenickstr + ' and
                   t.' + @rgcol + ' = @rowguid
         where t.' + @rgcol + ' = @rowguid and
         ((@match is not NULL and @match = 1) or 
          ((@metadata_type = 3 and c.rowguid is NULL) or
           (@metadata_type = 2 and c.rowguid is not NULL and c.lineage = @lineage_old)))

        select @rowcount= @@rowcount, @error= @@error
    end
    else
    begin
        update ' + @qualified_name + ' set '
                insert into #tempcmd (phase, cmdtext) values (70, @cmdpiece) 

                -- phase 75 is the list of column updates
                
                select @cmdpiece = ' 
         from ' + @qualified_name + ' t 
             where t.' + @rgcol + ' = @rowguid

        select @rowcount= @@rowcount, @error= @@error
    end'
                insert into #tempcmd (phase, cmdtext) values (80, @cmdpiece) 
            end
            else
            begin
                select @cmdpiece = '
    update ' + @qualified_name + ' set '
                insert into #tempcmd (phase, cmdtext) values (60, @cmdpiece) 
            
                -- phase 65 is the list of column updates
                
                select @cmdpiece = ' 
         from ' + @qualified_name + ' t 
             where t.' + @rgcol + ' = @rowguid
    select @rowcount= @@rowcount, @error= @@error'
                insert into #tempcmd (phase, cmdtext) values (70, @cmdpiece) 
            end
            select @cmdpiece = '
    if (@rowcount <> 1) or (@error <> 0)
    begin
        set @errcode= 3
        goto Failure
    end'
            insert into #tempcmd (phase, cmdtext) values (80, @cmdpiece) 
            
            if @maintainsmetadata = 1 and @tablenick != @logical_record_parent_nickname
            begin
                select @cmdpiece = '
    select @match = 1'
                insert into #tempcmd (phase, cmdtext) values (80, @cmdpiece) 
            end
        end
        else
        begin
            select @cmdpiece = ','
            insert into #tempcmd (phase, cmdtext) values (65, @cmdpiece)
            if @maintainsmetadata = 1 and @tablenick != @logical_record_parent_nickname
                insert into #tempcmd (phase, cmdtext) values (75, @cmdpiece)
        end

        if @maintainsmetadata = 1 and @tablenick != @logical_record_parent_nickname
        begin
            select @cmdpiece = '
            ' + @colname + ' = case when ' + @argname + ' is NULL then (case when sys.fn_IsBitSetInBitmask(@setbm, ' + @colordstr + ') <> 0 then ' + @argname + ' else t.' + @colname + ' end) else ' + @argname + ' end '
            insert into #tempcmd (phase, cmdtext) values (65, @cmdpiece)        
            insert into #tempcmd (phase, cmdtext) values (75, @cmdpiece)        
        end
        else
        begin
            select @cmdpiece = '
            ' + @colname + ' = case when ' + @argname + ' is NULL then (case when sys.fn_IsBitSetInBitmask(@setbm, ' + @colordstr + ') <> 0 then ' + @argname + ' else t.' + @colname + ' end) else ' + @argname + ' end '
            insert into #tempcmd (phase, cmdtext) values (65, @cmdpiece)        
        end
    end
    
Next_Column:        
    -- Advance loop to next column and repeat!
    if @sync_objid = @id
        select @colid = min (column_id) from sys.columns where object_id = @id and is_computed=0 and user_type_id<>type_id('timestamp') and column_id > @colid 
    else
        select @colid = min(cs.column_id) 
            from sys.columns cs inner join sys.columns co on co.object_id=@id and co.name = cs.name
        where cs.object_id = @sync_objid and 
              co.is_computed=0 and co.user_type_id<>type_id('timestamp') and cs.column_id > @colid 
    
    set @colname = NULL
    if (@colid is not null)
    begin
        select top 1 @colname = C.name, 
        @typename = type_name(C.user_type_id), 
        @base_typename = type_name(C.system_type_id), 
        @schname=case when S.name<>'sys' and S.name<>'dbo'
                                then QUOTENAME(S.name)+'.' else '' end, 
        @system_type_id = C.system_type_id,
        @blen = C.max_length,
        @prec = C.precision, 
        @scale = C.scale
        from sys.columns C  
                INNER JOIN sys.types T ON C.user_type_id = T.user_type_id
                INNER JOIN sys.schemas S ON T.schema_id = S.schema_id            
        where C.object_id = @sync_objid and C.column_id = @colid
    
        select @isidentitycolumn = is_identity, @iscomputed=is_computed, @xtype=user_type_id,
            @isrowguidcol = is_rowguidcol 
            from sys.columns 
            where object_id = @id and name = @colname
                
        if ((@base_typename='nvarchar' or @base_typename='nchar') and @blen <> -1) -- a unit of nchar takes 2 bytes
            set @len = @blen/2
        else
            set @len = @blen

        set @colordinal = @colordinal + 1
    end
end

if 1 = @maintainsmetadata
begin
    if @partition_options > 1 and @atpublisher = 1 -- should really be @well_partitioned_multiple_hops = 1, requires agent changes in commit batch
    begin
        set @cmdpiece = ', @compatlevel int = 10, @partition_id int = NULL '
        insert into #tempcmd (phase, cmdtext) values (1, @cmdpiece)
    end
    else
    begin
        set @cmdpiece = ', @compatlevel int = 10 '
        insert into #tempcmd (phase, cmdtext) values (1, @cmdpiece)
    end
end

-- Add dummy column list to select statement if there is no user updateable 
-- column.
if @has_updateable_columns_in_select_list = 0
begin
    insert into #tempcmd (phase, cmdtext) values (3, N'declare @l int')
    insert into #tempcmd (phase, cmdtext) values (5, N'@l = 1')
end

-- phase 20 finish the stored procedure
if 1 = @maintainsmetadata
begin

    if @partition_options > 1
        select @cmdpiece = ' 
    if @lineage_new is not null
    begin '
    else
        select @cmdpiece = ' '

    set @cmdpiece = @cmdpiece + '
    exec @retcode= sys.sp_MSsetrowmetadata 
        @tablenick, @rowguid, @generation, 
        @lineage_new, @colv, 2, NULL, 
        @compatlevel, 0, ''' + convert(nvarchar(36),@pubid) + ''''
        
    if @partition_options > 1
    begin
        if @atpublisher = 1
            select @cmdpiece = @cmdpiece + ',       
    @publication_number = @publication_number, @partition_id = @partition_id, @partition_options = 2 '
        else
            select @cmdpiece = @cmdpiece + ',       
    @publication_number = NULL, @partition_id = NULL, @partition_options = 2 '
    end
    
    select @cmdpiece = @cmdpiece + '
    if @retcode<>0 or @@ERROR<>0
    begin
        set @errcode= 3
        goto Failure
    end '

    if @partition_options > 1
        select @cmdpiece = @cmdpiece + ' 
    end '
    
    select @cmdpiece = @cmdpiece + '

delete from dbo.MSmerge_metadataaction_request
    where tablenick=@tablenick and rowguid=@rowguid

    if @started_transaction = 1
        commit transaction

-- DEBUG    insert into MSmerge_debug 
-- DEBUG        (okay, artnick, rowguid, type, successcode, generation_new, lineage_old, lineage_new, twhen, comment)
-- DEBUG        values (0, @tablenick, @rowguid, @metadata_type, 1, @generation, @lineage_old, @lineage_new, getdate(), ''sp_upd'')

    return(1)

Failure:
    --rollback transaction sub
    --commit transaction
    if @started_transaction = 1    
        rollback transaction
-- DEBUG    insert into MSmerge_debug 
-- DEBUG        (okay, artnick, rowguid, type, successcode, generation_new, lineage_old, lineage_new, twhen, comment)
-- DEBUG        values (1, @tablenick, @rowguid, @metadata_type, @errcode, @generation, @lineage_old, @lineage_new, getdate(), ''sp_upd'')

'
end
else
begin
    set @cmdpiece = '
    if @started_transaction = 1    
        commit transaction

    delete from dbo.MSmerge_metadataaction_request
        where tablenick=@tablenick and rowguid=@rowguid

    return(1)

Failure:
    --rollback transaction sub
    --commit transaction
    if @started_transaction = 1    
        rollback transaction

'
end
insert into #tempcmd (phase, cmdtext) values (120, @cmdpiece)

if 1 = @maintainsmetadata
begin
    exec sys.sp_MScreatedupkeyupdatequery
            @tablename= @qualified_name,
            @tablenickstr= @tablenickstr,
            @phase= 140,
            @isconflictproc= 0,
            @tablename2= @qualified_name2
end

set @cmdpiece = '
    return @errcode'
insert into #tempcmd (phase, cmdtext) values (200, @cmdpiece)

-- Now we select out the command text pieces in proper order so that our caller,
-- xp_execresultset will execute the command that creates the stored procedure.

select cmdtext from #tempcmd order by phase, step
drop table #tempcmd
drop table #coltab
GO
GRANT EXECUTE ON [sys].[sp_MSmakeupdateproc] TO [public] AS [dbo]
GO
