SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSmakeselectproc]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSmakeselectproc] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSmakeselectproc]
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
declare @retcode            smallint
declare @argname            nvarchar(10)
declare @varname            nvarchar(10)
declare @columns            varbinary(128)
declare @cmdpiece           nvarchar(4000)
declare @qualified_name     nvarchar(270)
declare @prefixed_column_list nvarchar(max)
declare @prefixed_column_list_blob nvarchar(max) -- list of columns with blob columns in the end.
declare @littlecomp nvarchar(300)
declare @colid              int
declare @max_length         int
declare @col_name           nvarchar(140)
declare @id                 int
declare @idstr              nvarchar(100)
declare @sync_objid         int
declare @tablenick          int
declare @rgcol              nvarchar(140)
declare @logical_record_view int
declare @iscoltracked bit
declare @maintainsmetadata bit
declare @loop_counter       int
declare @maxschemaguid  uniqueidentifier
declare @replnick binary(6)
declare @partition_options tinyint
declare @atpublisher bit
declare @rgcolname nvarchar(140)
declare @out_of_partition_check nvarchar(4000)
declare @cmdpiece_max       nvarchar(max)


-- The order of columns in the result set is changed so that
-- all blob columns follow all non-blob columns. This is done so
-- that the row can be read sequentially (DBPROP_ACCESSORDER = DBPROPVAL_AO_SEQUENTIALSTORAGEOBJECTS)
declare @column_list_result    table (
            line_no int identity(1,1) primary key, 
            line nvarchar(4000),
            line2 nvarchar(4000) NULL)

-- Need the list of columns as it appears in the
-- user table to return in response to sp_MSenumcolumns
declare @column_list_actual    table (
            line_no int identity(1,1) primary key, 
            line nvarchar(4000),
            line2 nvarchar(4000) NULL)

declare @xtype int
            , @system_type_id int
            , @view_has_blob bit
            , @column_is_blob bit
            , @colidstr nvarchar(5)

set @view_has_blob=0
set @column_is_blob=0
            
set nocount on

if @ownername is NULL or @ownername=''
    select @qualified_name = QUOTENAME(@tablename)
else    
    select @qualified_name = QUOTENAME(@ownername) + '.' + QUOTENAME(@tablename)

select @id = object_id(@qualified_name)
select @rgcol = quotename(name) from sys.columns where object_id = @id and is_rowguidcol = 1

select @sync_objid=sync_objid, @tablenick = nickname, @iscoltracked = column_tracking
from dbo.sysmergearticles where artid=@artid and pubid=@pubid
if @tablenick is NULL
    return (1)

select @logical_record_view = logical_record_view from dbo.sysmergepartitioninfo where artid = @artid and pubid=@pubid
set @idstr = rtrim(convert(nchar, @id)) 
set @prefixed_column_list = ''
set @prefixed_column_list_blob = ''

select @maxschemaguid = sys.fn_GetArticleSchemaVersionGuid(@artid, @pubid)

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
    select @maintainsmetadata= sys.fn_MSarticle_allows_DML_at_this_replica(@artid, default)
    select @atpublisher = sys.fn_MSmerge_islocalpubid(@pubid)
end

/*
** Do not allow out of partition deletes at the publisher.
** Check to see if the row being deleted is in the partition
** before deleting it.
*/
select @partition_options = partition_options
    from dbo.sysmergepartitioninfoview where objid=@id and pubid=@pubid

select @out_of_partition_check = ' '
if @atpublisher = 1 AND @partition_options > 0
begin
    -- Get the column name for the rowguid column.
    select @rgcolname = QUOTENAME(name) from sys.columns where object_id = @id and is_rowguidcol = 1
    if @rgcolname is null
        set @rgcolname = 'rowguid'

    if exists (select * from dbo.sysmergearticles where pubid = @pubid and objid = @id
                                            and len(subset_filterclause) > 0)
                                    or exists (select * from dbo.sysmergesubsetfilters where pubid = @pubid and 
                                                    (art_nickname = @tablenick or join_nickname = @tablenick))
    begin        
        select @out_of_partition_check = '
        if not exists (select 1 from ' + QUOTENAME(OBJECT_NAME(sync_objid))
            from dbo.sysmergearticles where pubid = @pubid and objid = @id
        set @out_of_partition_check = @out_of_partition_check + ' where ' + @rgcolname + ' = @rowguid) 
        begin
            raiserror(20734, 16, -1, ''' + sys.fn_replreplacesinglequote(@tablename) + ''', ' + convert(char(3), @partition_options) + ')
            return (1)
        end'
    end    
end


/*
** Include computed columns.
*/
if exists (select 1 from sys.columns  
                where object_id=@id and 
                --(sys.fn_IsTypeBlob(system_type_id, max_length)= 1)
                (system_type_id in (type_id('image'), type_id('text'), type_id('ntext'), type_id('xml')) or max_length = -1)
                and (name in (select name from sys.columns where object_id=@sync_objid))
              )
    set @view_has_blob=1

IF @view_has_blob=1 
    or exists (select name from sys.columns where object_id = @id and (name not in 
                    (select name from sys.columns where object_id = @sync_objid)))
    or exists (select name from sys.columns where object_id=@id and (is_computed=1 or user_type_id = type_id('timestamp')))
BEGIN

    select @loop_counter = 1
    while(@loop_counter <= 2)
    begin
        DECLARE column_cursor CURSOR LOCAL FAST_FORWARD FOR
            select name, user_type_id, system_type_id, column_id,max_length from sys.columns where object_id=@id 
                    and is_computed<>1 
                    and user_type_id <> type_id('timestamp' )
                    and name in (select name from sys.columns where object_id=@sync_objid)
                    order by column_id asc
        FOR READ ONLY
        open column_cursor
        fetch next from column_cursor into @col_name, @xtype, @system_type_id, @colid,@max_length
        WHILE (@@fetch_status <> -1)
        BEGIN

            set @column_is_blob=0
            if @view_has_blob=1 and (sys.fn_IsTypeBlob(@system_type_id, @max_length)= 1)
                select @column_is_blob=1
            set @colidstr =convert(nvarchar(4), @colid)
            
            if @loop_counter=1
            begin
                if @prefixed_column_list=''
                    select @prefixed_column_list = 't.' + quotename(@col_name)
                else
                    select @prefixed_column_list = @prefixed_column_list + ', t.' + quotename(@col_name)        
            end

            if @prefixed_column_list_blob=''
            begin
                -- Insert non blob column in the first iteration through the loop
                -- so that they are before any blob columns.
                -- Insert blob columns in the second iteration through the loop
                -- so that they are in the end of the result set.
                if ((@column_is_blob <> 1 and @loop_counter=1) or (@column_is_blob=1 and @loop_counter=2))
                    select @prefixed_column_list_blob = 't.' + quotename(@col_name)
            end
            else
            begin
                -- Insert non blob column in the first iteration through the loop
                -- so that they are before any blob columns.
                -- Insert blob columns in the second iteration through the loop
                -- so that they are in the end of the result set.
                if ((@column_is_blob <> 1 and @loop_counter=1) or (@column_is_blob=1 and @loop_counter=2))
                select @prefixed_column_list_blob = @prefixed_column_list_blob + ', t.' + quotename(@col_name)
            end
                    
            if ColumnProperty(@id, @col_name, 'isrowguidcol') = 1
                select @col_name='t.rowguidcol'
            else
                set @col_name = 't.' + QUOTENAME(@col_name)


            -- Fill the the column_list_actual in the first iteration.
            if @loop_counter=1
            begin
                if (select count(*) from @column_list_actual) = 0
                    insert into @column_list_actual(line, line2) values (@col_name, @col_name)
                else -- add a end of line character
                    insert into @column_list_actual(line, line2) 
                        values (',
        '+@col_name, ',
        '+@col_name)    
            end

            -- Insert non blob column in the first iteration through the loop
            -- so that they are before any blob columns.
            -- Insert blob columns in the second iteration through the loop
            -- so that they are in the end of the result set.
            if (select count(*) from @column_list_result) = 0
            begin
                if ((@column_is_blob <> 1 and @loop_counter=1) or (@column_is_blob=1 and @loop_counter=2))
                    insert into @column_list_result(line, line2) values (@col_name, @col_name)
            end
            else
            begin
                if ((@column_is_blob <> 1 and @loop_counter=1) or (@column_is_blob=1 and @loop_counter=2))
                    insert into @column_list_result(line, line2) 
                    values (',
        '+@col_name, ',
        '+@col_name)
            end
            
            fetch next from column_cursor into @col_name, @xtype, @system_type_id, @colid, @max_length            
        END
        close column_cursor
        deallocate column_cursor

        select @loop_counter = @loop_counter + 1
    end -- loop_counter
    if (select count(*) from @column_list_result) = 0
    begin
        RAISERROR(21125, 16, -1)
        return (1)
    end
END
else 
begin
    insert into @column_list_result(line, line2) values ('t.*', 't.*')
    insert into @column_list_actual(line, line2) values ('t.*', 't.*')
    select @prefixed_column_list = 't.*'
    select @prefixed_column_list_blob = 't.*'
end


if @generate_subscriber_proc = 0
    update dbo.sysmergepartitioninfo set column_list = @prefixed_column_list, column_list_blob =  @prefixed_column_list_blob where artid = @artid and pubid=@pubid
else
begin
    select @cmdpiece_max = '
update dbo.sysmergepartitioninfo 
    set column_list = N''' + sys.fn_replreplacesinglequote(@prefixed_column_list) + ''', 
        column_list_blob = N''' + sys.fn_replreplacesinglequote(@prefixed_column_list_blob) + '''
    where artid = ''' + convert(nvarchar(36),@artid) + ''' and pubid = ''' + convert(nvarchar(36),@pubid) + ''''
    select @cmdpiece_max
end

/*
** Check for dbo permission
*/
exec @retcode=sys.sp_MSreplcheck_subscribe
if @retcode<>0 or @@ERROR<>0 return (1)

set @cmdpiece= 'SET ANSI_NULLS ON SET QUOTED_IDENTIFIER ON'
if @generate_subscriber_proc = 0
    exec (@cmdpiece)
else
    select @cmdpiece
if @@error<>0 return(1)

exec @retcode = sys.sp_MSgetreplnick @replnick = @replnick out
if (@retcode<>0) or @replnick IS NULL
begin
    raiserror(14055, 11, -1)
    return(1)
end

-- create temp table to select the command text out of
declare @tempcmd table (step int identity NOT NULL, cmdtext nvarchar(4000) collate database_default null)

/* For Yukon version of this proc, add the @maxschemaguidforarticle as the first parameter */
if (0 = @generate_downlevel_procs)
begin
    select @cmdpiece = '
    create procedure dbo.'  + QUOTENAME(@procname) + ' (
        @maxschemaguidforarticle uniqueidentifier,
        @type int output, 
        @rowguid uniqueidentifier=NULL,
        @enumentirerowmetadata bit= 1,
        @blob_cols_at_the_end bit=0,
        @logical_record_parent_rowguid uniqueidentifier = ''00000000-0000-0000-0000-000000000000'',
        @metadata_type tinyint = 0,
        @lineage_old varbinary(311) = NULL,
        @rowcount int = NULL output
        ) 
    as
    begin
        declare @retcode    int
        
        set nocount on
            
        if ({ fn ISPALUSER(''' + convert(nvarchar(36),@pubid) + ''') } <> 1)
        begin       
            RAISERROR (14126, 11, -1)
            return (1)
        end '

end
else
begin
    select @cmdpiece = '
    create procedure dbo.'  + QUOTENAME(@procname) + ' (
        @type int output, 
        @rowguid uniqueidentifier=NULL,
        @enumentirerowmetadata bit= 1,
        @blob_cols_at_the_end bit=0,
        @logical_record_parent_rowguid uniqueidentifier = ''00000000-0000-0000-0000-000000000000'',
        @metadata_type tinyint = 0,
        @lineage_old varbinary(311) = NULL,
        @rowcount int = NULL output
        ) 
    as
    begin
        declare @retcode    int
        set nocount on
            
        if ({ fn ISPALUSER(''' + convert(nvarchar(36),@pubid) + ''') } <> 1)
        begin       
            RAISERROR (14126, 11, -1)
            return (1)
        end '
end

insert into @tempcmd (cmdtext) values (@cmdpiece)

if (0 = @generate_downlevel_procs) and (@generate_subscriber_proc = 0)
begin
    set @cmdpiece= '
    declare @maxschemaguid  uniqueidentifier
    select @maxschemaguid = ''' + convert(nvarchar(36),@maxschemaguid) + '''
    if ((@maxschemaguidforarticle IS NOT NULL) and (@maxschemaguid <> @maxschemaguidforarticle))
    begin
        RAISERROR (25007, 11, -1)
        return 5
    end'
    insert into @tempcmd (cmdtext) values (@cmdpiece)
end

select @cmdpiece= '
    if @type = 1
        begin
            select ' 
insert into @tempcmd (cmdtext) values (@cmdpiece)


insert into @tempcmd (cmdtext) select line from @column_list_actual order by line_no asc
select @cmdpiece='          from ' + @qualified_name + ' t where rowguidcol = @rowguid
        if @@ERROR<>0 return(1)
    end 
    else if @type < 4 
        begin
            -- case one: no blob gen optimization
            if @blob_cols_at_the_end=0
            begin
                select 
                c.tablenick, 
                c.rowguid, 
                c.generation,
                case @enumentirerowmetadata
                    when 0 then null
                    else c.lineage
                end as lineage,
                case @enumentirerowmetadata
                    when 0 then null
                    else c.colv1
                end as colv1,
                ' 
        insert into @tempcmd (cmdtext) values (@cmdpiece)
        insert into @tempcmd (cmdtext) select line from @column_list_actual order by line_no asc
        select @cmdpiece='
                from #cont c , ' +
                     @qualified_name + ' t with (rowlock)
                where t.rowguidcol = c.rowguid
                order by t.rowguidcol 
                
            if @@ERROR<>0 return(1)
            end'
        insert into @tempcmd (cmdtext) values (@cmdpiece)

select @cmdpiece='  
            -- case two: blob gen optimization
            else 
            begin
                select 
                c.tablenick, 
                c.rowguid, 
                c.generation,
                case @enumentirerowmetadata
                    when 0 then null
                    else c.lineage
                end as lineage,
                case @enumentirerowmetadata
                    when 0 then null
                    else c.colv1
                end as colv1,'
        insert into @tempcmd (cmdtext) values (@cmdpiece)
        insert into @tempcmd (cmdtext) select line2  from @column_list_result where line_no = 1
        insert into @tempcmd (cmdtext) select ' ' + line2 from @column_list_result where line_no > 1 order by line_no asc
        select @cmdpiece='
                from #cont c,' +
                     @qualified_name + ' t with (rowlock)
              where t.rowguidcol = c.rowguid
                 order by t.rowguidcol 
                 
            if @@ERROR<>0 return(1)
            end
        end'
        insert into @tempcmd (cmdtext) values (@cmdpiece)

select @cmdpiece=
'   else if @type = 4
    begin
        set @type = 0
        if exists (select * from ' + @qualified_name + ' where rowguidcol = @rowguid)
            set @type = 3
        if @@ERROR<>0 return(1)
    end

    else if @type = 5
    begin
        ' + @out_of_partition_check +
        '
        delete ' + @qualified_name + ' where rowguidcol = @rowguid
        if @@ERROR<>0 return(1)

        delete from dbo.MSmerge_metadataaction_request
            where tablenick=' + cast(@tablenick as nvarchar(20)) + ' and rowguid=@rowguid
    end '
    
insert into @tempcmd (cmdtext) values (@cmdpiece)
    
select @cmdpiece = '
    else if @type = 6 -- sp_MSenumcolumns
    begin
        select ' 
insert into @tempcmd (cmdtext) values (@cmdpiece)
insert into @tempcmd (cmdtext) select line from @column_list_actual order by line_no asc
select @cmdpiece='         from ' + @qualified_name + ' t where 1=2
        if @@ERROR<>0 return(1)
    end

    else if @type = 7 -- sp_MSlocktable
    begin
        select 1 from ' + @qualified_name + ' with (tablock holdlock) where 1 = 2
        if @@ERROR<>0 return(1)
    end

    else if @type = 8 -- put update lock
    begin
        if not exists (select * from ' + @qualified_name + ' with (UPDLOCK HOLDLOCK) where rowguidcol = @rowguid)
        begin
            RAISERROR(20031 , 16, -1)
            return(1)
        end
    end
    else if @type = 9
    begin
        declare @oldmaxversion int, @replnick binary(6)
                , @cur_article_rowcount int, @column_tracking int
                        
        select @replnick = ' + sys.fn_varbintohexstr(@replnick)
        insert into @tempcmd (cmdtext) values (@cmdpiece)
        
        select @cmdpiece = '
        select top 1 @oldmaxversion = maxversion_at_cleanup,
                     @column_tracking = column_tracking
        from dbo.sysmergearticles 
        where nickname = ' + convert(nvarchar(13),@tablenick) + '
        
        select @cur_article_rowcount = count(*) from #rows 
        where tablenick = ' + convert(nvarchar(13),@tablenick) + '
            
        update dbo.MSmerge_contents 
        set lineage = { fn UPDATELINEAGE(lineage, @replnick, @oldmaxversion+1) }
        where tablenick = ' + convert(nvarchar(13),@tablenick) + '
        and rowguid in (select rowguid from #rows where tablenick = ' + convert(nvarchar(13),@tablenick) + ') '
        
        insert into @tempcmd (cmdtext) values (@cmdpiece)
        
        select @cmdpiece = '
        if @@rowcount <> @cur_article_rowcount
        begin
            declare @lineage varbinary(311), @colv1 varbinary(1)
                    , @cur_rowguid uniqueidentifier, @prev_rowguid uniqueidentifier
            set @lineage = { fn UPDATELINEAGE(0x0, @replnick, @oldmaxversion+1) }
            if @column_tracking <> 0
                set @colv1 = 0xFF
            else
                set @colv1 = NULL
                
            select top 1 @cur_rowguid = rowguid from #rows
            where tablenick = ' + convert(nvarchar(13),@tablenick) + '
            order by rowguid
            
            while @cur_rowguid is not null
            begin
                if not exists (select * from dbo.MSmerge_contents 
                                where tablenick = ' + convert(nvarchar(13),@tablenick) + '
                                and rowguid = @cur_rowguid)
                begin
                    begin tran 
                    save tran insert_contents_row '
            
            insert into @tempcmd (cmdtext) values (@cmdpiece)
            select @cmdpiece = '
                    if exists (select * from ' + @qualified_name + 'with (holdlock) where rowguidcol = @cur_rowguid)
                    begin
                        exec @retcode = sys.sp_MSevaluate_change_membership_for_row @tablenick = ' + convert(nvarchar(13),@tablenick) + ', @rowguid = @cur_rowguid
                        if @retcode <> 0 or @@error <> 0
                        begin
                            rollback tran insert_contents_row
                            return 1
                        end
                        insert into dbo.MSmerge_contents (rowguid, tablenick, generation, lineage, colv1, logical_record_parent_rowguid)
                            values (@cur_rowguid, ' + convert(nvarchar(13),@tablenick) + ', 0, @lineage, @colv1, @logical_record_parent_rowguid)
                    end
                    commit tran
                end
                
                select @prev_rowguid = @cur_rowguid
                select @cur_rowguid = NULL
                
                select top 1 @cur_rowguid = rowguid from #rows
                where tablenick = ' + convert(nvarchar(13),@tablenick) + '
                and rowguid > @prev_rowguid
                order by rowguid
            end
        end '
        
        insert into @tempcmd (cmdtext) values (@cmdpiece)
        select @cmdpiece = '
        select 
            r.tablenick, 
            r.rowguid, 
            mc.generation,
            case @enumentirerowmetadata
                when 0 then null
                else mc.lineage
            end,
            case @enumentirerowmetadata
                when 0 then null
                else mc.colv1
            end,
            ' 

insert into @tempcmd (cmdtext) values (@cmdpiece)
insert into @tempcmd (cmdtext) select line from @column_list_actual order by line_no asc
select @cmdpiece='         from #rows r left outer join ' +
                 @qualified_name + ' t on r.rowguid = t.rowguidcol and r.tablenick = ' + convert(nvarchar(13),@tablenick) + '
                 left outer join dbo.MSmerge_contents mc on
                 mc.tablenick = ' + convert(nvarchar(13),@tablenick) + ' and mc.rowguid = t.rowguidcol
                 where r.tablenick = ' + convert(nvarchar(13),@tablenick) + '
         order by r.idx
         
        if @@ERROR<>0 return(1)
    end '

insert into @tempcmd (cmdtext) values (@cmdpiece)
if @logical_record_view is NOT NULL
    begin
        
    select @cmdpiece=' else if @type = 10 
        begin
            select 
                c.tablenick, 
                c.rowguid, 
                c.generation,
                case @enumentirerowmetadata
                    when 0 then null
                    else c.lineage
                end,
                case @enumentirerowmetadata
                    when 0 then null
                    else c.colv1
                end,
                ' 

    insert into @tempcmd (cmdtext) values (@cmdpiece)
    insert into @tempcmd (cmdtext) select line from @column_list_actual order by line_no asc
    select @cmdpiece='         from #cont c,' +
                     @qualified_name + ' t with (rowlock)
                    where t.' + @rgcol + ' = c.rowguid
                    and c.tablenick = ' + convert(nvarchar(13), @tablenick) + '
             order by t.rowguidcol
             option (force order)
               
            if @@ERROR<>0 return(1)
        end'
    insert into @tempcmd (cmdtext) values (@cmdpiece)

    end
else
    begin        
        select @cmdpiece='
        else if @type = 10  
        begin
            select 
                c.tablenick, 
                c.rowguid, 
                c.generation,
                case @enumentirerowmetadata
                    when 0 then null
                    else c.lineage
                end,
                case @enumentirerowmetadata
                    when 0 then null
                    else c.colv1
                end,
                null,
                ' 

        insert into @tempcmd (cmdtext) values (@cmdpiece)
        insert into @tempcmd (cmdtext) select line from @column_list_actual order by line_no asc
        select @cmdpiece='         from #cont c,' +
                     @qualified_name + ' t with (rowlock) where
                      t.rowguidcol = c.rowguid
             order by t.rowguidcol 
                        
            if @@ERROR<>0 return(1)
        end'
        insert into @tempcmd (cmdtext) values (@cmdpiece)
    end    

    select @cmdpiece='
    else if @type = 11
    begin
        ' + @out_of_partition_check +
        '
        -- we will do a delete with metadata match
        if @metadata_type = 0
        begin
            delete from ' + @qualified_name + ' where ' + @rgcol + ' = @rowguid
            select @rowcount = @@rowcount
            if @rowcount <> 1
            begin
                RAISERROR(20031 , 16, -1)
                return(1)
            end
        end
        else
        begin
            if @metadata_type = 3
                delete ' + @qualified_name + ' from ' + @qualified_name + ' t
                    where t.' + @rgcol + ' = @rowguid and 
                        not exists (select 1 from dbo.MSmerge_contents c with (rowlock) where
                                                c.rowguid = @rowguid and
                                                c.tablenick = ' + cast(@tablenick as nvarchar(20)) + ')
            else if @metadata_type = 5 or @metadata_type = 6
                delete ' + @qualified_name + ' from ' + @qualified_name + ' t
                    where t.' + @rgcol + ' = @rowguid and 
                         not exists (select 1 from dbo.MSmerge_contents c with (rowlock) where
                                                c.rowguid = @rowguid and
                                                c.tablenick = ' + cast(@tablenick as nvarchar(20)) + ' and
                                                c.lineage <> @lineage_old)
                                                
            else
                delete ' + @qualified_name + ' from ' + @qualified_name + ' t
                    where t.' + @rgcol + ' = @rowguid and 
                         exists (select 1 from dbo.MSmerge_contents c with (rowlock) where
                                                c.rowguid = @rowguid and
                                                c.tablenick = ' + cast(@tablenick as nvarchar(20)) + ' and
                                                c.lineage = @lineage_old)
            select @rowcount = @@rowcount
            if @rowcount <> 1 
            begin
                if not exists (select * from ' + @qualified_name + ' where ' + @rgcol + ' = @rowguid)
                begin
                    RAISERROR(20031 , 16, -1)
                    return(1)
                end
            end
        end
        if @@ERROR<>0 
        begin
            delete from dbo.MSmerge_metadataaction_request
                where tablenick=' + cast(@tablenick as nvarchar(20)) + ' and rowguid=@rowguid

            return(1)
        end        
    end'
    insert into @tempcmd (cmdtext) values (@cmdpiece)

    if @maintainsmetadata = 1
    select @cmdpiece = '
    else if @type = 12
    begin 
        -- this type indicates metadata type selection
        declare @maxversion int
        declare @error int
        
        select @maxversion= maxversion_at_cleanup from dbo.sysmergearticles 
            where nickname = ' + cast(@tablenick as nvarchar(20)) + ' and pubid = ''' + convert(nvarchar(36),@pubid) + '''
        if @error <> 0 
            return 1
        select case when (cont.generation is NULL and tomb.generation is null) 
                    then 0 
                    else isnull(cont.generation, tomb.generation) 
               end as generation, 
               case when t.' + @rgcol + ' is null 
                    then (case when tomb.rowguid is NULL then 0 else tomb.type end) 
                    else (case when cont.rowguid is null then 3 else 2 end) 
               end as type,
               case when tomb.rowguid is null 
                    then cont.lineage 
                    else tomb.lineage
               end as lineage, 
               cont.colv1 as colv, 
               @maxversion as maxversion
        from
        (select @rowguid as rowguid) as rows 
        left outer join ' + @qualified_name + ' t with (rowlock) 
        on t.' + @rgcol + ' = rows.rowguid
        and rows.rowguid is not null
        left outer join dbo.MSmerge_contents cont with (rowlock) 
        on cont.rowguid = rows.rowguid and cont.tablenick = ' + cast(@tablenick as nvarchar(20)) + '
        left outer join dbo.MSmerge_tombstone tomb with (rowlock) 
        on tomb.rowguid = rows.rowguid and tomb.tablenick = ' + cast(@tablenick as nvarchar(20)) + '
        where rows.rowguid is not null
        
        select @error = @@error
        if @error <> 0 
        begin
            --raiserror(@error, 16, -1)
            return 1
        end
    end'
    else
    select @cmdpiece = '
    else if @type = 12
    begin 
        -- this type indicates metadata type selection
        declare @maxversion int
        declare @error int
        
        select @maxversion= maxversion_at_cleanup from dbo.sysmergearticles 
            where nickname = ' + cast(@tablenick as nvarchar(20)) + ' and pubid = ''' + convert(nvarchar(36),@pubid) + '''
        if @error <> 0 
            return 1
        select 0 as generation, 
               case when t.' + @rgcol + ' is null then 0 else 3 end as type,
               NULL as lineage, 
               NULL as colv, 
               @maxversion as maxversion
        from
        (select @rowguid as rowguid) as rows 
        left outer join ' + @qualified_name + ' t with (rowlock) 
        on t.' + @rgcol + ' = rows.rowguid
        and rows.rowguid is not null
        where rows.rowguid is not null
        
        select @error = @@error
        if @error <> 0 
        begin
            --raiserror(@error, 16, -1)
            return 1
        end
    end'
    
    insert into @tempcmd (cmdtext) values (@cmdpiece)

    select @cmdpiece='
    return(0)
end
'

insert into @tempcmd (cmdtext) values (@cmdpiece)
select cmdtext from @tempcmd order by step
--drop table @tempcmd
GO
GRANT EXECUTE ON [sys].[sp_MSmakeselectproc] TO [public] AS [dbo]
GO
