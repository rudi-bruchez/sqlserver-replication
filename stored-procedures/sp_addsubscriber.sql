SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_addsubscriber]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_addsubscriber] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_addsubscriber]
	@subscriber [sysname],
	@type [tinyint],
	@login [sysname],
	@password [nvarchar](524),
	@commit_batch_size [int],
	@status_batch_size [int],
	@flush_frequency [int],
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
	@description [nvarchar](255),
	@security_mode [int],
	@encrypted_password [bit],
	@publisher [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @cmd			nvarchar(4000)
	DECLARE @retcode		int
	DECLARE @publisher_type	sysname

	/*
	** Security Check: require sysadmin
	*/
	IF (ISNULL(IS_SRVROLEMEMBER('sysadmin'),0) = 0)
	BEGIN
		RAISERROR(21089,16,-1) 
		RETURN (1)
	END

	SET @retcode = 0
	
	EXEC @retcode = sys.sp_MSrepl_getpublisherinfo	@publisher		= @publisher,
													@rpcheader		= @cmd            OUTPUT,
													@publisher_type	= @publisher_type OUTPUT

														
	IF @retcode <> 0
		RETURN (@retcode)

	--when called on mirror server, this adds original publisher name 
	--in distribution. (MSsubscriber_info and MSsubscriber_schedule)
	IF @publisher IS NULL
		SET @publisher = publishingservername() 

	-- Add sp
	SET @publisher = UPPER(@publisher) COLLATE DATABASE_DEFAULT
	set @cmd = @cmd + N'sys.sp_MSrepl_addsubscriber'
	
	EXEC @retcode = @cmd
					@subscriber,
					@type,
					@login,
					@password,
					@commit_batch_size,
					@status_batch_size,
					@flush_frequency,
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
					@description,
					@security_mode,
					@encrypted_password,
					@publisher,
					@publisher_type,
					N'PRE-YUKON'

	RETURN (@retcode)
END
GO
GRANT EXECUTE ON [sys].[sp_addsubscriber] TO [public] AS [dbo]
GO
