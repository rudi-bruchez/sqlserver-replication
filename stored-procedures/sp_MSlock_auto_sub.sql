SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSlock_auto_sub]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSlock_auto_sub] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSlock_auto_sub]
	@publisher_id [int],
	@publisher_db [sysname],
	@publication [sysname],
	@reset [bit]
WITH EXECUTE AS CALLER
AS
begin
	--
	-- security check
	-- only db_owner can execute this
	--
	if (is_member ('db_owner') != 1) 
	begin
		raiserror(14260, 16, -1)
		return (1)
	end

  /* This sp only work for 7.0 publisher since it use the publication name */  
   set nocount on

	DECLARE @virtual smallint     /* const: virtual subscriber id */
	DECLARE @virtual_anonymous smallint /* const: virtual anonymous subscriber id */
	DECLARE @subscribed tinyint
	DECLARE @automatic tinyint
	DECLARE @publication_id int
	DECLARE @counter int
	DECLARE @independent_agent bit
	DECLARE @active tinyint

	SELECT @virtual = -1
	SELECT @virtual_anonymous = -2
	SELECT @subscribed = 1
	SELECT @active = 2
	SELECT @automatic = 1

	select @publication_id = publication_id , @independent_agent = independent_agent
		from dbo.MSpublications 
		where 
		publisher_id = @publisher_id and
		publisher_db = @publisher_db and
		publication = @publication 


	/* 
	** Set exclusive lock on the rows that will be updated to prevent deadlock 
	**      in snapshot agent.
	** Note: using UPDATE lock may cause deadlock with sp_MSget_repl_commands as following
	** 1. The distribution agent gets shared lock on dbo.MSsubscriptions.
	** 2. The snapshot agent gets update lock on dbo.MSsubscriptions.
	** 3. The snapshot agent gets exclusive lock on MSrepl_commands (inserting into the table)
	** 4. The distribution agent waits to get shared lock on MSrepl_commands
	** 5. The snapshot agent waits to convert update lock to exclusive lock on MSrepl_subscriptions (updating the table).
	*/
	--SELECT @counter = COUNT(*) FROM dbo.MSsubscriptions with (ROWLOCK UPDLOCK)
	-- 1. Avoid defered updates: Don't update fields in the clusted index
	-- 2. Avoid updating fields in the where clause 
	UPDATE dbo.MSsubscriptions SET update_mode = update_mode 
	  WHERE 
		 publisher_id = @publisher_id and
		 publisher_db = @publisher_db and
		 publication_id = @publication_id and 
		 /* virtual subscriptions are automatic sync type */
		 sync_type = @automatic and 
		 (status = @subscribed or 
		 subscriber_id = @virtual or
		 subscriber_id = @virtual_anonymous or
		 @reset = 1) 
end
GO
GRANT EXECUTE ON [sys].[sp_MSlock_auto_sub] TO [public] AS [dbo]
GO
