SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdummyupdate90]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdummyupdate90] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdummyupdate90]
	@rowguid [uniqueidentifier],
	@tablenick [int],
	@metatype [tinyint],
	@pubid [uniqueidentifier],
	@inlineage [varbinary](311),
	@incolv [varbinary](2953),
	@logical_record_parent_rowguid [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
declare @retcode     int
    declare @lineage     varbinary(311)
    declare @conflict_lineage varbinary(311)
    declare @replnick binary(6)
    declare @col_tracking int
    declare @colv varbinary(2953)
    declare @oldmaxversion int
    declare @objid int
    declare @artid uniqueidentifier
    declare @logical_record_parent_nickname int
    declare @METADATA_TYPE_Missing tinyint
    declare @METADATA_TYPE_Tombstone tinyint
    declare @METADATA_TYPE_Contents tinyint
    declare @METADATA_TYPE_ContentsDeferred tinyint
    declare @METADATA_TYPE_SystemDelete tinyint
-- DEBUG    declare @lineage_old varbinary(311)

    set @METADATA_TYPE_Missing= 0
    set @METADATA_TYPE_Tombstone= 1
    set @METADATA_TYPE_Contents= 2
    set @METADATA_TYPE_ContentsDeferred= 3
    set @METADATA_TYPE_SystemDelete=6

    
    /* Parameter checks */
    if (@rowguid is null)
    begin
        RAISERROR(14043, 16, -1, '@rowguid', 'sp_MSdummyupdate90')
        return (1)
    end
    if (@tablenick is null)
    begin
        RAISERROR(14043, 16, -1, '@tablenick', 'sp_MSdummyupdate90')
        return (1)
    end
    if (@metatype is null)
    begin
        RAISERROR(14043, 16, -1, '@metatype', 'sp_MSdummyupdate90')
        return (1)
    end

    /*
    ** Check to see if current publication has permission
    */
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @pubid = @pubid, @tablenick = @tablenick
    if (@retcode <> 0) or (@@error <> 0)
        return 1
        
   /* Check if we have a merge publication by whether system table is there */
    if object_id('MSmerge_contents') is NULL
    begin
        RAISERROR(20054 , 16, -1)
        return (1)
    end

    exec sys.sp_MSgetreplnick @replnick = @replnick out
    if (@@error <> 0) or @replnick IS NULL 
    begin
        RAISERROR (14055, 11, -1)
        RETURN(1)
    end                 

    select @objid =  objid, @artid = artid
        from dbo.sysmergearticles where nickname=@tablenick
    if @objid is NULL
    begin
        RAISERROR(14043, 16, -1, '@objid', 'sp_MSdummyupdate90')
        return (1)
    end
    
    if @logical_record_parent_rowguid is not null
    begin
        select @logical_record_parent_nickname = logical_record_parent_nickname
        from dbo.sysmergepartitioninfo
        where artid = @artid
    end
        
    -- Look for the "other" lineage in a conflict table
    select @conflict_lineage = max(lineage) from MSmerge_errorlineage where
        rowguid = @rowguid and tablenick = @tablenick

    set @oldmaxversion= (select top 1 maxversion_at_cleanup from dbo.sysmergearticles 
                            where nickname = @tablenick)

    if (@metatype = @METADATA_TYPE_Missing)
    begin
        -- We don't have the row.  Putting in a system delete tombstone should cause a delete and
        -- eventual convergence.  We are already logging the row as a conflict / error.

        if @inlineage is null
        begin
            if @conflict_lineage is not null
            begin
-- DEBUG                set @lineage_old= @conflict_lineage
                set @lineage = { fn UPDATELINEAGE(@conflict_lineage, @replnick, @oldmaxversion+1) }
            end
            else
            begin
                set @lineage = { fn UPDATELINEAGE(0x0, @replnick, @oldmaxversion+1) }
-- DEBUG                set @lineage_old= 0x00
            end
        end
        else
        begin
            set @lineage= @inlineage
        end
        
        begin tran
        
        insert into dbo.MSmerge_tombstone (rowguid, tablenick, type, lineage, generation, logical_record_parent_rowguid) 
            select @rowguid, @tablenick, 6, @lineage, 0, @logical_record_parent_rowguid
                where not exists (select * from dbo.MSmerge_contents 
                                where tablenick = @tablenick
                                and rowguid = @rowguid)
        if @@rowcount = 0
        begin
            -- We get here only when there is an existing contents row, which caused us to 
            -- not insert the tombstone row. Let us dummy update the contents row in this
            -- case.
            update dbo.MSmerge_contents set generation = 0
            where tablenick = @tablenick
            and rowguid = @rowguid
        end
        else
        begin

            delete from dbo.MSmerge_current_partition_mappings where rowguid=@rowguid and tablenick=@tablenick
            insert into dbo.MSmerge_past_partition_mappings (publication_number, tablenick, rowguid,
            partition_id, generation,reason)
                    values (0, @tablenick, @rowguid, -1, 0, 1)
        end
-- DEBUG        insert into MSmerge_debug (okay, artnick, rowguid, lineage_old, lineage_new, generation_new, type, successcode, twhen, comment)
-- DEBUG            values (0, @tablenick, @rowguid, @lineage_old, @lineage, 0, @metatype, 0, getdate(), 'sp_MSdummyupdate90')

        if @logical_record_parent_rowguid is not null
        begin
            exec @retcode = sys.sp_MSupdate_singlelogicalrecordmetadata 
                                    @logical_record_parent_nickname,
                                    @logical_record_parent_rowguid,
                                    @replnick, 0
        end
                
        commit tran
        
    end
    else if (@metatype = @METADATA_TYPE_Tombstone)
    begin
        if @inlineage is null
        begin
            select @lineage = lineage from dbo.MSmerge_tombstone with (UPDLOCK ROWLOCK index = 1) 
                                    where tablenick = @tablenick and rowguid = @rowguid
-- DEBUG            set @lineage_old= @lineage
            if @conflict_lineage is not null
            begin
                exec @retcode= sys.xp_mergelineages @lineage, @conflict_lineage, @lineage output
                if @@error<>0 or @retcode<>0 return(1)
            end
            set @lineage = { fn UPDATELINEAGE(@lineage, @replnick, @oldmaxversion+1) }
        end
        else
        begin
-- DEBUG            select @lineage_old = lineage from dbo.MSmerge_tombstone with (UPDLOCK ROWLOCK index = 1) 
-- DEBUG                where tablenick = @tablenick and rowguid = @rowguid
            set @lineage = @inlineage
        end
            
        update dbo.MSmerge_tombstone set generation = 0, lineage = @lineage where
            tablenick = @tablenick and rowguid = @rowguid
            
        if @logical_record_parent_rowguid is not null
        begin
            exec @retcode = sys.sp_MSupdate_singlelogicalrecordmetadata 
                                    @logical_record_parent_nickname,
                                    @logical_record_parent_rowguid,
                                    @replnick, 0
        end
                
-- DEBUG        insert into MSmerge_debug (okay, artnick, rowguid, lineage_old, lineage_new, generation_new, type, successcode, twhen, comment)
-- DEBUG            values (0, @tablenick, @rowguid, @lineage_old, @lineage, 0, @metatype, 0, getdate(), 'sp_MSdummyupdate90')
    end
    else if (@metatype = @METADATA_TYPE_Contents)
    begin
        if @inlineage is not null
        begin
-- DEBUG            select @lineage_old = lineage from dbo.MSmerge_contents with (UPDLOCK ROWLOCK index = 1) 
-- DEBUG                where tablenick = @tablenick and rowguid = @rowguid
            set @lineage = @inlineage

            if @incolv is not null
            begin
                set @colv = @incolv
            end
            else
            begin
                select @colv = colv1 from dbo.MSmerge_contents with (UPDLOCK ROWLOCK index = 1) where 
                    tablenick = @tablenick and rowguid = @rowguid
                if @pubid is NULL
                    select @col_tracking = column_tracking from dbo.sysmergearticles where nickname = @tablenick
                else
                    select @col_tracking = column_tracking from dbo.sysmergearticles where nickname = @tablenick and pubid = @pubid
                if (@col_tracking = 0 or @colv is NULL)
                    set @colv = NULL
                else
                    set @colv = { fn UPDATECOLVBM(@colv, @replnick, 0x01, 0x00, { fn GETMAXVERSION(@lineage) }) }
            end
        end
        else
        begin
            -- @inlineage is null; thus, @incolv is also null
            select @lineage = lineage, @colv = colv1 from dbo.MSmerge_contents with (UPDLOCK ROWLOCK index = 1) where tablenick = @tablenick and
                rowguid = @rowguid
-- DEBUG            set @lineage_old= @lineage

            if @conflict_lineage is not null
            begin
                exec @retcode= sys.xp_mergelineages @lineage, @conflict_lineage, @lineage output
                if @@error<>0 or @retcode<>0 return(1)
            end
            set @lineage = { fn UPDATELINEAGE(@lineage, @replnick, @oldmaxversion+1) }
            if @pubid is NULL
                select @col_tracking = column_tracking from dbo.sysmergearticles where nickname = @tablenick
            else
                select @col_tracking = column_tracking from dbo.sysmergearticles where nickname = @tablenick and pubid = @pubid
            if (@col_tracking = 0 or @colv is NULL)
                set @colv = NULL
            else
                set @colv = { fn UPDATECOLVBM(@colv, @replnick, 0x01, 0x00, { fn GETMAXVERSION(@lineage) }) }
        end

        update dbo.MSmerge_contents set generation = 0, lineage = @lineage, colv1 = @colv where
            tablenick = @tablenick and rowguid = @rowguid

        update dbo.MSmerge_past_partition_mappings set generation = 0 where
            tablenick = @tablenick and rowguid = @rowguid
            
        if @logical_record_parent_rowguid is not null
        begin
                exec @retcode = sys.sp_MSupdate_singlelogicalrecordmetadata 
                    @logical_record_parent_nickname,
                    @logical_record_parent_rowguid,
                    @replnick, 0
        end

-- DEBUG        insert into MSmerge_debug (okay, artnick, rowguid, lineage_old, lineage_new, generation_new, type, successcode, twhen, comment)
-- DEBUG            values (0, @tablenick, @rowguid, @lineage_old, @lineage, 0, @metatype, 0, getdate(), 'sp_MSdummyupdate90')
    end
    else if (@metatype = @METADATA_TYPE_ContentsDeferred)
    begin
        if @inlineage is not null
        begin
-- DEBUG            if @conflict_lineage is not null set @lineage_old= @conflict_lineage
-- DEBUG            else set @lineage_old= 0x00 
            set @lineage = @inlineage
        end
        else if @conflict_lineage is not null
        begin
-- DEBUG            set @lineage_old= @conflict_lineage
            set @lineage = { fn UPDATELINEAGE(@conflict_lineage, @replnick, @oldmaxversion+1) }
        end
        else
        begin
-- DEBUG            set @lineage_old= 0x00
            set @lineage = { fn UPDATELINEAGE(0x0, @replnick, @oldmaxversion+1) }
        end

        if @incolv is not null
        begin
            set @colv = @incolv
        end
        else
        begin
            if @pubid is NULL
            begin
                select @col_tracking = column_tracking
                 from dbo.sysmergearticles where nickname = @tablenick
            end
            else
            begin
                select @col_tracking = column_tracking
                 from dbo.sysmergearticles where nickname = @tablenick and pubid = @pubid
            end

            if (@col_tracking = 0)
                set @colv = NULL
            else
            begin
                set @colv = 0xFF
            end
        end

        begin tran
        save tran eval_change_membership_for_row
        
        exec @retcode = sys.sp_MSevaluate_change_membership_for_row @tablenick = @tablenick, @rowguid = @rowguid
        if @retcode <> 0 or @@error <> 0
        begin
            rollback tran eval_change_membership_for_row
            commit tran
            return 1
        end

        -- METADATA_TYPE_ContentsDeferred has been determined even before we entered
        -- sp_MSdummyupdate90. Due to concurrency, it is possible that another merge
        -- already inserted contents rows through sp_MSdummyupdate90. Thus,
        -- we check again in the following insert statements.

        insert into dbo.MSmerge_contents (tablenick, rowguid, lineage, generation, colv1)
            select @tablenick, @rowguid, @lineage, 0, @colv
                where not exists (select * from dbo.MSmerge_contents
                                    where tablenick=@tablenick and rowguid=@rowguid)
                                    
         exec @retcode = sys.sp_MSevaluate_logicalrecordparent @nickname = @tablenick, @rowguid = @rowguid
         if @retcode <> 0 or @@error <> 0
                 begin
                        rollback tran eval_change_membership_for_row
            commit tran
            return 1
         end
                        
-- DEBUG        insert into MSmerge_debug (okay, artnick, rowguid, lineage_old, lineage_new, generation_new, type, successcode, twhen, comment)
-- DEBUG            values (0, @tablenick, @rowguid, @lineage_old, @lineage, 0, @metatype, 0, getdate(), 'sp_MSdummyupdate90')
        commit tran
    end
    else if (@metatype = @METADATA_TYPE_SystemDelete) -- e.g., used to cope with dup key / dup index
    begin
        if @inlineage is not null
        begin
-- DEBUG            if @conflict_lineage is not null set @lineage_old= @conflict_lineage
-- DEBUG            else set @lineage_old= 0x00 
            set @lineage = @inlineage
        end
        else if @conflict_lineage is not null
        begin
-- DEBUG        set @lineage_old= @conflict_lineage
            set @lineage = { fn UPDATELINEAGE(@conflict_lineage, @replnick, @oldmaxversion+1) }
        end
        else
        begin
-- DEBUG            set @lineage_old= 0x00
            set @lineage = { fn UPDATELINEAGE(0x0, @replnick, @oldmaxversion+1) }
        end

        begin transaction
        
        update dbo.MSmerge_tombstone set generation = 0, lineage = @lineage where
            tablenick = @tablenick and rowguid = @rowguid
            
        if @@rowcount = 0
        begin
            insert into dbo.MSmerge_tombstone (rowguid, tablenick, type, lineage, generation, logical_record_parent_rowguid) 
                select @rowguid, @tablenick, @metatype, @lineage, 0, @logical_record_parent_rowguid
                                where not exists (select * from dbo.MSmerge_contents 
                                        where tablenick = @tablenick
                                        and rowguid = @rowguid)
                        if @@rowcount = 0
                        begin
                                -- We get here only when there is an existing contents row, which caused us to 
                                -- not insert the tombstone row. Let us dummy update the contents row in this
                                -- case.
                                update dbo.MSmerge_contents set generation = 0
                                where tablenick = @tablenick
                                and rowguid = @rowguid
                        end
                        else
                        begin
                             
                            insert into dbo.MSmerge_past_partition_mappings (publication_number, tablenick, rowguid,
                            partition_id, generation,reason)
                                values (0, @tablenick, @rowguid, -1, 0, 1)
                
                                delete from dbo.MSmerge_current_partition_mappings where rowguid=@rowguid and tablenick=@tablenick
			            end
           
        end
        if @logical_record_parent_rowguid is not null
        begin
                exec @retcode = sys.sp_MSupdate_singlelogicalrecordmetadata 
                    @logical_record_parent_nickname,
                    @logical_record_parent_rowguid,
                    @replnick, 0
        end
        commit
-- DEBUG        insert into MSmerge_debug (okay, artnick, rowguid, lineage_old, lineage_new, generation_new, type, successcode, twhen, comment)
-- DEBUG            values (0, @tablenick, @rowguid, @lineage_old, @lineage, 0, @metatype, 0, getdate(), 'sp_MSdummyupdate90')
    end
    return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSdummyupdate90] TO [public] AS [dbo]
GO
