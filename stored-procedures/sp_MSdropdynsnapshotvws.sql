SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdropdynsnapshotvws]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdropdynsnapshotvws] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdropdynsnapshotvws]
	@dynamic_snapshot_views_table [sysname]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    declare @retcode int   
    declare @final_retcode int
    declare @select_command nvarchar(4000)
    declare @old_dynamic_snapshot_view_name sysname
    declare @dynamic_snapshot_view_name sysname
    declare @drop_view_command nvarchar(4000)
    declare @select_param_list nvarchar(4000)

    select @final_retcode = 0
    select @retcode = 0
    -- Security check 
    exec @retcode = sys.sp_MSreplcheck_publish
    if @@error<>0 or @retcode<>0
    begin
        return 1
    end

    -- For the first fecth, don't do comparison with the old view name...
    select @dynamic_snapshot_view_name  = null       
    select @select_command = N'
        select @dynamic_snapshot_view_name = min(dynamic_snapshot_view_name)
          from ' + quotename(@dynamic_snapshot_views_table)

    select @select_param_list =         
        N'@dynamic_snapshot_view_name sysname output'

    exec @retcode = sys.sp_executesql @select_command,
        @select_param_list,
        @dynamic_snapshot_view_name = @dynamic_snapshot_view_name output
    if @@error<>0 or @retcode<>0
    begin
        select @final_retcode = 1
    end

    -- Change query to do comparison with the old name
    select @select_command = N'
        select @dynamic_snapshot_view_name = min(dynamic_snapshot_view_name)
          from ' + quotename(@dynamic_snapshot_views_table) + N' 
         where dynamic_snapshot_view_name > @old_dynamic_snapshot_view_name'
    
    select @select_param_list =         
        N'@dynamic_snapshot_view_name sysname output, 
          @old_dynamic_snapshot_view_name sysname'

    -- Keep selecting view with the smallest name that
    -- is greater than the last one until we are done
    while @dynamic_snapshot_view_name is not null
    begin

        select @drop_view_command = N'drop view ' + 
            quotename(@dynamic_snapshot_view_name)
        exec(@drop_view_command)    
        if @@error<>0
        begin
            select @final_retcode = 1 
        end

        -- Drop the temporary function created for the dynamic snapshot view
        select @drop_view_command = 'drop function dbo.' + 
                quotename(@dynamic_snapshot_view_name + '_FN')
        exec(@drop_view_command)
        if @@error<>0
        begin
            select @retcode = 1
        end       

        delete MSdynamicsnapshotviews 
         where dynamic_snapshot_view_name = @dynamic_snapshot_view_name      
        if @@error<>0
        begin
            select @final_retcode = 1 
        end

        select @old_dynamic_snapshot_view_name = @dynamic_snapshot_view_name
        select @dynamic_snapshot_view_name = null
        exec @retcode = sys.sp_executesql @select_command,
            @select_param_list,
            @dynamic_snapshot_view_name = @dynamic_snapshot_view_name output,
            @old_dynamic_snapshot_view_name = @old_dynamic_snapshot_view_name  

        if @@error<>0 or @retcode<>0
        begin
            select @final_retcode = 1
        end
    end 
    -- At the end, we need to drop the temp table
    declare @drop_table_command nvarchar(4000)
    select @drop_table_command = N'drop table ' + quotename(@dynamic_snapshot_views_table)
    exec(@drop_table_command)
    if @@error<>0
    begin
        select @final_retcode = 1
    end
    return @final_retcode    
end
GO
GRANT EXECUTE ON [sys].[sp_MSdropdynsnapshotvws] TO [public] AS [dbo]
GO
