SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSmakebatchinsertproc]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSmakebatchinsertproc] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSmakebatchinsertproc]
	@tablename [sysname],
	@ownername [sysname],
	@procname [sysname],
	@pubid [uniqueidentifier],
	@artid [uniqueidentifier],
	@generate_subscriber_proc [bit],
	@destination_owner [sysname]
WITH EXECUTE AS CALLER
AS
declare @argname                        sysname
declare @id                             int
declare @sync_objid                     int
declare @qualified_name                 nvarchar(270)
declare @idstr                          nvarchar(100)
declare @iscomputed                     tinyint
declare @xtype                          int
declare @is_identitynotforreplication   bit
declare @retcode                        int
declare @colname                        nvarchar(140)
declare @typename                       nvarchar(258)
declare @base_typename                       nvarchar(140)
declare @schname                         nvarchar(140)   --track the typename owner if it is CLR UDT
declare @isidentitycolumn               bit
declare @len                            smallint
declare @prec                           int
declare @scale                          int
declare @tablenick                      int
declare @tablenickstr                   nvarchar(12)
declare @cmdpiece                       nvarchar(4000)
declare @maintainsmetadata              bit
declare @colid int -- index in sys.columns, used to iterate through sys.columns
declare @colordinal int -- index in @setbm, used to interate actual data sent across
declare @colordstr nvarchar(5) -- @colordinal stringification
declare @colcount int
declare @maxparams int
declare @batchingfactor int
declare @rownumber int
declare @rownumberstr nvarchar(5)
declare @insertcolumnsstarted bit
declare @colnumber int
declare @colidstr nvarchar(5)
declare @colalias nvarchar(100)
declare @isrowguidcol tinyint
declare @partition_options tinyint
declare @atpublisher bit
declare @publication_number smallint
declare @qualified_sync_view nvarchar(517)
declare @rgcolname nvarchar(140)
declare @before_image_objid int
declare @qualified_before_image_table nvarchar(517)
declare @col_in_bitable bit
declare @bitable_colnumber int
declare @unquoted_colname sysname
declare @maxschemaguid uniqueidentifier
declare @phaseid int
declare @command1 nvarchar(4000)
declare @command2 nvarchar(4000)
declare @command3 nvarchar(4000)
declare @max_colv_size_in_bytes int
declare @schema_option varbinary(8)

set nocount on

-- Check for subscribing permission
exec @retcode=sys.sp_MSreplcheck_subscribe
if @retcode<>0 or @@ERROR<>0 return (0)

if @ownername is NULL or @ownername=''
    select @qualified_name = QUOTENAME(@tablename)
else    
    select @qualified_name = QUOTENAME(@ownername) + '.' + QUOTENAME(@tablename)
    
select @id = object_id(@qualified_name)
if @id is NULL 
    return (1)
    
if exists (select * from dbo.sysmergearticles where objid = @id and column_tracking = 1)
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
                        
select @rgcolname = QUOTENAME(name) from sys.columns where object_id = @id and is_rowguidcol = 1
if @rgcolname is null
    set @rgcolname = 'rowguid'

select @sync_objid = sync_objid, 
@partition_options = partition_options, @schema_option=schema_option, @tablenick = nickname
from dbo.sysmergepartitioninfoview where artid = @artid and pubid=@pubid
if @tablenick is NULL
    return (1)

set @tablenickstr = rtrim(convert(nchar, @tablenick))

if exists (select * from dbo.sysmergearticles where pubid = @pubid and nickname = @tablenick
                        and len(subset_filterclause) > 0)
                or exists (select * from dbo.sysmergesubsetfilters where pubid = @pubid and 
                        (art_nickname = @tablenick or join_nickname = @tablenick))
begin
    exec @retcode = sys.sp_MSget_qualified_name @sync_objid, @qualified_sync_view output
    if @sync_objid is not NULL and @qualified_sync_view is NULL
            return 1
end
else
begin
    select @qualified_sync_view = NULL
end

select @before_image_objid = max(before_image_objid) from dbo.sysmergearticles where objid = @id and
        before_image_objid is not null
exec @retcode = sys.sp_MSget_qualified_name @before_image_objid, @qualified_before_image_table output
if @before_image_objid is not NULL and @qualified_before_image_table is NULL
    return 1

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

select @insertcolumnsstarted = 0


if @generate_subscriber_proc = 1
begin
    select @atpublisher = 0
    select @qualified_name = quotename(@destination_owner) + '.' + quotename(@tablename)
    if exists (select 1 from dbo.sysmergearticles where artid=@artid and pubid=@pubid and upload_options in (1,2))
        select @maintainsmetadata = 0
    else
        select @maintainsmetadata = 1
end
else
begin
    set @maintainsmetadata= sys.fn_MSarticle_allows_DML_at_this_replica(@artid, default)
    select @atpublisher = sys.fn_MSmerge_islocalpubid(@pubid)
    select @maxschemaguid = sys.fn_GetArticleSchemaVersionGuid(@artid, @pubid)
end


select top 1 @publication_number = publication_number 
from dbo.sysmergepublications 
where pubid = @pubid

-- compute batching factor. For each row we need 
-- max params is 1024-2 for the first 2 parameters which is number of rows to be inserted, partition id
select @maxparams=1024-2

-- subtract one more since we have a @maxschemaguidforarticle parameter on the publisher
if @atpublisher = 1
    select @maxparams = @maxparams - 1

if @sync_objid = @id
    select @colcount = count(*) from sys.columns where object_id = @id and is_computed=0 and user_type_id<>type_id('timestamp') 
else
    select @colcount = count(*) 
        from sys.columns cs inner join sys.columns co on co.object_id=@id and co.name = cs.name
    where cs.object_id = @sync_objid and 
          co.is_computed=0 and co.user_type_id<>type_id('timestamp') 

-- for regular articles for each row we need rowguid, generation, lineage and colv in addition 
-- to the list of user table columns. For download only articles we only need rowguid
if 1 = @maintainsmetadata
    select @colcount = @colcount + 4
else
    select @colcount = @colcount + 1

select @batchingfactor = @maxparams/@colcount
if @batchingfactor > 100
    select @batchingfactor = 100


-- create temp table to select the command text out of
declare @tempcmd table (phase int NOT NULL, step int identity NOT NULL, cmdtext nvarchar(4000) collate database_default null)

-- phase 0 : create procedure and fixed part of argument list

if @atpublisher = 1
begin
    set @cmdpiece = 'create procedure dbo.'  + QUOTENAME(@procname) + ' (
        @maxschemaguidforarticle uniqueidentifier,
        @rows_tobe_inserted int,
        @partition_id int = null '
    insert into @tempcmd (phase, cmdtext) values (0, @cmdpiece)
end
else
begin
    set @cmdpiece = 'create procedure dbo.'  + QUOTENAME(@procname) + ' (
        @rows_tobe_inserted int,
        @partition_id int = null '
    insert into @tempcmd (phase, cmdtext) values (0, @cmdpiece)
end

-- phase 10 is rest of the arguments built based on batching factor etc
select @cmdpiece = '
) as
begin
    declare @errcode    int
    declare @retcode    int
    declare @rowcount   int
    declare @error      int
    declare @rows_in_contents int
    declare @rows_inserted_into_contents int
    declare @publication_number smallint
    declare @gen_cur bigint
    declare @rows_in_tomb bit
    declare @rows_in_syncview int
    declare @marker uniqueidentifier
    
    set nocount on
    
    set @errcode= 0
    set @publication_number = ' + convert(nvarchar(10), @publication_number) + '
    
    if ({ fn ISPALUSER(''' + convert(nvarchar(36),@pubid) + ''') } <> 1)
    begin
        RAISERROR (14126, 11, -1)
        return 4
    end

    if @rows_tobe_inserted is NULL or @rows_tobe_inserted <=0
        return 0

'
   
    insert into @tempcmd (phase, cmdtext) values (20, @cmdpiece)

if @atpublisher = 1
begin
    -- phase 5 - check the max schema guid for article and error out if they do not match
    set @cmdpiece= '
    declare @maxschemaguid    uniqueidentifier
    select @maxschemaguid = ''' + convert(nvarchar(36),@maxschemaguid) + '''
    if ((@maxschemaguidforarticle IS NOT NULL) and (@maxschemaguid <> @maxschemaguidforarticle))
    begin
        RAISERROR (25007, 11, -1)
        return 5
    end    '
    insert into @tempcmd (phase, cmdtext) values (20, @cmdpiece)
end

select @cmdpiece = '
    begin tran
    save tran batchinsertproc 

    exec @retcode = sys.sp_MSmerge_getgencur_public ' + @tablenickstr + ', @rows_tobe_inserted, @gen_cur output
    if @retcode<>0 or @@error<>0
        return 4

'
insert into @tempcmd (phase, cmdtext) values (20, @cmdpiece)

-- we need to insert the row metadata first so that the insert trigger
-- does not insert the contents row.
if 1 = @maintainsmetadata
begin
    -- if any of the rows exist in tombstone we will abort the batched insert
    select @cmdpiece = '
    select @rows_in_tomb = 0
    select @rows_in_tomb = 1 from ('
    insert into @tempcmd (phase, cmdtext) values (22, @cmdpiece)
    -- list of rowguids will be in phase 25
    insert into @tempcmd (phase, cmdtext) select phase, cmdtext from sys.fn_MSgetrowguidvirtualtable(25, @batchingfactor) order by step
    select @cmdpiece = '
    ) as rows
    inner join dbo.MSmerge_tombstone tomb with (rowlock) 
    on tomb.rowguid = rows.rowguid
    and tomb.tablenick = ' + @tablenickstr + '
    and rows.rowguid is not NULL
        
    if @rows_in_tomb = 1
    begin
        raiserror(20692, 16, -1, ''' + sys.fn_replreplacesinglequote(@tablename) + ''')
        set @errcode=3
        goto Failure
    end'
    insert into @tempcmd (phase, cmdtext) values (27, @cmdpiece)
    
    select @cmdpiece = '
    
    select @marker = newid()
    insert into dbo.MSmerge_contents with (rowlock)
    (rowguid, tablenick, generation, partchangegen, lineage, colv1, marker)
    select rows.rowguid, ' + @tablenickstr + ', rows.generation, (-rows.generation), rows.lineage, rows.colv, @marker
    from ('
    insert into @tempcmd (phase, cmdtext) values (30, @cmdpiece)
    -- phase 50 will be virtual table with the row metadata
    select @cmdpiece = '
    ) as rows
    where rows.rowguid is not NULL '
    insert into @tempcmd (phase, cmdtext) values (60, @cmdpiece)
    
    if @partition_options > 1
    begin
        select @cmdpiece = '
    and rows.lineage is not null '
        insert into @tempcmd (phase, cmdtext) values (61, @cmdpiece)
    end

    select @cmdpiece = '
    select @rows_inserted_into_contents = @@rowcount, @error = @@error
    if @error<>0
    begin
        set @errcode=3
        goto Failure
    end'
    insert into @tempcmd (phase, cmdtext) values (62, @cmdpiece)
    
    if @partition_options < 2
    begin
        select @cmdpiece = '
    if (@rows_inserted_into_contents <> @rows_tobe_inserted)
    begin
        raiserror(20693, 16, -1, ''' + sys.fn_replreplacesinglequote(@tablename) + ''')
        set @errcode=4
        goto Failure
    end'    
        insert into @tempcmd (phase, cmdtext) values (63, @cmdpiece)
    end
    
    if @partition_options > 1 and @atpublisher = 1
    begin
        select @cmdpiece = '
    if @partition_id is not null
    begin
        insert into dbo.MSmerge_current_partition_mappings with (rowlock)
        (tablenick, rowguid, publication_number, partition_id)
        select distinct ' + @tablenickstr + ', rows.rowguid, @publication_number, @partition_id
        from ('
        insert into @tempcmd (phase, cmdtext) values (70, @cmdpiece)
        -- phase 80 will be virtual table with the row metadata
        select @cmdpiece = '
        ) as rows
        where rows.rowguid is not NULL
        and rows.lineage is not null
        select @error = @@error
        if @error<>0
        begin
            set @errcode= 3
            goto Failure
        end
    end'
        insert into @tempcmd (phase, cmdtext) values (90, @cmdpiece)
    end
end

-- phase 100 is the insert statement
select @cmdpiece = '
    insert into ' + @qualified_name + ' with (rowlock) ('
insert into @tempcmd (phase, cmdtext) values (100, @cmdpiece)
-- phase 120 will have all the column names
-- now for completing insert and the select from the vtable
select @cmdpiece = ')
    select '
insert into @tempcmd (phase, cmdtext) values (150, @cmdpiece)
-- phase 170 will contain column names selected from the virtual table
-- complete the select
select @cmdpiece = '
    from ('
insert into @tempcmd (phase, cmdtext) values (180, @cmdpiece)
-- phase 200 will have the virtual table declaration for all the column values
select @cmdpiece = '
    ) as rows
    where rows.rowguid is not NULL
    select @rowcount = @@rowcount, @error = @@error'
insert into @tempcmd (phase, cmdtext) values (250, @cmdpiece)

-- phase 250 will also contain the optional identity insert off
    
select @cmdpiece = '
    if (@rowcount <> @rows_tobe_inserted) or (@error <> 0)
    begin
        set @errcode= 3
        goto Failure
    end
'
insert into @tempcmd (phase, cmdtext) values (300, @cmdpiece)

-- if @qualified_sync_view is not NULL and partition_id is not null check if 
-- the row is present in sync_view. If NOT do the following:
-- 1. insert a past partition mapping for the row
-- 2. update generation and partchangegen to 0
-- 3. if there is a before image table, insert the row into the before image table
if @atpublisher = 1 and @qualified_sync_view is not NULL
begin
    if @partition_options>0
    begin
        -- for partition_options > 0 we will not allow out of partition inserts
        select @cmdpiece = '
     select @rows_in_syncview = count (*) from ' + @qualified_sync_view + ' syncview with (READPAST)
     where syncview.' + @rgcolname + ' in 
     ('
        insert into @tempcmd (phase, cmdtext) values (320, @cmdpiece)
        -- phase 330 will be rowguids
        insert into @tempcmd (phase, cmdtext) select phase, cmdtext from sys.fn_MSgetrowguids(330, @batchingfactor) order by step
        select @cmdpiece = '
     )
            
     if @rows_in_syncview <> @rows_tobe_inserted
     begin
        raiserror(20703, 16, -1, ''' + sys.fn_replreplacesinglequote(@tablename) + ''', ' + convert(char(3), @partition_options) + ')
        set @errcode= 3
        goto Failure
     end'
        insert into @tempcmd (phase, cmdtext) values (340, @cmdpiece)
    end
    else
    begin
        select @cmdpiece = '
    if @partition_id is not NULL
    begin
        insert into dbo.MSmerge_past_partition_mappings with (rowlock)
        (publication_number, tablenick, rowguid, partition_id, generation, reason)
        select @publication_number, ' + @tablenickstr + ', rows.rowguid, @partition_id, @gen_cur, 0
        from ('
        insert into @tempcmd (phase, cmdtext) values (320, @cmdpiece)
        -- phase 330 will be virtual table with the rowguids
        insert into @tempcmd (phase, cmdtext) select phase, cmdtext from sys.fn_MSgetrowguidvirtualtable(330, @batchingfactor) order by step
        select @cmdpiece = '
        ) as rows
        where not exists (select syncview.' + @rgcolname + ' from ' + @qualified_sync_view + ' syncview with (READPAST) where
                            syncview.' + @rgcolname + ' = rows.rowguid)
        and rows.rowguid is not NULL
        if @@error<>0
        begin
            set @errcode= 3
            goto Failure
        end
    end'
        insert into @tempcmd (phase, cmdtext) values (340, @cmdpiece)

        select @cmdpiece = '
    update dbo.MSmerge_contents with (rowlock)
        set generation = @gen_cur, partchangegen = @gen_cur
    from ('
        insert into @tempcmd (phase, cmdtext) values (350, @cmdpiece)
        -- phase 360 will be virtual table with the rowguids
        insert into @tempcmd (phase, cmdtext) select phase, cmdtext from sys.fn_MSgetrowguidvirtualtable(360, @batchingfactor) order by step
        select @cmdpiece = '
    ) as rows
    inner join dbo.MSmerge_contents cont with (rowlock, READPAST) 
    on cont.rowguid = rows.rowguid and cont.tablenick = ' + @tablenickstr + '
    and rows.rowguid is not null
    left outer join ' + @qualified_sync_view + ' syncview with (READPAST) 
    on syncview.' + @rgcolname + ' = rows.rowguid
    where syncview.' + @rgcolname + ' is NULL
    and rows.rowguid is not null
    
    if @@error<>0
    begin
        set @errcode= 3
        goto Failure
    end'
        insert into @tempcmd (phase, cmdtext) values (370, @cmdpiece)

        if @qualified_before_image_table is not NULL
        begin
            select @cmdpiece = '
    insert into ' + @qualified_before_image_table + ' with (rowlock)
    (generation, system_delete'
            insert into @tempcmd (phase, cmdtext) values (380, @cmdpiece)
            -- the list of columns in the before image table are filtering columns, generation, system_delete
            -- phase 390 will be the list of filtering columns and rowguid column
            select @cmdpiece = ')
        select @gen_cur, 1'
            insert into @tempcmd (phase, cmdtext) values (400, @cmdpiece)
            -- phase 410 will be the filtering column and rowguid selection from the virtual table
            select @cmdpiece = '
        from ( '
            insert into @tempcmd (phase, cmdtext) values (420, @cmdpiece)
            -- phase 430 will be the virtual table definition
            select @cmdpiece = '
    ) as rows
    left outer join ' + @qualified_sync_view + ' syncview with (READPAST) 
    on syncview.' + @rgcolname + ' = rows.rowguid
    and rows.rowguid is not null
    where syncview.' + @rgcolname + ' is NULL
    and rows.rowguid is not null
    
    if @@error<>0
    begin
        set @errcode= 3
        goto Failure
    end'
            insert into @tempcmd (phase, cmdtext) values (440, @cmdpiece)
        end
    end
end


if 1 = @maintainsmetadata
begin
    select @cmdpiece = '
    exec @retcode = sys.sp_MSdeletemetadataactionrequest ''' + convert(nvarchar(36),@pubid) + ''', ' + @tablenickstr
    set @rownumber = 1
    while @rownumber <= @batchingfactor
    begin
        select @cmdpiece = @cmdpiece + ', 
        @rowguid' + convert(nvarchar(3), @rownumber)
        select @rownumber = @rownumber + 1
    end
    select @cmdpiece = @cmdpiece + '
    if @retcode<>0 or @@error<>0
        goto Failure
    '
    insert into @tempcmd (phase, cmdtext) values (10200, @cmdpiece)
end
    
select @cmdpiece = '
    commit tran
    return 1

Failure:
    rollback tran batchinsertproc
    commit tran
    return 0
end
'
insert into @tempcmd (phase, cmdtext) values (15000, @cmdpiece)

-- this loop constructs the formal parameter declarations, the insert statement with actual column names and
-- the union clause which does a union over all rows.
-- phase 10 is the declarations, the rowsunion clause will be inserted into phases 200, 
-- the metadata union clause will be inserted into phase 400.

-- using these instead of directly inserting in the temp table is a performance optimization
select @command1 = ''
select @command2 = ''
select @command3 = ''
set @colordinal = 1
set @rownumber = 1
while @rownumber <= @batchingfactor
begin
    -- insert the metadada parameters for this row.
    set @rownumberstr = convert(nvarchar(5), @rownumber)

    if 1 = @maintainsmetadata
    begin
        select @command1 = @command1 + ',
    @rowguid' + @rownumberstr + ' uniqueidentifier = NULL,
    @generation' + @rownumberstr + ' bigint = NULL,
    @lineage' + @rownumberstr + ' varbinary(311) = NULL,
    @colv' + @rownumberstr + ' varbinary(' + convert(nvarchar(13), @max_colv_size_in_bytes) + ') = NULL'
        --insert into @tempcmd (phase, cmdtext) values (10, @cmdpiece)

        if @rownumber = 1
            select @command2 = @command2 + '
    select @rowguid' + @rownumberstr + ' as rowguid, @generation' + @rownumberstr + ' as generation, @lineage' + @rownumberstr + ' as lineage, @colv' + @rownumberstr + ' as colv'
        else
            select @command2 = @command2 + ' union all
    select @rowguid' + @rownumberstr + ' as rowguid, @generation' + @rownumberstr + ' as generation, @lineage' + @rownumberstr + ' as lineage, @colv' + @rownumberstr + ' as colv'

        if (datalength(@command2) > 7500) or (@rownumber = @batchingfactor)
        begin
            insert into @tempcmd (phase, cmdtext) values (50, @command2)
            
            if @partition_options > 1 and @atpublisher = 1
                insert into @tempcmd (phase, cmdtext) values (80, @command2)    
                
            select @command2 = ''
        end
    end
    else
    begin
        select @command1 = @command1 + ',
    @rowguid' + @rownumberstr + ' uniqueidentifier = NULL'
        --insert into @tempcmd (phase, cmdtext) values (10, @cmdpiece)
    end

    -- now loop over columns 
    select @colnumber = 1
    select @bitable_colnumber = 1
    if @sync_objid = @id
        select @colid = min (column_id) from sys.columns where object_id = @id and is_computed=0 and user_type_id<>type_id('timestamp') 
    else
        select @colid = min(cs.column_id) 
            from sys.columns cs inner join sys.columns co on co.object_id=@id and co.name = cs.name
        where cs.object_id = @sync_objid and 
              co.is_computed=0 and co.user_type_id<>type_id('timestamp') 

    select top 1 @colname = QUOTENAME(C.name), 
    @unquoted_colname = C.name,
    @typename = type_name(C.user_type_id), 
    @base_typename = type_name(C.system_type_id), 
    @schname=case when S.name<>'sys' and S.name<>'dbo'
                                then QUOTENAME(S.name)+'.' else '' end, 
    @len = C.max_length,
    @prec = C.precision, 
    @scale = C.scale
    from sys.columns C  
            INNER JOIN sys.types T ON C.user_type_id = T.user_type_id
            INNER JOIN sys.schemas S ON T.schema_id = S.schema_id            
    where C.object_id = @sync_objid and C.column_id = @colid
            
    select @isidentitycolumn = is_identity, 
           @iscomputed=is_computed, 
           @xtype=user_type_id, 
           @isrowguidcol = is_rowguidcol,
           @is_identitynotforreplication = convert(bit, isnull(columnproperty(@id, name, 'IsIdNotForRepl'), 0)) 
        from sys.columns 
        where object_id = @id and QUOTENAME(name) = @colname
    if @base_typename='nvarchar' or @base_typename='nchar' -- a unit of nchar takes 2 bytes
        select @len = @len/2

    while (@colname is not null)
    begin
        if (@iscomputed=1 OR type_name(@xtype)='timestamp')
            goto Next_Column

        set @colordstr = convert(nvarchar(4), @colordinal)
        set @colidstr = convert(nvarchar(4), @colid)

        if @generate_subscriber_proc = 0
            exec @retcode = sys.sp_MSmaptype @typename out, @len, @prec, @scale
        else
            exec @retcode = sys.sp_MSmap_subscriber_type @xtype, @len, @prec, @scale, @schema_option, @typename out, @schname out
        if @@error<>0 OR @retcode <>0 return (1)
        
        select @argname = '@p' + rtrim(convert(nchar, @colordinal))
        if @isrowguidcol = 1
            select @colalias = 'rowguid'
        else
            select @colalias = 'c' + @colidstr
            
        -- add to argument list (phase 1)
        set @command1 = @command1 + ',
    ' + @argname + ' ' + @schname + @typename + ' = NULL'
        if (datalength(@command1) > 7500) or (@rownumber = @batchingfactor)
        begin
            insert into @tempcmd (phase, cmdtext) values (10, @command1)
            select @command1 = ''
        end

        if @colnumber = 1
        begin
            if @rownumber = 1
                select  @command3 = @command3 + '
    select ' + @argname + ' as ' + @colalias
            else
                select @command3 = @command3 + ' union all
    select ' + @argname + ' as ' + @colalias
        end
        else
        begin
            if (@colnumber%10) = 0
                select @command3 = @command3 + ', 
        '
            else 
                select @command3 = @command3 + ', '
                
            select @command3 = @command3 + @argname + ' as ' + @colalias
        end

        if (datalength(@command3) > 7500) or (@rownumber = @batchingfactor)
        begin
            insert into @tempcmd (phase, cmdtext) values (200, @command3)
            select @command3 = ''
        end

        set @col_in_bitable = 0
        if @atpublisher = 1 and @partition_options=0 and @qualified_sync_view is not NULL and @qualified_before_image_table is not NULL
        begin 
            -- only filtering or rowguid columns are present in the before image table
            
            if @isrowguidcol=1
            begin
                set @col_in_bitable = 1
            end
            else
            begin
                -- does updating this column change membership in a partial replica? 
                if exists (select * from dbo.sysmergearticles 
                    where objid = @id and sys.fn_MSisfilteredcolumn(subset_filterclause, @unquoted_colname, @id) = 1)
                    set @col_in_bitable = 1
                else if exists (select * from dbo.sysmergesubsetfilters
                    where art_nickname = @tablenick and sys.fn_MSisfilteredcolumn(join_filterclause, @unquoted_colname, @id) = 1)
                    set @col_in_bitable = 1
                else if exists (select * from dbo.sysmergesubsetfilters
                    where join_nickname = @tablenick and sys.fn_MSisfilteredcolumn(join_filterclause, @unquoted_colname, @id) = 1)
                    set @col_in_bitable = 1
            end
        end
        
        -- insert the column in the virtual table that is used to insert into the bi table
        -- add the row in the virtual table that is used to insert into the before image table
        if @col_in_bitable = 1
        begin
            if @bitable_colnumber = 1
            begin
                if @rownumber = 1
                    select @cmdpiece = '
    select ' + @argname + ' as ' + @colalias
                else
                    select @cmdpiece = ' union all
    select ' + @argname + ' as ' + @colalias
            end
            else
                select @cmdpiece = ', ' + @argname + ' as ' + @colalias
            select @bitable_colnumber = @bitable_colnumber + 1
            insert into @tempcmd (phase, cmdtext) values (430, @cmdpiece)
        end

        if @rownumber = 1
        begin
            -- this is the actual column names to be specified in the insert
            if @insertcolumnsstarted = 0
            begin
                select @insertcolumnsstarted = 1
                -- this is the select list from the virual table to be specified in the
                -- select statement from which we insert
                select @cmdpiece = @colalias
                insert into @tempcmd (phase, cmdtext) values (170, @cmdpiece)

                -- this is the actual column name
                select @cmdpiece = @colname
                insert into @tempcmd (phase, cmdtext) values (120, @cmdpiece)
            end
            else
            begin
                -- this is the select list from the virual table to be specified in the
                -- select statement from which we insert
                select @cmdpiece = ', 
        ' + @colalias
                insert into @tempcmd (phase, cmdtext) values (170, @cmdpiece)
                
                -- this is the actual column name
                select @cmdpiece = ', 
        ' + @colname
                insert into @tempcmd (phase, cmdtext) values (120, @cmdpiece)
            end

            if @col_in_bitable = 1
            begin
                -- add the column in the column list for insert into the before image table
                select @cmdpiece = ', 
        ' + @colname
                insert into @tempcmd (phase, cmdtext) values (390, @cmdpiece)
                
                -- add the column in the select list for insert into the before image table
                select @cmdpiece = ', 
        ' + ' rows.' + @colalias
                insert into @tempcmd (phase, cmdtext) values (410, @cmdpiece)
            end
            
            -- is this an identity column without 'not for replication' marking?
            if (@isidentitycolumn = 1) and 
               @is_identitynotforreplication = 0
            begin
                -- turning identity insert on is phase 7
                set @cmdpiece = '
            set identity_insert ' + @qualified_name + ' on'
                insert into @tempcmd (phase, cmdtext) values (20, @cmdpiece)

                -- turning identity insert on is phase 13
                set @cmdpiece = '
            set identity_insert ' + @qualified_name + ' off'
                insert into @tempcmd (phase, cmdtext) values (250, @cmdpiece)
            end
        end

Next_Column:
        -- now set up to repeat the loop with the next column
        select @colid = min (column_id) from sys.columns where object_id = @sync_objid and column_id > @colid 
            
        set @colname = NULL
        if @colid is not null
            select top 1 @colname = QUOTENAME(C.name), 
            @unquoted_colname = C.name,
            @isidentitycolumn = C.is_identity,
            @typename = type_name(C.user_type_id), 
            @base_typename = type_name(C.system_type_id), 
            @schname=case when S.name<>'sys' and S.name<>'dbo'
                                then QUOTENAME(S.name)+'.' else '' end, 
            @len = C.max_length,
            @prec = C.precision, 
            @scale = C.scale
            from sys.columns C  
                    INNER JOIN sys.types T ON C.user_type_id = T.user_type_id
                    INNER JOIN sys.schemas S ON T.schema_id = S.schema_id            
            where C.object_id = @sync_objid and C.column_id = @colid
              
            select @isidentitycolumn = is_identity, 
               @iscomputed=is_computed, 
               @xtype=user_type_id, 
               @isrowguidcol = is_rowguidcol,
               @is_identitynotforreplication = convert(bit, isnull(columnproperty(@id, name, 'IsIdNotForRepl'), 0)) 
            from sys.columns 
            where object_id = @id and QUOTENAME(name) = @colname
            
        if @base_typename='nvarchar' or @base_typename='nchar' -- a unit of nchar takes 2 bytes
            select @len = @len/2
        set @colordinal = @colordinal + 1
        set @colnumber = @colnumber + 1
    end
    select @rownumber = @rownumber + 1
end

if @maintainsmetadata = 1 and @partition_options = 0 and @atpublisher = 1
        and exists (
                                        select * from dbo.sysmergearticles 
                                        where nickname = @tablenick 
                                        and pubid in 
                                        (
                                                select pubid from dbo.sysmergepublications where use_partition_groups <= 0
                                        )
                                )
begin
    -- now for each article for which this article is the parent see if inserting the rows that we
    -- inserted in this proc causes some child rows to qualify. If so update the generation and partchange gen
    -- for the parent row (row in this article) to 0.
    declare @joinnick int
    declare @qualified_jointable nvarchar(517)
    declare @unqualified_jointable nvarchar(300)
    declare @filter_clause nvarchar(2000)
    declare @tablealias sysname
    declare @join_tables_check_phase int

    select @join_tables_check_phase = 1000
    declare f_c CURSOR LOCAL FAST_FORWARD for  select art_nickname, join_filterclause 
        from dbo.sysmergesubsetfilters where join_nickname = @tablenick and pubid = @pubid and (filter_type & 1) = 1
        FOR READ ONLY
    open f_c
    fetch next from f_c into @joinnick, @filter_clause
    while (@@fetch_status <> -1)
    begin
        exec @retcode= sys.sp_MStablenamefromnick @joinnick, @qualified_jointable out, NULL, @unqualified_jointable out
        if @@error<>0 or @retcode<>0 
        begin
            close f_c
            deallocate f_c
            goto Failure
        end
        
        select @tablealias = quotename(name) from sys.objects where object_id=@id

        select @cmdpiece = '
        update dbo.MSmerge_contents with (rowlock)
            set generation = @gen_cur, partchangegen = @gen_cur
        from ('
        insert into @tempcmd (phase, cmdtext) values (@join_tables_check_phase, @cmdpiece)

        -- list of rowguids will be in phase @join_tables_check_phase+10
        select @phaseid = @join_tables_check_phase+10
        insert into @tempcmd (phase, cmdtext) select phase, cmdtext from sys.fn_MSgetrowguidvirtualtable(@phaseid, @batchingfactor) order by step

        select @cmdpiece = '
        ) as rows
        inner join dbo.MSmerge_contents cont with (rowlock, READPAST) 
        on cont.rowguid = rows.rowguid 
        and cont.tablenick = ' + @tablenickstr + '
        where rows.rowguid is not NULL and
              rows.rowguid in 
                (select rows.rowguid 
                    from ('
        insert into @tempcmd (phase, cmdtext) values (@join_tables_check_phase+20, @cmdpiece)

        -- list of rowguids
        select @phaseid = @join_tables_check_phase+30
        insert into @tempcmd (phase, cmdtext) select phase, cmdtext from sys.fn_MSgetrowguidvirtualtable(@phaseid, @batchingfactor) order by step
        select @cmdpiece = '
                         ) as rows,  
                         ' + @qualified_name + ' ' + @tablealias + ' with (rowlock, READPAST) ,
                         ' + @qualified_jointable + ' ' + @unqualified_jointable + ' with (rowlock)
                     where ' + @tablealias + '.' + @rgcolname + ' = rows.rowguid
                                                        and rows.rowguid is not null
                            and ' + @filter_clause + '
                 )
        if @@error<>0
        begin
            set @errcode= 3
            goto Failure
        end'
        insert into @tempcmd (phase, cmdtext) values (@join_tables_check_phase+40, @cmdpiece)

        select @join_tables_check_phase = @join_tables_check_phase+50
        fetch next from f_c into @joinnick, @filter_clause
    end
    close f_c
    deallocate f_c
end

-- Now we select out the command text pieces in proper order so that our caller,
-- xp_execresultset will execute the command that creates the stored procedure.
select cmdtext from @tempcmd order by phase, step

--drop table @tempcmd

return(0)


Failure:
    --drop table @tempcmd
    return(1)

GO
GRANT EXECUTE ON [sys].[sp_MSmakebatchinsertproc] TO [public] AS [dbo]
GO
