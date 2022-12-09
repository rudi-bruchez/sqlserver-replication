SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSrepl_backup_start]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSrepl_backup_start] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSrepl_backup_start]
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
        update MSrepl_backup_lsns set next_xact_id = t2.xact_id, next_xact_seqno = m.xact_seqno from 
            (select tm.publisher_database_id, max(tm.xact_seqno) from 
                -- max seqno of xacts not involved in partial tran processing
                (select t.publisher_database_id, max(substring(t.xact_seqno, 1, 10)) from 
                    MSrepl_transactions t where
                    not t.xact_id = 0x0 
                    group by t.publisher_database_id, substring(t.xact_seqno, 1, 10)
                    having count(t.xact_seqno) < 2
                union
                -- max seqno of xacts involved in and completed partial tran processing
                select t.publisher_database_id, max(substring(xact_seqno, 1, 10)) from
                    MSrepl_transactions t where
                    not t.xact_id = 0x0 
                    and t.xact_id = substring(t.xact_seqno, 1, 10)
                    group by t.publisher_database_id
                )as tm(publisher_database_id, xact_seqno) -- derived table containing up to 2 rows per publication_database_id
            group by tm.publisher_database_id -- derived table containing up to 1 row per publication_database_id
            )as m(publisher_database_id, xact_seqno), 
            MSrepl_transactions t2              
        where m.publisher_database_id = MSrepl_backup_lsns.publisher_database_id and
                t2.publisher_database_id = MSrepl_backup_lsns.publisher_database_id and
                t2.xact_seqno   = m.xact_seqno
        if @@error <> 0
            return 1
    end
    
    return 0
    
GO
GRANT EXECUTE ON [sys].[sp_MSrepl_backup_start] TO [public] AS [dbo]
GO
