SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_changepublication_snapshot]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_changepublication_snapshot] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_changepublication_snapshot]
	@publication [sysname],
	@frequency_type [int],
	@frequency_interval [int],
	@frequency_subday [int],
	@frequency_subday_interval [int],
	@frequency_relative_interval [int],
	@frequency_recurrence_factor [int],
	@active_start_date [int],
	@active_end_date [int],
	@active_start_time_of_day [int],
	@active_end_time_of_day [int],
	@snapshot_job_name [nvarchar](100),
	@publisher_security_mode [int],
	@publisher_login [sysname],
	@publisher_password [sysname],
	@job_login [nvarchar](257),
	@job_password [sysname],
	@publisher [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @cmd			nvarchar(4000)
	DECLARE @retcode		int
	DECLARE @publisher_type	sysname

	SET @retcode = 0
	
	EXEC @retcode = sys.sp_MSrepl_getpublisherinfo	@publisher		= @publisher,
													@publisher_type	= @publisher_type OUTPUT,
													@rpcheader		= @cmd            OUTPUT
	
	IF @retcode <> 0
		RETURN (@retcode)

	-- Add sp
	SET @publisher = UPPER(@publisher) COLLATE DATABASE_DEFAULT
	set @cmd = @cmd + N'sys.sp_MSrepl_changepublication_snapshot'
	
	EXEC @retcode = @cmd
					@publication,
					@frequency_type,
					@frequency_interval,
					@frequency_subday,
					@frequency_subday_interval,
					@frequency_relative_interval,
					@frequency_recurrence_factor,
					@active_start_date,
					@active_end_date,
					@active_start_time_of_day,
					@active_end_time_of_day,
					@snapshot_job_name,
					@publisher_security_mode,
					@publisher_login,
					@publisher_password,
					@job_login,
					@job_password,
					@publisher,
					@publisher_type
					

	RETURN (@retcode)
END
GO
GRANT EXECUTE ON [sys].[sp_changepublication_snapshot] TO [public] AS [dbo]
GO
