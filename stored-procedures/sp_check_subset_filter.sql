SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_check_subset_filter]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_check_subset_filter] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_check_subset_filter]
	@filtered_table [nvarchar](400),
	@subset_filterclause [nvarchar](1000),
	@has_dynamic_filters [bit] OUTPUT,
	@dynamic_filters_function_list [nvarchar](500) OUTPUT
WITH EXECUTE AS CALLER
AS
set nocount on
    
    declare @retcode int
    , @owner_qualified_art_name nvarchar(517)
    , @art_name nvarchar(258)
    , @viewname nvarchar(258)
    , @objid int
    , @found_functions bit
    , @can_use_partition_groups bit
    , @uses_host_name bit
    , @uses_suser_sname bit
    , @passed_in_has_dynamic_filters bit
   
    
    /*
    ** Security Check
    */
    exec @retcode = sys.sp_MSreplcheck_publish
    if @@ERROR <> 0 or @retcode <> 0
        return(1)
        
    set @passed_in_has_dynamic_filters = @has_dynamic_filters
        
    -- Initialize the flags to such a value that the occurrence of some condition will
    -- set the value to the opposite value.
    set @can_use_partition_groups = 1
    set @has_dynamic_filters = 0
    set @uses_host_name = 0
    set @uses_suser_sname = 0
    set @dynamic_filters_function_list = NULL
    
    select @objid = object_id(@filtered_table)
    
    if @objid is null
    begin
        declare @dbname sysname
        select @dbname = db_name()
        raiserror(20507, 16, 1, @filtered_table, @dbname)
        return 1
    end
    
    select @owner_qualified_art_name = quotename(SCHEMA_NAME(schema_id)) + '.' + quotename(name)
            , @art_name = quotename(name)
    from sys.objects
    where object_id = @objid
            
    select @viewname = quotename('MSmerge_subset_filter_view_' + convert(nvarchar(40), newid()))
        
    begin tran
    save tran check_subset_filter
        
    exec ('create view dbo.' + @viewname + ' as select placeholder = 1 from ' + @owner_qualified_art_name + ' ' + @art_name +  
            ' where ' + '(' + @subset_filterclause + ')')
                    
    if @@error <> 0
        goto UNDO
            
    exec @retcode = sys.sp_MScheck_functions_directly_in_view    @viewname = @viewname
                                                            , @has_dynamic_filters = @has_dynamic_filters output
                                                            , @dynamic_filters_function_list = @dynamic_filters_function_list output
                                                            , @uses_host_name = @uses_host_name output
                                                            , @uses_suser_sname = @uses_suser_sname output
                                                            
    if @@error <> 0 or @retcode <> 0
        goto UNDO
        
    exec @retcode = sys.sp_MScheck_functions_indirectly_in_view @viewname = @viewname
                                                            , @use_partition_groups = NULL
                                                            , @can_use_partition_groups = @can_use_partition_groups output
                                                            , @has_dynamic_filters = @found_functions output
                                                            , @dynamic_filters_function_list = @dynamic_filters_function_list output
                                                            , @uses_host_name = @uses_host_name output
                                                            , @uses_suser_sname = @uses_suser_sname output
    if @@error <> 0 or @retcode <> 0
        goto UNDO
    
    if @found_functions = 1
    begin
        set @can_use_partition_groups = 0
        set @has_dynamic_filters = 1
    end        
    
    -- rollback tran so that the temp view gets dropped. 
    rollback tran check_subset_filter
    commit tran

    if @passed_in_has_dynamic_filters is NULL
    begin
        select can_use_partition_groups = @can_use_partition_groups
        , has_dynamic_filters = @has_dynamic_filters
        , dynamic_filters_function_list = @dynamic_filters_function_list
        , uses_host_name = @uses_host_name
        , uses_suser_sname = @uses_suser_sname
    end
    return 0
    
UNDO:

    if @@trancount > 0
    begin
        rollback tran check_subset_filter
        commit tran
    end
    return 1
GO
GRANT EXECUTE ON [sys].[sp_check_subset_filter] TO [public] AS [dbo]
GO
