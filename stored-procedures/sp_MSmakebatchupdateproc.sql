SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSmakebatchupdateproc]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSmakebatchupdateproc] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSmakebatchupdateproc]
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
declare @schname                        nvarchar(140)  
declare @isidentitycolumn               bit
declare @len                            smallint
declare @prec                           int
declare @scale                          int
declare @tablenick                      int
declare @tablenickstr                   nvarchar(12)
declare @cmdpiece                       nvarchar(4000)
declare @article_name                   sysname
declare @maintainsmetadata              bit
declare @colid int -- index in sys.columns, used to iterate through sys.columns
declare @colordinal int -- index in @setbm, used to interate actual data sent across
declare @colordstr nvarchar(5) -- @colordinal stringification
declare @colcount int
declare @maxparams int
declare @batchingfactor int
declare @rownumber int
declare @rownumberstr nvarchar(5)
declare @updatecolumnsstarted bit
declare @colnumber int
declare @colidstr nvarchar(5)
declare @colalias nvarchar(100)
declare @isrowguidcol tinyint
declare @partition_options tinyint
declare @atpublisher bit
declare @publication_number smallint
declare @rgcolname nvarchar(140)
declare @unquoted_colname sysname
declare @is_filtering_column bit
declare @filtering_column_check_start_phase int
declare @unfiltered_column_found bit
declare @filtering_column_number int
declare @maxschemaguid uniqueidentifier
declare @command1 nvarchar(4000)
declare @command2 nvarchar(4000)
declare @command3 nvarchar(4000)
declare @command4 nvarchar(4000)
declare @max_colv_size_in_bytes int
declare @qualified_sync_view nvarchar(517)
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
@partition_options = partition_options, @schema_option = schema_option,
@tablenick = nickname
from dbo.sysmergepartitioninfoview where artid = @artid and pubid=@pubid
if @tablenick is NULL
    return (1)

set @tablenickstr = rtrim(convert(nchar, @tablenick))

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


select @updatecolumnsstarted = 0

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

select top 1 @publication_number = publication_number 
from dbo.sysmergepublications 
where pubid = @pubid


-- compute batching factor. For each row we need 
-- max params is 1024-2 for the first 2 parameters which is number of rows to be inserted, partition id
select @maxparams=1024-2

-- subtract one more since we have a @maxschemaguidforarticle parameter on the publisher
if @atpublisher = 1
    select @maxparams = @maxparams - 1

if @id = @sync_objid
    select @colcount = count(*) from sys.columns where object_id=@id and is_computed=0 and user_type_id<>type_id('timestamp') and is_identity=0
else
    select @colcount = count(*) 
        from sys.columns cs inner join sys.columns co on co.object_id=@id and co.name = cs.name
    where cs.object_id = @sync_objid and 
            co.is_computed=0 and co.user_type_id<>type_id('timestamp') and co.is_identity=0 

-- for regular articles for each row we need rowguid, setbm, metadata_type, lineage_old, generation, lineage_new, colv
-- in addition to the list of user table columns. For download only articles we only need rowguid and setbm
if 1 = @maintainsmetadata
    select @colcount = @colcount + 7
else
    select @colcount = @colcount + 2

select @batchingfactor = @maxparams/@colcount
if @batchingfactor > 100
    select @batchingfactor = 100

select @unfiltered_column_found = 0
if @sync_objid = @id
    select @colid = min(column_id) from sys.columns where object_id = @id and is_computed=0 and user_type_id<>type_id('timestamp') 
else
    select @colid = min(cs.column_id) 
        from sys.columns cs inner join sys.columns co on co.object_id=@id and co.name = cs.name
    where cs.object_id = @sync_objid and 
          co.is_computed=0 and co.user_type_id<>type_id('timestamp') 

select top 1 @colname = QUOTENAME(C.name), 
    @unquoted_colname = C.name,
    @typename = type_name(C.user_type_id), 
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
while (@colname is not null)
begin
    if (@isidentitycolumn = 1 or @iscomputed=1 OR type_name(@xtype)='timestamp')
        goto Next_Column1

    if @isrowguidcol = 1
        goto Next_Column1
    
    set @is_filtering_column = 0
    -- does updating this column change membership in a partial replica? 
    
    if exists (select * from dbo.sysmergearticles 
        where objid = @id and pubid = @pubid and sys.fn_MSisfilteredcolumn(subset_filterclause, @unquoted_colname, @id) = 1)
        set @is_filtering_column = 1
    else if exists (select * from dbo.sysmergesubsetfilters
        where art_nickname = @tablenick and pubid = @pubid and sys.fn_MSisfilteredcolumn(join_filterclause, @unquoted_colname, @id) = 1)
        set @is_filtering_column = 1
    else if exists (select * from dbo.sysmergesubsetfilters
        where join_nickname = @tablenick and pubid = @pubid and sys.fn_MSisfilteredcolumn(join_filterclause, @unquoted_colname, @id) = 1)
        set @is_filtering_column = 1
    if @is_filtering_column = 0
        select @unfiltered_column_found = 1
    

Next_Column1:
    -- now set up to repeat the loop with the next column
    select @colid = min (column_id) from sys.columns where object_id = @sync_objid and column_id > @colid 
        
    set @colname = NULL
    if @colid is not null
        select top 1 @colname = QUOTENAME(C.name), 
        @unquoted_colname = C.name,
        @isidentitycolumn = C.is_identity,
        @typename = type_name(C.user_type_id), 
        @len = C.max_length,
        @schname=case when S.name<>'sys' and S.name<>'dbo'
                                    then QUOTENAME(S.name)+'.' else '' end, 
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
end

-- the following is true if the only columns in the table are all filtering columns
if @unfiltered_column_found = 0
begin
    -- there is no point trying to create a update batch proc.
    -- just create an empty proc
    select 'create procedure dbo.'  + QUOTENAME(@procname) + '
    as
        -- do nothing
        select 1
    go'
    return 0
end


-- create temp table to select the command text out of
declare @tempcmd table (phase int NOT NULL, step int identity NOT NULL, cmdtext nvarchar(4000) collate database_default null)

-- phase 0 : create procedure and fixed part of argument list
if @atpublisher = 1
begin
    set @cmdpiece = 'create procedure dbo.'  + QUOTENAME(@procname) + ' (
        @maxschemaguidforarticle uniqueidentifier, 
        @rows_tobe_updated int,
        @partition_id int = null '
    insert into @tempcmd (phase, cmdtext) values (0, @cmdpiece)
end
else
begin
    set @cmdpiece = 'create procedure dbo.'  + QUOTENAME(@procname) + ' (
        @rows_tobe_updated int,
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
    declare @publication_number smallint
    declare @filtering_column_updated bit
    declare @rows_updated int
    declare @cont_rows_updated int
    declare @rows_in_syncview int
    
    set nocount on
    
    set @errcode= 0
    set @publication_number = ' + convert(nvarchar(10), @publication_number) + '
    
    if ({ fn ISPALUSER(''' + convert(nvarchar(36),@pubid) + ''') } <> 1)
    begin
        RAISERROR (14126, 11, -1)
        return 4
    end

    if @rows_tobe_updated is NULL or @rows_tobe_updated <=0
        return 0

    select @filtering_column_updated = 0
    select @rows_updated = 0
    select @cont_rows_updated = 0 '

insert into @tempcmd (phase, cmdtext) values (20, @cmdpiece)

-- phase 22 - check the max schema guid for article and error out if they do not match
if @atpublisher = 1
begin
    set @cmdpiece= '
    declare @maxschemaguid      uniqueidentifier
    select @maxschemaguid = ''' + convert(nvarchar(36),@maxschemaguid) + '''
    if ((@maxschemaguidforarticle IS NOT NULL) and (@maxschemaguid <> @maxschemaguidforarticle))
    begin
        RAISERROR (25007, 11, -1)
        return 5
    end'
    insert into @tempcmd (phase, cmdtext) values (22, @cmdpiece)
end

/*
** Do not allow out of partition updates at the publisher.
** Check to see if the rows being updated are in the partition
** before updating them.
*/
if @atpublisher = 1 AND @partition_options>0 and @qualified_sync_view is not NULL
begin
    -- for partition_options > 0 we will not allow out of partition inserts
        select @cmdpiece = '
     select @rows_in_syncview = count (*) from ' + @qualified_sync_view + ' syncview with (READPAST)
     where syncview.' + @rgcolname + ' in 
     ('
        insert into @tempcmd (phase, cmdtext) values (23, @cmdpiece)
        -- phase 23 will be rowguids
        insert into @tempcmd (phase, cmdtext) select phase, cmdtext from sys.fn_MSgetrowguids(23, @batchingfactor) order by step
        select @cmdpiece = '
     )
 
     if @rows_in_syncview <> @rows_tobe_updated
     begin
        raiserror(20733, 16, -1, ''' + sys.fn_replreplacesinglequote(@tablename) + ''', ' + convert(char(3), @partition_options) + ')
        return 3
     end'

    insert into @tempcmd (phase, cmdtext) values (23, @cmdpiece)
end


    set @cmdpiece= '
    begin tran
    save tran batchupdateproc '
insert into @tempcmd (phase, cmdtext) values (25, @cmdpiece)

-- phase 50 onwards will be all the checks to see if a filtering column has been
-- updated. If a filtering column has been updated we will get out of the batched
-- update proc. Merge agent should revert back to singleton updates

-- phase 40000 is where the update statement starts
select @cmdpiece = '
    update ' + @qualified_name + ' with (rowlock)
    set ' 
insert into @tempcmd (phase, cmdtext) values (40000, @cmdpiece)
-- phase 40100 will contain all the sets c1=@p1 etc.    
select @cmdpiece = '
    from ('
insert into @tempcmd (phase, cmdtext) values (40200, @cmdpiece)
-- phase 40300 will have the virtual table definition

if 1 = @maintainsmetadata
begin
    select @cmdpiece = ') as rows
    inner join ' + @qualified_name + ' t with (rowlock) on rows.rowguid = t.' + @rgcolname + '
        and rows.rowguid is not null
    left outer join dbo.MSmerge_contents cont with (rowlock) on rows.rowguid = cont.rowguid 
    and cont.tablenick = ' + @tablenickstr + '
    where  ((rows.metadata_type = 2 and cont.rowguid is not NULL and cont.lineage = rows.lineage_old) or
           (rows.metadata_type = 3 and cont.rowguid is NULL))
           and rows.rowguid is not null
    
    select @rowcount = @@rowcount, @error = @@error'
    insert into @tempcmd (phase, cmdtext) values (40400, @cmdpiece)
end
else
begin
    select @cmdpiece = ') as rows
    inner join ' + @qualified_name + ' t with (rowlock) on rows.rowguid = t.' + @rgcolname + '
    and rows.rowguid is not NULL
    option (force order, loop join)
    select @rowcount = @@rowcount, @error = @@error'
    insert into @tempcmd (phase, cmdtext) values (40400, @cmdpiece)
end
select @cmdpiece = '
    select @rows_updated = @rowcount
    if (@rows_updated <> @rows_tobe_updated) or (@error <> 0)
    begin
        raiserror(20695, 16, -1, @rows_updated, @rows_tobe_updated, ''' + sys.fn_replreplacesinglequote(@tablename) + ''')
        set @errcode= 3
        goto Failure
    end'
insert into @tempcmd (phase, cmdtext) values (40500, @cmdpiece)

-- insert or update the contents entry
if 1 = @maintainsmetadata
begin
    select @cmdpiece = '
    update dbo.MSmerge_contents with (rowlock)
    set generation = rows.generation,
        lineage = rows.lineage_new,
        colv1 = rows.colv
    from ('
    insert into @tempcmd (phase, cmdtext) values (41000, @cmdpiece)
    -- phase 41100 is the virtual table containing just the metadata new columns
    select @cmdpiece = '
    ) as rows
    inner join dbo.MSmerge_contents cont with (rowlock) 
    on cont.rowguid = rows.rowguid and cont.tablenick = ' + @tablenickstr + '
    and rows.rowguid is not NULL 
    and rows.lineage_new is not NULL
    option (force order, loop join)
    select @cont_rows_updated = @@rowcount, @error = @@error
    if @error<>0
    begin
        set @errcode= 3
        goto Failure
    end'
    insert into @tempcmd (phase, cmdtext) values (41200, @cmdpiece)
    
    select @cmdpiece = '
    if @cont_rows_updated <> @rows_tobe_updated
    begin'
    insert into @tempcmd (phase, cmdtext) values (48000, @cmdpiece)
    if @partition_options > 1 and @atpublisher = 1
    begin
        select @cmdpiece = '
        if @partition_id is not null
        begin
            insert into dbo.MSmerge_current_partition_mappings with (rowlock)
            (tablenick, rowguid, publication_number, partition_id)
            select distinct ' + @tablenickstr + ', rows.rowguid, @publication_number, @partition_id
            from ('
        insert into @tempcmd (phase, cmdtext) values (48000, @cmdpiece)
        -- phase 48100 will be virtual table with the list of rowguids and lineage
        select @cmdpiece = '
            ) as rows
            left outer join dbo.MSmerge_contents cont with (rowlock) 
            on cont.rowguid = rows.rowguid and cont.tablenick = ' + @tablenickstr + '
            and rows.rowguid is not NULL
            and      rows.lineage_new is not null
            where    cont.rowguid is NULL
            and rows.rowguid is not null
            and      rows.lineage_new is not null
            
            if @@error<>0
            begin
                set @errcode= 3
                goto Failure
            end
        end'
        insert into @tempcmd (phase, cmdtext) values (48200, @cmdpiece)
    end
    -- insert into contents
    select @cmdpiece = '
        insert into dbo.MSmerge_contents with (rowlock)
        (tablenick, rowguid, lineage, colv1, generation)
        select ' + @tablenickstr + ', rows.rowguid, rows.lineage_new, rows.colv, rows.generation
        from ('
    insert into @tempcmd (phase, cmdtext) values (48300, @cmdpiece)
    -- phase 48400 will be virtual table with the list of rowguids and metadata
    select @cmdpiece = '
        ) as rows
        left outer join dbo.MSmerge_contents cont with (rowlock) 
        on cont.rowguid = rows.rowguid and cont.tablenick = ' + @tablenickstr + '
        and rows.rowguid is not NULL
        and rows.lineage_new is not NULL
        where cont.rowguid is NULL
        and rows.rowguid is not NULL
        and rows.lineage_new is not NULL
        
        if @@error<>0
        begin
            set @errcode= 3
            goto Failure
        end
    end'
    insert into @tempcmd (phase, cmdtext) values (48500, @cmdpiece)
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
    insert into @tempcmd (phase, cmdtext) values (49000, @cmdpiece)
end

select @cmdpiece = '
    commit tran
    return 1

Failure:
    rollback tran batchupdateproc
    commit tran
    return 0
end
'
insert into @tempcmd (phase, cmdtext) values (50000, @cmdpiece)

-- this loop constructs the formal parameter declarations, the update statement with actual column names and
-- the union clause which does a union over all rows.
-- phase 10 is the declarations
select @command1 = ''
select @command2 = ''
select @command3 = ''
select @command4 = ''
set @colordinal = 1
set @rownumber = 1
select @filtering_column_check_start_phase = 0
while @rownumber <= @batchingfactor
begin
    -- insert the metadada parameters for this row.
    set @rownumberstr = convert(nvarchar(5), @rownumber)

    if 1 = @maintainsmetadata
    begin
        select @command1 = @command1 + ',
    @rowguid' + @rownumberstr + ' uniqueidentifier = NULL,
    @setbm' + @rownumberstr + ' varbinary(125) = NULL,
    @metadata_type' + @rownumberstr + ' tinyint = NULL,
    @lineage_old' + @rownumberstr + ' varbinary(311) = NULL,
    @generation' + @rownumberstr + ' bigint = NULL,
    @lineage_new' + @rownumberstr + ' varbinary(311) = NULL,
    @colv' + @rownumberstr + ' varbinary(' + convert(nvarchar(13), @max_colv_size_in_bytes) + ') = NULL'
        --insert into @tempcmd (phase, cmdtext) values (10, @cmdpiece)

        -- phase 40300 is for update of user table where we need rowguid, setbm, metadata_type and lineage_old
        -- to the virtual table in this phase we will add the user table columns
        if @rownumber = 1
            select @command2 = @command2 + '
    select @rowguid' + @rownumberstr + ' as rowguid, @setbm' + @rownumberstr + ' as setbm, @metadata_type' + @rownumberstr + ' as metadata_type, @lineage_old' + @rownumberstr + ' as lineage_old'
        else
            select @command2 = @command2 + ' union all
    select @rowguid' + @rownumberstr + ' as rowguid, @setbm' + @rownumberstr + ' as setbm, @metadata_type' + @rownumberstr + ' as metadata_type, @lineage_old' + @rownumberstr + ' as lineage_old'
        --insert into @tempcmd (phase, cmdtext) values (40300, @cmdpiece)

        -- phase 41100 is the virtual table containing just the metadata new columns, used to update contents
        if @rownumber = 1
            select @command3 = @command3 + '
    select @rowguid' + @rownumberstr + ' as rowguid, @generation' + @rownumberstr + ' as generation, @lineage_new' + @rownumberstr + ' as lineage_new, @colv' + @rownumberstr + ' as colv'
        else
            select @command3 = @command3 + ' union all
    select @rowguid' + @rownumberstr + ' as rowguid, @generation' + @rownumberstr + ' as generation, @lineage_new' + @rownumberstr + ' as lineage_new, @colv' + @rownumberstr + ' as colv'
        if (datalength(@command3) > 7500) or (@rownumber = @batchingfactor)
        begin
            insert into @tempcmd (phase, cmdtext) values (41100, @command3)

            -- phase 48400 is for the virtual table that inserts into contents
            insert into @tempcmd (phase, cmdtext) values (48400, @command3)

            select @command3 = ''
        end
                    
        -- this will be used to insert into current partition mappings
        if @partition_options > 1 and @atpublisher = 1
        begin
            if @rownumber = 1
                select @command4 = @command4 + '
                select @rowguid' + @rownumberstr + ' as rowguid, @lineage_new' + @rownumberstr + ' as lineage_new'
            else 
                select @command4 = @command4 + ' union all
                select @rowguid' + @rownumberstr + ' as rowguid, @lineage_new' + @rownumberstr + ' as lineage_new'
            if (datalength(@command4) > 7500) or (@rownumber = @batchingfactor)
            begin
                insert into @tempcmd (phase, cmdtext) values (48100, @command4) 
                select @command4 = ''
            end
        end
    end
    else
    begin
        select @command1 = @command1 + ',
        @rowguid' + @rownumberstr + ' uniqueidentifier = NULL,
        @setbm' + @rownumberstr + ' varbinary(125) = NULL'
        --insert into @tempcmd (phase, cmdtext) values (10, @cmdpiece)

        if @rownumber = 1
            select @command2 = @command2 + '
            select @rowguid' + @rownumberstr + ' as rowguid, @setbm' + @rownumberstr + ' as setbm'
        else 
            select @command2 = @command2 + ' union all
            select @rowguid' + @rownumberstr + ' as rowguid, @setbm' + @rownumberstr + ' as setbm'
        --insert into @tempcmd (phase, cmdtext) values (40300, @cmdpiece)
    end


    -- now loop over columns 
    select @colnumber = 1
    select @filtering_column_number = 1
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
    @len = C.max_length,
    @schname=case when S.name<>'sys' and S.name<>'dbo'
                                    then QUOTENAME(S.name)+'.' else '' end, 
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
        if (@isidentitycolumn = 1 or @iscomputed=1 OR type_name(@xtype)='timestamp')
            goto Next_Column

        set @colordstr = convert(nvarchar(4), @colordinal)
        set @colidstr = convert(nvarchar(4), @colid)

        if @generate_subscriber_proc = 0
            exec @retcode = sys.sp_MSmaptype @typename out, @len, @prec, @scale
        else
            exec @retcode = sys.sp_MSmap_subscriber_type @xtype, @len, @prec, @scale, @schema_option, @typename out, @schname out
        if @@error<>0 OR @retcode <>0 return (1)
        
        select @argname = '@p' + rtrim(convert(nchar, @colordinal))
        select @colalias = 'c' + @colidstr
        
        -- add to argument list (phase 1)
        set @command1 = @command1 + ',
    ' + @argname + ' ' + @schname + @typename + ' = NULL'
        if (datalength(@command1)>7000) or (@rownumber = @batchingfactor)
        begin 
            insert into @tempcmd (phase, cmdtext) values (10, @command1)
            select @command1 = ''
        end

        if @isrowguidcol = 1
            goto Next_Column
        
        set @is_filtering_column = 0
        -- does updating this column change membership in a partial replica? 
        
        if exists (select * from dbo.sysmergearticles 
            where objid = @id and pubid = @pubid and sys.fn_MSisfilteredcolumn(subset_filterclause, @unquoted_colname, @id) = 1)
            set @is_filtering_column = 1
        else if exists (select * from dbo.sysmergesubsetfilters
            where art_nickname = @tablenick and pubid = @pubid and sys.fn_MSisfilteredcolumn(join_filterclause, @unquoted_colname, @id) = 1)
            set @is_filtering_column = 1
        else if exists (select * from dbo.sysmergesubsetfilters
            where join_nickname = @tablenick and pubid = @pubid and sys.fn_MSisfilteredcolumn(join_filterclause, @unquoted_colname, @id) = 1)
            set @is_filtering_column = 1
        if @is_filtering_column = 1
        begin
            declare @start_phase int

            select @start_phase = @filtering_column_check_start_phase + @filtering_column_number*50
            -- we need to check if any partitioning/filtering column is being updated in the beginning of the
            -- batched update proc. Add the code for doing that here.
            -- if so abort the batched update proc and the merge agent should revert to singleton updates. 
            if @rownumber = 1
            begin
                select @cmdpiece = '
    select @filtering_column_updated = 0

    -- case 1 of setting the filtering column where we are setting it to NULL and the table has a non NULL value for this column
    select @filtering_column_updated = 1 from 
        ('
                insert into @tempcmd (phase, cmdtext) values (@start_phase, @cmdpiece)
                -- phase 60 is the rows virtual table contains rowguid, filtering column and setbm
                select @cmdpiece = '
            select @rowguid' + @rownumberstr + ' as rowguid, ' + @argname + ' as ' + @colalias + ', @setbm' + @rownumberstr + ' as setbm'
                insert into @tempcmd (phase, cmdtext) values (@start_phase+10, @cmdpiece)
                
                select @cmdpiece = '
        ) as rows
        inner join ' + @qualified_name + ' t with (rowlock) 
        on t.' + @rgcolname + ' = rows.rowguid and rows.rowguid is not NULL
        where rows.' + @colalias + ' is NULL and sys.fn_IsBitSetInBitmask(rows.setbm, ' + @colordstr + ') <> 0 and t.' + @colname + ' is not NULL
        
    if @filtering_column_updated = 1
    begin
        raiserror(20694, 16, -1, ''' + sys.fn_replreplacesinglequote(@tablename) + ''', ''' + sys.fn_replreplacesinglequote(@colname) + ''')
        set @errcode=4
        goto Failure
    end

    -- case 2 of setting the filtering column where we are setting it to a not null value and the value is not equal to the value in the table
    select @filtering_column_updated = 1 from 
        ('
                insert into @tempcmd (phase, cmdtext) values (@start_phase+20, @cmdpiece)
                -- following phase is the rows virtual table contains rowguid, filtering column and setbm
                select @cmdpiece = '
            select @rowguid' + @rownumberstr + ' as rowguid, ' + @argname + ' as ' + @colalias
                insert into @tempcmd (phase, cmdtext) values (@start_phase+30, @cmdpiece)

                select @cmdpiece = '
        ) as rows
        inner join ' + @qualified_name + ' t with (rowlock) 
        on t.' + @rgcolname + ' = rows.rowguid and rows.rowguid is not NULL
        where rows.' + @colalias + ' is not NULL and (t.' + @colname + ' is NULL or t.' + @colname + ' <> rows.' + @colalias + ' )   

    if @filtering_column_updated = 1
    begin
        raiserror(20694, 16, -1, ''' + sys.fn_replreplacesinglequote(@tablename) + ''', ''' + sys.fn_replreplacesinglequote(@colname) + ''')
        set @errcode=4
        goto Failure
    end'
                insert into @tempcmd (phase, cmdtext) values (@start_phase+40, @cmdpiece)
            end
            else
            begin
                select @cmdpiece = ' union all
            select @rowguid' + @rownumberstr + ' as rowguid, ' + @argname + ' as ' + @colalias + ', @setbm' + @rownumberstr + ' as setbm'
                insert into @tempcmd (phase, cmdtext) values (@start_phase+10, @cmdpiece)
                select @cmdpiece = ' union all
            select @rowguid' + @rownumberstr + ' as rowguid, ' + @argname + ' as ' + @colalias 
                insert into @tempcmd (phase, cmdtext) values (@start_phase+30, @cmdpiece)
            end
            select @filtering_column_number = @filtering_column_number + 1
            goto Next_Column
        end

        -- only non filtering columns will be part of the update statement
        -- peformance optimization to concatenate.
        if (@colid%10) = 0
            select @command2 = @command2 + ', 
            '
        else
            select @command2 = @command2 + ', '
            
        select @command2 = @command2 + @argname + ' as ' + @colalias
        -- phase 40300 should also contain the list of user columns and metadata columns.
        if (datalength(@command2)>7500) or (@rownumber = @batchingfactor)
        begin
            insert into @tempcmd (phase, cmdtext) values (40300, @command2)
            select @command2 = ''
        end
        if @rownumber = 1
        begin
            -- this is the actual update statement with set c1=rows.c1
            if @updatecolumnsstarted = 0
            begin
                select @updatecolumnsstarted = 1
                select @cmdpiece = ''
            end
            else
                select @cmdpiece = ','
            -- this is the select list from the virual table to be specified in the
            -- select statement from which we insert
            select @cmdpiece = @cmdpiece + '
        ' + @colname + ' = case when rows.' + @colalias + ' is NULL then (case when sys.fn_IsBitSetInBitmask(rows.setbm, ' + @colordstr + ') <> 0 then rows.' + @colalias + ' else t.' + @colname + ' end) else rows.' + @colalias + ' end '
            insert into @tempcmd (phase, cmdtext) values (40100, @cmdpiece)
        end

Next_Column:
        -- now set up to repeat the loop with the next column
        if @sync_objid = @id
            select @colid = min (column_id) from sys.columns where object_id = @id and is_computed=0 and user_type_id<>type_id('timestamp') and column_id > @colid 
        else
            select @colid = min(cs.column_id) 
                from sys.columns cs inner join sys.columns co on co.object_id=@id and co.name = cs.name
            where cs.object_id = @sync_objid and 
                  co.is_computed=0 and co.user_type_id<>type_id('timestamp') and cs.column_id > @colid 
	
            
        set @colname = NULL
        if @colid is not null

            select top 1 @colname = QUOTENAME(C.name), 
            @unquoted_colname = C.name,
            @isidentitycolumn = C.is_identity,
            @typename = type_name(C.user_type_id), 
            @base_typename = type_name(C.system_type_id), 
            @len = C.max_length,
            @schname=case when S.name<>'sys' and S.name<>'dbo'
                                        then QUOTENAME(S.name)+'.' else '' end, 
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

-- Now we select out the command text pieces in proper order so that our caller,
-- xp_execresultset will execute the command that creates the stored procedure.
select cmdtext from @tempcmd order by phase, step

--drop table @tempcmd

return(0)


Failure:
    --drop table @tempcmd
    return(1)

GO
GRANT EXECUTE ON [sys].[sp_MSmakebatchupdateproc] TO [public] AS [dbo]
GO
