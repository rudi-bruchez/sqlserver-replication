SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSget_last_transaction]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSget_last_transaction] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSget_last_transaction]
	@publisher_id [int],
	@publisher_db [sysname],
	@publisher [sysname],
	@max_xact_seqno [varbinary](16) OUTPUT,
	@for_truncate [bit]
WITH EXECUTE AS CALLER
AS
begin
	declare @publisher_database_id int
	declare @max_xact_id varbinary(16)
	declare @sync_bit int
	declare @sync_with_backup bit

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
	
	SELECT @sync_bit = 32

	-- sys.sp_replrestart calls sp_MSget_last_transaction without publisher_id, so we need to get it from sysservers 
	-- and then map to srvid from MSreplservers
	if @publisher_id is NULL
		select @publisher_id = srvid from master.dbo.sysservers where
			UPPER(srvname) = UPPER(@publisher)

	-- @publisher_id is always from master..sysservers, so we need to fetch from MSreplservers
	select @publisher_id = sys.fn_MSrepl_getsrvidfromdistdb(@publisher_id)
	-- Get publisher database id.
	SELECT @publisher_database_id = id from MSpublisher_databases where publisher_id = @publisher_id and 
		publisher_db = @publisher_db
	
	if exists ( select * from master.dbo.sysdatabases where 
			name = db_name() and
			category & @sync_bit = 0) 
		select @sync_with_backup = 0
	else
		select @sync_with_backup = 1



	if @for_truncate = 0
	begin
		select top 1 @max_xact_id = rt.xact_id, @max_xact_seqno = rt.xact_seqno
		  from
		  MSrepl_transactions rt
		  where 
			 rt.publisher_database_id = @publisher_database_id and
			 not xact_id = 0x0
			 order by xact_seqno desc
	end
	-- If (1) requesting truncate lsn (distbackuplsn), (2) sync with backup is set
	-- query the values from MSrepl_backup_lsn
	else if	@sync_with_backup = 1
	begin
		-- Get the last backed up lsn if available.
		select top 1 @max_xact_id = valid_xact_id, @max_xact_seqno = valid_xact_seqno
		  from
		  MSrepl_backup_lsns 
		  where 
			 publisher_database_id = @publisher_database_id 
	end
	
	-- If @publisher is not null, we are calling this sp from sp_replrestart
	-- Don't return result set.
	if @publisher is null
		select @max_xact_id, @max_xact_seqno, @publisher_database_id
			-- Don't return any result when requsting a truncate lsn and
			-- the database is not in 'sync with backup' mode, which signal the 
			-- distribution agent to use last dist lsn to call sp_repldone.
			where not (@sync_with_backup = 0 and @for_truncate = 1)
end
GO
GRANT EXECUTE ON [sys].[sp_MSget_last_transaction] TO [public] AS [dbo]
GO
