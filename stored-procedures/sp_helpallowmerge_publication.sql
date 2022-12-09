SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_helpallowmerge_publication]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_helpallowmerge_publication] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_helpallowmerge_publication]
WITH EXECUTE AS CALLER
AS
declare @db_name    sysname
declare @retcode    int

select @db_name = db_name()

exec @retcode = sys.sp_MSreplcheck_publish
if @@error <> 0 or @retcode <> 0
begin
    return (1)
end

if object_id('sysmergesubscriptions') is not NULL
begin
    if exists (select priority from dbo.sysmergesubscriptions 
                    where db_name=@db_name and 
                          UPPER(subscriber_server) collate database_default = UPPER(publishingservername()) collate database_default and 
                          priority=0 and
                          status <> 7) -- REPLICA_STATUS_BeforeRestore
    begin
        select 0
        RETURN (0)
    end
end

select 1
GO
GRANT EXECUTE ON [sys].[sp_helpallowmerge_publication] TO [public] AS [dbo]
GO
