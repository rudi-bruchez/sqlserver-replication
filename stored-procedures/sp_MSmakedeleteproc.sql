SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSmakedeleteproc]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSmakedeleteproc] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSmakedeleteproc]
	@tablename [sysname],
	@ownername [sysname],
	@procname [sysname],
	@pubid [uniqueidentifier],
	@artid [uniqueidentifier],
	@generate_subscriber_proc [bit],
	@destination_owner [sysname]
WITH EXECUTE AS CALLER
AS
declare @retcode            smallint
declare @argname            nvarchar(10)
declare @varname            nvarchar(10)
declare @cmdpiece           nvarchar(4000)
declare @cmdpiece2          nvarchar(4000)
declare @qualified_name     nvarchar(540)
declare @sync_objid         int
declare @tablenick          int
declare @rgcol              nvarchar(270)
declare @batching_factor    int
declare @id int
declare @maintainsmetadata bit
declare @escaped_qualified_name     nvarchar(540)
declare @partition_options tinyint
declare @atpublisher bit
declare @publication_number smallint
declare @rownumber int
declare @rownumberstr nvarchar(10)
declare @qualified_sync_view nvarchar(540)
declare @rgcolname nvarchar(270)



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
select @rgcol = quotename(name) from sys.columns where object_id = @id and is_rowguidcol = 1

select @sync_objid=sync_objid, @tablenick = nickname, @partition_options = partition_options
from dbo.sysmergepartitioninfoview where artid=@artid and pubid=@pubid
if @tablenick is NULL 
    return (1)
    
if @partition_options = 2
begin
    -- if this is a republisher of this article, and we are currently
    -- downloading from the top-level publisher, then pretend that this is 
    -- not a well-partitioned article. This is done such that the partition evaluation
    -- and setrowmetadata is done appropriately.
    if sys.fn_MSmerge_islocalpubid(@pubid) = 0 
        and exists (select * from dbo.sysmergearticles 
                    where nickname = @tablenick
                    and sys.fn_MSmerge_islocalpubid(pubid) = 1)
        select @partition_options = 0
end

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

select @batching_factor = 100


set @cmdpiece= 'SET ANSI_NULLS ON SET QUOTED_IDENTIFIER ON'
exec (@cmdpiece)
if @@error<>0 return(1)

-- create temp table to select the command text out of
declare @tempcmd table (phase int NOT NULL, step int identity NOT NULL, cmdtext nvarchar(4000) collate database_default null)

select @cmdpiece = '
create procedure dbo.'  + QUOTENAME(@procname) + '
(
    @rowstobedeleted int, 
    @partition_id int = NULL ' 
insert into @tempcmd (phase, cmdtext) values (1, @cmdpiece)

-- end create procedure
select @cmdpiece = '
)
as
begin
'
insert into @tempcmd (phase, cmdtext) values (20, @cmdpiece)

select @cmdpiece = '
    -- this proc returns 0 to indicate error and 1 to indicate success
    declare @retcode    int
    set nocount on
    declare @rows_deleted int
    declare @rows_remaining int
    declare @error int
    declare @tomb_rows_updated int
    declare @publication_number smallint
    declare @rows_in_syncview int
        
    if ({ fn ISPALUSER(''' + convert(nvarchar(36),@pubid) + ''') } <> 1)
    begin       
        RAISERROR (14126, 11, -1)
        return 0
    end
    
    select @publication_number = ' + convert(nvarchar(10), @publication_number) + '

    if @rowstobedeleted is NULL or @rowstobedeleted <= 0
        return 0

    begin tran
    save tran batchdeleteproc
'
insert into @tempcmd (phase, cmdtext) values (30, @cmdpiece)


/*
** Do not allow out of partition deletes at the publisher.
** Check to see if the rows being deleted are in the partition
** before deleting them.
*/
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

select @rgcolname = QUOTENAME(name) from sys.columns where object_id = @id and is_rowguidcol = 1
if @rgcolname is null
    set @rgcolname = 'rowguid'

if @atpublisher = 1 AND @partition_options>0 and @qualified_sync_view is not NULL
begin
    -- for partition_options > 0 we will not allow out of partition inserts
    select @cmdpiece = '
     select @rows_in_syncview = count (*) from ' + @qualified_sync_view + ' syncview with (READPAST)
     where syncview.' + @rgcolname + ' in 
     ('
        insert into @tempcmd (phase, cmdtext) values (35, @cmdpiece)
        -- phase 35 will be rowguids
        insert into @tempcmd (phase, cmdtext) select phase, cmdtext from sys.fn_MSgetrowguids(35, @batching_factor) order by step
        select @cmdpiece = '
     )    
     
     if @rows_in_syncview <> @rowstobedeleted
     begin
        raiserror(20734, 16, -1, ''' + sys.fn_replreplacesinglequote(@tablename) + ''', ' + convert(char(3), @partition_options) + ')
        goto Failure
     end'
    insert into @tempcmd (phase, cmdtext) values (35, @cmdpiece)
end


select @cmdpiece = '
    delete ' + @qualified_name + ' with (rowlock)
    from 
    ('
insert into @tempcmd (phase, cmdtext) values (40, @cmdpiece)
-- phase 50 will be a virtual table with rowguids and metadatainfo for an updatable subscriber
if 0 = @maintainsmetadata
begin
    -- phase 50 will be only rowguids when there is no metadata
    insert into @tempcmd (phase, cmdtext) select phase, cmdtext from sys.fn_MSgetrowguidvirtualtable(50, @batching_factor) order by step
end
select @cmdpiece = ') as rows
    inner join ' + @qualified_name + ' t with (rowlock) on rows.rowguid = t.' + @rgcol + ' and rows.rowguid is not NULL'
insert into @tempcmd (phase, cmdtext) values (60, @cmdpiece)
if 1 = @maintainsmetadata
begin
    select @cmdpiece = '
    left outer join dbo.MSmerge_contents cont with (rowlock) 
    on rows.rowguid = cont.rowguid and cont.tablenick = ' + cast(@tablenick as nvarchar(20)) + ' 
    and rows.rowguid is not NULL
    where ((rows.metadata_type = 3 and cont.rowguid is NULL) or
           ((rows.metadata_type = 5 or  rows.metadata_type = 6) and (cont.rowguid is NULL or cont.lineage = rows.lineage_old)) or
           (cont.rowguid is not NULL and cont.lineage = rows.lineage_old))
           and rows.rowguid is not NULL '
    insert into @tempcmd (phase, cmdtext) values (60, @cmdpiece)
end

select @cmdpiece = '
    select @rows_deleted = @@rowcount, @error = @@error
    if @error<>0
        goto Failure
    if @rows_deleted > @rowstobedeleted
    begin
        -- this is just not possible
        raiserror(20684, 16, -1, ''' + @escaped_qualified_name + ''')
        goto Failure
    end
    if @rows_deleted <> @rowstobedeleted
    begin'
insert into @tempcmd (phase, cmdtext) values (70, @cmdpiece)

if  1 = @maintainsmetadata
begin
    select @cmdpiece = '
        -- we will now check if any of the rows we wanted to delete were not deleted. If the rows were not deleted
        -- by the previous delete because it was already deleted, we will still assume that this is a success
        select @rows_remaining = count(*) from 
        ( '
    insert into @tempcmd (phase, cmdtext) values (80, @cmdpiece)
    -- phase 90 will be the virtual table with the list of rowguids only
    insert into @tempcmd (phase, cmdtext) select phase, cmdtext from sys.fn_MSgetrowguidvirtualtable(90, @batching_factor) order by step
    select @cmdpiece = '
        ) as rows
        inner join ' + @qualified_name + ' t with (rowlock) 
        on t.' + @rgcol + ' = rows.rowguid
        and rows.rowguid is not NULL
        
        if @@error <> 0
            goto Failure
        
        if @rows_remaining <> 0
        begin
            -- failed deleting one or more rows. Could be because of metadata mismatch
            --raiserror(20682, 10, -1, @rows_remaining, ''' + @qualified_name + ''')
            goto Failure
        end        
    end'
    insert into @tempcmd (phase, cmdtext) values (100, @cmdpiece)
end
else
begin
    select @cmdpiece = '
        -- we should never get into this situation since this is a downloadonly article
        raiserror(20683, 16, -1)
        goto Failure
    end'
    insert into @tempcmd (phase, cmdtext) values (100, @cmdpiece)
end

if  1 = @maintainsmetadata
begin
    select @cmdpiece = '
    -- if we get here it means that all the rows that we intend to delete were either deleted by us
    -- or they were already deleted by someone else and do not exist in the user table
    -- we insert a tombstone entry for the rows we have deleted and delete the contents rows if exists

    -- if the rows were previously deleted we still want to update the metadatatype, generation and lineage
    -- in MSmerge_tombstone. We could find rows in the following update also if the trigger got called by
    -- the user table delete and it inserted the rows into tombstone (it would have inserted with type 1)
    update dbo.MSmerge_tombstone with (rowlock)
        set type = case when (rows.metadata_type=5 or rows.metadata_type=6) then rows.metadata_type else 1 end,
            generation = rows.generation,
            lineage = rows.lineage_new
    from 
    ('
    insert into @tempcmd (phase, cmdtext) values (110, @cmdpiece)
    -- phase 120 will be the list of rowguids and metadata
    select @cmdpiece = '
    ) as rows
    inner join dbo.MSmerge_tombstone tomb with (rowlock) 
    on tomb.rowguid = rows.rowguid and tomb.tablenick = ' + cast(@tablenick as nvarchar(20)) + '
    and rows.rowguid is not null
    and rows.lineage_new is not NULL
    option (force order, loop join)
    select @tomb_rows_updated = @@rowcount, @error = @@error
    if @error<>0
        goto Failure'
    insert into @tempcmd (phase, cmdtext) values (130, @cmdpiece)
            
    select @cmdpiece = '
        -- the trigger would have inserted a row in past partition mapping for the currently deleted
        -- row. We need to update that row with the current generation if it exists
        update dbo.MSmerge_past_partition_mappings with (rowlock)
        set generation = rows.generation
    from
    ('
    insert into @tempcmd (phase, cmdtext) values (140, @cmdpiece)
                -- phase 150 will be the list of rowguids and metadata
        select @cmdpiece = '
        ) as rows
        inner join dbo.MSmerge_past_partition_mappings ppm with (rowlock) 
        on ppm.rowguid = rows.rowguid and ppm.tablenick = ' + cast(@tablenick as nvarchar(20)) + ' 
        and ppm.generation = 0
        and rows.rowguid is not NULL
        and rows.lineage_new is not null
        option (force order, loop join)
        if @error<>0
                goto Failure'
        insert into @tempcmd (phase, cmdtext) values (160, @cmdpiece)    

    select @cmdpiece = '
    if @tomb_rows_updated <> @rowstobedeleted
    begin
        -- now insert rows that are not in tombstone
        insert into dbo.MSmerge_tombstone with (rowlock)
            (rowguid, tablenick, type, generation, lineage)
        select rows.rowguid, ' + cast(@tablenick as nvarchar(20)) + ', 
               case when (rows.metadata_type=5 or rows.metadata_type=6) then rows.metadata_type else 1 end, 
               rows.generation, rows.lineage_new
        from 
        ('
    insert into @tempcmd (phase, cmdtext) values (170, @cmdpiece)
    -- phase 180 will be the list of rowguids and metadata
    select @cmdpiece = '
        ) as rows
        left outer join dbo.MSmerge_tombstone tomb with (rowlock) 
        on tomb.rowguid = rows.rowguid 
        and tomb.tablenick = ' + cast(@tablenick as nvarchar(20)) + '
        and rows.rowguid is not NULL and rows.lineage_new is not null
        where tomb.rowguid is NULL 
        and rows.rowguid is not NULL and rows.lineage_new is not null
        
        if @@error<>0
            goto Failure'
    insert into @tempcmd (phase, cmdtext) values (190, @cmdpiece)
    
    if @partition_options > 1 and @atpublisher = 1
        and (exists (select * from dbo.sysmergearticles where len(subset_filterclause) > 0)
                        or exists (select * from dbo.sysmergesubsetfilters))

    begin
        select @cmdpiece = '
        if @partition_id is not null
        begin
            -- now insert rows that are not in tombstone
            insert into dbo.MSmerge_past_partition_mappings with (rowlock)
                (rowguid, tablenick, generation, publication_number, partition_id, reason)
            select rows.rowguid, ' + cast(@tablenick as nvarchar(20)) + ', 
                   rows.generation, @publication_number, @partition_id, 1
            from 
            ('
        insert into @tempcmd (phase, cmdtext) values (200, @cmdpiece)
        -- phase 210 will be the list of rowguids and metadata
        select @cmdpiece = '
            ) as rows
            where rows.rowguid is not NULL and rows.lineage_new is not null
            if @@error<>0
                goto Failure
        end '
        insert into @tempcmd (phase, cmdtext) values (220, @cmdpiece)
    end
    
    if @partition_options = 2 or @partition_options = 3
    begin
        select @cmdpiece = '
        -- now delete the current mapping rows
        delete dbo.MSmerge_current_partition_mappings with (rowlock)
        from 
        ('
        insert into @tempcmd (phase, cmdtext) values (230, @cmdpiece)
        -- phase 240 will be the list of rowguids only
        insert into @tempcmd (phase, cmdtext) select phase, cmdtext from sys.fn_MSgetrowguidvirtualtable(240, @batching_factor) order by step
        select @cmdpiece = '
        ) as rows,
        dbo.MSmerge_current_partition_mappings cont with (rowlock)
        where cont.rowguid = rows.rowguid and cont.tablenick = ' + cast(@tablenick as nvarchar(20)) + '
        and rows.rowguid is not NULL
        option (force order, loop join)
        if @@error<>0 
            goto Failure '
        insert into @tempcmd (phase, cmdtext) values (250, @cmdpiece)
    end
    
    select @cmdpiece = '
        -- now delete the contents rows
        delete dbo.MSmerge_contents with (rowlock)
        from 
        ('
    insert into @tempcmd (phase, cmdtext) values (260, @cmdpiece)
    -- phase 270 will be a list of rowguids only
    insert into @tempcmd (phase, cmdtext) select phase, cmdtext from sys.fn_MSgetrowguidvirtualtable(270, @batching_factor) order by step
    select @cmdpiece = '
        ) as rows, dbo.MSmerge_contents cont with (rowlock)
        where cont.rowguid = rows.rowguid and cont.tablenick = ' + cast(@tablenick as nvarchar(20)) + '
            and rows.rowguid is not NULL
        option (force order, loop join)
        if @@error<>0 
            goto Failure
    end'
    insert into @tempcmd (phase, cmdtext) values (280, @cmdpiece)
end

select @cmdpiece = '
    exec @retcode = sys.sp_MSdeletemetadataactionrequest ''' + convert(nvarchar(36),@pubid) + ''', ' + cast(@tablenick as nvarchar(20))
set @rownumber = 1
while @rownumber <= @batching_factor
begin
    select @cmdpiece = @cmdpiece + ', 
        @rowguid' + convert(nvarchar(3), @rownumber)
    select @rownumber = @rownumber + 1
end
select @cmdpiece = @cmdpiece + '
    if @retcode<>0 or @@error<>0
        goto Failure
'
insert into @tempcmd (phase, cmdtext) values (500, @cmdpiece)

select @cmdpiece = '
    commit tran
    return 1

Failure:
    rollback tran batchdeleteproc
    commit tran
    return 0
end'
insert into @tempcmd (phase, cmdtext) values (1000, @cmdpiece)


select @rownumber = 1
select @cmdpiece = ''
select @cmdpiece2 = ''
while (@rownumber <= @batching_factor)
begin
    select @rownumberstr = convert(nvarchar(10), @rownumber)

    -- add the formal parameter declaration
    if 1 = @maintainsmetadata
    begin
        select @cmdpiece = @cmdpiece + ',
    @rowguid' + @rownumberstr + ' uniqueidentifier = NULL,
    @metadata_type' + @rownumberstr + ' tinyint = NULL,
    @generation' + @rownumberstr + ' bigint = NULL,
    @lineage_old' + @rownumberstr + ' varbinary(311) = NULL,
    @lineage_new' + @rownumberstr + ' varbinary(311) = NULL'
    end
    else
    begin
        select @cmdpiece = @cmdpiece + ',
    @rowguid' + @rownumberstr + ' uniqueidentifier = NULL'
    end
    if (@rownumber % 10) = 0
    begin
        insert into @tempcmd (phase, cmdtext) values (10, @cmdpiece)
        select @cmdpiece = ''
    end

    if 1 = @maintainsmetadata
    begin
        -- virtual table containing metadata and rowguid
        if @rownumber = 1
            select @cmdpiece2 = @cmdpiece2 + ''
        else 
            select @cmdpiece2 = @cmdpiece2 + ' union all '
        select @cmdpiece2 = @cmdpiece2 + '
    select @rowguid' + @rownumberstr + ' as rowguid, @metadata_type' + @rownumberstr + ' as metadata_type,' +
         ' @lineage_old' + @rownumberstr + ' as lineage_old, @lineage_new' + @rownumberstr + ' as lineage_new,' + 
         ' @generation' + @rownumberstr + ' as generation '

        if (@rownumber % 10) = 0
        begin
            insert into @tempcmd (phase, cmdtext) values (50, @cmdpiece2)
            insert into @tempcmd (phase, cmdtext) values (120, @cmdpiece2)                       
            insert into @tempcmd (phase, cmdtext) values (150, @cmdpiece2)
            
            insert into @tempcmd (phase, cmdtext) values (180, @cmdpiece2)
            
            if @partition_options > 1 and @atpublisher = 1 and
                                   (exists (select * from dbo.sysmergearticles where len(subset_filterclause) > 0)
                                        or exists (select * from dbo.sysmergesubsetfilters))
                insert into @tempcmd (phase, cmdtext) values (210, @cmdpiece2)

            select @cmdpiece2 = ''
        end
    end
    select @rownumber = @rownumber+1
end

select cmdtext from @tempcmd order by phase, step
--drop table @tempcmd
GO
GRANT EXECUTE ON [sys].[sp_MSmakedeleteproc] TO [public] AS [dbo]
GO
