SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_setsubscriptionxactseqno]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_setsubscriptionxactseqno] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_setsubscriptionxactseqno]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@xact_seqno [varbinary](16)
WITH EXECUTE AS CALLER
AS
BEGIN
    SET NOCOUNT ON
    
	DECLARE @retcode			int,
			@current_xact_seqno varbinary(16),
			@sub_streams_count	int

    -- Security Check
    EXEC @retcode = sys.sp_MSreplcheck_subscribe
    IF @@ERROR <> 0 OR @retcode <> 0
        RETURN 1

	-- Parameter Checks : @publisher
    IF @publisher IS NULL
    BEGIN
		-- The parameter @publisher cannot be NULL.
        RAISERROR (14043, 16, -1, '@publisher', 'sp_setsubscriptionxactseqno')
        RETURN 1
    END
    
    EXEC @retcode = sys.sp_validname @publisher
    IF @@ERROR <> 0 OR @retcode <> 0
       RETURN 1
    
 	-- Parameter Checks : @publisher_db
    IF @publisher_db IS NULL
    BEGIN
		-- The parameter @publisher_db cannot be NULL.
        RAISERROR (14043, 16, -1, '@publisher_db', 'sp_setsubscriptionxactseqno')
        RETURN 1
    END

    EXEC @retcode = sys.sp_validname @publisher_db
    IF @@ERROR <> 0 OR @retcode <> 0
        RETURN 1

    -- Parameter Check: @publication
    IF @publication IS NULL
    BEGIN
		-- The parameter @publisher cannot be NULL.
        RAISERROR (14043, 16, -1, '@publication', 'sp_setsubscriptionxactseqno')
        RETURN 1
    END

    EXEC @retcode = sys.sp_validname @publication
    IF @@ERROR <> 0 OR @retcode <> 0
		RETURN 1

	-- Parameter Check: @xact_seqno
	IF @xact_seqno IS NULL
	BEGIN
		-- The parameter @xact_seqno cannot be NULL.
        RAISERROR (14043, 16, -1, '@xact_seqno', 'sp_setsubscriptionxactseqno')
        RETURN 1
	END

	-- check to make sure we are at a subscription database
	IF OBJECT_ID('MSreplication_subscriptions', 'U') IS NULL
	BEGIN
		-- The subscription on the Subscriber does not exist.
	    RAISERROR (20017, 16, -1)
	    RETURN 1
	END 

	-- check if publication is independent agent if not @publication must be all
	IF UPPER(@publication) != N'ALL'
		AND NOT EXISTS (SELECT *
						FROM MSreplication_subscriptions 
						WHERE UPPER(publisher) = UPPER(@publisher) 
							AND publisher_db = @publisher_db 
							AND publication = @publication)
		AND EXISTS (SELECT *
						FROM MSreplication_subscriptions 
						WHERE UPPER(publisher) = UPPER(@publisher) 
							AND publisher_db = @publisher_db 
							AND publication = N''
							AND independent_agent = 0)
	BEGIN
		-- The subscription to publication '%s' was not found but a shared agent does exist. To specify a subscription to a publication that is replicated via a shared agent specify '%s' for the publication name.
		RAISERROR(22579, 16, -1, @publication, N'ALL')
		RETURN 1
	END
					
    -- Peer-To-Peer subscriptions do not support this feature
    IF OBJECT_ID(N'MSpeer_lsns', 'U') is not NULL
    BEGIN
        IF EXISTS(SELECT * 
                    FROM MSpeer_lsns
                    WHERE originator = UPPER(@publisher)
                        AND originator_db = @publisher_db
                        AND originator_publication = @publication)
        BEGIN
        	-- Peer-To-Peer publications do not support 'sp_setsubscriptionxactseqno'. Please change the '@publication' parameter value.
			RAISERROR(20646, 16, -1, '''sp_setsubscriptionxactseqno''', '@publication')
            RETURN 1
        END        
    END

    -- if there are mstreams ensure that the last commit xact_seqno 
	-- match for all streams before allowing this process to cont...
	IF (SELECT COUNT(*)
			FROM MSreplication_subscriptions msrs1
				JOIN MSreplication_subscriptions msrs2
					ON UPPER(msrs1.publisher) = UPPER(msrs2.publisher) 
						AND msrs1.publisher_db = msrs2.publisher_db 
						AND msrs1.publication = msrs2.publication
						AND CAST(SUBSTRING(msrs1.transaction_timestamp, 1, 15) AS binary(15)) != CAST(SUBSTRING(msrs2.transaction_timestamp, 1, 15) AS binary(15))
			WHERE UPPER(msrs1.publisher) = UPPER(@publisher) 
				AND msrs1.publisher_db = @publisher_db 
				AND (msrs1.publication = @publication
					OR (msrs1.publication = N''
						AND msrs1.independent_agent = 0
						AND UPPER(@publication) = N'ALL'))) > 0
	BEGIN
		-- The distribution agent must be run in single subscription stream mode prior to resetting the subscription xact_seqno.
		RAISERROR (21836, 16, -1)
		RETURN 1
	END

	SELECT @current_xact_seqno = transaction_timestamp
		FROM MSreplication_subscriptions 
		WHERE UPPER(publisher) = UPPER(@publisher) 
			AND publisher_db = @publisher_db 
			AND (publication = @publication
				OR (publication = N''
					AND independent_agent = 0
					AND UPPER(@publication) = N'ALL'))

	SELECT @sub_streams_count = @@ROWCOUNT
	
	IF @current_xact_seqno IS NULL
    BEGIN
		-- There is no subscription on Publisher '@publisher', publisher database '@publisher_db', publication '@publication'.
        RAISERROR(14135, 11, -1,  @publisher, @publisher_db, @publication)
        RETURN 1
    END
    
    UPDATE MSreplication_subscriptions 
		SET transaction_timestamp = CAST(@xact_seqno AS binary(15)) +  CAST(SUBSTRING(transaction_timestamp, 16, 1) AS binary(1))
        WHERE UPPER(publisher) = UPPER(@publisher) 
			AND publisher_db = @publisher_db 
			AND (publication = @publication
				OR (publication = N''
					AND independent_agent = 0
					AND UPPER(@publication) = N'ALL'))
    IF @@ERROR <> 0 
        RETURN 1

	
	SELECT @current_xact_seqno AS "ORIGINAL XACT_SEQNO", 
			@xact_seqno AS "UPDATED XACT_SEQNO",
			@sub_streams_count AS "SUBSCRIPTION STREAM COUNT"

	RETURN 0
END
GO
GRANT EXECUTE ON [sys].[sp_setsubscriptionxactseqno] TO [public] AS [dbo]
GO
