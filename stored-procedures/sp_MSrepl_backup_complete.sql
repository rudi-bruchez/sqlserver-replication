SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSrepl_backup_complete]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSrepl_backup_complete] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSrepl_backup_complete]
WITH EXECUTE AS CALLER
AS
declare @sync_bit int
    declare @dist_bit int

    set nocount on

    set @sync_bit = 32
    set @dist_bit = 16

    -- security Check
    -- BACKUP/RESTORE statements require sysadmin, dbcreator, dbo 
    if isnull(is_srvrolemember('sysadmin'),0) = 0 
        and isnull(is_srvrolemember('dbcreator'),0) = 0
        and isnull(is_member('db_owner'),0) = 0
    begin
        raiserror(18799, 16, -1) 
        return (1)
    end
    
    -- If this is a distribution database and it is marked by 'sync with backup'
    if exists (select * from master.dbo.sysdatabases where
        name = db_name() collate database_default and
        category & (@sync_bit | @dist_bit) = @sync_bit | @dist_bit)
    begin
        update MSrepl_backup_lsns set valid_xact_id = next_xact_id, 
            valid_xact_seqno = next_xact_seqno 
        if @@error <> 0
            return 1
    end

    return 0
GO
GRANT EXECUTE ON [sys].[sp_MSrepl_backup_complete] TO [public] AS [dbo]
GO
