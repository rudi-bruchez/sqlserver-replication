SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_changesubscriber_schedule]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_changesubscriber_schedule] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_changesubscriber_schedule]
	@subscriber [sysname],
	@agent_type [smallint],
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
	@publisher [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @cmd			nvarchar(4000)
	DECLARE @retcode		int
	DECLARE @publisher_type	sysname

	SET @retcode = 0
	
	EXEC @retcode = sys.sp_MSrepl_getpublisherinfo	@publisher		= @publisher,
													@rpcheader		= @cmd            OUTPUT,
													@publisher_type	= @publisher_type OUTPUT
	
	IF @retcode <> 0
		RETURN (@retcode)

	-- Add sp
	SET @publisher = UPPER(@publisher) COLLATE DATABASE_DEFAULT
	set @cmd = @cmd + N'sys.sp_MSrepl_changesubscriber_schedule'
	
	EXEC @retcode = @cmd
					@subscriber,
					@agent_type,
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
					@publisher,
					@publisher_type

	RETURN (@retcode)
END
GO
GRANT EXECUTE ON [sys].[sp_changesubscriber_schedule] TO [public] AS [dbo]
GO
