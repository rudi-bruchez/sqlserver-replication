SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSset_dynamic_filter_options]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSset_dynamic_filter_options] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSset_dynamic_filter_options]
	@publication [sysname],
	@dynamic_filters [bit] OUTPUT,
	@dont_raise_error [bit]
WITH EXECUTE AS CALLER
AS
declare @show_errors bit
    , @retcode int
    , @can_use_partition_groups bit
    , @use_partition_groups smallint
    , @dynamic_filters_function_list nvarchar(500)
    , @has_dynamic_filters bit
    , @validate_subscriber_info nvarchar(500)
    , @pubid uniqueidentifier
    , @compatlevel int
    , @old_has_dynamic_filters bit

    exec @retcode = sys.sp_MSreplcheck_publish
    if @@ERROR <> 0 or @retcode <> 0
        return(1)
    

    select @pubid = pubid
    , @use_partition_groups = use_partition_groups
    , @compatlevel = backward_comp_level
    , @old_has_dynamic_filters = dynamic_filters
    from dbo.sysmergepublications
    where name = @publication and UPPER(publisher)=UPPER(publishingservername()) and publisher_db=db_name()
    if @pubid is NULL
    begin
        raiserror (20026, 11, -1, @publication)
        return (1)
    end
        
    -- If dbo has not specified whether this publication should use partition groups or not,
    -- then we should use it if possible. Determine if any of the restrictions of partition
    -- ids are violated. If yes, then set use_partition_groups to 0, else set it to 2.
    --
    -- If dbo has specified that partition groups should be used, make sure that the publication
    -- does not violate any restrictions of partition groups. If it does, raise an error.
    exec @retcode = sys.sp_MScheck_dynamic_filters 
                                        @publication = @publication
                                        , @can_use_partition_groups = @can_use_partition_groups output
                                        , @has_dynamic_filters = @has_dynamic_filters output
                                        , @dynamic_filters_function_list = @dynamic_filters_function_list output
                                        , @validate_subscriber_info = @validate_subscriber_info output
                                        , @uses_host_name = NULL
                                        , @uses_suser_sname = NULL
                                        , @dont_raise_error = @dont_raise_error

    if @@error <> 0 or @retcode <> 0
        return 1

    -- dynamic filters setting cannot change for an active publication that has valid bcp schema changes
    -- since the schema types can either be dynamic or static whenever a publication changes from a static
    -- to a dynamic publication or vice versa we shoudl have deleted the bcp schema changes from sysmergepublications
    -- the following is to just check that this was done. This error can also happen after upgrade if the
    -- dynamic_filters property was incorrectly set in shiloh. The code path in addmerge or changemerge article
    -- should be settig dont_raise_error to true. Also these code paths should have already taken care of deleting
    -- the bcp schema changes from sysmergeschemachange.
    if ((@old_has_dynamic_filters = 0 and @has_dynamic_filters = 1) or
        (@old_has_dynamic_filters = 1 and @has_dynamic_filters = 0)) and
       exists (select 1 from dbo.sysmergeschemachange where pubid=@pubid and schematype in (3,4,131,132)) -- native and character bcp schema types
       and (@dont_raise_error is NULL or @dont_raise_error = 0)
    begin
        raiserror (20711, 11, -1, @publication)
        return (1)
    end
    
    update dbo.sysmergepublications set dynamic_filters = @has_dynamic_filters, 
        validate_subscriber_info = 
            case when validate_subscriber_info = N'' and @compatlevel >= 90 and @validate_subscriber_info is not null
            then @validate_subscriber_info 
            else validate_subscriber_info end
    where pubid = @pubid

    select @dynamic_filters = @has_dynamic_filters
        
    if @can_use_partition_groups = 1
        set @use_partition_groups = 2
    else if @use_partition_groups is NULL
    begin
        set @use_partition_groups = 0
        set @dynamic_filters_function_list = NULL
    end
            
    update dbo.sysmergepublications 
    set use_partition_groups = @use_partition_groups,
        dynamic_filters_function_list = @dynamic_filters_function_list,
        keep_before_values = case when backward_comp_level >= 90 then 0 else keep_before_values end
    where pubid = @pubid
    and (use_partition_groups is null or use_partition_groups = 2)

    update dbo.sysmergepublications 
    set dynamic_filters_function_list = @dynamic_filters_function_list
    where pubid = @pubid
    and (use_partition_groups = 0)
    
    if @dynamic_filters_function_list is not null
        update dbo.sysmergepublications 
        set dynamic_filters_function_list = @dynamic_filters_function_list       
        where pubid = @pubid
        and (use_partition_groups = 1)

    /* Only if the caller is interested in errors, set the retcode properly - sp_addmergearticle is not interested in these errors because it expects the snapshot to set the use_partition_groups properly */
    if (@dont_raise_error is NULL or @dont_raise_error = 0)
    begin
        if @can_use_partition_groups = 0 and @use_partition_groups = 2
        begin
            -- For this case, sp_MScheck_dynamic_filters would have already raised an error.
            return 1
        end
    end        
    return 0
GO
GRANT EXECUTE ON [sys].[sp_MSset_dynamic_filter_options] TO [public] AS [dbo]
GO
