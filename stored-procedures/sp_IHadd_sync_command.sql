SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_IHadd_sync_command]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_IHadd_sync_command] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_IHadd_sync_command]
	@publisher_id [smallint],
	@publisher_db [sysname],
	@xact_id [varbinary](16),
	@xact_seqno [varbinary](16),
	@originator [sysname],
	@originator_db [sysname],
	@article_id [int],
	@command_id [int],
	@type [int],
	@partial_command [bit],
	@command [varbinary](1024),
	@publisher [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
	SET NOCOUNT ON

	declare @retcode int
	DECLARE @date datetime
	DECLARE @publisher_database_id int
	declare @originator_id int
	DECLARE @syncmask int
	DECLARE @snapshot_bit int

	select @snapshot_bit = 0x80000000

	SELECT @date = GETDATE()

	-------- security check, db_owner
	exec @retcode = sys.sp_MSreplcheck_publish
	if @@ERROR <> 0 or @retcode <> 0
		return(1)

	if @publisher_id is NULL
		select @publisher_id = srvid from MSreplservers where
			UPPER(srvname collate database_default) = UPPER(@publisher)

	-- Get publisher database id.
	SELECT @publisher_database_id = id from MSpublisher_databases where publisher_id = @publisher_id and 
		publisher_db = @publisher_db

	IF @command_id = 1
	BEGIN
		INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
			@xact_id,  @xact_seqno, @date)
		IF @@ERROR <> 0
			RETURN 1
	END

	IF @command IS NOT NULL
	begin
		if @originator <> N'' and @originator_db <> N'' and @originator is not null and @originator_db is not null 
		begin
		set @originator_id = null select @originator_id = id from MSrepl_originators where
			publisher_database_id = @publisher_database_id and UPPER(srvname) = UPPER(@originator) and
			dbname = @originator_db
		if @originator_id is null
		begin
			insert into MSrepl_originators (publisher_database_id, srvname, dbname) values
				(@publisher_database_id, UPPER(@originator), @originator_db)
			select @originator_id = @@identity
		end
		end
		else
		select @originator_id = 0
	    

		if( @type in( 37,38 ) )
		begin
	  		declare @syncstat int
			select @syncstat = 38 - @type
			exec sp_MSset_syncstate @publisher_id, @publisher_db, @article_id, @syncstat, @xact_seqno 
		end

		INSERT INTO MSrepl_commands (publisher_database_id, xact_seqno, type, article_id, originator_id, command_id, partial_command, command)
		VALUES (@publisher_database_id, @xact_seqno,
			@type | @snapshot_bit, @article_id, @originator_id, @command_id, @partial_command, @command)
	end

	IF @@ERROR <> 0
		RETURN (1)
END
GO
GRANT EXECUTE ON [sys].[sp_IHadd_sync_command] TO [public] AS [dbo]
GO
