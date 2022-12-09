SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSbrowsesnapshotfolder]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSbrowsesnapshotfolder] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSbrowsesnapshotfolder]
	@publisher [sysname],
	@publisher_db [sysname],
	@article_id [int],
	@subscriber [sysname],
	@subscriber_db [sysname]
WITH EXECUTE AS CALLER
AS
begin
	SET NOCOUNT ON

	DECLARE @alt_directory_type     INT
	DECLARE @directory_type         INT
	DECLARE @publisher_id           INT
	DECLARE @publisher_database_id  INT
	DECLARE @subscriber_id          INT
	DECLARE @snapshot_bit           INT
	DECLARE @snapshot_mask          INT
	DECLARE @xact_seqno             VARBINARY(16)
	DECLARE @sync_init              INT
	DECLARE @sync_done              INT

	--
	-- security check
	-- only db_owner can execute this
	--
	if (is_member ('db_owner') != 1) 
	begin
		raiserror(14260, 16, -1)
		return (1)
	end

	SELECT @alt_directory_type = 25
	SELECT @directory_type = 7
	SELECT @subscriber_id = NULL
	SELECT @snapshot_bit = 0x80000000
	SELECT @snapshot_mask = ~@snapshot_bit
	SELECT @xact_seqno = NULL
	SELECT @sync_init = 37
	SELECT @sync_done = 38

    SELECT @publisher_id = srvid 
      FROM MSreplservers
     WHERE UPPER(@publisher) = UPPER(srvname)

	SELECT @publisher_database_id = publisher_database_id 
	  FROM dbo.MSsubscriptions
	 WHERE publisher_id = @publisher_id
	   AND publisher_db = @publisher_db
	   AND article_id = @article_id  

    -- @subscriber is null implies @subscriber_db is null also because 
    -- this sp can only be called by sp_browsesnapshotfolder
    IF @subscriber IS NULL
    BEGIN
        SELECT @xact_seqno = MAX(xact_seqno) 
          FROM MSrepl_commands
         WHERE publisher_database_id = @publisher_database_id
           AND article_id = @article_id
           AND (type & @snapshot_bit) <> 0            
           AND (type & @snapshot_mask) <> @sync_init
           AND (type & @snapshot_mask) <> @sync_done
    END
    ELSE 
    BEGIN
        -- Both @subscriber and @subscriber_db are non-null
        SELECT @subscriber_id = srvid 
          FROM MSreplservers
         WHERE UPPER(@subscriber) = UPPER(srvname)
        
        IF @subscriber_id IS NULL
        BEGIN
            RAISERROR(21150, 16, -1)  
            RETURN 1
        END
        
        SELECT @xact_seqno = subscription_seqno 
          FROM dbo.MSsubscriptions
         WHERE publisher_database_id = @publisher_database_id
           AND publisher_id = @publisher_id 
           AND article_id = @article_id
           AND subscriber_id = @subscriber_id
           AND subscriber_db = @subscriber_db

		IF @xact_seqno IS NULL
		BEGIN
			RAISERROR(14055, 16, -1)
			RETURN 1
		END                  
	END

	SELECT 'snapshot_folder' = CONVERT(NVARCHAR(255), command) 
	  FROM MSrepl_commands 
	 WHERE publisher_database_id = @publisher_database_id
	   AND (type & @snapshot_bit) <> 0
	   AND xact_seqno = @xact_seqno
	   AND (((type & ~@snapshot_bit) = @alt_directory_type) OR
			((type & ~@snapshot_bit) = @directory_type))
  ORDER BY command_id ASC
	IF @@ERROR <> 0
	BEGIN
		RETURN 1
	END
	ELSE
	BEGIN
		RETURN 0
	END
end
GO
GRANT EXECUTE ON [sys].[sp_MSbrowsesnapshotfolder] TO [public] AS [dbo]
GO
