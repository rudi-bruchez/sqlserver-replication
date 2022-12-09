SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_changesubstatus]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_changesubstatus] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_changesubstatus]
	@publication [sysname],
	@article [sysname],
	@subscriber [sysname],
	@status [sysname],
	@previous_status [sysname],
	@destination_db [sysname],
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
	@distribution_jobid [binary](16) OUTPUT,
	@from_auto_sync [bit],
	@ignore_distributor [bit],
	@offloadagent [bit],
	@offloadserver [sysname],
	@dts_package_name [sysname],
	@dts_package_password [nvarchar](524),
	@dts_package_location [int],
	@skipobjectactivation [int],
	@distribution_job_name [sysname],
	@publisher [sysname],
	@ignore_distributor_failure [bit]
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @cmd			nvarchar(4000)
	DECLARE @retcode		int
	DECLARE	@publisher_type	sysname

	SET @retcode = 0
	
	EXEC @retcode = sys.sp_MSrepl_getpublisherinfo	@publisher		= @publisher,
													@rpcheader		= @cmd OUTPUT,
													@publisher_type	= @publisher_type OUTPUT,
													@skipSecurityCheck	= 1
	IF @retcode <> 0
		RETURN (@retcode)

	-- Add sp
	SET @publisher = UPPER(@publisher) COLLATE DATABASE_DEFAULT
	set @cmd = @cmd + N'sys.sp_MSrepl_changesubstatus'
	
	EXEC @retcode = @cmd
					@publication,
					@article,
					@subscriber,
					@status,
					@previous_status,
					@destination_db,
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
					@distribution_jobid OUTPUT,
					@from_auto_sync,
					@ignore_distributor,
					-- Agent offload
					@offloadagent,
					@offloadserver,
					@dts_package_name,
					@dts_package_password,
					@dts_package_location,
					@skipobjectactivation,
					@distribution_job_name,
					@publisher,
					@publisher_type
					,@ignore_distributor_failure

	RETURN (@retcode)
END
GO
GRANT EXECUTE ON [sys].[sp_changesubstatus] TO [public] AS [dbo]
GO
