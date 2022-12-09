SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_mergearticlecolumn]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_mergearticlecolumn] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_mergearticlecolumn]
	@publication [sysname],
	@article [sysname],
	@column [sysname],
	@operation [nvarchar](4),
	@schema_replication [nvarchar](5),
	@force_invalidate_snapshot [bit],
	@force_reinit_subscription [bit]
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON

    declare @mergepublish    int
    declare @iscomputed      int
    declare @xtype           int
    declare @sync_mode       int
    declare @index_cnt       int
    declare @indid           int
    declare @in_partition    bit
    declare @colid           int
    DECLARE @cnt int, @idx  int    /* Loop counter, index */
    DECLARE @columnid smallint     /* Columnid-1 = bit to set */
    DECLARE @columns binary(128)         /* Temporary storage for the converted column */
    DECLARE @pubid uniqueidentifier                     /* Publication identification number */
    DECLARE @retcode int                /* Return code for stored procedures */
    DECLARE @artid uniqueidentifier
    declare @object_view   sysname
    declare @filter_clause nvarchar(1000)
    DECLARE @objid int              /* Article base table id */     
    declare @publisher    sysname
    declare @publisher_db sysname
    declare @pkkey        sysname
    declare @conflict_table sysname
    declare @status_value   int
    declare @column_list    nvarchar(max)
    declare @ins_conflict_proc sysname
    declare @qual_source_object nvarchar(270)
    declare @qual_object_view   nvarchar(270)
    declare @qual_tmp_object    nvarchar(270)
    declare @source_object    nvarchar(300)
    declare @quoted_source_object nvarchar(270)
    declare @column_name sysname
    declare @compatlevel int
    declare @identity_support int
    declare @automatic_reinitialization_policy bit
    declare @got_merge_admin_applock bit
    declare @column_tracking int
    declare @filestream_col_published int
    declare @has_filestream int

    select @got_merge_admin_applock = 0
    select @filestream_col_published = 0

    select @publisher = publishingservername()
    select @publisher_db = db_name()
    /*
    ** Security Check
    */
    exec @retcode = sys.sp_MSreplcheck_publish
    if @@ERROR <> 0 or @retcode <> 0
        return(1)

    select @mergepublish = 0x4000
    --select @v_unique_index     = 2        -- status in sysindexes
    --select @v_unique_constraint         = 4096 --status in sysindexes

    /*
    ** Check to see if the database has been activated for publication.
    */

    IF ( (SELECT category & 4 FROM master.dbo.sysdatabases WHERE name = DB_NAME() collate database_default) = 0 )
    BEGIN
        RAISERROR (14013, 16, -1)
        RETURN (1)
    END

    /*
    ** Parameter Check:     @publication.
    ** Make sure that the publication exists and that it conforms to the
    ** rules for identifiers.
    */

    IF @publication IS NULL
        BEGIN
            RAISERROR (14043, 16, -1, '@publication', 'sp_mergearticlecolumn')
            RETURN (1)
        END

    EXECUTE @retcode = sys.sp_validname @publication
    IF @retcode <> 0 or @@ERROR<>0
            RETURN (1)

    SELECT @pubid = pubid, 
           @sync_mode = sync_mode, 
           @compatlevel = backward_comp_level,
           @automatic_reinitialization_policy = automatic_reinitialization_policy
        FROM dbo.sysmergepublications WHERE name = @publication 
                                        and LOWER(publisher)=LOWER(@publisher)
                                        and publisher_db = @publisher_db
                                                                    
    IF @pubid IS NULL
        BEGIN
            RAISERROR (20026, 11, -1, @publication)
            RETURN (1)
        END

    /*
    ** Parameter Check:     @article.
    ** Check to make sure that the article exists in the publication.
    */

    IF @article IS NULL
        BEGIN
            RAISERROR (14043, 16, -1, '@article', 'sp_mergearticlecolumn')
            RETURN (1)
        END

    EXECUTE @retcode = sys.sp_validname @article
    IF @retcode <> 0 or @@ERROR<>0
            RETURN (1)

    /*
    ** Make sure the article exists.
    */
    SELECT @artid = artid, @column_tracking = column_tracking FROM dbo.sysmergearticles
       WHERE pubid = @pubid AND name = @article
    IF @artid IS NULL
        BEGIN
            RAISERROR (20027, 16, -1, @article)
            RETURN (1)
        END
    
    /*
    ** Parameter Check:     @column.
    ** Check to make sure that the column exists and conforms to the rules
    ** for identifiers.
    */

    IF @column IS NOT NULL
        BEGIN
            EXECUTE @retcode = sys.sp_validname @column
            IF @@ERROR <> 0 OR @retcode <> 0
            RETURN (1)
        END

    /*
    ** Parameter Check:     @operation.
    ** The operation can be either 'add' or 'drop'.
    */
    IF LOWER(@operation collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('add', 'drop')
        BEGIN
            RAISERROR (14019, 16, -1)
            RETURN (1)
        END
        
    /*
    ** column name can not be null for 'drop' operation. OK for 'add' operation
    */
    IF LOWER(@operation collate SQL_Latin1_General_CP1_CS_AS)='drop' and @column is NULL
        BEGIN
            RAISERROR(14043, 16, -1, '@column', 'sp_mergearticlecolumn')
            RETURN (1)
        END 

    declare @internalcallerbit bit
    exec @retcode = sys.sp_MScheckcontext_internalcaller @internalcallerbit OUTPUT
    if @retcode <>0 or @@ERROR<>0
        return 1

    /*
    ** @schema_replication must only be set to FALSE by user code, only internal code can set this to TRUE - 
    ** Check the mergearticlecolumn_internalcaller bit to verify that all internal code is using this FLAG.
    */
    IF LOWER(@schema_replication collate SQL_Latin1_General_CP1_CS_AS)='true' and (@internalcallerbit & 1 = 0)
        BEGIN
            RAISERROR(21490, 16, -1, '@schema_replication', 'FALSE')
            RETURN (1)
        END 


    /*
    ** Can not drop non-identity, non-timestamp, non-computed columns that are not nullable and have no default value
    */
    SELECT @status_value=status, @objid = objid, 
        @source_object = object_name(objid),@identity_support = identity_support FROM dbo.sysmergearticles WHERE artid = @artid and pubid=@pubid
        
    select @colid=column_id from sys.columns where object_id=@objid and name=@column
    if not exists (select * from sys.columns where object_id = @objid and name=@column and (is_nullable = 1 
                    OR system_type_id=type_id('timestamp') OR is_computed = 1))
        and not exists (select * from sysconstraints where id=@objid and colid=@colid and OBJECTPROPERTY ( constid , 'IsDefaultCnst' ) = 1)
            and LOWER(@operation collate SQL_Latin1_General_CP1_CS_AS)='drop' and LOWER(@schema_replication collate SQL_Latin1_General_CP1_CS_AS)='false'
            and ColumnProperty(@objid, @column, 'IsIdentity') <> 1
    BEGIN
        RAISERROR(21165, 16, -1, @column)
        return (1)
    END
        
    
    /*
    ** Make sure that the column <columns> is not NULL - if NULL set to 0x00.
    */
    SELECT @columns = columns FROM dbo.sysmergearticles WHERE artid = @artid and pubid=@pubid
    IF @columns IS NULL
    begin
        select @columns = 0x00
        UPDATE dbo.sysmergearticles SET columns = 0x00 WHERE artid = @artid and pubid=@pubid
    end


    /*
    **    Make sure that you are not trying to add more than 246 columns to the table.
    */

    IF LOWER(@operation collate SQL_Latin1_General_CP1_CS_AS) = 'add'
    BEGIN
        IF @column IS NULL
        BEGIN
            select @cnt = count(*) from sys.columns 
                where object_id=@objid and 
                     is_computed<>1 and 
                     system_type_id<>type_id('timestamp')
    
            IF @cnt > 246
            BEGIN
                RAISERROR(25006, 16, -1, @article, 246)
                RETURN (1)
            END
        
        END
        ELSE
        BEGIN
            exec sp_MSBitmapCount @bm1=@columns, @count = @cnt output
            IF @cnt >= 246
            BEGIN
                RAISERROR(25006, 16, -1, @article, 245)
                RETURN (1)
            END    
        END
    END

    -- Colvs can only handle 246 columns so we can not allow more than 246 columns to exist on a table
    -- if column tracking is being used. The reason is that we track all the columns even when vertical
    -- partitioning is used and only some of the columns are published.
    if @column_tracking = 1
    begin
        select @cnt = count(*) from sys.columns 
            where object_id=@objid
        IF @cnt > 246
        BEGIN
            RAISERROR(25020, 16, -1, @article, 246)
            RETURN (1)
        END
    end

    
    if LOWER(@operation collate SQL_Latin1_General_CP1_CS_AS) = 'drop'
    begin        
        select @indid = index_id from sys.indexes where object_id = @objid and is_primary_key <> 0    /* PK index */
        select @index_cnt = 1
        while (@index_cnt <= 16)
        begin
            select @pkkey = INDEX_COL(@source_object, @indid, @index_cnt)
            if @pkkey is NULL
                break
            if @pkkey=@column
            begin
                raiserror(21250, 16, -1, @column)
                return (1)
            end
            select @index_cnt = @index_cnt + 1
        end


        /* Not allowed to drop identity column if identity_support is set to 1 */

        if @identity_support = 1
        begin
            if exists (    select * from sys.columns where object_id = @objid  and
                                                        @column = name        and
                                                        is_identity = 1)
            begin
                raiserror(22550, 16, -1, @column)
                return (1)
            end
                                                        
        end
        
    
        /*
        ** Check for unique index defined on this column - to disallow such a column from being dropped
        */    
        if exists (select * from sys.indexes where object_id=@objid 
                    --and (status & @v_unique_index = @v_unique_index 
                    --    or status & @v_unique_constraint = @v_unique_constraint))
                    and (is_unique = 1 or is_unique_constraint = 1))
        begin
            declare @keys varbinary(816)
            declare @i        int
            declare #check_unique CURSOR LOCAL FAST_FORWARD for 
            select index_id from sys.indexes where object_id=@objid 
                    and (is_unique = 1 or is_unique_constraint = 1)
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
                            if LOWER(@schema_replication collate SQL_Latin1_General_CP1_CS_AS)='true'
                                raiserror(21265, 16, -1, @column, @source_object)
                            else
                                raiserror(21347, 16, -1, @column)                            
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
    end

    begin tran
    save TRANSACTION articlecolumn

    exec @retcode = sys.sp_MSgetmergeadminapplock @timeout = 0, -- no wait
                                                  @lockowner = N'Transaction'
    if @retcode<>0 or @@error<>0
    begin
        raiserror(20713, 16, -1, 'sp_mergearticlecolumn', @publication)
        goto FAILURE            
    end

    select @got_merge_admin_applock = 1

    -- Get exclusive object lock upfront so subsequent %%ColumnEx can proceed
    exec sys.sp_MSget_qualified_name @objid, @qual_source_object OUTPUT
    if @qual_source_object is null 
        goto FAILURE

    exec %%Object(MultiName = @qual_source_object).LockMatchID(ID = @objid, Exclusive = 1, BindInternal = 0)      
    --exec %%Object(MultiName = @qual_source_object).LockExclusiveMatchID(ID = @objid)      
    if @@error <> 0
        goto FAILURE
    
    /*
    ** If no columns are specified, or if NULL is specified, set all
    ** the bits in the 'columns' column so all columns will be included, 
    */
    IF @column IS NULL
    BEGIN
        SELECT @cnt = max(column_id), @idx = 1 FROM sys.columns WHERE object_id = @objid 
        SELECT @columns = NULL
        WHILE @idx <= @cnt
        BEGIN
            /* to make sure column holes will not be included */
            if exists (select * from sys.columns where column_id=@idx and object_id=@objid and 
                (@sync_mode=0 OR (is_computed<>1 and system_type_id <> type_id('timestamp'))))
            begin
                exec sys.sp_MSsetbit @bm=@columns OUTPUT, @coltoadd=@idx, @toset = 1
                if @@ERROR<>0 or @retcode<>0
                    goto FAILURE

                select @column_name = name, @has_filestream = is_filestream  from sys.columns where object_id=@objid and column_id=@idx
                if @@error<>0
                    goto FAILURE
                exec %%ColumnEx(ObjectID=@objid, Name=@column_name).SetMergePublished(Value=1) 
                if @@ERROR<>0
                    goto FAILURE

                if ( @filestream_col_published <> 1  and @has_filestream = 1 )
                    select @filestream_col_published = 1

            end
            SELECT @idx = @idx + 1
        END
        UPDATE dbo.sysmergearticles SET columns = @columns WHERE name = @article AND pubid = @pubid
        if @sync_mode=1 and exists (select * from sys.columns where object_id=@objid and (is_computed=1 or system_type_id=type_id('timestamp')))
            UPDATE dbo.sysmergearticles SET vertical_partition = 1 WHERE name = @article AND pubid = @pubid
    END
    ELSE
    BEGIN
        /* if @column is NULL, meanning all columns are in, do not bump up version to Shiloh. */
        if @compatlevel < 40
        begin
            if LOWER(@schema_replication collate SQL_Latin1_General_CP1_CS_AS)='false'
                raiserror(21351, 10, -1, @publication)
            else
                raiserror(21352, 10, -1, @publication)
            exec @retcode = sys.sp_MSBumpupCompLevel @pubid, 40
            if @@ERROR<>0 or @retcode<>0
                GOTO FAILURE
        end

        SELECT @columnid = column_id, @iscomputed=is_computed, @xtype=system_type_id, @has_filestream = is_filestream 
            FROM sys.columns WHERE object_id = @objid AND name = @column
        IF ((@@error <> 0) OR (@columnid IS NULL))
        BEGIN
            RAISERROR (21166, 16, -1, @column)
            GOTO FAILURE
        END

        if ( @filestream_col_published <> 1  and @has_filestream = 1 )
            select @filestream_col_published = 1

        /*
        ** for character mode publications, we do not allow adding computed column or timestamp columns
        ** into the vertical parititioning. 
        */
        if @sync_mode=1 and (@iscomputed = 1 or type_name(@xtype) ='timestamp') and LOWER(@operation collate SQL_Latin1_General_CP1_CS_AS) = 'add'
        begin
            if LOWER(@schema_replication collate SQL_Latin1_General_CP1_CS_AS)='false'
                begin
                    raiserror(21269, 16, -1)
                    GOTO FAILURE
                end
            else
            begin    
                if @@TRANCOUNT >0 
                begin
                    ROLLBACK TRANSACTION articlecolumn
                    COMMIT TRAN
                end
                return (0)
            end
        end
        
        if ColumnProperty(@objid, @column, 'isrowguidcol') = 1 and LOWER(@operation collate SQL_Latin1_General_CP1_CS_AS) = 'drop'
        begin
            RAISERROR(21162, 16, -1)
            GOTO FAILURE
        end

        -- for computed columns, make sure all dependent cols are published if add
        if @iscomputed = 1
        begin
            declare @refid int, @isinpartition smallint
            declare @ref_major_id int
            declare @ref_object_name nvarchar(512)
            select top 1 @refid=referenced_minor_id, @ref_major_id=referenced_major_id from sys.sql_dependencies where column_id=@columnid and class =1 and object_id=@objid order by referenced_minor_id
            while @refid is not null
            begin

				if @objid = @ref_major_id	-- columns within the same table.
				begin
	                -- check its dependent cols are published
	                exec @isinpartition = sys.sp_MStestbit @bm=@columns, @coltotest=@refid
	                if @isinpartition=0
	                begin
	                    RAISERROR(21549, 16, -1, @column)
	                    GOTO FAILURE
	                end 
				end
				else	-- other objects that this depends on.
				begin
	                -- check that the objects it depends on are published only if the referenced object is a table,view,proc or function.
	                if 	exists (select * from sys.objects where object_id = @ref_major_id and type in ('U','V','P','FN')) and 
	                	not exists (select * from dbo.sysmergearticles where objid = @ref_major_id and pubid = @pubid) and
	                	not exists (select * from dbo.sysmergeschemaarticles where objid = @ref_major_id and pubid = @pubid)
	                begin
	                	exec sys.sp_MSget_qualified_name @ref_major_id, @ref_object_name OUTPUT
	                    RAISERROR(20723, 16, -1, @column, @ref_object_name)
	                    GOTO FAILURE
	                end 
				end

                -- next loop
                select top 1 @refid=referenced_minor_id, @ref_major_id=referenced_major_id from sys.sql_dependencies where column_id=@columnid and class =1 and object_id=@objid and referenced_minor_id>@refid order by referenced_minor_id
                if @@rowcount = 0
                    set @refid = NULL
            end
        end
        
        -- if drop, make sure the computed columns that depends on it is already dropped
        if LOWER(@operation collate SQL_Latin1_General_CP1_CS_AS) = 'drop'
        begin
            declare @refid2 int, @isinpartition2 smallint
            select top 1 @refid2=column_id from sys.sql_dependencies where referenced_minor_id=@columnid and class =1 and object_id=@objid order by referenced_minor_id
            while @refid2 is not null
            begin
                -- check its dependent cols are published
                exec @isinpartition2 = sys.sp_MStestbit @bm=@columns, @coltotest=@refid2
                if @isinpartition2<>0
                begin
                    RAISERROR(21550, 16, -1, @column)
                    GOTO FAILURE
                end 
                -- next loop
                select top 1 @refid2=column_id from sys.sql_dependencies where referenced_minor_id=@columnid and class =1 and object_id=@objid and column_id>@refid2 order by referenced_minor_id
                if @@rowcount = 0
                    set @refid2 = NULL
            end
        end
        
        exec @in_partition = sys.sp_MStestbit @bm=@columns, @coltotest=@columnid

        if @in_partition=1 and LOWER(@operation collate SQL_Latin1_General_CP1_CS_AS) = 'add' and LOWER(@schema_replication collate SQL_Latin1_General_CP1_CS_AS)='false'
        begin
            RAISERROR(21335, 10, -1, @column)
            --GOTO FAILURE    -- Juse because column has already been added to vertical partition doesn't mean we need to error out.
        end
        
        if @in_partition=0 and LOWER(@operation collate SQL_Latin1_General_CP1_CS_AS) = 'drop' and LOWER(@schema_replication collate SQL_Latin1_General_CP1_CS_AS)='false'
        begin
            RAISERROR(21336, 10, -1, @column)
            GOTO FAILURE
        end

        SELECT @columns = columns, @filter_clause=subset_filterclause, @ins_conflict_proc=ins_conflict_proc, @conflict_table=conflict_table FROM dbo.sysmergearticles WHERE name = @article AND pubid = @pubid
        IF LOWER(@operation collate SQL_Latin1_General_CP1_CS_AS) = 'add'
            begin
                exec @retcode = sys.sp_MSsetbit @bm = @columns OUTPUT, @coltoadd=@columnid, @toset=1
                if @@ERROR<>0 or @retcode<>0 
                    GOTO FAILURE
                select @column_name = name from sys.columns where object_id=@objid and column_id=@colid
                if @@error<>0
                    goto FAILURE
                exec %%ColumnEx(ObjectID=@objid, Name=@column_name).SetMergePublished(Value=1)
                if @@ERROR<>0
                    goto FAILURE
            end
        ELSE
            begin
                
                exec @retcode = sys.sp_MSsetbit @bm = @columns OUTPUT, @coltoadd=@columnid, @toset=0
                if @@ERROR<>0 or @retcode<>0 
                    GOTO FAILURE
                if @columns = 0x00
                    begin
                        raiserror(21345, 16, -1)
                        goto FAILURE
                    end
                exec @retcode = sys.sp_MSclearcolumnbit @pubid, @artid, @column
                if @@ERROR<>0 or @retcode<>0
                    goto FAILURE
            end

        /*
        ** Set vertical_partitioning flag so that publication view would be re-generated even
        ** if there is not subsetfilters nor join filters
        */
        UPDATE dbo.sysmergearticles     SET columns = @columns, vertical_partition=1 
            WHERE name = @article AND pubid = @pubid
        IF @@ERROR <> 0
        BEGIN
            RAISERROR (14021, 16, -1)
            GOTO FAILURE
        END

        select @column_list = NULL
        
        /*
        ** check to see if that column can be dropped based on current article's filter clause
        ** and if the article is involved in any join_filter_clauses - to make sure the drop of
        ** one column does not affect any such joins
        */ 
        if ((@filter_clause is not NULL and @filter_clause <>'' ) or 
            exists (select * from dbo.sysmergesubsetfilters where pubid=@pubid and 
            (artid=@artid or join_articlename=@article))) and LOWER(@operation collate SQL_Latin1_General_CP1_CS_AS) = 'drop'
        begin
            exec @retcode = sys.sp_MSgetcolumnlist @pubid, @column_list OUTPUT, @objid
            if @@ERROR<>0 or @retcode<>0
                GOTO FAILURE

            select @object_view='TEMP_VIEW_' + @source_object  --@source_object is not quoted
            select @qual_object_view=quotename(@object_view)

            exec @retcode = sys.sp_MSget_qualified_name @objid, @qual_source_object OUTPUT
            if @@ERROR<>0 or @retcode<>0
                goto FAILURE
            select @quoted_source_object=QUOTENAME(@source_object)

            exec ('create view dbo.' + @qual_object_view + ' as select ' + @column_list + ' from ' + @qual_source_object + ' ' + @quoted_source_object)
            if @@ERROR<>0
                GOTO FAILURE
            if @filter_clause is not NULL and @filter_clause <>'' 
            begin
                exec ('declare @test int select @test=1 from ' + @qual_object_view + ' ' + @quoted_source_object + ' where ' + @filter_clause)
                if @@ERROR<>0
                    begin
                        exec('drop view ' + @qual_object_view)
                        raiserror(21256, 16, -1, @filter_clause, @source_object)
                        GOTO FAILURE
                    end
            end            
        end
        
        /*
        ** Check to make sure dropping a column will not breaking any other articles that using current article as join_article
        */
        if exists (select * from dbo.sysmergesubsetfilters where pubid=@pubid and 
            (artid=@artid or join_articlename=@article)) and LOWER(@operation collate SQL_Latin1_General_CP1_CS_AS) = 'drop'
        begin
            declare @join_articlename sysname
            declare @tmp_artid uniqueidentifier
            declare @join_objid int
            declare @join_object sysname
            declare @qual_join_object nvarchar(517)
            declare @quoted_join_object nvarchar(258)
            
            declare per_article CURSOR LOCAL FAST_FORWARD FOR 
                select artid, join_filterclause, join_articlename from sysmergesubsetfilters 
                    where pubid=@pubid and (join_articlename=@article or artid=@artid)
            for READ ONLY
            open per_article
            fetch per_article into @tmp_artid, @filter_clause, @join_articlename
            while (@@fetch_status<>-1)
            begin
                if @artid<>@tmp_artid
                    select @join_objid=objid from sysmergearticles where pubid=@pubid and artid=@tmp_artid
                else
                    select @join_objid=objid from sysmergearticles where pubid=@pubid and name=@join_articlename

                select @join_object = object_name(@join_objid)
                select @qual_join_object = quotename(schema_name(schema_id)) + '.' + quotename(name) from sys.objects where object_id = @join_objid
                select @quoted_join_object = quotename(object_name(@join_objid))

                if @join_object is not NULl and @join_object<>''
                begin
                    exec ('declare @test int select @test=1 from ' + @qual_object_view + ' ' + @quoted_source_object + ', ' + @qual_join_object + ' ' + @quoted_join_object + ' where ' + @filter_clause)                    
                    if @@ERROR<>0
                    begin
                        close per_article
                        deallocate per_article
                        raiserror(21256, 16, -1, @filter_clause, @source_object)
                        GOTO FAILURE
                    end
                end
                fetch per_article into @tmp_artid, @filter_clause, @join_articlename    
            end
            close per_article
            deallocate per_article        
        end            
    END      


   -- filestream_change
    if (@filestream_col_published = 1)    
    begin
        -- filestream column is not supported for character mode publications
        if ( @sync_mode = 1 )
        begin 
            raiserror(22581, 16, -1, @article, @publication)
            GOTO FAILURE
        end
        -- filestream column is only supported for Yukon+ subscribers as
        -- conversion of filestream column (max type) to base type is not allowed.
        else if ( @compatlevel < 90 )
        begin
            raiserror(22582, 16, -1, @article, @publication)
            GOTO FAILURE          
        end     
    end   

    /*
    ** if snapshot is ready, change it to obsolete to force another snapshot run.    
    ** Note this is the third value of snapshot_ready. 0 for not ready, 1 for OK, 2 for obsolete
    */     
    IF EXISTS (SELECT * FROM dbo.sysmergepublications WHERE pubid=@pubid and snapshot_ready>0) 
            and LOWER(@schema_replication collate SQL_Latin1_General_CP1_CS_AS)='false'
    BEGIN
        update dbo.sysmergearticles set status=1, conflict_table=NULL where pubid=@pubid and artid=@artid and status=2
        if @@ERROR<>0
            goto FAILURE

        update dbo.sysmergearticles set status=5, conflict_table=NULL where pubid=@pubid and artid=@artid and status=6
        if @@ERROR<>0
            goto FAILURE
            
        /*
        ** Force a re-generation of conflict table and its ins_proc
        */
        if object_id(@ins_conflict_proc) is not NULL
        begin
            set @quoted_source_object= quotename(@ins_conflict_proc)
            exec ('drop proc ' + @quoted_source_object)
            if @@ERROR<>0
                goto FAILURE
        end
        if object_id(@conflict_table) is not NULL
        begin
            set @quoted_source_object= quotename(@conflict_table)
            exec ('drop table ' + @quoted_source_object)
            if @@ERROR<>0
                goto FAILURE
        end


        /*
        ** make sure we know we really want to do this.
        */
        if exists (select * from dbo.sysmergepublications where pubid=@pubid and snapshot_ready<>2)
        begin
            if @force_invalidate_snapshot = 0
                begin
                    raiserror(20607, 16, -1)
                    goto FAILURE
                end
        end
        update dbo.sysmergepublications set snapshot_ready=2 where pubid=@pubid
        if @@ERROR<>0
            goto FAILURE

        if @force_reinit_subscription = 0 and @status_value<>5 --5 is the value for new_inactive
        begin
            raiserror(20608, 16, -1)
            goto FAILURE
        end

        --do a global re
        
        if @force_reinit_subscription = 1
        begin
                --global reinitialization will bump up backward-comp-level to SP2.
            exec @retcode = sys.sp_MSreinitmergepublication 
                                    @publication = @publication,
                                    @upload_first = @automatic_reinitialization_policy
            if @retcode<>0 or @@ERROR<>0
                goto FAILURE
        end
        /*
        ** Even for vertical partitioning on new article - we do not need to bumpup backward-comp-level
        **
        else
            begin    --bump up the backward-comp-level so that only 80 subscribers can use it.
            exec @retcode = sys.sp_MSBumpupCompLevel @pubid, 40
            if @@ERROR<>0 or @retcode<>0
                GOTO FAILURE
            end
        */
    END

    exec sys.sp_MSreleasemergeadminapplock @lockowner = N'Transaction'
    COMMIT TRANSACTION
    if object_id(@qual_object_view) is not NULL
    begin
        exec ('drop view ' + @qual_object_view)
    end
    return (0)
FAILURE:

    if @@TRANCOUNT >0 
        begin
            if @got_merge_admin_applock=1
                exec sys.sp_MSreleasemergeadminapplock @lockowner = N'Transaction'
            ROLLBACK TRANSACTION articlecolumn
            COMMIT TRAN
        end

    if object_id(@qual_object_view) is not NULL
    begin
        exec ('drop view ' + @qual_object_view)
    end

    return (1)
GO
GRANT EXECUTE ON [sys].[sp_mergearticlecolumn] TO [public] AS [dbo]
GO
