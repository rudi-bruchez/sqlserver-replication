SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdropmergearticle]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdropmergearticle] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdropmergearticle]
	@pubid [uniqueidentifier],
	@artid [uniqueidentifier],
	@ignore_merge_metadata [bit]
WITH EXECUTE AS CALLER
AS
declare @snapshot_ready            int
    declare @objid                    int
    declare @retcode                int
    declare @qualified_name            nvarchar(517)
    declare @filterid                int
    declare @proc_name                nvarchar(258)
    declare @sync_objid        int
    declare @view_type        int
    declare @type            tinyint
    declare @tablenick      int
    declare @drop_downlevel_procs    bit
    declare @preserve_rowguidcol bit
    declare @viewname         nvarchar(258)
    declare @SCHEMA_TYPE_DDL_ACTIONS int
    declare @SCHEMA_TYPE_DDL_RELATED_COLUMN_FIXUP int
    declare @SCHEMA_TYPE_NONSQLALTERTABLE int

    set @SCHEMA_TYPE_DDL_ACTIONS= 300
    set @SCHEMA_TYPE_DDL_RELATED_COLUMN_FIXUP= 301
    set @SCHEMA_TYPE_NONSQLALTERTABLE= 13
    
    /*
    ** Security Check
    */
    EXEC @retcode = sys.sp_MSreplcheck_publish
    IF @@ERROR <> 0 or @retcode <> 0 return (1)
    
    select @objid = NULL
    select @type = type, @objid = objid from dbo.sysmergeextendedarticlesview where artid = @artid AND pubid = @pubid
    -- nothing to drop
    if @objid is NULL return 0

    exec sys.sp_MSget_qualified_name @objid, @qualified_name OUTPUT
    if @qualified_name is null return 1

    /*
    ** Mark all entries in sysmergeschemachange with schematype 
	** SCHEMA_TYPE_USER_SCHEMA	31
    ** SCHEMA_TYPE_USER_DEFINED_DATA_TYPE
    ** SCHEMA_TYPE_CLR_USER_DEFINED_DATA_TYPE
    ** SCHEMA_TYPE_ASSEMBLY
    ** SCHEMA_TYPE_PARTITIONSCHEME
    ** SCHEMA_TYPE_PARTITIONFUNCTION
    ** SCHEMA_TYPE_XMLSCHEMANAMESPACE
	** SCHEMA_TYPE_FULLTEXTCATALOG
	** SCHEMA_TYPE_USER_DEFINED_TABLE_TYPE
    ** as inactive.
    ** These entries will either be deleted or activated when snapshot runs depending on whether
    ** they are in the dependency list of the articles still remaining in the publication.
    */

    update dbo.sysmergeschemachange set schemastatus = 0 where pubid = @pubid AND schematype in (88, 89, 90, 91, 92, 93, 96, 31, 105)
    if @@ERROR <> 0 return 1

    -- Remove the corresponding rows from dbo.sysmergeschemachange
    -- However, keep schemachanges like alter table; otherwise, the following will
    -- fail for msgbased:
    --  1) After having synched, add column.
    --  2) Drop article, then readd it.
    --  3) DML at pub (new schema) then at sub (old schema).
    --  4) Sub requests reinit with upload.
    --  5) As a result, the upload cannot be applied due to table schema mismatch;
    --     however, there will be no schemaonly message, as the DDL schemachange is gone.
    DELETE FROM dbo.sysmergeschemachange 
        WHERE artid = @artid AND pubid = @pubid and schematype not in (@SCHEMA_TYPE_DDL_ACTIONS, @SCHEMA_TYPE_DDL_RELATED_COLUMN_FIXUP, @SCHEMA_TYPE_NONSQLALTERTABLE)
    if @@ERROR <> 0 return 1

    -- this code is only needed if the article was added incrementally
    delete from dbo.sysmergeschemachange 
        where substring(convert(binary(16), artid),5,4) = convert(binary(4), @objid) and
              substring(convert(binary(16), artid),0,5) = 0x00000000
            and pubid = @pubid
    
    /*
    ** Removing a schema only article is a lot simpler than 
    ** removing a table article so a different code path is created
    ** to handle this.    
    */
    if @type in (0x20, 0x40, 0x80, 0xA0)
    begin
        /*
        ** Remove the corresponding record in dbo.sysmergeschemaarticles
        */
        delete dbo.sysmergeschemaarticles where artid = @artid and pubid = @pubid

        /*
        ** drop the system pre snapshot script schema chnage since it could contain the
        ** the schema only article (in case of view and functions) if this is the last 
        ** article of type view or func. A subsequent snapshot
        ** run will anyway regenerate the system pre snapshot script
        */
        if not exists (select * from dbo.sysmergeschemaarticles where pubid = @pubid and (type = 0x40 or type = 0x80 or type = 0xA0))
        begin
            delete from dbo.sysmergeschemachange where pubid = @pubid and schematype = 60
        end

        /*
        ** If this is the last schema only article for the underlying 
        ** view or proc object, unmark the 0x200 bit in sysobject.replinfo    
        */
        if not exists (select * from dbo.sysmergeschemaarticles 
                        where objid = @objid)
        begin            
            exec %%Object(MultiName = @qualified_name).LockMatchID(ID = @objid, Exclusive = 1, BindInternal = 0)
            --exec %%Object(MultiName = @qualified_name).LockExclusiveMatchID(ID = @objid)
            if @@error <> 0
                return 1

            if object_id('sysmergeschemaarticles') is NULL
            begin    
                exec %%Object(ID = @objid).SetSchemaPublished(Value = 0)
                if @@error <> 0
                    return 1
            end       
            else if not exists (select * from sysmergeschemaarticles 
                                  where objid = @objid) 
            begin    
                exec %%Object(ID = @objid).SetSchemaPublished(Value = 0)
                if @@error <> 0
                    return 1
            end       
        end
    end
    else 
    begin
        /*
        ** Retrieve the object id of the underlying table.
        */
        select @sync_objid = sync_objid, 
               @view_type = view_type, 
               @artid = artid, 
               @objid = objid,
               @tablenick = nickname
            from dbo.sysmergearticles where artid = @artid AND pubid = @pubid
            
        /*
        ** If this is the last article that refers to the base table, drop the 
        ** triggers and stored procs 
        */
        if NOT exists (select * from dbo.sysmergearticles WHERE artid = @artid AND pubid <> @pubid)
        begin
            -- set the identity column as not for replication before calling article cleanup
            -- so that article cleanup can reseed the table to have the highest identity value
            declare @colname sysname

            -- Acquire sch-M lock up-front on the published object 
            exec %%Object(MultiName = @qualified_name).LockMatchID(ID = @objid, Exclusive = 1, BindInternal = 0)
            --exec %%Object(MultiName = @qualified_name).LockExclusiveMatchID(ID = @objid)
            if @@error <> 0
                return 1

            select @colname = name
            from sys.columns
            where object_id = @objid and
                is_identity = 1 and -- is identity
                ColumnProperty(object_id, name, 'IsIdNotForRepl') = 1 -- 'not for repl' property
            if @colname is not null
            begin
                -- Mark 'not for repl'
                EXEC %%ColumnEx(ObjectID = @objid, Name = @colname).SetIdentityNotForRepl(Value = 0)
                IF @@ERROR <> 0
                    return 1
            end

            /*
            ** Cleanup the triggers and stored procs
            */
            EXECUTE @retcode = sys.sp_MSarticlecleanup @artid = @artid, @pubid = @pubid, @ignore_merge_metadata = @ignore_merge_metadata
            if @@ERROR <> 0 OR @retcode <> 0
            BEGIN
                return 1
            END
        
            /*
            ** Clear the replication bit in sys.objects. Now merge and transactional level
            ** uses different replication bit, checking transactional level is not needed.
            */

            exec %%Relation(ID = @objid).SetMergePublished(Value = 0, SetColumns = 0)
            -- rmak: How about the merge published bits in sys.columns??

            -- Delete pending requests for resending rows.
            delete from dbo.MSmerge_metadataaction_request where tablenick=@tablenick

            IF @@ERROR <> 0
                return 1
        end                
        else
        begin

            -- reset the trigger only if this article is shared with other publications and also the snapshot is ready 
            if exists (select 1 
                        from dbo.sysmergepublications pub join dbo.sysmergearticles art
                        on pub.pubid = art.pubid
                        where pub.snapshot_ready = 1
                        and pub.pubid <> @pubid
                        and UPPER(publisher) = UPPER(publishingservername()) and publisher_db = DB_NAME())
            begin
                exec @retcode = sys.sp_MSaddmergetriggers @qualified_name
                if @retcode<>0 or @@ERROR<>0 return (1)                
            end
        
            /* Always drop the article proc's they are not shared among publications */

            select @drop_downlevel_procs = 0
            if (sys.fn_MSmerge_islocalpubid(@pubid) = 1)
            begin
                if exists (select 1 from dbo.sysmergepublications where pubid = @pubid and backward_comp_level<90)
                    select @drop_downlevel_procs = 1
            end

            EXECUTE @retcode = sys.sp_MSdroparticleprocs @artid = @artid, @pubid = @pubid
            if @@ERROR <> 0 OR @retcode <> 0
            begin
                return 1
            end

            -- Drop the article-specific conflict table.
            exec @retcode= sys.sp_MSdrop_article_conflict_table @pubid=@pubid, @artid=@artid
            if @@error<>0 or @retcode<>0 return 1

            /* If the article's has a temporary ( view type = 2) or a permanent view (view_type = 1 ) drop the sync object */
            if (@objid <> @sync_objid)
            begin
                select @viewname = sys.objects.name from sys.objects where type='V' and is_ms_shipped = 1 
                    and object_id = @sync_objid
                if @viewname IS NOT NULL
                begin
                        set @viewname = QUOTENAME(@viewname)
                        exec ('drop view ' + @viewname)
                        if @@ERROR<>0  
                            return 1
                end
            end
            
            -- Drop repl_view_
            select @viewname = NULL
            select @viewname = object_name(repl_view_id) from dbo.sysmergepartitioninfo WHERE artid = @artid AND pubid = @pubid
            if object_id(@viewname) is not NULL
            begin
				set @viewname = QUOTENAME(@viewname)
                exec ('drop view ' + @viewname)
                select @viewname = NULL
            end

           -- if this article is published in another publication do not drop the identity constraint
           -- do not delete the publisher entry from MSmerge_identity_range. Update the pubid
           -- with the other pubid that exists
           if object_id('dbo.MSmerge_identity_range', 'U') is not NULL
           begin
               exec @retcode = sys.sp_MSremoveidrangesupport @pubid, @artid, 0 /* @propagate_ddl_change */ 
               IF @@ERROR <> 0 or @retcode <> 0
                   return 1
           end

                        
        end
        /*
        ** Remove the row from dbo.sysmergearticles.
        */
        -- drop the expand procs, membership eval proc and logical record views before removing 
        -- the row from sysmergepartitioninfo
        -- do not worry about the errors here since this is just for cleanup
        select @viewname = NULL
        select @viewname = object_name(logical_record_view) from dbo.sysmergepartitioninfo WHERE artid = @artid AND pubid = @pubid
        if object_id(@viewname) is not NULL
        begin
			set @viewname = QUOTENAME(@viewname)
            exec ('drop view ' + @viewname)
            select @viewname = NULL
        end
        select @proc_name = NULL
        select @proc_name = quotename(membership_eval_proc_name) from dbo.sysmergepartitioninfo WHERE artid = @artid AND pubid = @pubid
        if object_id(@proc_name) is not NULL
        begin
            exec ('drop proc ' + @proc_name)
            select @proc_name = NULL
        end
        select @proc_name = quotename(expand_proc) from dbo.sysmergepartitioninfo WHERE artid = @artid AND pubid = @pubid
        if object_id(@proc_name) is not NULL
        begin
            exec ('drop proc ' + @proc_name)
            select @proc_name = NULL
        end
        
        DELETE FROM dbo.sysmergepartitioninfo WHERE artid = @artid AND pubid = @pubid
        if @@ERROR <> 0
        BEGIN
            return 1
        END
        DELETE FROM dbo.sysmergearticles WHERE artid = @artid AND pubid = @pubid
        if @@ERROR <> 0
        BEGIN
            return 1
        END


        /* delete all the filter components that are defined upon the designated article */
        select @filterid = min(join_filterid) from dbo.sysmergesubsetfilters where
            artid = @artid AND pubid = @pubid
        while (@filterid is not null)
        begin
            select @proc_name = expand_proc from dbo.sysmergesubsetfilters where
                artid = @artid AND pubid = @pubid and join_filterid = @filterid

            if (@proc_name IS NOT NULL) and exists (select * from sys.objects where
                name = @proc_name and type = 'P')
                begin
                    set @proc_name= quotename(@proc_name)
                    exec ('drop proc ' + @proc_name)
                    IF @@ERROR <> 0
                        return 1
                end
            delete from dbo.sysmergesubsetfilters where
                artid = @artid AND pubid = @pubid and join_filterid = @filterid
            IF @@ERROR <> 0
                return 1
            select @filterid = min(join_filterid) from dbo.sysmergesubsetfilters where
                artid = @artid AND pubid = @pubid
        end
    end        
GO
GRANT EXECUTE ON [sys].[sp_MSdropmergearticle] TO [public] AS [dbo]
GO
