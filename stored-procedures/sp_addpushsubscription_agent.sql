SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_addpushsubscription_agent]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_addpushsubscription_agent] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_addpushsubscription_agent]
	@publication [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname],
	@subscriber_security_mode [smallint],
	@subscriber_login [sysname],
	@subscriber_password [sysname],
	@job_login [nvarchar](257),
	@job_password [sysname],
	@job_name [sysname],
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
	@dts_package_name [sysname],
	@dts_package_password [sysname],
	@dts_package_location [nvarchar](12),
	@enabled_for_syncmgr [nvarchar](5),
	@distribution_job_name [sysname],
	@publisher [sysname],
	@subscriber_provider [sysname],
	@subscriber_datasrc [nvarchar](4000),
	@subscriber_location [nvarchar](4000),
	@subscriber_provider_string [nvarchar](4000),
	@subscriber_catalog [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @cmd			nvarchar(4000)
	DECLARE @retcode		int
	DECLARE @publisher_type	sysname

	SET @retcode = 0
	
	EXEC @retcode = sys.sp_MSrepl_getpublisherinfo	@publisher		= @publisher,
													@rpcheader		= @cmd OUTPUT,
													@publisher_type = @publisher_type OUTPUT
	
	IF @retcode <> 0
		RETURN (@retcode)

	-- Get subscriber without port number
	EXEC sys.sp_MSget_server_portinfo 
		@name = @subscriber, 
		@srvname = @subscriber OUTPUT

	-- Add sp
	SET @publisher = UPPER(@publisher) COLLATE DATABASE_DEFAULT
	set @cmd = @cmd + N'sys.sp_MSrepl_addpushsubscription_agent'
	
	EXEC @retcode = @cmd @publication,
							@subscriber,
							@subscriber_db,
							@subscriber_security_mode,
							@subscriber_login,
							@subscriber_password,
							@job_login,
							@job_password,
							@job_name,
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
							@dts_package_name,
							@dts_package_password,
							@dts_package_location,
							@enabled_for_syncmgr,
							@distribution_job_name,
							@publisher,
							@publisher_type,
							@subscriber_provider,
							@subscriber_datasrc,
							@subscriber_location,
							@subscriber_provider_string,
							@subscriber_catalog

	RETURN (@retcode)
END
GO
GRANT EXECUTE ON [sys].[sp_addpushsubscription_agent] TO [public] AS [dbo]
GO
