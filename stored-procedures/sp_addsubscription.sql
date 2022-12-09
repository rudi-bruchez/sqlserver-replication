SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_addsubscription]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_addsubscription] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_addsubscription]
	@publication [sysname],
	@article [sysname],
	@subscriber [sysname],
	@destination_db [sysname],
	@sync_type [nvarchar](255),
	@status [sysname],
	@subscription_type [nvarchar](4),
	@update_mode [nvarchar](30),
	@loopback_detection [nvarchar](5),
	@frequency_type [int],
	@frequency_interval [int],
	@frequency_relative_interval [int],
	@frequency_recurrence_factor [int],
	@frequency_subday [int],
	@frequency_subday_interval [int],
	@active_start_time_of_day [int],
	@active_end_time_of_day [int],
	@active_start_date [int],
	@active_end_date [int],
	@optional_command_line [nvarchar](4000),
	@reserved [nvarchar](10),
	@enabled_for_syncmgr [nvarchar](5),
	@offloadagent [bit],
	@offloadserver [sysname],
	@dts_package_name [sysname],
	@dts_package_password [sysname],
	@dts_package_location [nvarchar](12),
	@distribution_job_name [sysname],
	@publisher [sysname],
	@backupdevicetype [nvarchar](20),
	@backupdevicename [nvarchar](1000),
	@mediapassword [sysname],
	@password [sysname],
	@fileidhint [int],
	@unload [bit],
	@subscriptionlsn [binary](10),
	@subscriptionstreams [tinyint],
	@subscriber_type [tinyint],
	@memory_optimized [bit]
WITH EXECUTE AS CALLER
AS
BEGIN
    DECLARE @cmd			nvarchar(4000)
    DECLARE @retcode		int
    DECLARE @publisher_type	sysname

    SET @retcode = 0

    EXEC @retcode = sys.sp_MSrepl_getpublisherinfo	@publisher		= @publisher,
                                                    @rpcheader		= @cmd OUTPUT,
                                                    @publisher_type	= @publisher_type OUTPUT

    IF @retcode <> 0
        RETURN (@retcode)

    -- Add sp
    SET @publisher = UPPER(@publisher) COLLATE DATABASE_DEFAULT
    set @cmd = @cmd + N'sys.sp_MSrepl_addsubscription'
    
    EXEC @retcode = @cmd
                    @publication,
                    @article,
                    @subscriber,
                    @destination_db,
                    @sync_type,
                    @status,
                    @subscription_type,
                    @update_mode,
                    @loopback_detection,
                    @frequency_type,
                    @frequency_interval,
                    @frequency_relative_interval,
                    @frequency_recurrence_factor,
                    @frequency_subday,
                    @frequency_subday_interval,
                    @active_start_time_of_day,
                    @active_end_time_of_day,
                    @active_start_date,
                    @active_end_date,
                    @optional_command_line,
                    @reserved,
                    @enabled_for_syncmgr,
                    @offloadagent,
                    @offloadserver,
                    @dts_package_name,
                    @dts_package_password,
                    @dts_package_location,
                    @distribution_job_name,
                    @publisher,
                    @backupdevicetype,
                    @backupdevicename,
                    @mediapassword,
                    @password,
                    @fileidhint,
                    @unload,
                    @subscriptionlsn,
                    @publisher_type,
                    @subscriptionstreams,
                    @subscriber_type,
                    @memory_optimized

    RETURN (@retcode)
END
GO
GRANT EXECUTE ON [sys].[sp_addsubscription] TO [public] AS [dbo]
GO
