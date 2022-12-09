SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_adddynamicsnapshot_job]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_adddynamicsnapshot_job] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_adddynamicsnapshot_job]
	@publication [sysname],
	@suser_sname [sysname],
	@host_name [sysname],
	@dynamic_snapshot_jobname [sysname] OUTPUT,
	@dynamic_snapshot_jobid [uniqueidentifier] OUTPUT,
	@frequency_type [int],
	@frequency_interval [int],
	@frequency_subday [int],
	@frequency_subday_interval [int],
	@frequency_relative_interval [int],
	@frequency_recurrence_factor [int],
	@active_start_date [int],
	@active_end_date [int],
	@active_start_time_of_day [int],
	@active_end_time_of_day [int]
WITH EXECUTE AS CALLER
AS
declare @retcode int
    
    exec @retcode = sys.sp_MSreplcheck_publish
    if @@error <> 0 or @retcode <> 0
        return (1)

    if @suser_sname is NULL or ltrim(rtrim(@suser_sname)) = N''
        select @suser_sname = NULL
    if @host_name is NULL or ltrim(rtrim(@host_name)) = N''
        select @host_name = NULL
        
    exec @retcode = sys.sp_MSaddmergedynamicsnapshotjob 
            @publication = @publication, 
            @dynamic_filter_login = @suser_sname, 
            @dynamic_filter_hostname = @host_name, 
            @dynamic_snapshot_location = NULL, 
            @dynamic_snapshot_jobname = @dynamic_snapshot_jobname output,
            @dynamic_snapshot_jobid = @dynamic_snapshot_jobid output,
            @frequency_type = @frequency_type,
            @frequency_interval = @frequency_interval,
            @frequency_subday = @frequency_subday,
            @frequency_subday_interval = @frequency_subday_interval,
            @frequency_relative_interval = @frequency_relative_interval, 
            @frequency_recurrence_factor = @frequency_recurrence_factor,
            @active_start_date = @active_start_date,
            @active_end_date = @active_end_date,
            @active_start_time_of_day = @active_start_time_of_day, 
            @active_end_time_of_day = @active_end_time_of_day
     return @retcode
GO
GRANT EXECUTE ON [sys].[sp_adddynamicsnapshot_job] TO [public] AS [dbo]
GO
