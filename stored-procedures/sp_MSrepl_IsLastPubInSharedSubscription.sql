SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSrepl_IsLastPubInSharedSubscription]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSrepl_IsLastPubInSharedSubscription] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSrepl_IsLastPubInSharedSubscription]
	@subscriber [sysname],
	@subscriber_db [sysname],
	@publication [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
	SET NOCOUNT ON
	
	DECLARE @fLastPub int,
			@retcode int
	
	-- Security check
	exec @retcode = sys.sp_MSreplcheck_publish
	IF @@error <> 0 or @retcode <> 0
		RETURN 1

	-- Check to see if database is activated for publication
	IF sys.fn_MSrepl_ispublished(db_name()) <> 1
	BEGIN
		-- "This database is not enabled for publication."
		RAISERROR (14013, 16, -1)
		RETURN 1
	END

	IF @subscriber IS NULL
	BEGIN
		-- The parameter @subscriber cannot be NULL.
		RAISERROR (14043, 16, -1, '@subscriber', 'fn_MSrepl_IsLastPubInSharedSubscription')
		RETURN 1
	END

	EXEC @retcode = sys.sp_validname @subscriber
	IF @@ERROR <> 0 OR @retcode <> 0
		RETURN 1
		
	IF @subscriber_db IS NULL
	BEGIN
		-- The parameter @subscriber_db cannot be NULL.
		RAISERROR (14043, 16, -1, '@subscriber_db', 'fn_MSrepl_IsLastPubInSharedSubscription')
		RETURN 1
	END

	EXEC @retcode = sys.sp_validname @subscriber_db
	IF @@ERROR <> 0 OR @retcode <> 0
		RETURN 1
		
	IF @publication IS NULL
	BEGIN
		-- The parameter @publication cannot be NULL.
		RAISERROR (14043, 16, -1, '@publication', 'fn_MSrepl_IsLastPubInSharedSubscription')
		RETURN 1
	END

	EXEC @retcode = sys.sp_validname @publication
	IF @@ERROR <> 0 OR @retcode <> 0
		RETURN 1
	
	SET @fLastPub = 0
	
	-- Verify that the passed publication is a publication for this publishing database
	-- that uses an independent agent and has a subscription at the specified
	-- subscriber / subscriber database pair.
	IF NOT EXISTS
	(
		SELECT	*
		FROM	syspublications p, sysarticles a, syssubscriptions s
		WHERE	p.pubid = a.pubid
		  AND	a.artid = s.artid
		  AND	p.independent_agent = 0
		  AND	s.dest_db = @subscriber_db
		  AND	s.srvname = UPPER(@subscriber) 
		  AND	p.name = @publication
	)	  
	BEGIN
		-- No shared agent subscription exists for publication '%s' and the subscriber/subscriber database pair '%s'/'%s'.
		RAISERROR (21426, 16, -1, '@publication', '@subscriber', 'subscriber_db')
		RETURN 1
	END
	
	IF NOT EXISTS
	(
		SELECT	*
		FROM	syspublications p, sysarticles a, syssubscriptions s
		WHERE	p.pubid = a.pubid
		  AND	a.artid = s.artid
		  AND	p.independent_agent = 0
		  AND	s.dest_db = @subscriber_db
		  AND	s.srvname = UPPER(@subscriber) 
		  AND	p.name <> @publication
	)	  
	BEGIN
		-- The passed publication is the only publication for this publishing database
		-- that uses an independent agent and has a subscription at the specified
		-- subscriber / subscriber database pair.
		SET @fLastPub = 1
	END

	SELECT @fLastPub
	RETURN 0
END
GO
GRANT EXECUTE ON [sys].[sp_MSrepl_IsLastPubInSharedSubscription] TO [public] AS [dbo]
GO
