SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSreset_transaction]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSreset_transaction] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSreset_transaction]
	@publisher [sysname],
	@publisher_db [sysname],
	@xact_seqno [varbinary](10)
WITH EXECUTE AS CALLER
AS
begin
	SET NOCOUNT ON
	--
	-- security check
	-- only db_owner can execute this
	--

	if (is_member ('db_owner') != 1) 
	begin
		raiserror(14260, 16, -1)
		return (1)
	end
	declare @publisher_database_id int

	select @publisher_database_id = a.id	
			from dbo.MSpublisher_databases a join MSreplservers b on  a.publisher_id = b.srvid
		where a.publisher_db = @publisher_db
			and upper(b.srvname) = upper(@publisher) collate database_default

	if @@error<>0
		return 1 

	insert dbo.MSrepl_transactions (publisher_database_id, xact_id, xact_seqno, entry_time) 
				values 	(@publisher_database_id, @xact_seqno, @xact_seqno, GetDate())
	if @@error<>0
		return 1 
	return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSreset_transaction] TO [public] AS [dbo]
GO
