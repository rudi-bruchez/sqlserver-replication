SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSrepl_distributionagentstatussummary]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSrepl_distributionagentstatussummary] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSrepl_distributionagentstatussummary]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname],
	@distribution_status [int] OUTPUT,
	@distribution_message [nvarchar](255) OUTPUT,
	@distribution_time [datetime] OUTPUT,
	@distribution_duration [int] OUTPUT
WITH EXECUTE AS CALLER
AS
BEGIN
	SET NOCOUNT ON
	DECLARE @retcode                int,
			@distribution_agent_id  int,
			@publisher_id           int,
			@subscriber_id          int

	SET @retcode = 0

	--
	-- Making sure that we are at a distribution database
	--
	IF sys.fn_MSrepl_isdistdb(db_name()) <> 1
	BEGIN
		RAISERROR (21482, 16, -1, 'sp_MSrepl_distributionagentstatussummary', 'distribution')
		RETURN 1
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

    SET @subscriber_id = null
    SELECT @subscriber_id = srvid
      FROM MSreplservers
     WHERE UPPER(srvname collate database_default) = UPPER(@subscriber) COLLATE database_default
    IF @subscriber_id IS NULL
    BEGIN
        RAISERROR (14048, 16, -1, @subscriber)
        RETURN 1
    END    

	-- Initialize output params
	SELECT @distribution_status = 0,
		   @distribution_time = NULL,
		   @distribution_message = formatmessage(14196),
		   @distribution_duration = 0            

	-- Get distribution agent id
	SELECT @distribution_agent_id = id
	  FROM dbo.MSdistribution_agents
	 WHERE publisher_id = @publisher_id
	   AND publisher_db = @publisher_db
	   AND publication = @publication
	   AND subscriber_id = @subscriber_id
	   AND subscriber_db = @subscriber_db
 
	-- Get distribution agent summary
	IF EXISTS
	(
		SELECT *
		  FROM dbo.MSdistribution_history WITH (READPAST)
		 WHERE agent_id = @distribution_agent_id
	)
	BEGIN
		SELECT TOP (1)
				@distribution_status    = runstatus,
				@distribution_time      = sys.fn_replformatdatetime(start_time),
				@distribution_message   = comments,
				@distribution_duration  = duration
		  FROM dbo.MSdistribution_history WITH (READPAST)
		 WHERE agent_id = @distribution_agent_id
				and comments not like N'<stats state%'
		ORDER BY time DESC, timestamp DESC 
	END            
	
	RETURN 0
END
GO
GRANT EXECUTE ON [sys].[sp_MSrepl_distributionagentstatussummary] TO [public] AS [dbo]
GO
