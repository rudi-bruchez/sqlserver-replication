SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSrepl_mergeagentstatussummary]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSrepl_mergeagentstatussummary] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSrepl_mergeagentstatussummary]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname],
	@merge_status [int] OUTPUT,
	@merge_message [nvarchar](1000) OUTPUT,
	@merge_time [datetime] OUTPUT,
	@merge_duration [int] OUTPUT,
	@merge_percent_complete [decimal](5, 2) OUTPUT
WITH EXECUTE AS CALLER
AS
BEGIN
	SET NOCOUNT ON
	DECLARE @retcode        int,
			@merge_agent_id int,
			@publisher_id   int,
			@subscriber_id  int

	--
	-- Making sure that we are at a distribution database
	--
	IF sys.fn_MSrepl_isdistdb(db_name()) <> 1
	BEGIN
		RAISERROR (21482, 16, -1, 'sp_MSrepl_mergeagentstatussummary', 'distribution')
	END

    --
    -- PAL check and validate publication
    --
    EXEC @retcode = sys.sp_MSreplcheck_pull @publication = @publication,
                                            @raise_fatal_error = 0
    IF (@@error != 0) OR (@retcode != 0)
        RETURN 1
    
    SET @publisher_id = NULL
    SELECT @publisher_id = srvid
      FROM MSreplservers
     WHERE UPPER(srvname collate database_default) = UPPER(@publisher) COLLATE database_default
    IF @publisher_id IS NULL
    BEGIN
        RAISERROR (21618, 16, -1, @publisher)
        RETURN 1
    END

	-- Check to make sure the subscription is valid
	IF NOT EXISTS (
		select 1 from MSpublications p join MSmerge_subscriptions s
			on p.publication_id = s.publication_id and
			   p.publisher_id = s.publisher_id and
			   p.publisher_db = s.publisher_db
		 where UPPER(s.subscriber collate database_default) = UPPER(@subscriber collate database_default) and
			   UPPER(s.subscriber_db collate database_default) = UPPER(@subscriber_db collate database_default) and
			   UPPER(p.publisher_db collate database_default) = UPPER(@publisher_db collate database_default) and
			   UPPER(p.publication collate database_default) = UPPER(@publication collate database_default) and
			   p.publisher_id = @publisher_id
	)
	BEGIN
		RAISERROR (14048, 16, -1, @subscriber)
		RETURN 1
	END

	-- Initialize output params
	SELECT @merge_status = 0,
		   @merge_time = NULL,
		   @merge_message = formatmessage(14196),
		   @merge_duration = 0,
		   @merge_percent_complete = 0.0
	
	-- Get merge agent id
	SELECT @merge_agent_id = id
	  FROM dbo.MSmerge_agents
	 WHERE publisher_id = @publisher_id
	   AND publisher_db = @publisher_db
	   AND publication = @publication
	   AND UPPER(subscriber_name collate database_default)= UPPER(@subscriber collate database_default)
	   AND subscriber_db = @subscriber_db

	-- Get merge agent summary
	IF EXISTS
	(
		SELECT *
		  FROM dbo.MSmerge_history WITH (READPAST)
		 WHERE agent_id = @merge_agent_id
	)
	BEGIN
		SELECT TOP (1)
				@merge_status           = msms.runstatus,
				@merge_time             = sys.fn_replformatdatetime(msms.start_time),
				@merge_message          = msmh.comments,
				@merge_duration         = msms.duration,
				@merge_percent_complete = msms.percent_complete
		  FROM dbo.MSmerge_history msmh WITH (READPAST)
	 LEFT JOIN dbo.MSmerge_sessions msms WITH (READPAST)
			ON msmh.session_id = msms.session_id
		 WHERE msmh.agent_id = @merge_agent_id
	   ORDER BY msmh.time DESC, msmh.timestamp DESC
	END

	RETURN 0
END
GO
GRANT EXECUTE ON [sys].[sp_MSrepl_mergeagentstatussummary] TO [public] AS [dbo]
GO
