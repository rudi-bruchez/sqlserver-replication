SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSmakeinsertproc]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSmakeinsertproc] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSmakeinsertproc]
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
declare @argname                        sysname
declare @id                             int
declare @sync_objid                     int
declare @qualified_name                 nvarchar(270)
declare @qualified_name2                nvarchar(270)
declare @idstr                          nvarchar(100)
declare @iscomputed                     tinyint
declare @xtype                          int
declare @is_identitynotforreplication   bit
declare @permissions                    int
declare @permissions_str                nvarchar(10)
declare @partition_options              tinyint
declare @retcode                        int
declare @colname                        nvarchar(140)
declare @rgcolname                      nvarchar(140)
declare @typename                       nvarchar(258)
declare @base_typename                       nvarchar(140)
declare @schname                          nvarchar(140)  --track the data type owner name if it is CLR UDT
declare @isidentitycolumn               bit
declare @len                            smallint
declare @prec                           int
declare @scale                          int
declare @tablenick                      int
declare @tablenickstr                   nvarchar(12)
declare @cmdpiece                       nvarchar(4000)
declare @maintainsmetadata              bit
declare @colid smallint -- index in sys.columns, used to iterate through sys.columns
declare @colordinal smallint -- index in @setbm, used to interate actual data sent across
declare @colordstr nvarchar(4) -- @colordinal stringification
declare @valuename nvarchar(4000)
declare @atpublisher                    bit
declare @publication_number             smallint
declare @single_hop                     bit
declare @maxschemaguid                  uniqueidentifier
declare @max_colv_size_in_bytes         int
declare @schema_option                  varbinary(8)
set nocount on

-- Check for subscribing permission
exec @retcode=sys.sp_MSreplcheck_subscribe
if @retcode<>0 or @@ERROR<>0 return (0)

if @ownername is NULL or @ownername=''
    select @qualified_name = QUOTENAME(@tablename)
else    
    select @qualified_name = QUOTENAME(@ownername) + '.' + QUOTENAME(@tablename)
    
select @id = object_id(@qualified_name)
if @id is NULL return (1)

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
                                
select @sync_objid = sync_objid, @permissions_str=convert(nvarchar(10),check_permissions), 
       @permissions=check_permissions, @schema_option = schema_option,
       @tablenick = nickname 
    from dbo.sysmergearticles where artid=@artid and pubid=@pubid
if @tablenick is NULL
    return (1)
    
set @tablenickstr = rtrim(convert(nchar, @tablenick))

select @maxschemaguid = sys.fn_GetArticleSchemaVersionGuid(@artid, @pubid)
if @@ERROR <>0 OR @retcode <>0  
    return (1)

select @partition_options = partition_options
from dbo.sysmergepartitioninfo
where pubid = @pubid and artid = @artid

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


/* Get name of rowguidcol. Aliasing doesn't work through a view. */
select @rgcolname = QUOTENAME(name) from sys.columns where object_id = @id and is_rowguidcol = 1
if @rgcolname is null
    set @rgcolname = 'rowguid'

select @qualified_name2 = @qualified_name

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
end
    
select top 1 @publication_number = publication_number 
from dbo.sysmergepublications 
where pubid = @pubid


-- create temp table to select the command text out of
create table #tempcmd (phase int NOT NULL, step int identity NOT NULL, cmdtext nvarchar(4000) collate database_default null)

create table #coltab (colname nvarchar(140), paramname nvarchar(10))

-- insert text pieces that don't repeat for each column

-- phase 0 : create procedure and fixed part of argument list

/* For Yukon version of this proc, add the @maxschemaguidforarticle as the first parameter */
if (0 = @generate_downlevel_procs AND @atpublisher = 1)
begin
    if 1 = @maintainsmetadata
    begin
        set @cmdpiece = 'create procedure dbo.'  + QUOTENAME(@procname) + ' (@maxschemaguidforarticle uniqueidentifier = NULL, @rowguid uniqueidentifier, 
            @generation bigint, @lineage varbinary(311),  @colv varbinary(' + convert(nvarchar(13), @max_colv_size_in_bytes) + ') '
    end
    else
    begin
        set @cmdpiece = 'create procedure dbo.'  + QUOTENAME(@procname) + ' (@maxschemaguidforarticle uniqueidentifier = NULL, @rowguid uniqueidentifier '
    end
end
else
begin
    if 1 = @maintainsmetadata
    begin
        set @cmdpiece = 'create procedure dbo.'  + QUOTENAME(@procname) + ' (@rowguid uniqueidentifier, 
            @generation bigint, @lineage varbinary(311),  @colv varbinary(' + convert(nvarchar(13), @max_colv_size_in_bytes) + ') '
    end
    else
    begin
        set @cmdpiece = 'create procedure dbo.'  + QUOTENAME(@procname) + ' (@rowguid uniqueidentifier '
    end
end

insert into #tempcmd (phase, cmdtext) values (0, @cmdpiece)

-- phase 1 is rest of argument list; goes in during loop over columns
-- phase 2 : paren to close argument list, and variable declarations
select @cmdpiece = ') as
    declare @errcode    int
    declare @retcode    int
    declare @rowcount   int
    declare @error      int
    declare @tablenick  int
    declare @started_transaction bit
    declare @publication_number smallint
    
    set nocount on

    select @started_transaction = 0
    select @publication_number = ' + convert(nvarchar(10), @publication_number)

    insert into #tempcmd (phase, cmdtext) values (2, @cmdpiece)

    -- phases 3,4 are not used
 
    -- phase 6
    set @cmdpiece = '
    set @errcode= 0
    select @tablenick= ' + @tablenickstr + '
    
    if ({ fn ISPALUSER(''' + convert(nvarchar(36),@pubid) + ''') } <> 1)
    begin
        RAISERROR (14126, 11, -1)
        return 4
    end

'

if 1 = @maintainsmetadata
begin
    set @cmdpiece= @cmdpiece + '

    declare @resend int

    set @resend = 0 '
end

if @permissions>0
begin
    select @cmdpiece = @cmdpiece + '
    exec @retcode = sys.sp_MSreplcheck_permission @objid = ' + @idstr + ', @type = 1, @permissions = ' + @permissions_str + '
    if @retcode<>0 or @@ERROR<>0 return (4)'
end 

insert into #tempcmd (phase, cmdtext) values (6, @cmdpiece)


if (0 = @generate_downlevel_procs AND @atpublisher = 1 and @maxschemaguid is not NULL)
begin
    -- phase 5 - check the max schema guid for article and error out if they do not match
    set @cmdpiece= '
    declare @maxschemaguid  uniqueidentifier
    select @maxschemaguid = ''' + convert(nvarchar(36),@maxschemaguid) + '''
    if ((@maxschemaguidforarticle IS NOT NULL) and (@maxschemaguid <> @maxschemaguidforarticle))
    begin
        RAISERROR (25007, 11, -1)
        return 5
    end'
    insert into #tempcmd (phase, cmdtext) values (5, @cmdpiece)
end



-- phase 7 is optional set identity insert on, goes in during loop if needed
-- phase 8 is beginning a sub transaction, setting save point and starting insert statement
if 1 = @maintainsmetadata
begin
    set @cmdpiece = '
    if @@trancount = 0 
    begin
        begin transaction
        select @started_transaction = 1
    end
    if @metadata_type = 1 or @metadata_type = 5
    begin
        if @compatlevel < 90 and @lineage_old is not null
            set @lineage_old= {fn LINEAGE_80_TO_90(@lineage_old)}
        -- check meta consistency
        if not exists (select * from dbo.MSmerge_tombstone where tablenick = @tablenick and rowguid = @rowguid and
                        lineage = @lineage_old)
        begin
            set @errcode= 2
-- DEBUG            insert into MSmerge_debug 
-- DEBUG                (okay, artnick, rowguid, type, successcode, generation_new, lineage_old, lineage_new, twhen, comment)
-- DEBUG                values (1, @tablenick, @rowguid, @metadata_type, @errcode, @generation, @lineage_old, @lineage, getdate(), ''sp_ins'')
            goto Failure
        end
    end
    -- set row meta data
    '
    
    if @partition_options = 2 or @partition_options = 3
        select @cmdpiece = @cmdpiece + '
    if @lineage is not null
    begin '

    select @cmdpiece = @cmdpiece + '
        exec @retcode= sys.sp_MSsetrowmetadata 
            @tablenick, @rowguid, @generation, 
            @lineage, @colv, 2, @resend OUTPUT,
            @compatlevel, 1, ''' + convert(nvarchar(36),@pubid) + ''''
     
     if @partition_options = 2 or @partition_options = 3
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
            set @errcode= 0
            goto Failure
        end '

    if @partition_options = 2 or @partition_options = 3
        select @cmdpiece = @cmdpiece + '
    end '
    
    select @cmdpiece = @cmdpiece + '
    insert into ' + @qualified_name + ' ('
end
else
begin
    set @cmdpiece= '
    insert into ' + @qualified_name + ' ('
end

insert into #tempcmd (phase, cmdtext) values (8, @cmdpiece)

-- phase 9 is column list that we are inserting; done in loop

-- phase 10 is just the opening and closing parens and VALUES keyword
set @cmdpiece = ') values ('
insert into #tempcmd (phase, cmdtext) values (10, @cmdpiece)

-- phase 11 is all of those arguments as the list of value expressions; done in loop
-- phase 12 finish insert, check status, etc.
-- if we have a permanent view, check for case where we inserted a row that doesn't
-- meet filters of subscriber we are getting the insert from
set @cmdpiece = ')
        select @rowcount= @@rowcount, @error= @@error
        if (@rowcount <> 1)
        begin
            set @errcode= 3
            goto Failure
        end
'
insert into #tempcmd (phase, cmdtext) values (12, @cmdpiece)

-- only add the following code when creating proc at publisher
if @atpublisher = 1
begin
    if @partition_options > 0
    begin
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
                raiserror(20703, 16, -1, ''' + sys.fn_replreplacesinglequote(@tablename) + ''', ' + convert(char(3), @partition_options) + ')
                set @errcode= 3
                goto Failure
            end'
            insert into #tempcmd (phase, cmdtext) values (12, @cmdpiece)
        end
    end
    else
    begin
        -- Add in pieces that check for inserting a row that instantly means other rows need to be downloaded
        -- If we insert such a row, set the generation and partchangegen so that we will download everything
        -- that needs to go.

        exec sys.sp_MSexclause @tablenick, @pubid, @phase = 12
        if @@error<>0 return(1)

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
                    select @resend = 1 '
    
            insert into #tempcmd (phase, cmdtext) values (12, @cmdpiece)

            if exists (select * from dbo.sysmergepublications where pubid = @pubid and use_partition_groups >= 1)
            begin
                    select @cmdpiece = '
                    if @partition_id is not null
                            insert into dbo.MSmerge_past_partition_mappings (publication_number,tablenick,rowguid,partition_id,generation, reason)
                            values (@publication_number, @tablenick, @rowguid, @partition_id, 0,0)'

                    insert into #tempcmd (phase, cmdtext) values (12, @cmdpiece)
            end
                                                
            exec sys.sp_MSinsertbeforeimageclause @pubid, @id, @tablenickstr, @phase = 12

            set @cmdpiece = ' 
            end '
            insert into #tempcmd (phase, cmdtext) values (12, @cmdpiece)
        end
    end
end

-- if we already have a tombstone for this row, (especially a remove from partial) then
-- make sure we will set the generation so that it goes on down to subscribers of republishers
-- for backward compatibility, for 7.0 subscribers we do not want @resend to be 1

if 1 = @maintainsmetadata
begin
    set @cmdpiece = '
    -- set row meta data
    if @resend > 0  
        update dbo.MSmerge_contents set generation = 0, partchangegen = 0 
            where rowguid = @rowguid and tablenick = @tablenick '

    insert into #tempcmd (phase, cmdtext) values (12, @cmdpiece)

    set @cmdpiece='
    if @started_transaction = 1
        commit tran
    '
    insert into #tempcmd (phase, cmdtext) values (12, @cmdpiece)
end

-- phase 13 is setting identity insert off if needed; done in loop

-- now loop over columns and insert missing command pieces
--
if @sync_objid = @id
    select @colid = min (column_id) from sys.columns where object_id = @id and is_computed=0 and user_type_id<>type_id('timestamp') 
else
    select @colid = min(cs.column_id) 
        from sys.columns cs inner join sys.columns co on co.object_id=@id and co.name = cs.name
    where cs.object_id = @sync_objid and 
          co.is_computed=0 and co.user_type_id<>type_id('timestamp') 


select top 1 @colname = QUOTENAME(C.name), 
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
    
select @isidentitycolumn = is_identity, @iscomputed = is_computed, @xtype=user_type_id, @is_identitynotforreplication = convert(bit, isnull(columnproperty(@id, name, 'IsIdNotForRepl'), 0)) from sys.columns 
    where object_id = @id and QUOTENAME(name) = @colname
if @base_typename='nvarchar' or @base_typename='nchar' -- a unit of nchar takes 2 bytes
    select @len = @len/2
set @colordinal = 1

while (@colname is not null)
begin
    if (@iscomputed=1 OR type_name(@xtype)='timestamp')
        goto Next_Column

    set @colordstr = convert(nvarchar(4), @colordinal)

    if @generate_subscriber_proc = 0
        exec @retcode = sys.sp_MSmaptype @typename out, @len, @prec, @scale
    else
        exec @retcode = sys.sp_MSmap_subscriber_type @xtype, @len, @prec, @scale, @schema_option, @typename out, @schname out
    if @@error<>0 OR @retcode <>0 return (1)

    select @argname = '@p' + rtrim(convert(nchar, @colordinal))

    insert into #coltab (colname, paramname) values (@colname, @argname)

    -- add to argument list (phase 1)
    set @cmdpiece = ', 
        ' + @argname + ' ' + @schname + @typename
    insert into #tempcmd (phase, cmdtext) values (1, @cmdpiece)

    set @valuename=@argname

    -- add to column list and value list
    if (@colordinal = 1)
    begin
        -- column list is phase 9
        set @cmdpiece = @colname
        insert into #tempcmd (phase, cmdtext) values (9, @cmdpiece)

        -- argname for values list is phase 11
        set @cmdpiece = @valuename
        insert into #tempcmd (phase, cmdtext) values (11, @cmdpiece)
    end
    else
    begin
        -- column list is phase 9; need preceding comma since not the first one.
        set @cmdpiece = ', 
        '+@colname
        insert into #tempcmd (phase, cmdtext) values (9, @cmdpiece)

        -- argname for values list is phase 11 need preceding comma since not the first one.
        set @cmdpiece = ', 
        '+@valuename
        insert into #tempcmd (phase, cmdtext) values (11, @cmdpiece)
        end
        
    -- is this an identity column without 'not for replication' marking?
    if (@isidentitycolumn = 1) and 
       @is_identitynotforreplication = 0
    begin
        -- turning identity insert on is phase 7
        set @cmdpiece = '
    set identity_insert ' + @qualified_name + ' on'
        insert into #tempcmd (phase, cmdtext) values (7, @cmdpiece)

        -- turning identity insert on is phase 13
        set @cmdpiece = '
    set identity_insert ' + @qualified_name + ' off'
        insert into #tempcmd (phase, cmdtext) values (13, @cmdpiece)
    end

Next_Column:
    -- now set up to repeat the loop with the next column
    select @colid = min (column_id) from sys.columns where object_id = @sync_objid and column_id > @colid 
        
    set @colname = NULL
    if @colid is not null

    select top 1 @colname = QUOTENAME(C.name), 
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

    select @isidentitycolumn = is_identity, @iscomputed=is_computed, @xtype=user_type_id, @is_identitynotforreplication = convert(bit, isnull(columnproperty(@id, name, 'IsIdNotForRepl'), 0)) from sys.columns 
        where object_id = @id and QUOTENAME(name) = @colname
        
    if @base_typename='nvarchar' or @base_typename='nchar' -- a unit of nchar takes 2 bytes
        select @len = @len/2
    set @colordinal = @colordinal + 1
end

if 1 = @maintainsmetadata
begin
    select @cmdpiece = ',@metadata_type tinyint = NULL, @lineage_old varbinary(311) = NULL, @compatlevel int = 10 '
    
    if @atpublisher = 1
        select @cmdpiece = @cmdpiece + ', @partition_id int = NULL'

    insert into #tempcmd (phase, cmdtext) values (1, @cmdpiece)
end
           
-- phase 10 is returning our success / failure status
if 1 = @maintainsmetadata
begin
    set @cmdpiece = '
    delete from dbo.MSmerge_metadataaction_request
        where tablenick=@tablenick and rowguid=@rowguid

    -- DEBUG    insert into MSmerge_debug 
    -- DEBUG        (okay, artnick, rowguid, type, successcode, generation_new, lineage_old, lineage_new, twhen, comment) 
    -- DEBUG        values (0, @tablenick, @rowguid, @metadata_type, 1, @generation, @lineage_old, @lineage, getdate(), ''sp_ins, @resend='' + convert(nchar(1), @resend))

    return(1)

Failure:
    if @started_transaction = 1
        rollback tran
    -- DEBUG    insert into MSmerge_debug 
    -- DEBUG        (okay, artnick, rowguid, type, successcode, generation_new, lineage_old, lineage_new, twhen, comment) 
    -- DEBUG        values (1, @tablenick, @rowguid, @metadata_type, @errcode, @generation, @lineage_old, @lineage, getdate(), ''sp_ins, @resend='' + convert(nchar(1), @resend))

    '
end
else
begin
    set @cmdpiece = '
    delete from dbo.MSmerge_metadataaction_request
        where tablenick=@tablenick and rowguid=@rowguid

    return(1)

Failure:
    '
end

insert into #tempcmd (phase, cmdtext) values (14, @cmdpiece)

if 1 = @maintainsmetadata
begin
    exec sys.sp_MScreatedupkeyupdatequery
            @tablename= @qualified_name,
            @tablenickstr= @tablenickstr,
            @phase= 14,
            @isconflictproc= 0,
            @tablename2 = @qualified_name2
end

set @cmdpiece= '
    return(@errcode)
    '
insert into #tempcmd (phase, cmdtext) values (14, @cmdpiece)

-- Now we select out the command text pieces in proper order so that our caller,
-- xp_execresultset will execute the command that creates the stored procedure.
select cmdtext from #tempcmd order by phase, step

drop table #tempcmd
drop table #coltab
GO
GRANT EXECUTE ON [sys].[sp_MSmakeinsertproc] TO [public] AS [dbo]
GO
