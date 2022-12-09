SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_repladdcolumn]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_repladdcolumn] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_repladdcolumn]
	@source_object [nvarchar](358),
	@column [sysname],
	@typetext [nvarchar](3000),
	@publication_to_add [nvarchar](4000),
	@from_agent [int],
	@schema_change_script [nvarchar](4000),
	@force_invalidate_snapshot [bit],
	@force_reinit_subscription [bit]
WITH EXECUTE AS CALLER
AS
set nocount on
declare @objid          int
declare @pubid          uniqueidentifier
declare @retcode        int
declare @partitioned    int
declare @at_publisher   bit
declare @pubname        sysname
declare @artname        sysname
declare @colid          int
declare @tablename      sysname
declare @artid          uniqueidentifier
declare @tran_artid     int
declare @tran_pubid     int
declare @schematext     nvarchar(4000)
declare @schemaversion  int
declare @schematype     int
declare @schemaguid     uniqueidentifier
declare @conflict_table sysname
declare @ins_conflict_proc nvarchar(258)
declare @publisher      sysname
declare @qual_column    nvarchar(258)
declare @publisher_db   sysname
declare @command        nvarchar(max)
declare @sync_objid     int
declare @con_id         int
declare @owner          sysname
declare @dest_owner     sysname
declare @dest_object    nvarchar(517)
declare @merge_pub_object_bit int
declare @is_for_merge   bit                -- 1 if merge is on AND the table is published in a merge publication AND the publication is in @publivation_to_add list
declare @is_for_tran    bit
declare @not_for_merge  int            -- 0 if merge is on AND the table is published in a merge publication
declare @not_for_tran   int
declare @dbname         sysname
declare @servername     sysname
declare @no_publication bit
declare @no_schema_replication bit
declare @qual_source_object nvarchar(517)
declare @len            int
declare @prec           int
declare @scale int
declare @typename nvarchar(270)
declare @qual_dest_object nvarchar(517)
declare @invalid_datatype bit
declare @is_yukon_datatype bit
declare @xtype        int
declare @max_length   int
declare @iscomputed bit
declare @pass_to_heterogenious bit
declare @merge_pub_markcolumn_bit    int
declare @schema_start_lsn binary(10)
declare @schema_end_lsn binary(10)
declare @nickname        int
declare @columns_in_partition    int
declare @artnick int
declare @allow_initialize_from_backup bit
declare @is_timestamp_column bit
declare @is_identity_column bit
declare @is_identity_column_not_for_replication bit
        ,@BinVar varbinary(128)
declare @count              int
declare @DATATYPE_ID_UDT    int
declare @got_merge_admin_applock bit

select @got_merge_admin_applock = 0

/*
** Security Check
*/
EXEC @retcode = sys.sp_MSreplcheck_publish
IF @@ERROR <> 0 or @retcode <> 0
    return (1)


select @qual_column=QUOTENAME(@column)
select @merge_pub_markcolumn_bit = 0x4000

select @objid = object_id(@source_object)

-- check to see if this stored procedure is called via replication agent.
if sessionproperty('replication_agent')<>1
    select @from_agent = 0
else
    begin --if table does not exists and the SP is called from replication agent, ignore the error and exit with success.
        select @from_agent = 1
        if @objid is NULL
            return (0)
    end

if @objid is NULL
begin
    raiserror(14027, 16, -1, @source_object)
    return (1)
end

if exists (select * from sys.columns where object_id=@objid and name=@column)
begin
    if @from_agent=0
    begin
        raiserror(21255, 16, -1, @column, @source_object)
        return (1)
    end
    else
        return (0)
end


-- PARSENAME VARS
    declare        @UnqualName         sysname  --rightmost name node
    declare        @QualName1         sysname  
-- END PARSENAME VARS

    select @UnqualName = PARSENAME(@source_object, 1)
    select @QualName1 = PARSENAME(@source_object, 2)
    if @UnqualName IS NULL
         return 1
    if @QualName1 is not NULL
        select @owner = @QualName1
            else select @owner=schema_name(schema_id) from sys.objects where object_id = @objid
    select @tablename = @UnqualName

    select @qual_source_object = QUOTENAME(@owner) + '.' + QUOTENAME(@tablename)
select @no_schema_replication = 0
select @no_publication=0
select @servername=publishingservername()
select @dbname=db_name()
select @merge_pub_object_bit    = 128
select @not_for_merge = 0
select @not_for_tran = 0

if exists (select * from sys.objects where name='sysmergearticles')
begin
    -- the article can not be inside a republisher
    if @from_agent=0 and exists (select * from dbo.sysmergearticles where objid=@objid and pubid not in 
        (select pubid from dbo.sysmergepublications where LOWER(publisher)=LOWER(@servername) and publisher_db=@dbname))
    begin
        raiserror(21260, 16, -1, @dbname, @servername, @source_object)
        return (1)
    end
end

-- validate  to avoid SQL injection risk
declare @alter_stmt    nvarchar(4000)
select @alter_stmt = 'alter table ' + @qual_source_object + ' add ' + @qual_column + N' ' + @typetext
exec @retcode = sys.sp_repl_validate_parameter @str = @alter_stmt
if (@@error <> 0) or @retcode <> 0
begin
    raiserror(21285, 16, -1, @column, @source_object)
    RETURN(1)
end

select @invalid_datatype=0
select @is_yukon_datatype=0
select @DATATYPE_ID_UDT = 240 --system_type_id for UDT.
-- signal to db ddl trigger to bail out
EXEC @retcode = sys.sp_MSsetcontext_bypasswholeddleventbit @onoff=1
IF @@ERROR <> 0 or @retcode <> 0
    RETURN(1)

/* the transaction below is just an experiment to validate type text */
BEGIN TRAN
SAVE TRANSACTION fake_move
    exec @retcode = sys.sp_MSunmarkreplinfo @object=@tablename, @owner=@owner
    if @retcode<>0 or @@ERROR<>0
    begin
        goto CHECKING_DONE
    end
    declare @temp_id        int
    declare @temp_colid        int
    select @is_identity_column = 0
    select @is_timestamp_column = 0
    select @is_identity_column_not_for_replication = 0
    exec (@alter_stmt)
    select @temp_id = object_id(@qual_source_object)
    if @temp_id is NULL
    begin
        raiserror(21285, 16, -1, @column, @source_object)
        select @invalid_datatype = 1
        GOTO CHECKING_DONE
    end
    select @pass_to_heterogenious=0, @temp_colid = column_id, @xtype=system_type_id, @iscomputed=is_computed,
        @max_length = max_length
        from sys.columns where object_id = @temp_id and name=@column
    if @iscomputed <> 1 and type_name(@xtype) <> 'timestamp'
        select @pass_to_heterogenious=1
    if COLUMNPROPERTY(@temp_id, @column, 'IsIdentity') = 1
        select @is_identity_column = 1
    if type_name(@xtype) = 'timestamp'
        select @is_timestamp_column = 1
    if @is_identity_column = 1 and COLUMNPROPERTY(@temp_id, @column, 'IsIdNotForRepl') = 1
        select @is_identity_column_not_for_replication = 1
    if COLUMNPROPERTY(@temp_id, @column, 'IsIdentity') = 0
        and not exists (select * from sys.columns where object_id = @temp_id and name=@column and is_nullable=1)
        and not exists (select * from sysconstraints where id=@temp_id and colid=@temp_colid and OBJECTPROPERTY ( constid , 'IsDefaultCnst' ) = 1)
        and @iscomputed <> 1 and type_name(@xtype) <> 'timestamp'  --not computed column nor timestamp column
    begin
        select @invalid_datatype = 1
    end
    -- Check for yukon data type.
    if (@xtype = @DATATYPE_ID_UDT) OR ((@max_length = -1) and type_name(@xtype) in ('xml','varchar','nvarchar','varbinary'))
    begin
        select @is_yukon_datatype = 1
    end
CHECKING_DONE:
ROLLBACK TRANSACTION fake_move
COMMIT TRAN
if @invalid_datatype = 1
    begin
        raiserror(21285, 16, -1, @column, @source_object)
        return (1)
    end

select @is_for_merge = 0
select @is_for_tran = 0
if not exists (select * from sys.objects where name='sysmergepublications') and
    not exists (select * from sys.objects where name='syspublications')
begin
    raiserror(21230, 16, -1)
    return (1)
end

create table #tmp_table (name sysname collate database_default)

if LOWER(@publication_to_add)='all' or LOWER(@publication_to_add)='[all]'
begin    
    select @publication_to_add = '%'
end
else 
begin
if charindex(',', @publication_to_add)<>0 --publication list
    begin
        declare @tmp_publist    nvarchar(4000)
        declare @total            int
        declare @invalid_pub    sysname
        select @invalid_pub = NULL
            select @tmp_publist = @publication_to_add
        while @tmp_publist <> ''
        begin
            select @tmp_publist = LTRIM(@tmp_publist)
            select @total=len(@tmp_publist)
            select @len=charindex(',', @tmp_publist)
            if @len=0
                begin
                    insert #tmp_table values(@tmp_publist)
                    select @tmp_publist=''
                end
            else
                begin
                    insert #tmp_table values(substring(@tmp_publist, 1, @len-1))
                    select @tmp_publist = right(@tmp_publist, @total-@len)
                end
        end
        if exists (select * from sys.objects where name='sysmergepublications') and 
            exists (select * from sys.objects where name='syspublications')
            select @invalid_pub=name from #tmp_table where name not in (select ('[' + name + ']') from dbo.sysmergepublications) and 
                                                            name not in (select ('[' + name + ']') from syspublications)
        else 
            if exists (select * from sys.objects where name='sysmergepublications') 
                select @invalid_pub=name from #tmp_table where name not in (select ('[' + name + ']') from dbo.sysmergepublications)            
            else
                if exists (select * from sys.objects where name='syspublications')        
                    select @invalid_pub=name from #tmp_table where name not in (select ('[' + name + ']') from syspublications)                        
        if @invalid_pub is not NULL and @from_agent=0
        begin
            raiserror(21274, 16, -1, @invalid_pub)
            return (1)        
        end
    end
else 
    begin --single publication
        insert #tmp_table values(@publication_to_add)
        insert #tmp_table values('[' + @publication_to_add + ']')
    end
    
end

-- if in both merge and tran publication
if exists (select * from sys.objects where name='sysmergepublications')
    and exists (select * from sys.objects where name='syspublications')
begin
    if not exists (select * from syspublications where name like @publication_to_add 
                or (('[' + name + ']') in (select name from #tmp_table)))
            and not exists (select * from dbo.sysmergepublications where name like @publication_to_add 
                or (('[' + name + ']') in (select name from #tmp_table)))
        select @no_publication = 1

    if not exists (select * from sysarticles where objid=@objid and pubid in 
            (select pubid from syspublications where repl_freq = 0 and (name like @publication_to_add 
                or (('[' + name + ']') in (select name from #tmp_table)))))
        and not exists (select * from dbo.sysmergearticles where objid=@objid and pubid in 
            (select pubid from dbo.sysmergepublications where name like @publication_to_add 
                    or (('[' + name + ']') in (select name from #tmp_table))))
        select @no_schema_replication=1
end
-- if a merge publication
else if exists (select * from sys.objects where name='sysmergepublications')
begin
    if not exists (select * from dbo.sysmergepublications where name like @publication_to_add 
                or (('[' + name + ']') in (select name from #tmp_table)))
        select @no_publication = 1

    if not exists (select * from dbo.sysmergearticles where objid=@objid and pubid in 
            (select pubid from dbo.sysmergepublications where name like @publication_to_add 
                    or (('[' + name + ']') in (select name from #tmp_table))))
        select @no_schema_replication = 1
end
-- if tran publication
else if exists (select * from sys.objects where name='syspublications')
begin
    if not exists (select * from syspublications where name like @publication_to_add 
                or (('[' + name + ']') in (select name from #tmp_table)))
        select @no_publication = 1
        
    if not exists (select * from sysarticles where objid=@objid and pubid in 
            (select pubid from syspublications where  repl_freq = 0 and (name like @publication_to_add 
                or (('[' + name + ']') in (select name from #tmp_table)))))
        select @no_schema_replication =1
end

if @no_publication=1 and @publication_to_add <> '%' and LOWER(@publication_to_add)<>'none' and LOWER(@publication_to_add)<>'[none]'
    begin
        raiserror(21200, 16, -1, @publication_to_add)
        return (1)
    end

if @no_schema_replication=1 and LOWER(@publication_to_add)<>'none' and LOWER(@publication_to_add)<>'[none]'
    begin
        if @publication_to_add = '%'
            begin
                raiserror(21246, 16, -1, @source_object)
                return (1)
            end
        else
            begin
                raiserror(21245, 16, -1, @source_object, @publication_to_add)
                return (1)
            end
    end

select @at_publisher = 0

if exists (select * from sys.objects where name = 'sysarticles')
begin
    if exists (select a.objid from sysarticles a, syspublications p where a.objid=@objid
                and p.pubid = a.pubid
                and (p.name like @publication_to_add or charindex('[' + p.name + ']', @publication_to_add)>0))
    begin
        select @is_for_tran = 1
    end
end

if exists (select * from sys.objects where name = 'sysmergearticles')
begin
    if exists (select a.objid from sysmergearticles a, sysmergepublications p where a.objid=@objid
                and p.pubid = a.pubid
                and (p.name like @publication_to_add or charindex('[' + p.name + ']', @publication_to_add)>0))
    begin
        select @is_for_merge = 1
    end
end
else
    select @is_for_merge = 0

-- Cannot add yukon specific datatypes using repladdcolumn when backward comp level is less than 90
-- for merge. For tran we never adding these datatypes using sp_repladdcolumn. Use alter table for tran.
if (@is_for_merge = 1) and (@is_yukon_datatype = 1)
begin
    if ((select min(backward_comp_level) from dbo.sysmergepublications where pubid 
            in (select pubid from dbo.sysmergearticles where objid=@objid))    < 90)
    begin
        raiserror(25014, 16, -1)
        return (1)
    end
end
else if (@is_for_tran = 1) and (@is_yukon_datatype = 1)
begin
    raiserror(25014, 16, -1)
    return (1)
end

if (@is_for_tran =1 and @force_reinit_subscription = 0)
begin
    if (@is_timestamp_column = 1 )
    begin
        raiserror(21380, 16, -1)
        return (1)
    end
    if (@is_identity_column = 1  and @is_identity_column_not_for_replication <> 1)
    begin
    begin
        raiserror(21810, 16, -1)
        return (1)
    end
    end
    if exists (SELECT P.pubid FROM dbo.syspublications P, dbo.sysarticles A, dbo.syssubscriptions S 
                    WHERE A.objid = @objid    and A.pubid = P.pubid and A.artid = S.artid
                        and (P.allow_sync_tran = 1 or P.allow_queued_tran = 1) 
                        and S.status = 2  -- active
                        and S.sync_type != 2 -- not 'none'
                        and S.update_mode != 0 ) -- not 'read only'

    begin 
        raiserror(21381, 16, -1, @tablename)
        return (1)
    end
end

begin TRAN
save tran sp_repladdcolumn
    /*
    if not exists (select * from tempdb.sys.objects where name = '##MS_internal_old_style_DDL_support_being_used')
        create table ##MS_internal_old_style_DDL_support_being_used(db_name sysname, objid int)

    insert ##MS_internal_old_style_DDL_support_being_used(db_name, objid) values(db_name(), @objid)
    if @@ERROR<>0
        goto FAILURE
    */    
    if not exists (select * from sys.objects where name='sysmergearticles')
        select @not_for_merge = 1
    else
        if not exists (select * from dbo.sysmergearticles where objid=@objid)
            select @not_for_merge =1

    if not exists (select * from sys.objects where name='sysarticles')
        select @not_for_tran = 1
    else
        if not exists (select * from dbo.sysarticles where objid=@objid)
            select @not_for_tran =1

    -- Merge only supports a max of 246 columns. Check and error out if we already have
    -- 246 columns that are replicating and we are trying to add another one.

    if @is_for_merge = 1
    begin
        select @count = count(*) from sys.columns 
            where object_id=@objid  and 
                 is_computed<>1     and 
                 system_type_id <> type_id('timestamp') and
                 is_merge_published = 1

        IF @count > 245
        BEGIN
            RAISERROR(25006, 16, -1, @qual_source_object, 245)
            goto FAILURE
        END
    end


    -- ***********tran alter table part
    if @is_for_tran = 1
    begin
        if not exists (select * from sys.columns where name=@column and object_id =@objid)
        begin
            exec @retcode = sys.sp_MSprep_exclusive @qual_source_object
            if @@ERROR<>0 or @retcode <> 0
                goto FAILURE
            exec @retcode = sp_replincrementlsn @schema_start_lsn OUTPUT
            if @@ERROR<>0 or @retcode <> 0
                goto FAILURE

            exec ('alter table '+ @qual_source_object + ' add ' + @qual_column + ' ' + @typetext )
                if @@ERROR<>0
                    goto FAILURE
        end
    end
    -- if tran is enabled, but merge is not, sp_repladdcolumn with none pub list should just add the column
    else if @not_for_merge = 1 and @not_for_tran = 0 and (LOWER(@publication_to_add) = 'none' or LOWER(@publication_to_add) = '[none]')
    begin 
            exec ('alter table '+ @qual_source_object + ' add ' + @qual_column + ' ' + @typetext )
                if @@ERROR<>0
                    goto FAILURE
    end

    -- ***********merge alter table part
    if @is_for_merge=1
    begin
        -- obtain the snapshot/DDL/admin proc applock to avoid having contention with snapshot
        -- Attempt to get the lock with no wait
        exec @retcode = sys.sp_MSgetmergeadminapplock @timeout = 0, -- no wait
                                                      @lockowner = N'Transaction'
        if @retcode<>0 or @@error<>0
            goto FAILURE
        select @got_merge_admin_applock = 1
    
        exec @retcode = sys.sp_MSunmarkreplinfo @object=@tablename, @owner=@owner
        if @retcode<>0 or @@ERROR<>0
            goto FAILURE
        if    not exists (select * from sys.columns where name=@column and object_id =@objid)
        begin
            exec ('alter table '+ @qual_source_object + ' add ' + @qual_column + ' ' + @typetext )
                if @@ERROR<>0
                    goto FAILURE
        end
    end
    -- cannot add @not_for_tran = 1 as the case for "if none publist and both merge/tran are on"
    else if @not_for_merge = 0 and (LOWER(@publication_to_add) = 'none' or LOWER(@publication_to_add) = '[none]')
    begin 
        if not exists (select * from sys.columns where name=@column and object_id =@objid)
        begin
            exec ('alter table '+ @qual_source_object + ' add ' + @qual_column + ' ' + @typetext )
            if @@ERROR<>0
                goto FAILURE
        end
    end

    -- Now for real work if publist is not empty
    if @is_for_merge=1
    begin
        if not exists (select * from sys.columns where name=@column and object_id =@objid)
        begin
            exec ('alter table '+ @qual_source_object + ' add ' + @qual_column + ' ' + @typetext )
            if @@ERROR<>0
                goto FAILURE
        end

        /*
        ** whether the column is added to this publication, the articles whose underlying table contains
        ** a new column will be regareded as vertically partitioned.
        */ 
        update dbo.sysmergearticles set vertical_partition=1 where objid=@objid
        if @@ERROR<>0
            goto FAILURE

        /*
        ** Heterogenious subscriber are not to receive computed column or timestamp columns
        */
        declare #nosnapshot CURSOR LOCAL FAST_FORWARD for
            select p.name, a.name, a.pubid from dbo.sysmergepublications p, dbo.sysmergearticles a 
                    where p.pubid=a.pubid and a.objid=@objid and p.snapshot_ready=0 and (p.name like @publication_to_add or charindex('[' + p.name + ']', @publication_to_add)>0)
                            and (p.sync_mode=0 or @pass_to_heterogenious=1)                    
            open #nosnapshot
            fetch #nosnapshot into @pubname, @artname, @pubid
                while (@@fetch_status<>-1)
                begin
               		-- Indicate that this is an internal caller of sp_mergearticlecolumn
    				EXEC @retcode = sys.sp_MSsetcontext_internalcaller @onoff=1
	    			IF @@ERROR <> 0 or @retcode <> 0
		    			goto ERROR_EXIT

                    exec @retcode = sys.sp_mergearticlecolumn @pubname, @artname, @column, 'add', 'true'
                    if @retcode <>0 or @@ERROR<>0
                        goto ERROR_EXIT

            		-- Turn off indication that this is an internal caller of sp_mergearticlecolumn
    				EXEC @retcode = sys.sp_MSsetcontext_internalcaller @onoff=0
    				IF @@ERROR <> 0 or @retcode <> 0
    					goto ERROR_EXIT
                
                    fetch #nosnapshot into @pubname, @artname, @pubid                    
                end
        CLOSE #nosnapshot
        DEALLOCATE #nosnapshot


        /*
        ** Handle those cases where snapshot is already ran and new schema change needs to be added
        ** ; Heterogenious subscriber are not to receive computed column or timestamp columns
        */
        declare #addcolumn CURSOR LOCAL FAST_FORWARD for 
                select pubid, name, sync_objid, artid, nickname, conflict_table, ins_conflict_proc, destination_owner
                    from dbo.sysmergearticles where objid=@objid and pubid
                        in (select pubid from dbo.sysmergepublications where snapshot_ready>0 
                            and (sync_mode=0 or @pass_to_heterogenious=1))
        open #addcolumn
        fetch #addcolumn into @pubid, @artname, @sync_objid, @artid, @artnick, @conflict_table, @ins_conflict_proc, @dest_owner
        while (@@fetch_status <> -1)
        BEGIN
            if @dest_owner is not NULL
                select @dest_object = QUOTENAME(@dest_owner) + '.' + QUOTENAME(@tablename)
            else
                select @dest_object = QUOTENAME(@tablename)

            select @pubname=name, @publisher=publisher, @publisher_db=publisher_db
                from dbo.sysmergepublications where pubid=@pubid

            if @conflict_table is not NULL 
            begin
                select @con_id = object_id(quotename(@conflict_table))
                if @con_id is NULL
                    begin
                        raiserror(21286, 16, -1, @conflict_table)
                        GOTO INNER_FAIL
                    end
                if not exists (select name from sys.columns where name=@column and object_id=@con_id) and (@pubname like @publication_to_add or charindex('[' + @pubname + ']', @publication_to_add)>0)
                begin
                    select @typename = type_name(system_type_id), @len = max_length, @prec = precision,
                            @scale = scale, @iscomputed=is_computed, @xtype=system_type_id    
                        from sys.columns where name=@column and object_id=@objid
                    --we want to column property of 'computed' or 'timestamp' of the newly added column
                    if @iscomputed <> 1 and type_name(@xtype) <> 'timestamp'
                    begin
                        if @typename='nvarchar' or @typename='nchar' -- a unit of nchar takes 2 bytes 
                            select @len = @len/2
                            
                        exec @retcode = sys.sp_MSRecontructType @typename out, @len, @prec, @scale
                        if @@error<>0 OR @retcode <>0 
                            GOTO INNER_FAIL

                        --doing so instead of using @typetext as we once did is that we do not want any constraint or identity properties 
                        --defined on conflict tables. Also it is safe to make the column NULLable in conflict tables.
                        select @command = 'alter table ' + QUOTENAME(@conflict_table) + ' add ' + @qual_column + ' ' + @typename + ' NULL '
                    end
                    else
                    --continue to use typetext when adding computed/timestamp column to the conflict tables.
                    begin
                        select @command = 'alter table ' + QUOTENAME(@conflict_table) + ' add ' + @qual_column + ' ' + @typetext                        
                    end
                    exec (@command)
                    if @@ERROR<>0
                        goto INNER_FAIL

                end
            end

            /*
            ** Force the re-generation of conflict insert table cause the schema is changed for sure
            */
            if @ins_conflict_proc is not NULL and object_id(@ins_conflict_proc) is not NULL and (@pubname like @publication_to_add or charindex('[' + @pubname + ']', @publication_to_add)>0)
            begin
                select @ins_conflict_proc = QUOTENAME(@ins_conflict_proc)
                
                exec ('drop procedure ' + @ins_conflict_proc)
                if @@ERROR<>0
                    goto INNER_FAIL
                update dbo.sysmergearticles set ins_conflict_proc=NULL where pubid=@pubid and artid=@artid
                if @@ERROR<>0
                    goto INNER_FAIL
            end

            /*
            ** Force the regeneration of publication view for all publications that publish the current table.
            */
            update dbo.sysmergearticles set vertical_partition=1 where artid=@artid and pubid=@pubid
            if @@ERROR<>0
                goto INNER_FAIL
            select @at_publisher=0
            if @publisher=publishingservername() and @publisher_db=db_name()
            begin
                select @at_publisher=1
                if @pubname like @publication_to_add or charindex('[' + @pubname + ']', @publication_to_add)>0
                begin
                    select @schematext = 'exec sp_repladdcolumn ''' + replace(@dest_object, '''', '''''') + ''',''' + replace(@column, '''', '''''') + ''','+     QUOTENAME(@typetext) + ', ''' + replace(@publication_to_add, '''', '''''') + ''', 1'    
                    select @schemaversion = schemaversion from dbo.sysmergeschemachange
                    if (@schemaversion is NULL)
                        set @schemaversion = 1
                    else
                        select @schemaversion = 1 + max(schemaversion) from dbo.sysmergeschemachange        
                    set @schemaguid = newid()
                    set @schematype = 11 /* alter table */

                    -- Indicate that this is an internal caller of sp_mergearticlecolumn
                    EXEC @retcode = sys.sp_MSsetcontext_internalcaller @onoff=1
                    IF @@ERROR <> 0 or @retcode <> 0
                        goto INNER_FAIL

                    exec @retcode = sys.sp_mergearticlecolumn @pubname, @artname, @column, 'add','true'
                    if @retcode<>0 or @@ERROR<>0
                        goto INNER_FAIL -- need to deallocate cursor for this loop.

                    -- Turn off indication that this is an internal caller of sp_mergearticlecolumn
                    EXEC @retcode = sys.sp_MSsetcontext_internalcaller @onoff=0
                    IF @@ERROR <> 0 or @retcode <> 0
                        goto INNER_FAIL
                        
                    exec @retcode=sys.sp_MSinsertschemachange @pubid, @artid, @schemaversion, @schemaguid, @schematype, @schematext
                    if @@ERROR<>0 or @retcode<>0 
                        goto INNER_FAIL
                        
                    --------------------------------------
                    -- prepare parsing event
                    create table #SSCE_parsedschemacmds(
                        id int identity,
                        DDLsubtype sysname, 
                        TableOwner sysname,  
                        TableName sysname,
                        ColumnName sysname NULL, 
                        ColumnAttr sysname NULL
                    )
                    select @schematext = 'alter table ' +  @dest_object + ' add ' + QUOTENAME(@column) + ' ' + @typetext
                    insert #SSCE_parsedschemacmds(DDLsubtype, TableOwner, TableName, 
                        ColumnName, ColumnAttr) 
                        exec sys.sp_replddlparser @ddlCmd=@schematext
                    if @@ERROR <> 0
                    begin
                        DROP TABLE #SSCE_parsedschemacmds
                        goto INNER_FAIL
                    end                    

                    /* If the sp_repladdcolumn @typetext contains foreign key constraints, use the sp_MSNonSQLDDL to post them as separate schema changes */
                	if exists( select * from #SSCE_parsedschemacmds psc where psc.DDLsubtype = N'ADDREFERENCE')
                	begin
                    	--------------------------------------
                    	/* Fix up foreign key constraint names */
                        declare @colname sysname
                        declare @typeid varchar(10)
                        declare @modified_date datetime
                        declare @row_id int

                    	DECLARE #fkcursor CURSOR LOCAL FAST_FORWARD for
                    		select name, type, modify_date from sys.foreign_keys	
                    					where parent_object_id = @objid
                    		order by modify_date desc

                    	open #fkcursor
                    	fetch #fkcursor into @colname, @typeid, @modified_date 
                    	while @@fetch_status <> -1
                    	begin
                       		set @row_id = NULL
                    		select top 1 @row_id = id
                    					from #SSCE_parsedschemacmds psc where 
                    						psc.DDLsubtype = N'ADDREFERENCE'
                    						and len(isnull(ColumnName, '')) = 0 order by id desc
                       		
                    		if @row_id is null
                    		begin
               	    			break
                	    	end
                		    else
                    		begin
                    			update #SSCE_parsedschemacmds set ColumnName = @colname where id = @row_id
                    			if @@error > 0
                    				goto INNER_FAIL
                    		end
                        					
                       		fetch #fkcursor into @colname, @typeid, @modified_date 
                       	end
                      	close #fkcursor
                      	deallocate #fkcursor

                    	
                        declare @statement_id int
                        declare @schemasubtype int
                        declare @subtype sysname

                        declare @parsed_columnname sysname
                        declare #alter_table_cursor CURSOR LOCAL FAST_FORWARD FOR 
                            select DISTINCT id, DDLsubtype, ColumnName 
                            from #SSCE_parsedschemacmds
                            order by id ASC
                            for read only
                        open #alter_table_cursor
                        fetch #alter_table_cursor into @statement_id, @subtype, @parsed_columnname

                        while (@@fetch_status <> -1)
                        begin
                            if @subtype=N'ADDCOLUMN'
                                    select @schemasubtype = 1
                            else if @subtype = N'ADDPRIMARYKEY'
                                select @schemasubtype = 4
                            else if @subtype = N'ADDUNIQUE'
                                select @schemasubtype = 5
                            else if @subtype = N'ADDREFERENCE'
                                select @schemasubtype = 6
                            else if @subtype = N'ADDDEFAULT'
                                select @schemasubtype = 8
                            else
                                select @schemasubtype = 0 --dummy row

                            exec @retcode = sys.sp_MSNonSQLDDL @qual_source_object, @pubid, @parsed_columnname, @schemasubtype --add column
                            if @@ERROR<>0 or @retcode<>0 
                                begin
                                    DROP TABLE #SSCE_parsedschemacmds
                                    close #alter_table_cursor
                                    deallocate #alter_table_cursor
                                    goto INNER_FAIL
                                end                
                            fetch #alter_table_cursor into @statement_id, @subtype, @parsed_columnname
                		end -- while-loop over #alter_table_cursor 
                        close #alter_table_cursor
                        deallocate #alter_table_cursor
                	end
                	else
                	begin
                        --insert a schema change for non SQL subscribers    
                        select @schematext = 'alter table ' +  @dest_object + ' add ' + @column + ' ' + @typetext
                        select @schemaversion = @schemaversion + 1
                        set @schematype = 13 -- for non SQL subscribers use only
                        set @schemaguid = newid()
                        exec @retcode=sys.sp_MSinsertschemachange @pubid, @artid, @schemaversion, @schemaguid, @schematype, @schematext
                        if @@ERROR<>0 or @retcode<>0 
                            begin
                                DROP TABLE #SSCE_parsedschemacmds
                                goto INNER_FAIL
                            end
                	end
            		DROP TABLE #SSCE_parsedschemacmds
                end
            end

            if @at_publisher=1
            begin
                exec @retcode = sys.sp_MSpublicationview @publication = @pubname, @force_flag = 2, @articlename = @artname
                
                if @retcode<>0 or @@ERROR<>0
                    goto INNER_FAIL
            end

            select @columns_in_partition=count(*) from sys.columns where object_id = @sync_objid
            if @columns_in_partition>246
            begin
                raiserror(21759, 16, 1,@column, @source_object)
                goto INNER_FAIL
            end

            -- only 246 colv entries are allowed if article belongs to a publication with Shiloh compat level
            if ((select min(backward_comp_level) from dbo.sysmergepublications where pubid 
                    in (select pubid from dbo.sysmergearticles where objid=@objid))    < 90)
                and
                sys.fn_cColvEntries_80(@pubid, @artnick) >= 246
            begin
                raiserror(21523,16,1,'@column','@source_object', 246)
                goto INNER_FAIL
            end

            exec @retcode = sys.sp_MSdroparticletriggers @tablename, @owner
            if @retcode<>0 or @@ERROR<>0
                goto INNER_FAIL
            exec @retcode = sys.sp_MSaddmergetriggers @qual_source_object
            if @retcode<>0 or @@ERROR<>0
                goto INNER_FAIL

            /*
            ** Force the regeneration of merge procs for all publications that publish the current table
            */
            if @at_publisher=1
                exec @retcode = sys.sp_MSsetartprocs @publication=@pubname, @article=@artname, @force_flag=0, @pubid=@pubid
            else
                exec @retcode = sys.sp_MSmakearticleprocs @pubid, @artid
            if @retcode<>0 or @@ERROR<>0
                goto INNER_FAIL
                
            /*
            ** passing in one more parameter to sp_MSgetconflictinsertproc such that there is 
            ** no select statement at the end of that SP as needed else where. The default is 1.
            */
            exec @retcode = sys.sp_MSgetconflictinsertproc @artid, @pubid, 0, 1
            if @retcode<>0 or @@ERROR<>0
                goto INNER_FAIL

            fetch #addcolumn into @pubid, @artname, @sync_objid, @artid, @artnick, @conflict_table, @ins_conflict_proc, @dest_owner
        END
        close #addcolumn
        deallocate #addcolumn
    end

    if @is_for_tran = 1
    begin 
        declare #trancolumn CURSOR LOCAL FAST_FORWARD for 
            select a.artid, p.name, p.allow_initialize_from_backup    from sysarticles a, syspublications p where a.objid=@objid
                and p.pubid = a.pubid
                and (p.name like @publication_to_add or charindex('[' + p.name + ']', @publication_to_add)>0)
        open #trancolumn
        fetch #trancolumn into @tran_artid, @pubname, @allow_initialize_from_backup
        while (@@fetch_status <> -1)
        BEGIN

            -- Error out if the current publication allows backup subscription
            -- and the column being added is a timestamp column (restriction is temporarily lifted)
--            if @allow_initialize_from_backup = 1 and @is_timestamp_column = 1
--            begin
--                raiserror(18797, 16, -1)
--                select @retcode = 1
--                goto DROPTRAN
--            end

            select @artname = name, @tran_pubid = pubid, @owner = dest_owner, @tablename = dest_table from sysarticles where artid=@tran_artid
            exec @retcode = sys.sp_articlecolumn @publication = @pubname, @article = @artname, @column = @column, 
                             @operation = 'add', @change_active = 2
                            ,@force_invalidate_snapshot = 1
                            ,@force_reinit_subscription = 1
                            ,@internal = 1
            if @retcode <>0 or @@ERROR<>0
                goto DROPTRAN
            if(@force_reinit_subscription = 0)    
            begin
                if(@owner is not NULL) and (len(@owner) > 0)
                    select @qual_dest_object = QUOTENAME(@owner) + N'.' 
                else 
                    select @qual_dest_object = N'' 
                if(@tablename is not null) and (len(@tablename) > 0)
                    select @qual_dest_object = @qual_dest_object + QUOTENAME(@tablename)
                else 
                    select @qual_dest_object = @qual_source_object
                exec @retcode = sys.sp_MSrepl_schema @pubname = @pubname 
                            ,@artid = @tran_artid
                            ,@qual_source_object = @qual_dest_object
                            ,@column = @column
                            ,@operation = 0 -- 0 is add, 1 is delete
                            ,@typetext = @typetext
                            ,@schema_change_script = @schema_change_script
                if @retcode <>0 or @@ERROR<>0
                    goto DROPTRAN
            end
            exec @retcode = sys.sp_MSreinit_article 
                            @publication = @pubname
                            ,@article = @artname
                            ,@need_new_snapshot = @force_invalidate_snapshot
                            ,@need_reinit_subscription = @force_reinit_subscription 
                            ,@force_invalidate_snapshot = @force_invalidate_snapshot
                            ,@force_reinit_subscription = @force_reinit_subscription
            if @retcode <>0 or @@ERROR<>0
                goto DROPTRAN
            if @allow_initialize_from_backup = 1
            begin
                -- If the column being added is an identity column that is 
                -- not marked 'not for replication', do so now. Re-acquire
                -- schema mod lock to make the code more resilient to changes
                -- although this must have been done inside sp_Mrepl_schema
                if @is_identity_column = 1 and 
                   @is_identity_column_not_for_replication <> 1
                begin
                    exec %%Object(MultiName = @qual_source_object).LockMatchID(ID = @objid, Exclusive = 1, BindInternal = 0)
                    --exec %%Object(MultiName = @qual_source_object).LockExclusiveMatchID(ID = @objid)
                    if @@error <> 0 begin select @retcode = 1 goto DROPTRAN end
                    exec %%ColumnEx(ObjectID = @objid, Name = @column).SetIdentityNotForRepl(Value = 1)
                    if @@error <> 0 begin select @retcode = 1 goto DROPTRAN end
                end
                -- Note that the min publication autonosync lsn is 
                -- incremented in sp_articlecolumn
            end
            fetch #trancolumn into @tran_artid, @pubname, @allow_initialize_from_backup            
        END
        close #trancolumn
        deallocate #trancolumn
        exec @retcode = sp_replincrementlsn @schema_end_lsn OUTPUT
        if @@ERROR<>0 or @retcode <> 0
            goto FAILURE
        if (@schema_start_lsn is not null) and (@schema_end_lsn is not null)
        begin
            insert systranschemas (tabid, startlsn, endlsn, typeid) values (@objid, @schema_start_lsn, @schema_end_lsn, 51)
            if @@ERROR<>0
                goto FAILURE
            exec @retcode = sys.sp_replflush @objid, @schema_start_lsn, @schema_end_lsn
            if @@ERROR<>0 or @retcode <> 0
                goto FAILURE
        end
        else
            goto FAILURE
    end
    
    /* Get back to its original replication state */
    if @is_for_merge=1
    begin
        exec @retcode = sys.sp_MSmarkreplinfo @tablename, @owner
        if @retcode<>0 or @@ERROR<>0
            goto FAILURE
    end

    -- end of signal
    EXEC @retcode = sys.sp_MSsetcontext_bypasswholeddleventbit @onoff=0

    if @got_merge_admin_applock=1
        exec sys.sp_MSreleasemergeadminapplock @lockowner = N'Transaction'

COMMIT TRAN
--delete ##MS_internal_old_style_DDL_support_being_used where db_name=db_name() and objid= @objid
return (0)

INNER_FAIL:
CLOSE #addcolumn
DEALLOCATE #addcolumn

GOTO FAILURE

ERROR_EXIT:
CLOSE #nosnapshot
DEALLOCATE #nosnapshot
GOTO FAILURE

DROPTRAN:
CLOSE #trancolumn
DEALLOCATE #trancolumn

FAILURE:
    if @got_merge_admin_applock=1
        exec sys.sp_MSreleasemergeadminapplock @lockowner = N'Transaction'
    rollback tran sp_repladdcolumn
    commit tran
    raiserror(21285, 16, -1, @column, @source_object)
    -- end of signal
    EXEC @retcode = sys.sp_MSsetcontext_bypasswholeddleventbit @onoff=0
    return (1)    
GO
GRANT EXECUTE ON [sys].[sp_repladdcolumn] TO [public] AS [dbo]
GO
