SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdelsubrowsbatch]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdelsubrowsbatch] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdelsubrowsbatch]
	@tablenick [int],
	@rowguid_array [varbinary](8000),
	@metadatatype_array [varbinary](500),
	@oldlineage_len_array [varbinary](1000),
	@oldlineage_array [varbinary](311),
	@generation_array [varbinary](4000),
	@newlineage_len_array [varbinary](1000),
	@newlineage_array [varbinary](311),
	@pubid [uniqueidentifier],
	@rowsdeleted [int] OUTPUT,
	@allarticlesareupdateable [bit]
WITH EXECUTE AS CALLER
AS
declare @rowguid uniqueidentifier, @metadata_type tinyint, @lineage_old varbinary(311), 
            @generation bigint, @lineage_new varbinary(311), @match int, @errcode int, @new_metatype tinyint, 
            @retcode smallint, @procname sysname, @tnstr nvarchar(11), @error int, @rowcount int,
            @tablenicklast int, @rowguidarraylen int, @oldlineage_len smallint, @newlineage_len smallint,
            @guidoffset int, @metatypeoffset int, @oldlinlenoffset int, @newlinlenoffset int, @oldlinoffset int,
            @newlinoffset int, @genoffset int, @transaction_started bit,
            @parentarticleisupdateable bit, @partition_options tinyint
            
    declare @rowstochangetype TABLE (tablenick int NOT NULL, rowguid uniqueidentifier NOT NULL)

    declare @METADATA_TYPE_Tombstone tinyint
    declare @METADATA_TYPE_PartialDelete tinyint
    declare @METADATA_TYPE_SystemDelete tinyint

    set @METADATA_TYPE_Tombstone= 1
    set @METADATA_TYPE_PartialDelete= 5
    set @METADATA_TYPE_SystemDelete= 6

    -- Do all DDL first
    create table #notbelong (   tablenick int NOT NULL, rowguid uniqueidentifier NOT NULL, flag int NOT NULL, generation bigint NULL, 
                                lineage_old varbinary(311) NULL, metadatatype_old tinyint NULL, 
                                lineage_new varbinary(311) NULL, metadatatype_new tinyint NULL, original_row bit NULL default 0)
    create clustered index #indnbelong on #notbelong (tablenick, rowguid)
                
    /*
    ** Check to see if current publication has permission. Skip check if caller is the merge agent.
    */
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @pubid = @pubid, @tablenick = @tablenick
    if (@retcode <> 0) or (@@error <> 0)
        return 4
        
    /* Parameter validation */
    if (@rowguid_array is null)
    begin
        RAISERROR(14043, 16, -1, '@rowguid_array', 'sp_MSdelsubrowsbatch')
        return (0)
    end
    if (@tablenick is null)
    begin
        RAISERROR(14043, 16, -1, '@tablenick', 'sp_MSdelsubrowsbatch')
        return (0)
    end

    if (1 = @allarticlesareupdateable and
        @newlineage_array is null)
    begin
        RAISERROR(14043, 16, -1, '@newlineage_array', 'sp_MSdelsubrowsbatch')
        return (0)
    end

    set @rowsdeleted = 0
    set @transaction_started = 0

    -- initialize offsets and length for walking through arrays
    set @guidoffset = 1
    set @metatypeoffset = 1
    set @oldlinlenoffset = 1
    set @newlinlenoffset = 1
    set @oldlinoffset = 1
    set @newlinoffset = 1
    set @genoffset = 1
    
    set @rowguidarraylen = datalength(@rowguid_array)

    declare @numgenbytes tinyint
    set @numgenbytes= col_length('MSmerge_contents', 'generation')

        if 1 = @allarticlesareupdateable
            set @parentarticleisupdateable= 1
        else
            set @parentarticleisupdateable= sys.fn_MSarticle_allows_DML_at_this_replica(default, @tablenick)

    -- walk through arrays and populate temp table
    while (@guidoffset < @rowguidarraylen)
    begin
        -- Retrieve values, and increment offsets for next row.
        set @rowguid = substring(@rowguid_array, @guidoffset, 16)   -- 16 = sizeof uniqueidentifier (rowguid)
        set @guidoffset = @guidoffset + 16

        set @metadata_type = substring(@metadatatype_array, @metatypeoffset, 1) -- 1 = sizeof tinyint (metadata_type)
        set @generation = substring(@generation_array, @genoffset, @numgenbytes)
        set @oldlineage_len = substring(@oldlineage_len_array, @oldlinlenoffset, 2) -- 2 = sizeof smallint (oldlineage_len)
        set @newlineage_len = substring(@newlineage_len_array, @newlinlenoffset, 2) -- 2 = sizeof smallint (newlineage_len)
        set @lineage_old = substring(@oldlineage_array, @oldlinoffset, @oldlineage_len) -- @oldlineage_len = sizeof old lineage for current row
        set @lineage_new = substring(@newlineage_array, @newlinoffset, @newlineage_len) -- @newlineage_len = sizeof new lineage for current row

        set @metatypeoffset = @metatypeoffset + 1
        set @genoffset = @genoffset + @numgenbytes
        set @oldlinlenoffset = @oldlinlenoffset + 2
        set @newlinlenoffset = @newlinlenoffset + 2
        set @oldlinoffset = @oldlinoffset + @oldlineage_len
        set @newlinoffset = @newlinoffset + @newlineage_len

        -- Insert the old metadata type as the new metadata type. We can modify later if it is supposed to be different.
        insert into #notbelong (tablenick, rowguid, flag, generation, lineage_old, metadatatype_old, lineage_new, metadatatype_new, original_row) values (@tablenick, @rowguid, 0, @generation, @lineage_old, @metadata_type, @lineage_new, @metadata_type, 1)
    end
    
    if (exists(select * from #notbelong))
    begin
        declare @tn int
        declare @qualified_table_name nvarchar(517)
        declare @unqualified_table_name nvarchar(270)
                    
        -- Expansion is an expensive and time-consuming process. Defer starting transaction until after expansion 
        -- has taken place.

        /* call expand proc */
        exec @retcode = sys.sp_MSexpandsubsnb @pubid
        IF @@ERROR<>0 or @retcode<>0
        begin
            set @errcode= 0
            goto Failure
        end

        select @procname = 'dbo.' + select_proc,
        @partition_options = partition_options
        from dbo.sysmergepartitioninfoview
        where nickname = @tablenick and pubid = @pubid
        
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

        -- After the #notbelong has been expanded, the original_row column can be used to distinguish original rows
        -- from the rows that were brought in by the expansion.

        -- open a cursor on #notbelong for rows with original_row = 1
        declare original_rows_1 CURSOR LOCAL FAST_FORWARD for 
        select rowguid, generation, lineage_old, metadatatype_old, lineage_new from #notbelong where tablenick = @tablenick and original_row = 1
        FOR READ ONLY
        open original_rows_1
        fetch original_rows_1 into @rowguid, @generation, @lineage_old, @metadata_type, @lineage_new

        begin transaction
        save tran start_of_batch
        set @transaction_started = 1

        while (@@fetch_status <> -1)
        begin
            if 1 = @parentarticleisupdateable
            begin
                if (@metadata_type = @METADATA_TYPE_PartialDelete or 
                    @metadata_type = @METADATA_TYPE_Tombstone)
                begin
                    if exists (select * from dbo.MSmerge_tombstone where rowguid = @rowguid and tablenick = @tablenick)
                    begin
                        update dbo.MSmerge_tombstone 
                            set type = @metadata_type, generation = @generation, lineage = @lineage_new 
                            where rowguid = @rowguid and tablenick = @tablenick

    -- DEBUG                        insert into MSmerge_debug (okay, artnick, rowguid, lineage_old, lineage_new, generation_new, type, successcode, twhen, comment)
    -- DEBUG                            values (0, @tablenick, @rowguid, @lineage_old, @lineage_new, @generation, @metadata_type, 1, getdate(), 'sp_MSdelsubrowsbatch: new type 5')
        
                        -- This row will later be removed from #notbelong. We were only supposed to update the tombstone
                        -- metadata type for this row (which we have already done above).
                        insert into @rowstochangetype values (@tablenick, @rowguid)
                        fetch original_rows_1 into @rowguid, @generation, @lineage_old, @metadata_type, @lineage_new
                        continue    -- on to the next row
                    end
                end
                else if (@metadata_type = @METADATA_TYPE_SystemDelete)
                begin
                    if exists (select * from dbo.MSmerge_tombstone where rowguid = @rowguid and tablenick = @tablenick)
                    begin
                        update dbo.MSmerge_tombstone set type = @metadata_type 
                            where rowguid = @rowguid and tablenick = @tablenick

    -- DEBUG                    insert into MSmerge_debug (okay, artnick, rowguid, lineage_old, lineage_new, generation_new, type, successcode, twhen, comment)
    -- DEBUG                        values (0, @tablenick, @rowguid, @lineage_old, @lineage_new, @generation, @metadata_type, 1, getdate(), 'sp_MSdelsubrowsbatch: new type 6')
        
                        -- This row will later be removed from #notbelong. We were only supposed to update the tombstone
                        -- metadata type for this row (which we have already done above).
                        insert into @rowstochangetype values (@tablenick, @rowguid)
                        fetch original_rows_1 into @rowguid, @generation, @lineage_old, @metadata_type, @lineage_new
                        continue    -- on to the next row
                    end
                end
            end

            -- lock this particular row of the base table
            exec @retcode = @procname @maxschemaguidforarticle = NULL, @type = 8, @rowguid=@rowguid
            IF @@ERROR<>0 or @retcode<>0
            begin
                set @errcode= 0
                close original_rows_1
                deallocate original_rows_1
                goto Failure
            end
            
            if 1 = @parentarticleisupdateable
            begin
                if @metadata_type = @METADATA_TYPE_PartialDelete
                begin
                    set @new_metatype = @METADATA_TYPE_PartialDelete
                end
                else if @metadata_type = @METADATA_TYPE_SystemDelete
                begin
                    set @new_metatype = @METADATA_TYPE_SystemDelete
                end
                else
                begin
                    set @new_metatype = @METADATA_TYPE_Tombstone
                end
                
                -- call sp_MScheckmetadatamatch with @compatlevel=90, because even if the 
                -- reconciler is Shiloh, the lineages were already mapped up when the 
                -- deletes where enumerated, and the reconciler then 
                -- concatenated the mapped-up lineages
                exec @retcode=sys.sp_MScheckmetadatamatch 
                    @metatype=@metadata_type, @rowguid=@rowguid, @tablenick=@tablenick, 
                    @lineage=@lineage_old, @match=@match output, @compatlevel=90

                IF @@ERROR<>0 or @retcode<>0
                begin
                    set @errcode= 0
                    close original_rows_1
                    deallocate original_rows_1
                    goto Failure
                end
            end
            else
                set @match= 1

            if (@match = 1)
            begin
                if (@metadata_type <> @new_metatype and 1 = @parentarticleisupdateable)
                begin
                    -- we will later need this new metadata type when calling sp_MSsetrowmetadata
                    update #notbelong set metadatatype_new = @new_metatype where tablenick = @tablenick and rowguid = @rowguid and original_row = 1
                end
            end
            else
            begin
                set @errcode= 2
                close original_rows_1
                deallocate original_rows_1
                goto Failure
            end

            fetch original_rows_1 into @rowguid, @generation, @lineage_old, @metadata_type, @lineage_new
        end

        close original_rows_1
        deallocate original_rows_1

        -- delete the rows in #notbelong that needn't be deleted. We were only supposed to update the tombstone
        -- metadata type for those rows (which we have already done above).
        delete #notbelong with (paglock) from #notbelong a, @rowstochangetype b where a.tablenick = b.tablenick and a.rowguid = b.rowguid
        
        select @tn = max(tablenick) from #notbelong where flag > -1
        while @tn is not null
        begin
            select @tnstr = convert(nvarchar(11), @tn)
            exec @retcode = sys.sp_MStablenamefromnick @tn, @qualified_table_name out, @pubid, @unqualified_table_name out
            -- delete all rows indicated by the temp table
            IF @@ERROR<>0 or @retcode<>0
            begin
                set @errcode= 0
                goto Failure
            end
            exec ('delete ' + @qualified_table_name + ' from #notbelong nb, ' + @qualified_table_name + ' t 
                   where nb.tablenick = ' + @tnstr + ' and t.RowGuidCol = nb.rowguid
                   option (FORCE ORDER, LOOP JOIN)')
            select @error=@@error, @rowcount=@@rowcount
            IF @error<>0
            begin
                set @errcode= 0
                goto Failure
            end

            select @rowsdeleted = @rowsdeleted + @rowcount
                
            -- remove metadata action request for the rows we just deleted.
            delete mar with (rowlock) from dbo.MSmerge_metadataaction_request as mar
                inner join #notbelong as nb
                on mar.tablenick=nb.tablenick and
                   mar.rowguid=nb.rowguid
                where mar.tablenick=@tn

            -- move on to next nickname - decreasing makes delete order correct
            update #notbelong set flag = -1 where tablenick = @tn
            select @tn = max(tablenick) from #notbelong where flag > -1
        end

        -- change tombstone type for the non-original rows (the rows that got deleted via expansion).
       update dbo.MSmerge_tombstone 
                set type = @METADATA_TYPE_PartialDelete
        from
          (select distinct tablenick, rowguid from 
               #notbelong where original_row <> 1) nb,
          dbo.MSmerge_tombstone ts
            where ts.tablenick = nb.tablenick and
                  ts.rowguid = nb.rowguid
          option (FORCE ORDER, LOOP JOIN)

        -- open a cursor and get the new metadata types for the original rows and then call sp_MSsetrowmetadata for each original row.
        declare original_rows_2 CURSOR LOCAL FAST_FORWARD for 
        select tablenick, rowguid, generation, lineage_new, metadatatype_new from #notbelong where original_row = 1
        FOR READ ONLY
        open original_rows_2
        fetch original_rows_2 into @tablenick, @rowguid, @generation, @lineage_new, @new_metatype
        while (@@fetch_status <> -1)
        begin
            if 1 = @parentarticleisupdateable and (@partition_options < 2 or @lineage_new is not null)
            begin
                -- Call sp_MSsetrowmetadata for only the original rows whose delete requests were passed in to this proc.
                -- call it with @compatlevel=90, because even if the reconciler is Shiloh, the lineages
                -- were already mapped up when the deletes where enumerated, and the reconciler then 
                -- concatenated the mapped-up lineages
                exec @retcode= sys.sp_MSsetrowmetadata 
                @tablenick, @rowguid, @generation, 
                @lineage_new, NULL, @new_metatype, NULL, 90
                IF @@ERROR<>0 or @retcode<>0
                begin
                        set @errcode= 0
                        close original_rows_2
                        deallocate original_rows_2
                        goto Failure
                end
            end
            fetch original_rows_2 into @tablenick, @rowguid, @generation, @lineage_new, @new_metatype
        end
        close original_rows_2
        deallocate original_rows_2

        commit tran

    end

-- DEBUG    insert into MSmerge_debug (okay, artnick, rowguid, lineage_old, lineage_new, generation_new, type, successcode, twhen, comment)
-- DEBUG        select 0, tablenick, rowguid, lineage_old, lineage_new, generation, metadatatype_old, 1, getdate(), 'sp_MSdelsubrowsbatch: new type ' + cast(@new_metatype as nvarchar(2)) from #notbelong where original_row = 1

    drop table #notbelong
    
    return 1 -- in sp_MSdelsubrows, 1=okay

Failure:
    -- instead of checking @@trancount, check our bit flag. This is safer as we can rely on it whether or not we are called 
    -- from an outer transaction.
    if (@transaction_started = 1)
    begin
        rollback tran start_of_batch
        commit tran
    end

-- DEBUG    insert into MSmerge_debug (okay, artnick, rowguid, lineage_old, lineage_new, generation_new, type, successcode, twhen, comment)
-- DEBUG        select 1, tablenick, rowguid, lineage_old, lineage_new, generation, metadatatype_old, @errcode, getdate(), 'sp_MSdelsubrowsbatch: new type ' + cast(@new_metatype as nvarchar(2)) from #notbelong where original_row = 1

    drop table #notbelong

    if @errcode = 1
        set @errcode = 0

    return(@errcode) -- in sp_MSdelsubrows, 0=error

GO
GRANT EXECUTE ON [sys].[sp_MSdelsubrowsbatch] TO [public] AS [dbo]
GO
