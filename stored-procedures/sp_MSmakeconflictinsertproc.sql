SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSmakeconflictinsertproc]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSmakeconflictinsertproc] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSmakeconflictinsertproc]
	@tablename [sysname],
	@ownername [sysname],
	@procname [sysname],
	@basetableid [int],
	@pubid [uniqueidentifier],
	@generate_subscriber_proc [bit]
WITH EXECUTE AS CALLER
AS
declare @arglist    nvarchar(4000)
declare @header     nvarchar(4000)
declare @qualname   nvarchar(517) -- 258 * 2 + 1
declare @argname    nvarchar(270)
declare @wherepc    nvarchar(255)
declare @idstr      nvarchar(100)
declare @colname nvarchar(258)
declare @guidcol nvarchar(258)
declare @typename nvarchar(258)
declare @base_typename sysname
declare @schname nvarchar(140)  --use this to track the user schema name
declare @len smallint
declare @prec smallint
declare @scale int
declare @retcode smallint
declare @create_time_col nvarchar(8)
declare @pubidstr nvarchar(40)
declare @guid_colname sysname
declare @original_datasourcecol sysname
declare @tablenick  int
declare @tablenickstr nvarchar(12)
declare @basetablename   nvarchar(270)
declare @qualifiedbasetable   nvarchar(517) -- 258 * 2 + 1
declare @qualifiedbasetable2   nvarchar(517) -- 258 * 2 + 1
declare @basetableowner   nvarchar(270)
declare @maintainsmetadata bit
declare @artid uniqueidentifier
declare @schema_option varbinary(8)
declare @user_type_id int

declare @id int                     -- conflict table id
declare @sync_objid int             -- article view

declare @colid smallint             -- index in sys.columns, used to iterate through sys.columns
declare @colordinal smallint        -- index in @setbm, used to interate actual data sent across
declare @colordstr nvarchar(4)      -- @colordinal stringification

declare @noset bit          -- set when column is two special ones: rowguidcol or origin_datasource_id.
                            -- they are discovered when @sys_loop=1 and need to be treated specially for the insertion to conflict table (ie skipped there)
declare @sys_loop bit       -- 0 as first staget for columns in base table, 1 as 2nd stage for columns not in base table
declare @quotedprocname nvarchar(258)

set nocount on

set @guidcol='rowguid'

select @sys_loop = 0
set @create_time_col = NULL

if (@ownername is null or @ownername = ' ')
    set @qualname = QUOTENAME(@tablename)
else
    set @qualname = QUOTENAME(@ownername) + '.' + QUOTENAME(@tablename)

/*
** To check if specified object exists in current database
*/
set @id = object_id(@qualname)
if @id is NULL return (1)
set @idstr = rtrim(convert(nchar, @id)) 
select @pubidstr = case when @pubid is null then 'NULL' else 
                '''' + convert(nvarchar(40),@pubid) + '''' end
                
-- security check
exec @retcode = sys.sp_MSrepl_PAL_rolecheck @pubid=@pubid, @objid=@id
if @@error <> 0 or @retcode <> 0
    return 1

set @basetablename= object_name(@basetableid)
select @basetableowner= SCHEMA_NAME(schema_id) from sys.objects where object_id=@basetableid

if @basetableowner is not null
    set @qualifiedbasetable= quotename(@basetableowner) + '.' + quotename(@basetablename)
else
    set @qualifiedbasetable= quotename(@basetablename)

if @generate_subscriber_proc = 1
begin
    select @qualifiedbasetable2 = quotename(destination_owner) + '.' + quotename(@basetablename) from dbo.sysmergearticles where pubid=@pubid and objid = object_id(@qualifiedbasetable)
end
else
    set @qualifiedbasetable2= @qualifiedbasetable

execute @retcode= sys.sp_MStablenickname @basetableowner, @basetablename, @tablenick output
if @@ERROR <>0 OR @retcode <>0 return (1)
set @tablenickstr = rtrim(convert(nchar, @tablenick))

-- create temp table to select the command text out of
create table #tempcmd (phase int NOT NULL, step int identity NOT NULL, 
cmdtext nvarchar(max) collate database_default null)

-- create temp table that will be used by sp_MScreatedupkeyupdatequery
create table #coltab (colname nvarchar(140), paramname nvarchar(10))

-- now create the procedure
select @quotedprocname = QUOTENAME(@procname)

if @generate_subscriber_proc = 0
begin
    exec ('if object_id (''dbo.' + @quotedprocname + ''') is not null drop procedure dbo.' + @quotedprocname)
    if @@error<>0 return 1
end

select @header = 'Create procedure dbo.' + @quotedprocname + ' ( ' 
insert into #tempcmd (phase, cmdtext) values (0,  @header)

select @sync_objid= sync_objid, @artid= artid, @schema_option = schema_option from dbo.sysmergearticles where objid = @basetableid and (pubid = @pubid or @pubid is NULL)

set @maintainsmetadata= sys.fn_MSarticle_allows_DML_at_this_replica(@artid, default)

--it doesn't make sense to replicate only token column - rowguidcol column
declare @colcount int
declare @column sysname

select @colcount=count(*) from sys.columns where object_id = @sync_objid
if @colcount = 1
begin
    select @column=name from sys.columns where object_id = @sync_objid
    if ColumnProperty(@id, @column, 'isrowguidcol') = 1        
    begin
        raiserror(21597, 16, -1)
        return (1)
    end
end

set @colordinal=0

-- the column exists in conflict table and
-- either exists or not exists
-- in base table
if @sys_loop =1
    select @colid = min(column_id) from sys.columns where object_id = @id and is_computed<>1 and user_type_id <> type_id('timestamp')
        and name not in (select name from sys.columns where object_id=@basetableid)
else
    select @colid = min(column_id) from sys.columns where object_id = @id and is_computed<>1 and user_type_id <> type_id('timestamp')
        and name in (select name from sys.columns where object_id=@basetableid)

select top 1 @colname = C.name, 
    @typename = type_name(C.user_type_id), 
    @base_typename=type_name(C.system_type_id),
    @len = C.max_length,
    @schname=case when S.name<>'sys' and S.name<>'dbo'
                     then QUOTENAME(S.name)+'.' 
                     else '' end,  
    @prec = C.precision, 
    @scale = C.scale,
    @user_type_id = C.user_type_id
    from sys.columns C  
            INNER JOIN sys.types T ON C.user_type_id = T.user_type_id
            INNER JOIN sys.schemas S ON T.schema_id = S.schema_id            
    where C.object_id = @id and C.column_id = @colid
    
/*
** Get the column list from the conflict_table schema and filter it with 
table view for vertical partitioning
*/
-- do first for basic columns and 2nd for columns not in basic tables
Reverse_Order:
-- loop over columns
while (@colname is not null) 
begin
    set @noset = 0
    -- skip unless
    -- the column exists in base table and in article view
    -- or the column does not exist in base table (i.e. conflict table only)
    if exists (select * from sys.columns where name=@colname and object_id=@basetableid)
        and not exists (select * from sys.columns where name=@colname and object_id=@sync_objid)
        goto NEXT_COL

    set @colordinal = @colordinal + 1
    set @colordstr = convert(nvarchar(4), @colordinal)
    
    if ((@base_typename='nvarchar' or @base_typename='nchar') and  @len <> -1)-- a unit of nchar takes 2 bytes
        select @len = @len/2

    if @generate_subscriber_proc = 0
        exec @retcode = sys.sp_MSmaptype @typename out, @len, @prec, @scale
    else
        exec @retcode = sys.sp_MSmap_subscriber_type @user_type_id, @len, @prec, @scale, @schema_option, @typename out, @schname out
    if @@ERROR<>0 or @retcode<>0 return (1)
    select @argname = '@p' + rtrim(convert(nchar, @colid))
            
    insert into #coltab (colname, paramname) values (quotename(@colname), @argname)

    -- based on colid, add text to appropriate pieces
    if (COLUMNPROPERTY( @basetableid, @colname, 'IsRowGuidCol') = 1)  
    begin
        select @noset =1
        select @guid_colname=@argname -- @px
        set @wherepc = ' where info.rowguid = ' + @argname
        set @guidcol=QUOTENAME(@colname) -- rowguid or [rg] like
    end
    else if (@colname = 'origin_datasource_id')
    begin
        select @wherepc =@wherepc +  ' and info.origin_datasource = ' + @argname
        select @typename = ' nvarchar(255) '
        select @original_datasourcecol = @argname; -- @px
        set @noset =1
    end
    set @colname = QUOTENAME(@colname)

    -- 1st piece
    if @arglist is null
    begin
        set @arglist = @argname + ' ' + @schname + @typename
        --give default value of NULL to new merge columns for backward compatibility concern
        insert into #tempcmd (phase, cmdtext) values (3, @colname)
        select @header = ') values ('
        insert into #tempcmd (phase, cmdtext) values (4, @header)
        insert into #tempcmd (phase, cmdtext) values (4, nchar(13)+nchar(10)+@argname)
        -- this is update case
        if @noset=0
        begin
            insert into #tempcmd (phase, cmdtext) values (1, @colname + ' = ' + @argname)
        end
    end
    -- consecutive piece
    else 
    begin
        if len(@arglist)>3700
        begin
            insert into #tempcmd (phase, cmdtext) values (0,  @arglist)            
            select @arglist = ' '
        end
        set @arglist = @arglist + ', 
        ' + @argname + ' ' + @schname + @typename

        -- 3 and 4 are for insert part
        insert into #tempcmd (phase, cmdtext) values (3, ',
        ' + @colname)

        if (@argname = @original_datasourcecol)
            select @argname=' @source_id '
        insert into #tempcmd (phase, cmdtext) values (4, ',
        ' + @argname) -- source id case

         -- 1 is for update part
        if @noset =0
            begin
                if exists (select * from #tempcmd where phase=1)
                    insert into #tempcmd (phase, cmdtext) values (1, ',
        ' + @colname + ' = ' + @argname)
                else
                    insert into #tempcmd (phase, cmdtext) values (1, @colname + ' = ' + @argname)
            end
        end
NEXT_COL:
    if @sys_loop =1
        select @colid = min(column_id) from sys.columns where object_id = @id and is_computed<>1 and user_type_id <> type_id('timestamp')
            and name not in (select name from sys.columns where object_id=@basetableid)
            and column_id>@colid
    else
        select @colid = min(column_id) from sys.columns where object_id = @id and is_computed<>1 and user_type_id <> type_id('timestamp')
            and name in (select name from sys.columns where object_id=@basetableid)
            and column_id>@colid

    set @colname = NULL

    select top 1 @colname = C.name, 
    @typename = type_name(C.user_type_id), 
    @base_typename = type_name(C.system_type_id), 
    @len = C.max_length,
    @schname=case when S.name<>'sys' and S.name<>'dbo'
                             then QUOTENAME(S.name)+'.' else '' end, 
    @prec = C.precision, 
    @scale = C.scale,
    @user_type_id = C.user_type_id
    from sys.columns C  
            INNER JOIN sys.types T ON C.user_type_id = T.user_type_id
            INNER JOIN sys.schemas S ON T.schema_id = S.schema_id            
    where C.object_id = @id and C.column_id = @colid

end

if @sys_loop = 0
begin
    select @sys_loop = 1
    select @colid = min(column_id) from sys.columns where object_id = @id and is_computed<>1 and user_type_id <> type_id('timestamp')
        and name not in (select name from sys.columns where object_id=@basetableid)

    select top 1 @colname = C.name, 
    @typename = type_name(C.user_type_id), 
    @base_typename = type_name(C.system_type_id),
    @len = C.max_length,
    @schname=case when S.name<>'sys' and S.name<>'dbo'
                                then QUOTENAME(S.name)+'.' else '' end, 
    @prec = C.precision, 
    @scale = C.scale,
    @user_type_id = C.user_type_id
    from sys.columns C  
            INNER JOIN sys.types T ON C.user_type_id = T.user_type_id
            INNER JOIN sys.schemas S ON T.schema_id = S.schema_id            
    where C.object_id = @id and C.column_id = @colid

    goto Reverse_Order
end

insert into #tempcmd (phase, cmdtext) values (0,  @arglist)            
select @arglist = ', @conflict_type int,  @reason_code int,  @reason_text nvarchar(720)'
insert into #tempcmd (phase, cmdtext) values (0,  @arglist)            
select @arglist = ', @pubid uniqueidentifier, @create_time datetime = NULL'
insert into #tempcmd (phase, cmdtext) values (0,  @arglist)        
select @arglist = ', @tablenick int = 0, @source_id uniqueidentifier = NULL, @check_conflicttable_existence bit = 0 '
insert into #tempcmd (phase, cmdtext) values (0,  @arglist)        

select @header =  ') as
declare @retcode int
-- security check
exec @retcode = sys.sp_MSrepl_PAL_rolecheck @objid = ' + @idstr + ', @pubid = ' + @pubidstr + '
if @@error <> 0 or @retcode <> 0 return 1 '
insert into #tempcmd (phase, cmdtext) values (0,  @header)

-- If the subscriber database was upgraded to Yukon, and we now use conflict logging on both sides
-- the subscriber database might not have the conflict logging table.
-- We then return without error.
set @header='
if 1 = @check_conflicttable_existence
begin
    if ' + cast(@id as nvarchar) + ' is null return 0
end
'
insert into #tempcmd (phase, cmdtext) values (0,  @header)

--select @header = ' if @source_id is NULL select @source_id = newid() '
select @header = '
    if @source_id is NULL 
        select @source_id = subid from dbo.sysmergesubscriptions 
            where lower(' +  @original_datasourcecol + ') = LOWER(subscriber_server) + ''.'' + LOWER(db_name) '

insert into #tempcmd (phase, cmdtext) values (0,  @header)

-- For down level anonymous pull subscriptions, the Publisher's sysmergesubscriptions does not contain a valid entry for the Subscriber 
-- Hence the source_id might still be NULL -In that case generate a new guid 

select @header = '
    if @source_id is NULL select @source_id = newid() '
insert into #tempcmd (phase, cmdtext) values (0,  @header)

select @header =  '  
    set @create_time=getdate()
'
insert into #tempcmd (phase, cmdtext) values (0,  @header)

select @header = ' '
-- for ease of expansion here in case we add new merge columns in conflict tables.
if @create_time_col is not NULL
    select @header = @header + ' 
    select ' + @create_time_col + ' = getdate() '

select @header = @header + ' if exists (select * from MSmerge_conflicts_info info inner join ' + @qualname + ' ct 
    on ct.rowguidcol=info.rowguid and 
       ct.origin_datasource_id = info.origin_datasource_id
    ' + @wherepc + ' and info.tablenick = @tablenick)
    begin
        update ' + @qualname + ' with (rowlock) set ' 
insert into #tempcmd (phase, cmdtext) values (0,  @header)

--see comment in sp_MSinsertdeleteconflict for this <5 or >4 checking.

select @header = ' from ' + @qualname + ' ct inner join MSmerge_conflicts_info info 
        on ct.rowguidcol=info.rowguid and 
           ct.origin_datasource_id = info.origin_datasource_id' 
insert into #tempcmd (phase, cmdtext) values (2,  @header)

-- concatenate for Insert case
insert into #tempcmd (phase, cmdtext) values (4, ')')

-- concatenate for Update case
select @header = @wherepc + ' and info.tablenick = @tablenick
'
insert into #tempcmd (phase, cmdtext) values (2,  @header)


select @header='
    end
    else
    begin
        insert into ' + @qualname + ' ('
insert into #tempcmd (phase, cmdtext) values (2,  @header)

insert into #tempcmd (phase, cmdtext) values (4, '
    end') -- finishing scope for insert+insert_update

select @header='
    
    if exists (select * from MSmerge_conflicts_info info where tablenick=@tablenick and rowguid=' 
    + @guid_colname + ' and info.origin_datasource= ' + @original_datasourcecol + ' and info.conflict_type not in (4,7,8,12))
    begin
        update MSmerge_conflicts_info with (rowlock) 
            set conflict_type=@conflict_type, 
                reason_code=@reason_code,
                reason_text=@reason_text,
                pubid=@pubid,
                MSrepl_create_time=@create_time
            where tablenick=@tablenick and rowguid=' + @guid_colname + ' and origin_datasource= ' + @original_datasourcecol + '
            and conflict_type not in (4,7,8,12)
    end
    else    
    begin
    
        insert MSmerge_conflicts_info with (rowlock) 
            values(@tablenick, ' + @guid_colname + ', ' + @original_datasourcecol
                + ', @conflict_type, @reason_code, @reason_text,  @pubid, @create_time, @source_id)
    end'            
insert into #tempcmd (phase, cmdtext) values (5, @header)

if 1 = @maintainsmetadata
begin
    exec sys.sp_MScreatedupkeyupdatequery
            @tablename= @qualifiedbasetable,
            @tablenickstr= @tablenickstr,
            @phase= 5,
            @isconflictproc= 1,
            @tablename2 = @qualifiedbasetable2
end

-- Now we select out the command text pieces in proper order so that our caller,
-- xp_execresultset will execute the command that creates the stored procedure.
select cmdtext from #tempcmd order by phase, step

drop table #tempcmd
drop table #coltab
GO
GRANT EXECUTE ON [sys].[sp_MSmakeconflictinsertproc] TO [public] AS [dbo]
GO
