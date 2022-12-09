SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_removedistpublisherdbreplication]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_removedistpublisherdbreplication] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_removedistpublisherdbreplication]
	@publisher [sysname],
	@publisher_db [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @retcode		int,
			@publisher_id	int,
			@publication_id	int,
			@publication	sysname,
			@subscriber		sysname,
			@subscriber_id	int,
			@subscriber_db	sysname,
			@article_id		int,
			@article		sysname

	-- Security Check: require sysadmin/dbo of dist 
	IF IS_MEMBER('db_owner') != 1
	BEGIN
		RAISERROR(21089,16,-1) 
		RETURN 1
	END

	-- database must be distribution db
	IF sys.fn_MSrepl_isdistdb(DB_NAME()) <> 1
	BEGIN
		RAISERROR (21482, 16, -1, 'sp_removedistpublisherdbreplication', 'distribution')
		RETURN 1
	END

	-- retrieve the publisher_id
	SELECT @publisher_id = srvid 
		FROM MSreplservers
		WHERE UPPER(srvname) = UPPER(@publisher)
	
	BEGIN TRANSACTION
	SAVE TRANSACTION drop_publisherdb_metadata

	-- drop all subscriptions associated with the pub/pubdb
	DECLARE #cursorSubscriptions CURSOR LOCAL FAST_FORWARD FOR
		SELECT DISTINCT msp.publication,
				mss.article_id,
				msa.article,
				msyss.srvname,
				mss.subscriber_db
			FROM MSsubscriptions mss
				JOIN MSpublications msp
					ON mss.publisher_id = msp.publisher_id
						AND mss.publisher_db = msp.publisher_db
						AND mss.publication_id = msp.publication_id
				JOIN MSreplservers msyss
					ON msyss.srvid = mss.subscriber_id
				JOIN MSarticles msa
					ON mss.publisher_id = msa.publisher_id
						AND mss.publisher_db = msa.publisher_db
						AND mss.publication_id = msa.publication_id
						AND mss.article_id = msa.article_id
			WHERE mss.publisher_id = @publisher_id
				AND mss.publisher_db = @publisher_db
	FOR READ ONLY
	
	OPEN #cursorSubscriptions

	FETCH #cursorSubscriptions INTO @publication, @article_id, @article, @subscriber, @subscriber_db
	WHILE @@FETCH_STATUS != -1
	BEGIN
		EXEC @retcode = sys.sp_MSdrop_subscription @publisher = @publisher,
													@publisher_db = @publisher_db,
													@subscriber = @subscriber,
													@article_id = @article_id,
													@subscriber_db = @subscriber_db,
													@publication = @publication,
													@article = @article
		IF @@ERROR != 0 OR @retcode != 0
			GOTO UNDO

		FETCH #cursorSubscriptions INTO @publication, @article_id, @article, @subscriber, @subscriber_db
	END

	CLOSE #cursorSubscriptions
	DEALLOCATE #cursorSubscriptions

	-- drop all articles associated with the pub/pubdb
	DECLARE #cursorArticles CURSOR LOCAL FAST_FORWARD FOR
		SELECT DISTINCT msp.publication,
				msa.article
			FROM MSpublications msp
				JOIN MSarticles msa
				ON msp.publisher_id = msa.publisher_id
					AND msp.publisher_db = msa.publisher_db
					AND msp.publication_id = msa.publication_id
			WHERE msp.publisher_id = @publisher_id
				AND msp.publisher_db = @publisher_db
	FOR READ ONLY
	
	OPEN #cursorArticles

	FETCH #cursorArticles INTO @publication, @article
	WHILE @@FETCH_STATUS != -1
	BEGIN
		EXEC @retcode = sys.sp_MSdrop_article @publisher = @publisher, 
												@publisher_db = @publisher_db, 
												@publication = @publication, 
												@article = @article
		IF @@ERROR != 0 OR @retcode != 0
			GOTO UNDO

		FETCH #cursorArticles INTO @publication, @article
	END

	CLOSE #cursorArticles
	DEALLOCATE #cursorArticles
	
	-- drop all publications associated with the pub/pubdb
	DECLARE #cursorPublications CURSOR LOCAL FAST_FORWARD FOR
		SELECT DISTINCT msp.publication
			FROM MSpublications msp
			WHERE msp.publisher_id = @publisher_id
				AND msp.publisher_db = @publisher_db
	FOR READ ONLY
	
	OPEN #cursorPublications

	FETCH #cursorPublications INTO @publication
	WHILE @@FETCH_STATUS != -1
	BEGIN
		EXEC @retcode = sys.sp_MSdrop_publication @publisher = @publisher,
													@publisher_db = @publisher_db,
													@publication = @publication
		IF @@ERROR != 0 OR @retcode != 0
			GOTO UNDO

		FETCH #cursorPublications INTO @publication
	END

	CLOSE #cursorPublications
	DEALLOCATE #cursorPublications
	
	-- drop all jobs associated with the pub/pubdb that remain
	EXEC @retcode = sys.sp_MSforce_drop_distribution_jobs @publisher = @publisher,
															@publisher_db = @publisher_db
															,@type = N'tran'
	IF @@ERROR <> 0 OR @retcode <> 0
	BEGIN
		GOTO UNDO
	END
	
	COMMIT TRANSACTION drop_publisherdb_metadata

	RETURN 0
UNDO:
	ROLLBACK TRANSACTION drop_publisherdb_metadata
	COMMIT TRANSACTION 
	
	RETURN 1
END
GO
GRANT EXECUTE ON [sys].[sp_removedistpublisherdbreplication] TO [public] AS [dbo]
GO
