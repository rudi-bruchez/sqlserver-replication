SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSsetup_partition_groups]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSsetup_partition_groups] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSsetup_partition_groups]
	@publication [sysname]
WITH EXECUTE AS CALLER
AS
begin
    declare @use_partition_groups smallint
            , @dynamic_filters bit
            , @dynamic_filters_function_list nvarchar(500)
            , @retcode int
            , @pubid uniqueidentifier
            , @snapshot_ready int
    
    exec @retcode = sys.sp_MSreplcheck_publish
    if @retcode<>0 or @@ERROR<>0
        return 1

    select @pubid = pubid, 
    @use_partition_groups = use_partition_groups, 
    @dynamic_filters = dynamic_filters, 
    @dynamic_filters_function_list = dynamic_filters_function_list,
    @snapshot_ready = snapshot_ready
    from dbo.sysmergepublications 
    where name = @publication and UPPER(publisher)=UPPER(publishingservername()) and publisher_db=db_name()

    if @pubid is null
    begin
        raiserror(20026, 16, -1, @publication)
        return (1)
    end

    if @snapshot_ready = 1 -- this is a subsequent snapshot and partition groups should have already been setup.
        return 0
        
    if (@use_partition_groups = 1)
    begin
        if (@dynamic_filters = 1 and @dynamic_filters_function_list is not null and @dynamic_filters_function_list <> ' ')
            or (@dynamic_filters = 0)
        begin
            -- dynamically filtered and we have the dynamic filters function list.
            -- or
            -- statically-filtered

            begin tran
            save transaction setup_partition_groups

            -- Then make sure that existing changes in contents are evaluated for partition memberships for this pubid only.
            -- Note that the tombstone changes cannot be evaluated since the data is no longer present. We may either not support
            -- going from use_partition_groups = 0 to use_partition_groups = 1, or we can document that all existing subscriptions must
            -- be in sync with the publication before sp_changemergepublication is called, or all tombstone rows can be marked as going to 
            -- all known partitions at this time. This has the effect of sending some unnecessary deletes, but if we use the generation value
            -- properly in the PastChange_to_Partition_Mapping table, then irrelevant deletes will not be sent after the first merge
            -- after sp_changemergepublication.
            -- For a given dynamic subscription the unique partition id is determined based on the row that has only the columns
            -- corresponding to functions used in that publication's filters, and obviously when the column values match the values
            -- those functions evaluate to for the merge agent.
            exec @retcode = sys.sp_MSsetup_publication_for_partition_groups @pubid

            if @retcode <> 0 or @@error <> 0
            begin 
                goto UNDO
            end

            commit transaction
        end
    end

    -- If not using partition groups, and snapshot is not already ready, 
    -- then call sp_MSevaluate_logicalrecordparent_allcontentsrows.
    -- This is for unfiltered publications using logical records. For 
    -- filtered publications, sp_MSevaluate_logicalrecordparent_allcontentsrows
    -- has already been called above in sp_MSsetup_publication_for_partition_groups.
    if (@use_partition_groups = 0 and @snapshot_ready <> 1)
    begin

        -- don't regenerate triggers as the snapshot will do it after calling this proc
        /*
        exec @retcode = sys.sp_MSregenerate_mergetriggers @publication
        if @@ERROR<>0 OR @retcode<>0 
        begin
            goto UNDO
        end */
        
        exec @retcode = sys.sp_MSevaluate_logicalrecordparent_allcontentsrows @pubid=@pubid
        if @@ERROR<>0 OR @retcode<>0 
        begin
            goto UNDO
        end 
    end
    
    if @use_partition_groups = 1
    begin
        
        IF NOT EXISTS (SELECT * FROM sys.indexes WHERE name = 'nc5MSmerge_contents' 
            AND object_id = OBJECT_ID('MSmerge_contents'))
        begin
            create unique index nc5MSmerge_contents on dbo.MSmerge_contents(tablenick, marker, rowguid)
            if @@ERROR <> 0    goto UNDO
        end
    end
    else
    begin
        if not exists (select * from dbo.sysmergepublications where use_partition_groups > 0)
        begin
            IF EXISTS (SELECT * FROM sys.indexes WHERE name = 'nc5MSmerge_contents' 
                AND object_id = OBJECT_ID('MSmerge_contents'))
                drop index dbo.MSmerge_contents.nc5MSmerge_contents
        end
    end

    return 0

UNDO:
    if @@trancount > 0
    begin
        rollback transaction setup_partition_groups
        commit transaction
    end

    return 1
end
GO
GRANT EXECUTE ON [sys].[sp_MSsetup_partition_groups] TO [public] AS [dbo]
GO
