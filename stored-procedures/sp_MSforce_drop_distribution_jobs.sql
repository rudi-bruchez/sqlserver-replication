SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSforce_drop_distribution_jobs]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSforce_drop_distribution_jobs] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSforce_drop_distribution_jobs]
	@publisher [sysname],
	@publisher_db [sysname],
	@type [nvarchar](5)
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @retcode			int,
			@agent_id			int,
			@publisher_id		smallint,
			@publication		sysname,
			@subscriber			sysname,
			@subscriber_id		smallint,
			@subscriber_db		sysname,
			@subscription_type	int
			,@drop_tran_jobs bit
			,@drop_merge_jobs bit
	
	-- Security Check
	IF ISNULL(IS_SRVROLEMEMBER('sysadmin'),0) = 0 
	BEGIN
		RAISERROR(21089, 16, -1)
		RETURN 1
	END
	
	IF LOWER(@type collate SQL_Latin1_General_CP1_CS_AS) IN (N'tran', N'both')
		AND DatabasePropertyEx(@publisher_db, 'IsPublished') = 1
	BEGIN
		set @drop_tran_jobs = 1
	END
	else
	begin
		set @drop_tran_jobs = 0
	end

	IF LOWER(@type collate SQL_Latin1_General_CP1_CS_AS) IN (N'merge', N'both')
		AND DatabasePropertyEx(@publisher_db, 'IsMergePublished') = 1
	BEGIN
		set @drop_merge_jobs = 1
	END
	else
	BEGIN
		set @drop_merge_jobs = 0
	END

	-- retrieve the publisher_id and if we do not 
	-- find one then we can just exit silently...
	SELECT @publisher_id = srvid
		FROM MSreplservers
		WHERE UPPER(srvname) = UPPER(@publisher)
	IF @publisher_id IS NULL
	BEGIN
		RETURN 0
	END
	
	BEGIN TRANSACTION tr_drop_distribution_jobs
	SAVE TRANSACTION tr_drop_distribution_jobs

	-------------------------
	-- DROP QREADER AGENTS
	-------------------------

	-- NOTE:
	--		We do not drop qreader agents in the force
	--		drop case since we have no way of knowing 
	--		when we can drop the qreader agent (i.e. 
	--		when the publisher is using it still...)


	-------------------------
	-- DROP SNAPSHOT AGENTS
	-------------------------
	DECLARE #cursorSnapshot CURSOR LOCAL FAST_FORWARD FOR
		SELECT publication
			FROM MSsnapshot_agents
			WHERE publisher_id = @publisher_id
				AND publisher_db = @publisher_db
				AND ((@drop_tran_jobs = 1 and publication_type = 1)
					or (@drop_merge_jobs = 1 and publication_type = 2)
				)
	FOR READ ONLY
	
	OPEN #cursorSnapshot

	FETCH #cursorSnapshot INTO @publication
	WHILE @@FETCH_STATUS != -1
	BEGIN
		EXEC @retcode = sys.sp_MSdrop_snapshot_agent @publisher = @publisher,
														@publisher_db = @publisher_db,
														@publication = @publication
		IF @@ERROR != 0 OR @retcode != 0
			GOTO UNDO

		FETCH #cursorSnapshot INTO @publication
	END

	CLOSE #cursorSnapshot
	DEALLOCATE #cursorSnapshot

	if (@drop_tran_jobs = 1)
	begin
		-------------------------
		-- DROP LOGREADER AGENTS
		-------------------------
		DECLARE #cursorLogreader CURSOR LOCAL FAST_FORWARD FOR
			SELECT publication
				FROM MSlogreader_agents
				WHERE publisher_id = @publisher_id
					AND publisher_db = @publisher_db
		FOR READ ONLY
		
		OPEN #cursorLogreader

		FETCH #cursorLogreader INTO @publication
		WHILE @@FETCH_STATUS != -1
		BEGIN
			EXEC @retcode = sys.sp_MSdrop_logreader_agent @publisher = @publisher,
															@publisher_db = @publisher_db,
															@publication = @publication
			IF @@ERROR != 0 OR @retcode != 0
				GOTO UNDO

			FETCH #cursorLogreader INTO @publication
		END

		CLOSE #cursorLogreader
		DEALLOCATE #cursorLogreader

		-----------------------------
		-- DROP DISTRIBUTION AGENTS
		-----------------------------
		DECLARE #cursorDistrib CURSOR LOCAL FAST_FORWARD FOR
			SELECT publication,
					subscriber_id,
					subscriber_db,
					subscription_type
				FROM MSdistribution_agents
				WHERE publisher_id = @publisher_id
					AND publisher_db = @publisher_db
		FOR READ ONLY
		
		OPEN #cursorDistrib

		FETCH #cursorDistrib INTO @publication, @subscriber_id, @subscriber_db, @subscription_type
		WHILE @@FETCH_STATUS != -1
		BEGIN
			EXEC @retcode = sys.sp_MSdrop_distribution_agent @publisher_id = @publisher_id,
																@publisher_db = @publisher_db,
																@publication = @publication,
																@subscriber_id = @subscriber_id, 
																@subscriber_db = @subscriber_db, 
																@subscription_type = @subscription_type
			IF @@ERROR != 0 OR @retcode != 0
				GOTO UNDO

			FETCH #cursorDistrib INTO @publication, @subscriber_id, @subscriber_db, @subscription_type
		END

		CLOSE #cursorDistrib
		DEALLOCATE #cursorDistrib
	end
	-----------------------------
	-- DROP MERGE AGENTS
	-----------------------------
	DECLARE #cursorReplmerg CURSOR LOCAL FAST_FORWARD FOR
		SELECT msma.publication,
				msma.subscriber_name,
				msma.subscriber_db
			FROM MSmerge_agents msma
			WHERE publisher_id = @publisher_id
				AND publisher_db = @publisher_db
				AND @drop_merge_jobs = 1
	FOR READ ONLY
	
	OPEN #cursorReplmerg

	FETCH #cursorReplmerg INTO @publication, @subscriber, @subscriber_db
	WHILE @@FETCH_STATUS != -1
	BEGIN
		EXEC @retcode = sys.sp_MSdrop_merge_agent @publisher = @publisher,
													@publisher_db = @publisher_db,
													@publication = @publication,
													@subscriber = @subscriber, 
													@subscriber_db = @subscriber_db
		IF @@ERROR != 0 OR @retcode != 0
			GOTO UNDO

		FETCH #cursorReplmerg INTO @publication, @subscriber, @subscriber_db
	END

	CLOSE #cursorReplmerg
	DEALLOCATE #cursorReplmerg

	COMMIT TRANSACTION tr_drop_distribution_jobs
	
	RETURN 0
UNDO:
	ROLLBACK TRANSACTION tr_drop_distribution_jobs
	COMMIT TRANSACTION
	
	RETURN 1
END
GO
GRANT EXECUTE ON [sys].[sp_MSforce_drop_distribution_jobs] TO [public] AS [dbo]
GO
