SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_helpsubscriptionerrors]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_helpsubscriptionerrors] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_helpsubscriptionerrors]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @retcode		int,
			@publisher_id	int,
			@subscriber_id	int,
			@agent_id		int

	-- database must be distribution db
	IF sys.fn_MSrepl_isdistdb(DB_NAME()) <> 1
	BEGIN
		RAISERROR (21482, 16, -1, 'sp_helpsubscriptionerrors', 'distribution')
		RETURN 1
	END
	
	-- retrieve pub/sub/agent id
	SELECT @publisher_id = srvid
		FROM MSreplservers
		WHERE UPPER(srvname) = UPPER(@publisher)

	SELECT @subscriber_id = srvid
		FROM MSreplservers
		WHERE UPPER(srvname) = UPPER(@subscriber)

	SELECT @agent_id = id
		FROM MSdistribution_agents
		WHERE publisher_id = @publisher_id
			AND publisher_db = @publisher_db
			AND (publication = @publication
				OR lower(publication) = N'all')
			AND subscriber_id = @subscriber_id
			AND subscriber_db = @subscriber_db	

	-- PAL Security Check
	EXEC @retcode = sys.sp_MScheck_pull_access @agent_id = @agent_id,
												@agent_type = 0 -- distribution agent
	IF @@ERROR <> 0 OR @retcode <> 0
		RETURN 1

	-- return the resultset
	SELECT msre.* 
		FROM MSrepl_errors msre
		WHERE msre.id IN (SELECT error_id
							FROM MSdistribution_history
							WHERE agent_id = @agent_id)
		ORDER by msre.time desc

	RETURN 0
END
GO
GRANT EXECUTE ON [sys].[sp_helpsubscriptionerrors] TO [public] AS [dbo]
GO
