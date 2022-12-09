SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSrepl_init_backup_lsns]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSrepl_init_backup_lsns] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSrepl_init_backup_lsns]
WITH EXECUTE AS CALLER
AS
begin
	-- The stored procedure is called by sp_replicationdboption when changing a dist
	-- db to 'sync with backup' mode
	set nocount on	
	--
	-- security check
	-- only db_owner can execute this
	--
	if (is_member ('db_owner') != 1) 
	begin
		raiserror(14260, 16, -1)
		return (1)
	end
	-- Set the truncate lsns to null. By doing this
	-- the distribution agent will stop calling sp_repldone untill a dist db
	-- backup is done.
	update MSrepl_backup_lsns set valid_xact_seqno = NULL,
		valid_xact_id = NULL
	if @@error <> 0
		return 1
	return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSrepl_init_backup_lsns] TO [public] AS [dbo]
GO
