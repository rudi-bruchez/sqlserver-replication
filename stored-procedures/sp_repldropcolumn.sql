SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_repldropcolumn]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_repldropcolumn] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_repldropcolumn]
	@source_object [nvarchar](270),
	@column [sysname],
	@from_agent [int],
	@schema_change_script [nvarchar](4000),
	@force_invalidate_snapshot [bit],
	@force_reinit_subscription [bit]
WITH EXECUTE AS CALLER
AS
set nocount on
declare @objid          int
declare @at_publisher   bit
declare @pubname        sysname
declare @artname        sysname
declare @tran_pubname   sysname
declare @tran_artname   sysname
declare @tran_artid     int
declare @tran_pubid     int
declare @colid          int
declare @missing_index  int
declare @tablename      sysname
declare @pubid          uniqueidentifier
declare @artid          uniqueidentifier
declare @partitioned    int
declare @missing_count  int
declare @missing_bm     varbinary(128)
declare @old_missing_bm varbinary(128)
declare @schematext     nvarchar(4000)
declare @schemaversion  int
declare @not_for_merge  bit            -- 1 if the db is not merge replication enabled or the table is not in merge publication
declare @qual_source_object nvarchar(517)
declare @qual_dest_object nvarchar(517)
declare @schematype        int
declare @schemaguid        uniqueidentifier
declare @conflict_table    sysname
declare @ins_conflict_proc nvarchar(258)
declare @publisher        sysname
declare @publisher_db    sysname
declare @command        nvarchar(3000)
declare @sync_objid        int
declare @retcode         int
declare @snapshot_ready int
declare @con_id            int
declare @dest_owner        nvarchar(258)
declare @dest_object    nvarchar(386)
declare @owner            sysname
declare @columnbm        varbinary(128)
declare @in_partition    int
declare @merge_pub_object_bit    int
declare @is_for_merge    bit        -- 1 if db is merge replication enabled and table is in merge publication, ie., not @not_for_merge
declare @is_for_tran    bit
declare @no_schema_replication bit
declare @servername        sysname
declare @dbname            sysname
declare @con_name        sysname
declare @v_unique_index    int
declare @qual_column        nvarchar(258)
declare @indid                int
declare @index_cnt             int
declare @pkkey                sysname
declare @v_unique_constraint    int
declare @merge_pub_unmarkcolumn_bit    int
declare @merge_pub_markcolumn_bit    int
declare @schema_start_lsn binary(10)
declare @schema_end_lsn binary(10)
        ,@BinVar varbinary(128)
declare @contextset bit
declare @got_merge_admin_applock bit

select @got_merge_admin_applock = 0

set @contextset=0

if not exists (select * from sys.objects where name='sysmergepublications') and
    not exists (select * from sys.objects where name='syspublications')
begin
    raiserror(21230, 16, -1)
    return (1)
end

/*
** Security Check
*/
EXEC @retcode = sys.sp_MSreplcheck_subscribe_withddladmin
IF @@ERROR <> 0 or @retcode <> 0
    return (1)

-- check to see if this stored procedure is called via replication agent.
if sessionproperty('replication_agent')<>1
    select @from_agent = 0
else
    select @from_agent = 1
select @merge_pub_markcolumn_bit = 0x4000
select @merge_pub_unmarkcolumn_bit = ~@merge_pub_markcolumn_bit
select @v_unique_constraint = 4096
select @v_unique_index      = 2         -- status in sysindexes

select @qual_column=QUOTENAME(@column)

select @no_schema_replication = 0
select @not_for_merge    = 0
select @merge_pub_object_bit     = 128
select @objid = object_id(@source_object)
select @servername=publishingservername()
select @dbname=db_name()

if @objid is NULL
begin
    --if table does not exists and the SP is called from replication agent, ignore the error and exit with success.
    if @from_agent=1
        return (0)
    else
    begin
        raiserror(14027, 16, -1, @source_object)
        return (1)
    end
end

if not exists (select * from sys.columns where name=@column and object_id=@objid)
begin
    if @from_agent=0
    begin
        raiserror(21166, 16, -1, @column)
        return (1)
    end
    else
        return (0)
end

select @indid = indid from sysindexes where id = @objid and (status & 2048) <> 0    /* PK index */
select @index_cnt = 1
while (@index_cnt <= 16)
begin
    select @pkkey = INDEX_COL(@source_object, @indid, @index_cnt)
    if @pkkey is NULL
        break
    if @pkkey=@column
    begin
        raiserror(21264, 16, -1, @column, @source_object)
        return (1)
    end
    select @index_cnt = @index_cnt + 1
end
    
/*
** Check for unique index defined on this column - to disallow such a column from being dropped
*/    
if exists (select * from sysindexes where id=@objid 
    and (status & @v_unique_index = @v_unique_index 
            or status & @v_unique_constraint = @v_unique_constraint))
begin
    declare @keys varbinary(816)
    declare @i         int
    declare #check_unique CURSOR LOCAL FAST_FORWARD for 
        select indid from sysindexes where id=@objid 
                and (status & @v_unique_index = @v_unique_index 
                    or status & @v_unique_constraint = @v_unique_constraint)
    open #check_unique
    fetch #check_unique into @indid
    while (@@fetch_status<>-1)
    begin
        SELECT @i = 1
        WHILE (@i <= 16)
        BEGIN
            SELECT @pkkey = INDEX_COL(@source_object, @indid, @i)
            if @pkkey is NULL
                break
            if @pkkey=@column
            BEGIN
                raiserror(21265, 16, -1, @column, @source_object)
                close #check_unique
                deallocate #check_unique
                return (1)
            END
            select @i = @i + 1
        END
        fetch #check_unique into @indid
    end
    close #check_unique
    deallocate #check_unique
end

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

-- if in both tran and merge publication
if exists (select * from sys.objects where name='sysmergepublications')
    and exists (select * from sys.objects where name='syspublications')
begin
    if not exists (select * from sysarticles where objid=@objid)
            and not exists (select * from dbo.sysmergearticles where objid=@objid)
        select @no_schema_replication=1
end
-- if a merge publication
else if exists (select * from sys.objects where name='sysmergepublications')
begin
    if not exists (select * from dbo.sysmergearticles where objid=@objid)
        select @no_schema_replication = 1
end
-- if a tran publication
else if exists (select * from sys.objects where name='syspublications')
begin
    if not exists (select * from sysarticles a join syspublications p on a.pubid = p.pubid 
	    where a.objid=@objid and p.repl_freq = 0)
        select @no_schema_replication =1
end

if @no_schema_replication=1
begin
    raiserror(21246, 16, -1, @source_object)
    return (1)
end

if exists (select * from sys.objects where name = 'sysmergearticles')
begin
    if exists  (select * from dbo.sysmergearticles where objid=@objid)
        select @is_for_merge=1
    else
        select @is_for_merge=0
end
else
    select @is_for_merge=0

-- PARSENAME VARS
    declare      @UnqualName      sysname  --rightmost name node
    declare      @QualName1       sysname  
-- END PARSENAME VARS

    select @UnqualName = PARSENAME(@source_object, 1)
    select @QualName1 = PARSENAME(@source_object, 2)
    if @UnqualName IS NULL
         return 1
    if @QualName1 is not NULL
        select @owner = @QualName1
            else select @owner=schema_name(schema_id) from sys.objects where object_id = @objid

select @tablename = @UnqualName
select @qual_source_object = QUOTENAME(@owner) + N'.' + QUOTENAME(@tablename)
select @at_publisher = 0
select @colid=column_id from sys.columns where object_id=@objid and name=@column
if @colid is NULL
    begin
        raiserror(21166, 16, -1, @column)
        return (1)
    end

/*
** Considering holes, colid is not necessarily the one in bitmap. Get this value from count(*)
*/
select @missing_index = @colid
begin TRAN
save tran sp_repldropcolumn
    /* will be in once server check in full metadata support
    **
    if not exists (select * from tempdb.sys.objects where name = '##MS_internal_old_style_DDL_support_being_used')
        create table ##MS_internal_old_style_DDL_support_being_used(db_name sysname, objid int)

    insert ##MS_internal_old_style_DDL_support_being_used(db_name, objid) values(db_name(), @objid)
    if @@ERROR<>0
        goto FAILURE
    **    
    */
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
    end


    select @is_for_tran = 0    
    if exists (select * from sys.objects where name='sysarticles')
    begin
        if exists (select * from dbo.sysarticles where objid=@objid)
        begin
            if exists (SELECT P.pubid FROM dbo.syspublications P, dbo.sysarticles A, dbo.syssubscriptions S 
                    WHERE A.objid = @objid    and A.pubid = P.pubid and A.artid = S.artid
                        and (P.allow_sync_tran = 1 or P.allow_queued_tran = 1) 
                        and S.status = 2  -- active
                        and S.sync_type != 2 -- not 'none'
                        and S.update_mode != 0 ) -- not 'read only'
             and @force_reinit_subscription = 0
            begin 
                raiserror(21381, 16, -1, @tablename)
                goto FAILURE
            end

            select @is_for_tran =1
        end
    end

    if @is_for_tran = 1 or @is_for_merge=1
    begin
            EXEC @retcode = sys.sp_MSsetcontext_bypasswholeddleventbit @onoff=1
            IF @@ERROR <> 0 or @retcode <> 0
                RETURN(1)
        set @contextset=1
    end

    /*
    ** First call TRAN Level stored procedure to 
    */
    if @is_for_tran = 1
    begin
        exec @retcode = sys.sp_MSprep_exclusive @qual_source_object
        if @@ERROR<>0 or @retcode <> 0
            goto FAILURE
        exec @retcode = sp_replincrementlsn @schema_start_lsn OUTPUT
        if @@ERROR<>0 or @retcode <> 0
            goto FAILURE

        declare #trancolumn CURSOR LOCAL FAST_FORWARD for 
            select a.artid, p.name from sysarticles a, syspublications p where a.objid=@objid
                    and p.pubid = a.pubid
        open #trancolumn
        fetch #trancolumn into @tran_artid, @tran_pubname
        while (@@fetch_status <> -1)
        BEGIN
            select @tran_artname=name from sysarticles where artid=@tran_artid
            exec @retcode = sys.sp_articlecolumn @publication = @tran_pubname, @article = @tran_artname, @column = @column, 
                         @operation = 'drop', @change_active = 2
                        ,@force_invalidate_snapshot = 1
                        ,@force_reinit_subscription = 1
                        ,@internal = 1
            if @retcode <>0 or @@ERROR<>0
                goto DROPTRAN
            fetch #trancolumn into @tran_artid, @tran_pubname            
        END
        close #trancolumn
        deallocate #trancolumn
    end


    if not exists (select * from sys.objects where name='sysmergearticles')
        select @not_for_merge = 1
    else
        if not exists (select * from dbo.sysmergearticles where objid=@objid)
            select @not_for_merge =1

            
    if @not_for_merge = 1 
    begin
        if exists (select * from sys.columns where name=@column and object_id =@objid)
        begin
            exec ('alter table '+ @qual_source_object + ' drop column ' + @qual_column )
                    if @@ERROR<>0
                        goto FAILURE
            exec @retcode = sys.sp_MSverifytranfilter @objid
            if @@ERROR <> 0 or @retcode <> 0
            begin
                goto FAILURE
            end                    
            
        end
    end
    else
    begin
        if exists (select * from dbo.sysmergepublications where pubid in 
            (select pubid from dbo.sysmergearticles where objid=@objid) and snapshot_ready=0)
            and exists (select * from sys.columns where name=@column and object_id =@objid)
        begin
            declare #nosnapshot CURSOR LOCAL FAST_FORWARD for
                select p.name, a.name from dbo.sysmergepublications p, dbo.sysmergearticles a 
                    where p.pubid=a.pubid and a.objid=@objid and p.snapshot_ready=0
            open #nosnapshot
            fetch #nosnapshot into @pubname, @artname
            while (@@fetch_status<>-1)
            begin
        		-- Indicate that this is an internal caller of sp_mergearticlecolumn
				EXEC @retcode = sys.sp_MSsetcontext_internalcaller @onoff=1
				IF @@ERROR <> 0 or @retcode <> 0
                    goto ERROR_EXIT

                exec @retcode = sys.sp_mergearticlecolumn @pubname, @artname, @column, 'drop', 'true'
                if @retcode <>0 or @@ERROR<>0
                    goto ERROR_EXIT

        		-- Turn off indication that this is an internal caller of sp_mergearticlecolumn
				EXEC @retcode = sys.sp_MSsetcontext_internalcaller @onoff=0
				IF @@ERROR <> 0 or @retcode <> 0
                    goto ERROR_EXIT
            
                fetch #nosnapshot into @pubname, @artname
            end
            close #nosnapshot
            deallocate #nosnapshot
        end

        declare #dropcolumn_schema CURSOR LOCAL FAST_FORWARD for 
                select name, pubid, artid, destination_owner, columns from dbo.sysmergearticles where objid=@objid and pubid
                            in (select pubid from dbo.sysmergepublications where snapshot_ready>0) order by pubid ASC
        open #dropcolumn_schema
        fetch #dropcolumn_schema into @artname, @pubid, @artid, @dest_owner, @columnbm
        while (@@fetch_status <> -1)
        BEGIN
            if @dest_owner is not NULL
                select @dest_object = QUOTENAME(@dest_owner) + N'.' + QUOTENAME(@tablename)
            else
                select @dest_object = QUOTENAME(@tablename)

            exec @in_partition = sys.sp_MStestbit @bm=@columnbm, @coltotest=@colid

            select @pubname=name, @publisher=publisher, @publisher_db=publisher_db
                from dbo.sysmergepublications where pubid=@pubid
            select @at_publisher=0
            if @publisher=publishingservername() and @publisher_db=db_name() and @in_partition<>0
            begin
                select @at_publisher=1
                select @schematext = 'exec sp_repldropcolumn ''' + replace(@dest_object, '''', '''''') + ''', ''' + replace(@column, '''', '''''') + ''', 1'
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
                    goto INNER_FAIL2

                exec @retcode = sys.sp_mergearticlecolumn @pubname, @artname, @column, 'drop', 'true'
                if @retcode<>0 or @@ERROR<>0
                    goto INNER_FAIL2 -- need to deallocate cursor for this loop.

                -- Turn off indication that this is an internal caller of sp_mergearticlecolumn
                EXEC @retcode = sys.sp_MSsetcontext_internalcaller @onoff=0
                IF @@ERROR <> 0 or @retcode <> 0
                    goto INNER_FAIL2
                
                exec @retcode=sys.sp_MSinsertschemachange @pubid, @artid, @schemaversion, @schemaguid, @schematype, @schematext
                if @@ERROR<>0 or @retcode<>0 
                    goto INNER_FAIL2
                    
                select @schematext = 'alter table ' +  @dest_object + ' drop column ' + @qual_column 
                select @schemaversion = @schemaversion + 1
                set @schematype = 13 -- for Jet use only
                set @schemaguid = newid()
                exec @retcode=sys.sp_MSinsertschemachange @pubid, @artid, @schemaversion, @schemaguid, @schematype, @schematext
                if @@ERROR<>0 or @retcode<>0 
                    goto INNER_FAIL2

                select @schematext = N' if object_id(''' + @dest_object + ''') is not NULL and exists (select * from syscolumns where name = ''' + replace(@column, '''', '''''') + ''' and id = object_id(''' + @dest_object + ''')) ' +'alter table ' +  @dest_object + ' drop column ' + QUOTENAME(@column)
                select @schemaversion = @schemaversion + 1
                set @schematype = 300 -- for 90+ ddl user
                set @schemaguid = newid()
                exec @retcode=sys.sp_MSinsertschemachange @pubid, @artid, @schemaversion, @schemaguid, @schematype, @schematext
                if @@ERROR<>0 or @retcode<>0 
                    goto INNER_FAIL2
            end
            fetch #dropcolumn_schema into @artname, @pubid, @artid, @dest_owner, @columnbm
        END
        close #dropcolumn_schema
        deallocate #dropcolumn_schema

        /* drop the column only once */
        if exists (select  *  from sys.columns where object_id=@objid and name=@column)
        begin
            select @command = 'alter table ' + @qual_source_object + ' drop column ' + @qual_column
            exec (@command)
            if @@ERROR<>0
                GOTO INNER_FAIL

            -- if transactionally replicated, verify that filter columns weren't dropped

            if( @is_for_tran = 1 )
            begin
                exec @retcode = sys.sp_MSverifytranfilter @objid
                if @@ERROR <> 0 or @retcode <> 0
                begin
                    goto FAILURE
                end                    
            end
        end
        declare #dropcolumn CURSOR LOCAL FAST_FORWARD for 
                select pubid, name, sync_objid, artid, missing_col_count, missing_cols, 
                    conflict_table, ins_conflict_proc from dbo.sysmergearticles where objid=@objid and pubid
                            in (select pubid from dbo.sysmergepublications where snapshot_ready>0) order by pubid ASC
        open #dropcolumn
        fetch #dropcolumn into @pubid, @artname, @sync_objid, @artid, 
                @missing_count, @missing_bm, @conflict_table, @ins_conflict_proc
        while (@@fetch_status <> -1)
        BEGIN
            select @pubname=name, @publisher=publisher, @publisher_db=publisher_db
                from dbo.sysmergepublications where pubid=@pubid
            select @at_publisher=0
            if @publisher=publishingservername() and @publisher_db=db_name()
                select @at_publisher=1

            if @conflict_table is not NULL 
            begin
                select @con_id = object_id(quotename(@conflict_table))
                if @con_id is NULL
                begin
                    raiserror(21286, 16, -1, @conflict_table)
                    GOTO INNER_FAIL
                end

            select @colid=column_id from sys.columns where object_id = @con_id and name=@column            
            

                if exists (select name from sys.columns where name=@column and object_id=@con_id)
                begin
                    select @command = 'alter table ' + QUOTENAME(@conflict_table) + ' drop column ' + @qual_column
                    exec (@command)
                    if @@ERROR<>0
                        goto INNER_FAIL
                end
            end

            /*
            ** Force the re-generation of conflict insert table cause the schema is changed for sure
            */
            if @ins_conflict_proc is not NULL and object_id(@ins_conflict_proc) is not NULL
            begin
                select @ins_conflict_proc = QUOTENAME(@ins_conflict_proc)
                
                exec ('drop procedure ' + @ins_conflict_proc)
                if @@ERROR<>0
                    goto INNER_FAIL
                update dbo.sysmergearticles set ins_conflict_proc=NULL where pubid=@pubid and artid=@artid
                if @@ERROR<>0
                    goto INNER_FAIL
            end

            if @at_publisher=1
            begin
                exec @retcode = sys.sp_MSpublicationview @publication = @pubname, @force_flag = 2, @articlename = @artname
                if @retcode<>0 or @@ERROR<>0
                begin
                    raiserror(21201, 16, -1) 
                    goto INNER_FAIL
                end
            end
            select @missing_count=@missing_count + 1
            select @old_missing_bm=@missing_bm
            exec @retcode=sys.sp_MSsetbit @missing_bm OUTPUT, @missing_index
            if @retcode<>0 or @@ERROR<>0
                goto INNER_FAIL
            --if no change, that is, the column is already marked as missing, do not increase 
            --its count
            
            if @missing_bm<>@old_missing_bm
            begin
                update dbo.sysmergearticles set missing_col_count=@missing_count, missing_cols=@missing_bm
                        where pubid=@pubid and artid=@artid
                if @@ERROR<>0
                    goto INNER_FAIL
            end


                
            exec @retcode = sys.sp_MSdroparticletriggers @tablename, @owner
            if @retcode<>0 or @@ERROR<>0
                goto INNER_FAIL
            exec @retcode = sys.sp_MSaddmergetriggers @qual_source_object
            if @retcode<>0 or @@ERROR<>0
                goto INNER_FAIL
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

            fetch #dropcolumn into @pubid, @artname, @sync_objid, @artid, 
                @missing_count, @missing_bm, @conflict_table, @ins_conflict_proc
        END
        CLOSE #dropcolumn
        DEALLOCATE #dropcolumn

        -- do column index shifting for MSmerge_contents.colv1 if there is dropped column
        declare @rowguid uniqueidentifier
        declare @delcols_now varbinary(128) 
        declare @cols_being_dropped varbinary(128)
        declare @input_colv1 varbinary(2953)
        declare @output_colv1 varbinary(2953)
        declare @islightweight bit

        select top 1 @islightweight= lightweight
            from dbo.sysmergearticles where objid=@objid

        exec sys.sp_MSfillup_deleted_cols @objid, @delcols_now OUTPUT
        set @delcols_now=isnull(@delcols_now, 0x00)
        begin
            update dbo.sysmergearticles set deleted_cols=@delcols_now
                where objid=@objid

            -- set bitmap using @colid
            exec sys.sp_MSsetbit @cols_being_dropped out, @colid

            if @islightweight <>1 and @islightweight is not null
            begin
                -- going over all pub/art with the object and adjust their MSmerge_contents.colv1
                declare cur_RowColv1 CURSOR LOCAL FORWARD_ONLY for 
                        select rowguid, colv1
                        from dbo.MSmerge_contents 
                        where colv1 is not null and tablenick in (select nickname from dbo.sysmergearticles where objid=@objid)    
                        FOR update of colv1
                    
                open cur_RowColv1
                fetch next from cur_RowColv1 into @rowguid, @input_colv1

                    while (@@fetch_status <> -1)
                    begin
                        exec @retcode=sys.sp_MSget_shifted_colv1 @cols_being_dropped, @input_colv1, @output_colv1 output

                        if @@error<>0 or @retcode<>0 
                            goto FAILURE

                        update dbo.MSmerge_contents 
                            set colv1=@output_colv1
                            where current of cur_RowColv1
                        
                        fetch next from cur_RowColv1 into @rowguid, @input_colv1
                    end

                    close cur_RowColv1
                    deallocate cur_RowColv1
              end 
              -- what about LWS?

        end


        if @is_for_merge=1
        begin
            exec @retcode = sys.sp_MSmarkreplinfo @tablename, @owner
            if @retcode<>0 or @@ERROR<>0
                goto FAILURE
        end
    end

-- finally, if it's transactional, trigger a reinit
if @is_for_tran = 1
begin

    if exists (select * from sysarticles where objid = @objid)
    begin
        declare #trancolumn CURSOR LOCAL FAST_FORWARD for 
            select a.artid, p.name 
            from sysarticles a, syspublications p
            where a.objid=@objid
            and p.pubid = a.pubid

        open #trancolumn
        fetch #trancolumn into @tran_artid, @tran_pubname
        while (@@fetch_status <> -1)
        BEGIN
            select @tran_artname=name, @tran_pubid = pubid, @owner = dest_owner, @tablename = dest_table from sysarticles where artid=@tran_artid
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
                exec @retcode = sys.sp_MSrepl_schema @pubname = @tran_pubname 
                            ,@artid = @tran_artid
                            ,@qual_source_object = @qual_dest_object
                            ,@column = @column
                            ,@operation = 1 -- 0 is add, 1 is delete
                            ,@schema_change_script = @schema_change_script
                if @retcode <>0 or @@ERROR<>0
                    goto DROPTRAN
            end
            exec @retcode = sys.sp_MSreinit_article 
                            @publication = @tran_pubname
                            ,@article = @tran_artname
                            ,@need_new_snapshot = @force_invalidate_snapshot
                            ,@need_reinit_subscription = @force_reinit_subscription
                            ,@force_invalidate_snapshot = @force_invalidate_snapshot
                            ,@force_reinit_subscription = @force_reinit_subscription
            if @retcode <>0 or @@ERROR<>0
                goto DROPTRAN
            fetch #trancolumn into @tran_artid, @tran_pubname            
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
end

if @contextset=1
begin
    EXEC @retcode = sys.sp_MSsetcontext_bypasswholeddleventbit @onoff=0
end

if @got_merge_admin_applock=1
    exec sys.sp_MSreleasemergeadminapplock @lockowner = N'Transaction'

COMMIT TRAN
-- delete ##MS_internal_old_style_DDL_support_being_used where db_name=db_name() and objid=@objid

return (0)

DROPTRAN:
CLOSE #trancolumn
DEALLOCATE #trancolumn
GOTO FAILURE

INNER_FAIL:
CLOSE #dropcolumn
DEALLOCATE #dropcolumn
GOTO FAILURE

INNER_FAIL2:
CLOSE #dropcolumn_schema
DEALLOCATE #dropcolumn_schema
GOTO FAILURE


ERROR_EXIT:
CLOSE #nosnapshot
DEALLOCATE #nosnapshot

FAILURE:
    if @contextset=1
    begin
            EXEC @retcode = sys.sp_MSsetcontext_bypasswholeddleventbit @onoff=0
    end
    if @got_merge_admin_applock=1
        exec sys.sp_MSreleasemergeadminapplock @lockowner = N'Transaction'
    rollback tran sp_repldropcolumn
    commit tran
    raiserror(21284, 16, -1, @column, @source_object)
    return (1)    
GO
GRANT EXECUTE ON [sys].[sp_repldropcolumn] TO [public] AS [dbo]
GO
