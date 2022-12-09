SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdelsubrows]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdelsubrows] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdelsubrows]
	@rowguid [uniqueidentifier],
	@tablenick [int],
	@metadata_type [tinyint],
	@lineage_old [varbinary](311),
	@generation [bigint],
	@lineage_new [varbinary](311),
	@pubid [uniqueidentifier],
	@rowsdeleted [int] OUTPUT,
	@compatlevel [int],
	@allarticlesareupdateable [bit]
WITH EXECUTE AS CALLER
AS
declare @match          int
    declare @errcode        int
    declare @new_metatype   tinyint
    declare @retcode        smallint
    declare @procname       sysname
    declare @tnstr          nvarchar(11)
    declare @error int, @rowcount int
    declare @parentarticleisupdateable bit
    declare @METADATA_TYPE_Tombstone tinyint
    declare @METADATA_TYPE_PartialDelete tinyint
    declare @METADATA_TYPE_SystemDelete tinyint
    declare @logical_record_parent_nickname int
    declare @partition_options tinyint

    set @METADATA_TYPE_Tombstone= 1
    set @METADATA_TYPE_PartialDelete= 5
    set @METADATA_TYPE_SystemDelete= 6

    /* By default this sp should delete exactly one row */
    set @rowsdeleted = 1
    
    /*
    ** Check to see if current publication has permission
    */
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @pubid = @pubid, @tablenick = @tablenick
    if (@retcode <> 0) or (@@error <> 0)
        return 4
        
    /* Parameter validation */
    if (@rowguid is null)
    begin
        RAISERROR(14043, 16, -1, '@rowguid', 'sp_MSdelsubrows')
        return (0)
    end
    if (@tablenick is null)
    begin
        RAISERROR(14043, 16, -1, '@tablenick', 'sp_MSdelsubrows')
        return (0)
    end

    if 1 = @allarticlesareupdateable
        set @parentarticleisupdateable= 1
    else
        set @parentarticleisupdateable= sys.fn_MSarticle_allows_DML_at_this_replica(default, @tablenick)

    if 1 = @parentarticleisupdateable
    begin
        if @compatlevel < 90
        begin
            set @lineage_new= {fn LINEAGE_80_TO_90(@lineage_new)}
            if @lineage_old is not null
                set @lineage_old= {fn LINEAGE_80_TO_90(@lineage_old)}
        end

        -- Are we just changing the type of a tombstone?
        if (@metadata_type = @METADATA_TYPE_PartialDelete or 
            @metadata_type = @METADATA_TYPE_Tombstone)
        begin
            if exists (select * from dbo.MSmerge_tombstone where rowguid = @rowguid and tablenick = @tablenick)
            begin
                
                update dbo.MSmerge_tombstone 
                    set type = @metadata_type, generation = @generation, lineage = @lineage_new 
                    where rowguid = @rowguid and tablenick = @tablenick
    -- DEBUG    insert into MSmerge_debug (okay, artnick, rowguid, lineage_old, lineage_new, generation_new, type, successcode, twhen, comment)
    -- DEBUG        values (0, @tablenick, @rowguid, @lineage_old, @lineage_new, @generation, @metadata_type, 1, getdate(), 'sp_MSdelsubrows: new type 5')
            return 1
            end
        end
        
        -- Are we just changing the type of a tombstone?
        else if (@metadata_type = @METADATA_TYPE_SystemDelete)
        begin
            if exists (select * from dbo.MSmerge_tombstone where rowguid = @rowguid and tablenick = @tablenick)
            begin
                update dbo.MSmerge_tombstone set type = @metadata_type
                    where rowguid = @rowguid and tablenick = @tablenick
    -- DEBUG    insert into MSmerge_debug (okay, artnick, rowguid, lineage_old, lineage_new, generation_new, type, successcode, twhen, comment)
    -- DEBUG        values (0, @tablenick, @rowguid, @lineage_old, @lineage_new, @generation, @metadata_type, 1, getdate(), 'sp_MSdelsubrows: new type 6')
                return 1
            end
        end

    end

    -- begin transaction and lock row that we plan to delete
    begin transaction
    save tran sp_MSdelsubrows

    select @procname = 'dbo.' + select_proc, @logical_record_parent_nickname = logical_record_parent_nickname,
                @partition_options = partition_options
    from dbo.sysmergepartitioninfoview
    where nickname = @tablenick 
    and pubid = @pubid
    
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
    
    exec @retcode = @procname @maxschemaguidforarticle = NULL, @type =8, @rowguid=@rowguid
    IF @@ERROR<>0 or @retcode<>0
    begin
        set @errcode= 0
        goto Failure
    end
        
    if 1 = @parentarticleisupdateable
    begin
        if @metadata_type = @METADATA_TYPE_PartialDelete
        begin
            set @new_metatype = @METADATA_TYPE_PartialDelete
        end
        else if @metadata_type = 6
        begin
            set @new_metatype = @METADATA_TYPE_SystemDelete
        end
        else
        begin
            set @new_metatype = @METADATA_TYPE_Tombstone
        end
        
            -- call sp_MScheckmetadatamatch with @compatlevel=90, because sp_MSdelsubrows already
            -- did the map-up if needed
            if @logical_record_parent_nickname = @tablenick
                            select @match = 1
                    else
                    begin
                            exec @retcode=sys.sp_MScheckmetadatamatch 
                        @metatype=@metadata_type, @rowguid=@rowguid, @tablenick=@tablenick, 
                                    @lineage=@lineage_old, @match=@match output, @compatlevel=90, @lineage_new=@lineage_new, 
                                    @new_type_contents=0
                            IF @@ERROR<>0 or @retcode<>0
                            begin
                        set @errcode= 0
                                    goto Failure
                            end
                    end

    end
    else
    begin
            set @match= 1
    end

    if (@match = 1)
    begin
        
        /* If there are any joinfilters with this as the join table, try to expand to deleting
        ** a set of related rows.
        */
        if (exists (select * from dbo.sysmergesubsetfilters where pubid = @pubid and join_nickname = @tablenick and (filter_type & 1) = 1))
        begin
            declare @tn int
            declare @qualified_table_name nvarchar(517)
            declare @unqualified_table_name nvarchar(270)
            
            select @rowsdeleted = 0

            /* create temp and put in our tablenick, rowguid */
            create table #notbelong (tablenick int NOT NULL, rowguid uniqueidentifier NOT NULL, flag int NOT NULL)
            create clustered index #indnbelong on #notbelong (tablenick, rowguid)
            insert into #notbelong (tablenick, rowguid, flag) values
                    (@tablenick, @rowguid, 0)
            
            /* call expand proc */
            exec @retcode = sys.sp_MSexpandsubsnb @pubid
            IF @@ERROR<>0 or @retcode<>0
            begin
                set @errcode= 0
                goto Failure
            end
        
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

            -- change tombstone type for those rows          
           update dbo.MSmerge_tombstone 
                    set type = @METADATA_TYPE_PartialDelete
            from
              (select distinct tablenick, rowguid from 
                   #notbelong) nb,
              dbo.MSmerge_tombstone ts
                where ts.tablenick = nb.tablenick and
                      ts.rowguid = nb.rowguid
              option (FORCE ORDER, LOOP JOIN)

            if 1 = @parentarticleisupdateable and (@partition_options < 2 or @lineage_new is not null)
            begin
                    -- call sp_MSsetrowmetadata with @compatlevel=90, because sp_MSdelrow
                    -- already did the map-up if it is needed
                    exec @retcode= sys.sp_MSsetrowmetadata 
                            @tablenick, @rowguid, @generation, 
                            @lineage_new, NULL, @new_metatype,
                            NULL, 90
                    IF @@ERROR<>0 or @retcode<>0
                    begin
                        set @errcode= 0
                        goto Failure
                    end
            end

            drop table #notbelong
        end
        else
        begin
            -- select_proc makes a delete with @type = 5, despite its name. 
            exec @retcode = @procname @maxschemaguidforarticle = NULL, @type =5, @rowguid=@rowguid
            select @error= @@error, @rowcount= @@rowcount
            IF @error<>0 or @retcode<>0
            begin
                set @errcode= 0
                goto Failure
            end

            if @rowcount <> 1
                        begin
                                set @errcode= 3
                                goto Failure
                        end
        
            if 1 = @parentarticleisupdateable and (@partition_options < 2 or @lineage_new is not null)
            begin
                -- call sp_MSsetrowmetadata with @compatlevel=90, because sp_MSdelrow
                -- already did the map-up if it is needed
                exec @retcode= sys.sp_MSsetrowmetadata 
                    @tablenick, @rowguid, @generation, 
                    @lineage_new, NULL, @new_metatype, NULL, 90
                IF @@ERROR<>0 or @retcode<>0
                begin
                    set @errcode= 0
                    goto Failure
                end
            end
        end
    end
    else if @match <> -1
    begin
        set @errcode= 2
        goto Failure
    end

    commit tran
-- DEBUG    insert into MSmerge_debug (okay, artnick, rowguid, lineage_old, lineage_new, generation_new, type, successcode, twhen, comment)
-- DEBUG        values (0, @tablenick, @rowguid, @lineage_old, @lineage_new, @generation, @metadata_type, 1, getdate(), 'sp_MSdelsubrows: new type ' + cast(@new_metatype as nvarchar(2)))
    return 1 -- in sp_MSdelsubrows, 1=okay

Failure:
    rollback tran sp_MSdelsubrows
    commit tran
-- DEBUG    insert into MSmerge_debug (okay, artnick, rowguid, lineage_old, lineage_new, generation_new, type, successcode, twhen, comment)
-- DEBUG        values (1, @tablenick, @rowguid, @lineage_old, @lineage_new, @generation, @metadata_type, @errcode, getdate(), 'sp_MSdelsubrows: new type ' + cast(@new_metatype as nvarchar(2)))
    return(@errcode) -- in sp_MSdelsubrows, 0=error

GO
GRANT EXECUTE ON [sys].[sp_MSdelsubrows] TO [public] AS [dbo]
GO
