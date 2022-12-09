SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSreset_subscription]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSreset_subscription] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSreset_subscription]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname],
	@subscription_type [int]
WITH EXECUTE AS CALLER
AS
begin
	SET NOCOUNT ON

	/*
	** Declarations.
	*/
	DECLARE @retcode            int
	DECLARE @publisher_id       smallint
	DECLARE @subscriber_id      smallint
	DECLARE @virtual            smallint
	DECLARE @virtual_anonymous  smallint
	declare @anonymous_subtype  smallint
	declare @publication_id		int
	declare @immediate_sync		bit

	--
	-- security check
	-- only db_owner can execute this
	--
	if (is_member ('db_owner') != 1) 
	begin
		raiserror(14260, 16, -1)
		return (1)
	end

	/*
	** Initializations
	*/
	select @virtual = -1
	select @virtual_anonymous = -2
	select @anonymous_subtype = 2

    select @publisher_id = srvid from MSreplservers where 
        UPPER(srvname) = UPPER(@publisher)

    select @subscriber_id = srvid from MSreplservers where 
        UPPER(srvname) = UPPER(@subscriber) 

	select @publication_id = publication_id, @immediate_sync = immediate_sync
		from dbo.MSpublications where
		publisher_id = @publisher_id AND
		publisher_db = @publisher_db AND
		publication = @publication

	if @subscriber is NULL
		select @subscriber_id = @virtual

	-- No need to have 2 updates in one transaction.
	if @immediate_sync = 1
	begin
		UPDATE MSdistribution_agents SET subscription_guid = newid()
			WHERE
			publisher_id = @publisher_id AND
			publisher_db = @publisher_db AND
			publication = @publication and
			subscriber_id = @subscriber_id and
			subscriber_db = @subscriber_db and
			subscription_type = @subscription_type

		IF @@ERROR <> 0
			GOTO UNDO

		if @subscriber_id = @virtual
		begin
			-- reset the partial snapshot progress of all anonymous 
			-- agents associated with this virtual subscription

			update dbo.MSdistribution_agents 
			   set reset_partial_snapshot_progress = 1
			 where
			publisher_id = @publisher_id AND
			publisher_db = @publisher_db AND
			publication = @publication and
			subscriber_id <> @virtual and
			subscriber_id <> @virtual_anonymous and
			subscription_type = @anonymous_subtype
		end 
	end

	UPDATE dbo.MSsubscriptions set subscription_time = getdate() 
		WHERE
		publisher_id = @publisher_id AND
		publisher_db = @publisher_db AND
		publication_id = @publication_id and
		subscriber_id = @subscriber_id and
		subscriber_db = @subscriber_db and
		subscription_type = @subscription_type

	IF @@ERROR <> 0
		GOTO UNDO

	RETURN(0)

UNDO:
	return(1)
end
GO
GRANT EXECUTE ON [sys].[sp_MSreset_subscription] TO [public] AS [dbo]
GO
