SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_check_dynamic_filters]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_check_dynamic_filters] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_check_dynamic_filters]
	@publication [sysname]
WITH EXECUTE AS CALLER
AS
set nocount on
    
    declare @can_use_partition_groups bit
    , @has_dynamic_filters bit
    , @dynamic_filters_function_list nvarchar(500)
    , @validate_subscriber_info nvarchar(500)
    , @uses_host_name bit
    , @uses_suser_sname bit
    , @retcode int
    
    /*
    ** Security Check
    */
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @publication=@publication
    if @@ERROR <> 0 or @retcode <> 0
        return(1)
    
    exec @retcode = sys.sp_MScheck_dynamic_filters @publication = @publication    
                                                    , @can_use_partition_groups = @can_use_partition_groups output
                                                    , @has_dynamic_filters = @has_dynamic_filters output
                                                    , @dynamic_filters_function_list = @dynamic_filters_function_list output
                                                    , @validate_subscriber_info = @validate_subscriber_info output
                                                    , @uses_host_name = @uses_host_name output
                                                    , @uses_suser_sname = @uses_suser_sname output
    if @@error <> 0 or @retcode <> 0
        return 1
        
    select can_use_partition_groups = @can_use_partition_groups
    , has_dynamic_filters = @has_dynamic_filters
    , dynamic_filters_function_list = @dynamic_filters_function_list
    , validate_subscriber_info = @validate_subscriber_info
    , uses_host_name = @uses_host_name
    , uses_suser_sname = @uses_suser_sname
    
    return 0
                                    
GO
GRANT EXECUTE ON [sys].[sp_check_dynamic_filters] TO [public] AS [dbo]
GO
