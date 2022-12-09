SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_mergesubscriptionsummary]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_mergesubscriptionsummary] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_mergesubscriptionsummary]
	@publication [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
	SET NOCOUNT ON
	DECLARE @retcode            int,
			@distributor_rpc    sysname,
			@distributor        sysname,
			@distribution_db    sysname,
			@pubid              uniqueidentifier,
			@procedure          nvarchar(4000),
			@publisher          sysname,
			@publisher_db       sysname

	SET @retcode        = 0
	SET @publisher      = publishingservername()
	SET @publisher_db   = db_name()

	--
	-- PAL check and validate publication
	--
	exec @retcode = sp_MSreplcheck_pull @publication = @publication,
										@raise_fatal_error = 0
	IF (@@error != 0) OR (@retcode != 0)
		RETURN 1
	
	-- Make sure current database is enabled for merge replication
	EXEC @retcode = sys.sp_MSCheckmergereplication
	IF (@@error != 0) OR (@retcode != 0)
		RETURN 1

	-- Parameter check: @subscriber
	IF @subscriber IS NULL
	BEGIN
		-- "The parameter @subscriber cannot be NULL."
		RAISERROR (14043, 16, -1, '@subscriber', 'sp_mergesubscriptionsummary')
		RETURN 1
	END

	SELECT @pubid = pubid
	  FROM dbo.sysmergepublications
	 WHERE UPPER(publisher) = UPPER(@publisher)
	   AND publisher_db = @publisher_db
	   AND name = @publication
	IF @pubid IS NULL
	BEGIN
		-- The publication '@publication' does not exist.
		RAISERROR (20026, 16, -1, @publication)
		RETURN 1
	END

	IF NOT EXISTS (SELECT *
					 FROM dbo.sysmergesubscriptions
					WHERE UPPER(subscriber_server) = UPPER(@subscriber)
					  AND db_name = @subscriber_db
					  AND pubid = @pubid) -- We allow retrieval of push and (well-known) pull merge agent status
	BEGIN
		-- "The subscription could not be found."
		RAISERROR (20021, 16, -1)
		RETURN 1
	END
				
	EXEC @retcode = sys.sp_helpdistributor
			@rpcsrvname = @distributor_rpc OUTPUT,
			@distribdb = @distribution_db OUTPUT
	IF (@@error != 0) OR (@retcode != 0) OR @distribution_db IS NULL
	BEGIN
		-- "The Distributor has not been installed correctly."
		RAISERROR (20036, 16, -1)
		RETURN 1
	END

	DECLARE @merge_status           int,
			@merge_message          nvarchar(1000),
			@merge_time             datetime,
			@merge_duration         int,
			@merge_percent_complete decimal(5,2)

	SET @procedure = QUOTENAME(RTRIM(@distributor_rpc)) + '.' + QUOTENAME(RTRIM(@distribution_db)) + '.sys.sp_MSrepl_mergeagentstatussummary'
	EXEC @retcode = @procedure
			@publisher = @publisher,
			@publisher_db = @publisher_db,
			@publication = @publication,
			@subscriber = @subscriber,
			@subscriber_db = @subscriber_db,
			@merge_status = @merge_status OUTPUT,
			@merge_message = @merge_message OUTPUT,
			@merge_time = @merge_time OUTPUT,
			@merge_duration = @merge_duration OUTPUT,
			@merge_percent_complete = @merge_percent_complete OUTPUT
	
	IF (@@error != 0) OR (@retcode != 0)
	BEGIN
		RETURN 1
	END
	
	SELECT @merge_status AS merge_status,
		   @merge_message AS merge_message,
		   @merge_time AS merge_time,
		   @merge_duration AS merge_duration,
		   @merge_percent_complete AS merge_percent_complete

	RETURN (@retcode)
END
GO
GRANT EXECUTE ON [sys].[sp_mergesubscriptionsummary] TO [public] AS [dbo]
GO
