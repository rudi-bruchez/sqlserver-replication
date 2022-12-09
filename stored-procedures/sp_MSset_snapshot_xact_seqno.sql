SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSset_snapshot_xact_seqno]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSset_snapshot_xact_seqno] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSset_snapshot_xact_seqno]
	@publisher_id [int],
	@publisher_db [sysname],
	@article_id [int],
	@xact_seqno [varbinary](16),
	@reset [bit],
	@publication [sysname],
	@publisher_seqno [varbinary](16),
	@ss_cplt_seqno [varbinary](16)
WITH EXECUTE AS CALLER
AS
begin
	DECLARE @virtual smallint     /* const: virtual subscriber id */
	DECLARE @virtual_anonymous smallint /* const: virtual anonymous subscriber id */
	DECLARE @old_xact_seqno varbinary(16)
	DECLARE @old_publisher_seqno varbinary(16)
	DECLARE @subscribed tinyint
	DECLARE @automatic tinyint
	DECLARE @old_snapshot_seqno_flag bit
	DECLARE @publication_id int
	DECLARE @initiated tinyint
	DECLARE @publisher_database_id int

	--
	-- security check
	-- only db_owner can execute this
	--
	if (is_member ('db_owner') != 1) 
	begin
		raiserror(14260, 16, -1)
		return (1)
	end

	SELECT @publisher_database_id = id
	  FROM dbo.MSpublisher_databases
	 WHERE publisher_db = @publisher_db
	   AND publisher_id = @publisher_id

	SELECT @virtual = -1
	SELECT @virtual_anonymous = -2
	SELECT @subscribed = 1
	SELECT @automatic = 1
	SELECT @initiated = 3
	
	if @ss_cplt_seqno is null 
	begin
		select @ss_cplt_seqno = @xact_seqno;
	end

	-- 6.5 only!!! @publication is not null only if the publisher is 6.5 sever!
	-- Set the publication_id and sync_type in dbo.MSsubscriptions.
	-- It will be used in sp_MSupdate_subscriptions 
	IF @publication IS NOT NULL
	BEGIN
		-- Get the publication id
		SELECT @publication_id = publication_id FROM dbo.MSpublications
			WHERE   publisher_id = @publisher_id AND
					publisher_db = @publisher_db AND    
					publication  = @publication

		-- Set the pubid and the sync_type
		-- Avoid update rows with no change to reduce update locks.
		
		UPDATE dbo.MSsubscriptions SET publication_id = @publication_id
		  FROM dbo.MSsubscriptions with (index(iMSsubscriptions))
			WHERE   publisher_id = @publisher_id AND
					publisher_database_id = @publisher_database_id AND    
					article_id  = @article_id and
					status = @subscribed and
					publication_id <> @publication_id
		
		-- Have to do this to avoid no sync subs from 6.5 publisher being
		-- updated.
		UPDATE dbo.MSsubscriptions SET sync_type = @automatic
		  FROM dbo.MSsubscriptions with (index(iMSsubscriptions)) 
			WHERE   publisher_id = @publisher_id AND
					publisher_database_id = @publisher_database_id AND    
					article_id  = @article_id and
					status = @subscribed and
					sync_type <> @automatic
	END

	begin tran
	save TRANSACTION MSset_snapshot_xact_seqno

	/* 
	** Set snapshot_xact_seqno for all new subscriptions,
	** plus the virtual subscription or all subscriptions if @reset = 1
	** Note virtual anonymous subscription will not be set
	** (2 virtual subscriptions of anonymous publication will be activated
	** immediately without snapshot
	** 
	** @reset = 1 is used for Scheduled Snapshot publications by snapshot
	*/
	UPDATE dbo.MSsubscriptions SET subscription_seqno = @xact_seqno,
		publisher_seqno = @publisher_seqno,
		snapshot_seqno_flag = 1,
		subscription_time = getdate(),
		ss_cplt_seqno = @ss_cplt_seqno
	  FROM dbo.MSsubscriptions with (index(iMSsubscriptions))
	  WHERE 
		 dbo.MSsubscriptions.publisher_id = @publisher_id and
		 dbo.MSsubscriptions.publisher_database_id = @publisher_database_id and
		 dbo.MSsubscriptions.article_id = @article_id and 
		 /* virtual subscriptions are automatic sync type */
		 dbo.MSsubscriptions.sync_type = @automatic and 
		 (MSsubscriptions.status in(@subscribed,@initiated) or 
		 dbo.MSsubscriptions.subscriber_id = @virtual or
		 -- Set for virtual anonymous account if snapshot_seqno_flag
		 -- is 0.
		 -- The virtual anonymous account is activated immediately at subscription
		 -- time for no init option for anonymous agent.
		 (MSsubscriptions.subscriber_id = @virtual_anonymous and 
		 (MSsubscriptions.snapshot_seqno_flag = 0 or 
		 dbo.MSsubscriptions.status in(@subscribed,@initiated))) or
		 @reset = 1) 

	IF @@ERROR <> 0
	BEGIN
		if @@trancount > 0
		begin
			ROLLBACK TRANSACTION MSset_snapshot_xact_seqno
			commit tran
		end
		RETURN (1)
	END

	COMMIT TRANSACTION
end
GO
GRANT EXECUTE ON [sys].[sp_MSset_snapshot_xact_seqno] TO [public] AS [dbo]
GO
