SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSrepl_agentstatussummary]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSrepl_agentstatussummary] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSrepl_agentstatussummary]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@snap_status [int] OUTPUT,
	@snap_time [datetime] OUTPUT,
	@snap_comments [nvarchar](255) OUTPUT,
	@snap_duration [int] OUTPUT,
	@log_status [int] OUTPUT,
	@log_time [datetime] OUTPUT,
	@log_comments [nvarchar](255) OUTPUT,
	@log_duration [int] OUTPUT
WITH EXECUTE AS CALLER
AS
BEGIN
	SET NOCOUNT ON
	DECLARE    @snap_agent_id int,
			@log_agent_id  int,
			@retcode       int

	--
	-- PAL check and validate publication
	--
	exec @retcode = sp_MSreplcheck_pull    @publication = @publication,
										@raise_fatal_error = 0
	IF (@@error != 0) or (@retcode != 0)
		RETURN 1

	-- Initialize output params
	SELECT @snap_status   = 0,
			@snap_time     = NULL,
			@snap_comments = formatmessage(14196),
			@snap_duration = 0,
			@log_status    = 0,
			@log_time      = NULL,
			@log_comments  = formatmessage(14196),
			@log_duration = 0

    -- Get snapshot agent id (skip dynamic snapshot agents)
    SELECT    @snap_agent_id = SA.id
    FROM    dbo.MSsnapshot_agents AS SA, 
            MSreplservers AS SS
    WHERE    SA.publisher_id = SS.srvid
        AND    SA.publisher_db = @publisher_db
        AND    SA.publication  = @publication
        AND    UPPER(SS.srvname COLLATE DATABASE_DEFAULT) = UPPER(@publisher) COLLATE DATABASE_DEFAULT
        AND    SA.dynamic_filter_login is NULL
        AND    SA.dynamic_filter_hostname is NULL

    -- Get logreader agent id
    SELECT    @log_agent_id = LA.id  
    FROM    dbo.MSlogreader_agents AS LA, 
            MSreplservers SS
    WHERE    LA.publisher_id = SS.srvid
      AND    LA.publisher_db = @publisher_db
      AND    UPPER(SS.srvname COLLATE DATABASE_DEFAULT) = UPPER(@publisher) COLLATE DATABASE_DEFAULT

	-- Get snapshot agent summary
	IF EXISTS
	(
		SELECT    *
		FROM    dbo.MSsnapshot_history with (READPAST) 
		WHERE    agent_id = @snap_agent_id
	)
	BEGIN
		SELECT TOP(1)
				 @snap_status   = runstatus,
				 @snap_time     = sys.fn_replformatdatetime(start_time),
				 @snap_comments = comments,
				 @snap_duration = duration
		FROM     dbo.MSsnapshot_history with (READPAST) 
		WHERE     agent_id = @snap_agent_id
		ORDER BY time DESC, timestamp DESC
	END

	-- Get logreader agent summary
	IF EXISTS
	(
		SELECT    *  
		FROM    dbo.MSlogreader_history with (READPAST) 
		WHERE    agent_id = @log_agent_id
	)
	BEGIN
		SELECT     TOP(1)
				 @log_status    = runstatus,
				 @log_time      = sys.fn_replformatdatetime(start_time),
				 @log_comments  = comments,
				 @log_duration = duration
		FROM     dbo.MSlogreader_history with (READPAST) 
		WHERE     agent_id = @log_agent_id
				and comments not like N'<stats state%'
		ORDER BY time DESC, timestamp DESC
	END

	RETURN (0)
END
GO
GRANT EXECUTE ON [sys].[sp_MSrepl_agentstatussummary] TO [public] AS [dbo]
GO
