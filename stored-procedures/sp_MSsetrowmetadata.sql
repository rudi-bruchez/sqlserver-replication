SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSsetrowmetadata]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSsetrowmetadata] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSsetrowmetadata]
	@tablenick [int],
	@rowguid [uniqueidentifier],
	@generation [bigint],
	@lineage [varbinary](311),
	@colv [varbinary](2953),
	@type [tinyint],
	@was_tombstone [int] OUTPUT,
	@compatlevel [int],
	@isinsert [bit],
	@pubid [uniqueidentifier],
	@publication_number [smallint],
	@partition_id [int],
	@partition_options [tinyint]
WITH EXECUTE AS CALLER
AS
declare @retcode int, @partchangegen bigint
    declare @mycommand2 nvarchar(2000), @myflag int
    declare @marker uniqueidentifier
    
    if (@isinsert = 1)
        set @partchangegen = -(@generation)
    else
        set @partchangegen = NULL
        
    if (@tablenick is null)
    begin
        RAISERROR(14043, 16, -1, '@tablenick', 'sp_MSsetrowmetadata')
        return (1)
    end
    if (@rowguid is null)
    begin
        RAISERROR(14043, 16, -1, '@rowguid', 'sp_MSsetrowmetadata')
        return (1)
    end
    if (@generation is null)
    begin
        RAISERROR(14043, 16, -1, '@generation', 'sp_MSsetrowmetadata')
        return (1)
    end
    if (@lineage is null)
    begin
        RAISERROR(14043, 16, -1, '@lineage', 'sp_MSsetrowmetadata')
        return (1)
    end

    /*
    ** Check to see if current publication has permission
    */
    if @pubid is NULL
    begin
        exec @retcode = sys.sp_MSrepl_PAL_rolecheck @tablenick = @tablenick
        if @retcode<>0 or @@ERROR<>0 return (1)
    end
    else
    begin
        if ({ fn ISPALUSER(@pubid) } <> 1)
        begin
            RAISERROR (14126, 11, -1)
            return (1)
        end
    end

    if @compatlevel < 90
    begin
        set @lineage= {fn LINEAGE_80_TO_90(@lineage)}
        if @colv is not null
            set @colv= {fn COLV_80_TO_90(@colv)}
    end

    if (@type=1 or @type=5 or @type=6)
    begin
        -- update or insert dbo.MSmerge_tombstone
        update dbo.MSmerge_tombstone set generation = @generation, lineage = @lineage, type = @type
            where tablenick = @tablenick and rowguid = @rowguid

        if (@@rowcount = 0)
        begin
            insert into dbo.MSmerge_tombstone (rowguid, tablenick, type, generation, lineage)
               values(@rowguid, @tablenick, @type, @generation, @lineage)

            delete from dbo.MSmerge_current_partition_mappings where rowguid=@rowguid and tablenick=@tablenick
            delete from dbo.MSmerge_contents where tablenick = @tablenick and rowguid = @rowguid

            if @partition_options > 1 and @partition_id is not null
            begin
                insert into dbo.MSmerge_past_partition_mappings (publication_number, tablenick, rowguid, 
                    partition_id, generation, reason)
                    values(@publication_number, @tablenick, @rowguid, @partition_id, @generation, 1)
            end
            else
            begin
                insert into dbo.MSmerge_past_partition_mappings (publication_number, tablenick, rowguid,
                    partition_id, generation, reason)
                    values (0, @tablenick, @rowguid, -1, @generation, 1)
            end            
        end
        else
        begin
            update dbo.MSmerge_past_partition_mappings
                set generation = @generation 
                where tablenick = @tablenick and rowguid = @rowguid and generation = 0
        end
    end
    else
    begin

        if not exists (select rowguid from dbo.MSmerge_contents where tablenick = @tablenick and rowguid = @rowguid)
        begin
            -- for the update case, evaluate partition membership if inserting a new contents row.
            -- this is needed when upd_sp does not really make an update, e.g. when no column value
            -- really changed. hence the trigger never fires and the contents entry doesn't get the 
            -- partition id's.
            -- for insert case, trigger always takes care of it.
          
            if @partition_options > 1
            begin
                if @partition_id is not null
                begin
                    insert into dbo.MSmerge_current_partition_mappings (publication_number, tablenick, rowguid, partition_id)
                    select distinct @publication_number, @tablenick, @rowguid, @partition_id
                        where not exists (select * from dbo.MSmerge_current_partition_mappings
                            where publication_number = @publication_number
                            and tablenick = @tablenick
                            and rowguid = @rowguid
                            and partition_id = @partition_id)

                end
            end
            else if @isinsert = 0
            begin
                exec @retcode = sys.sp_MSevaluate_change_membership_for_row @tablenick = @tablenick, @rowguid = @rowguid
                if @retcode <> 0 or @@error <> 0
                    return 1
            end
            
            if @isinsert = 1
                select @marker = newid()
            else
                select @marker = NULL
            
            insert into dbo.MSmerge_contents (rowguid, tablenick, generation, partchangegen, lineage, colv1, marker)
                values (@rowguid, @tablenick, @generation, @partchangegen, @lineage, @colv, @marker)
            delete from dbo.MSmerge_tombstone where tablenick = @tablenick and rowguid = @rowguid
            select @was_tombstone = @@rowcount
             -- for insert case, trigger always takes care of it.
            if @partition_options < 2 and @isinsert = 0
            -- don't need to do this for well-partitioned articles.
            begin
                exec @retcode = sys.sp_MSevaluate_logicalrecordparent @nickname = @tablenick, @rowguid = @rowguid
                if @retcode <> 0 or @@error <> 0
                    return 1
            end
        end
        else
        begin
            -- update or insert to MSmerge_contents
            -- The following updates the generation to passed in value only if the 
            -- filter columns have not changed.

            -- If filter values have changed, update the generation to gen_cur for article - 
            -- This will allow a subsequent download to cleanup rows that don't belong at subscriber
            -- the trigger would have already set partchangegen to gencur in case there was a partition column or filtering
            -- column that changed. Here we ill set the generation to be the passed in generation only if 
            -- partchangegen is NULL. If not we will set it to generation itself which will be gen_cur

            -- in some cases it is possible that the trigger was NFR. In that case both partchangegen and generation may have
            -- old values. Hence in those cases we want to be sure that the generation is a valid open gen.
            update dbo.MSmerge_contents 
            set generation = case when (isnull(partchangegen, -1) <> mc.generation and isnull(partchangegen, -1) <> (-mc.generation)) or g.genstatus in (1,2) then @generation else mc.generation end, 
                lineage = @lineage, 
                colv1 = @colv
                --@@@colv1 = case when datalength(@colv) < datalength(colv1) then colv1 else @colv end
            from dbo.MSmerge_contents mc, dbo.MSmerge_genhistory g
            where mc.tablenick = @tablenick 
            and mc.rowguid = @rowguid
            and g.generation = mc.generation
        end

    end -- end of insert/update

    IF @@ERROR<>0 return (1) 
    return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSsetrowmetadata] TO [public] AS [dbo]
GO
