SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSsetup_use_partition_groups]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSsetup_use_partition_groups] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSsetup_use_partition_groups]
	@publication [sysname]
WITH EXECUTE AS CALLER
AS
declare @use_partition_groups smallint
            , @dynamic_filters bit
            , @dynamic_filters_function_list nvarchar(500)
            , @retcode int
            , @pubid uniqueidentifier
                
    exec @retcode = sys.sp_MSreplcheck_publish
    if @retcode<>0 or @@ERROR<>0
        return 1

    select @pubid = pubid, 
    @use_partition_groups = use_partition_groups, 
    @dynamic_filters = dynamic_filters, 
    @dynamic_filters_function_list = dynamic_filters_function_list
    from dbo.sysmergepublications 
    where name = @publication and UPPER(publisher)=UPPER(publishingservername()) and publisher_db=db_name()

    if @pubid is null
    begin
        raiserror(20026, 16, -1, @publication)
        return (1)
    end

    begin tran
    save transaction setup_partition_groups_table
    if (@use_partition_groups = 2)
    begin
        if (@dynamic_filters = 1 and @dynamic_filters_function_list is not null and @dynamic_filters_function_list <> ' ')
            or (@dynamic_filters = 0)
        begin
            
            -- dynamically filtered and we have the dynamic filters function list.
            -- or
            -- statically-filtered

            update dbo.sysmergepublications 
            set use_partition_groups = 1
            where pubid = @pubid
            and use_partition_groups = 2
            
            -- First make sure the appropriate columns are added to MSmergepartition_groups
            exec @retcode = sys.sp_MSsetup_partition_groups_table @pubid

            if @retcode <> 0 or @@error <> 0
            begin 
                goto UNDO
            end
        end
    end
    else if (@use_partition_groups = -1)
    begin
        
        exec @retcode = sys.sp_MSdisable_use_partition_groups @pubid
        if @retcode <> 0 or @@error <> 0
        begin
            goto UNDO
        end
    end
    else if (@dynamic_filters = 1 and @use_partition_groups = 0)
    begin
        exec @retcode = sys.sp_MSsetup_partition_groups_table @pubid
        if @retcode <> 0 or @@error <> 0
        begin 
            goto UNDO
        end
    end
    commit transaction

    return 0

UNDO:
    rollback transaction setup_partition_groups_table
    commit transaction

    return 1
GO
GRANT EXECUTE ON [sys].[sp_MSsetup_use_partition_groups] TO [public] AS [dbo]
GO
