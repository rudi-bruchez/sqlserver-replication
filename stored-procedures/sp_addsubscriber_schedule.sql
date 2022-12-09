SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_addsubscriber_schedule]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_addsubscriber_schedule] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_addsubscriber_schedule]
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
DECLARE @distributor sysname
	DECLARE @distribdb sysname
	DECLARE @distproc nvarchar (300)
	DECLARE @retcode int
	DECLARE @msg nvarchar(255)
	DECLARE @subscriber_provstr nvarchar(4000) = NULL

	-- Heterogeneous publishers
	DECLARE @publisher_local sysname
	
	/*
	** Security Check: require sysadmin
	*/
	IF (ISNULL(IS_SRVROLEMEMBER('sysadmin'),0) = 0)
	BEGIN
		RAISERROR(21089,16,-1) 
		RETURN (1)
	END

	/*
	** If @publisher is NULL, set @publisher_local to @@SERVERNAME
	** otherwise, set @publisher_local to @publisher
	*/
	IF @publisher IS NULL
	BEGIN
		select @publisher_local = publishingservername()
	END 
	ELSE
	BEGIN
		EXEC sys.sp_MSget_server_portinfo  
			@name = @publisher,
			@srvname = @publisher OUTPUT

	/* Check if publisher exists */
	  EXEC @retcode = sys.sp_MSrepl_getpublisherinfo	@publisher		= @publisher	
	IF @retcode <> 0
		RETURN (@retcode)
	/* For heterogeneous publisher, the current database must be the */
	/* distribution db for the publisher */

		select @publisher_local = @publisher

		IF NOT EXISTS ( select * from master.dbo.sysservers s, msdb..MSdistpublishers m
		where UPPER(s.srvname collate database_default) = UPPER(m.name collate database_default)
		and UPPER(s.srvname collate database_default) = UPPER(@publisher) collate database_default
		and (m.distribution_db collate database_default) = (DB_NAME() collate database_default)
		)
		RETURN (1)   
	
	IF @@ERROR <> 0 
		RETURN (1)
	
	END 

	/*
	** Parameter Check:  @subscriber.
	** Check to make sure that the subscriber doesn't already exist, and
	** that the name is a valid non-null identifier.
	*/

	IF @subscriber IS NULL
		BEGIN
			RAISERROR (14043, 16, -1, '@subscriber', 'sp_addsubscriber_schedule')
			RETURN (1)
		END

	EXECUTE @retcode = sys.sp_validname @subscriber

	IF @@ERROR <> 0 OR @retcode <> 0
	RETURN (1)

	if LOWER(@subscriber) = 'all'
		BEGIN
			RAISERROR (14032, 16, -1, '@subscriber')
			RETURN (1)
		END

	--Get subscriber server name.
	declare @subserver_with_port sysname
	EXEC sys.sp_MSget_server_portinfo  
		@name = @subscriber,
		@srvname = @subscriber OUTPUT,
		@srvname_with_port = @subserver_with_port OUTPUT

	EXEC @retcode = sys.sp_MSrepl_getdistributorinfo @rpcsrvname = @distributor OUTPUT,
													   @distribdb = @distribdb   OUTPUT,
													   @publisher = @publisher

	IF @@error <> 0
		BEGIN
		 RAISERROR (14071, 16, -1)
		 RETURN (1)
	 END

	IF @retcode <> 0 OR @distribdb IS NULL OR @distributor IS NULL
		BEGIN
			RAISERROR (14071, 16, -1)
			RETURN (1)
		END
	
	SELECT @distproc = QUOTENAME(RTRIM(@distributor)) + '.' + QUOTENAME(RTRIM(@distribdb)) + '.dbo.sp_MSadd_subscriber_schedule'
	EXEC @retcode = @distproc
		 @publisher_local,
		 @subserver_with_port,
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
		 @active_end_date
	IF @@error <> 0 OR @retcode <> 0
		BEGIN
		RAISERROR (14042, 16, -1)
		RETURN (1)
	END

	RETURN (0)
GO
GRANT EXECUTE ON [sys].[sp_addsubscriber_schedule] TO [public] AS [dbo]
GO
