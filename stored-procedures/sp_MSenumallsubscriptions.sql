SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenumallsubscriptions]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenumallsubscriptions] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenumallsubscriptions]
	@subscription_type [nvarchar](5),
	@subscriber_db [sysname]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    declare @current_db        sysname
                ,@retcode        int
                ,@proc            nvarchar(200)
                ,@db_status        int

    create table #tmp_subscriptions (
                        publisher            sysname collate database_default not null,
                        publisher_db        sysname collate database_default not null,
                        publication            sysname collate database_default null,
                        replication_type    int not NULL,
                        subscription_type    int not NULL,
                        last_updated        datetime null,
                        subscriber_db        sysname collate database_default not null,
                        update_mode            smallint null,
                        last_sync_status    int null,
                        last_sync_summary    sysname collate database_default null,
                        last_sync_time        datetime null
                        )

    declare #cur_db cursor local FAST_FORWARD FOR select DISTINCT name, status
        FROM master.dbo.sysdatabases where ((@subscriber_db = N'%' collate database_default) or (name = @subscriber_db collate database_default)) and
            has_dbaccess(name) = 1
    open #cur_db
    fetch #cur_db into @current_db, @db_status
    while (@@fetch_status <> -1)
    begin
        /*
         * we only return subscriptions in db which is not in loading (0x20), suspect(0x100),
         * offline(0x200), in recovering(0x80), shutdown(0x40000), not recovered(0x40)
         */
        if (@db_status & 0x403e0) = 0
        begin
            --
            -- sp_MSenumsubscriptions will use the same temp table inside
            --
            select @proc = QUOTENAME(@current_db) + N'.sys.sp_MSenumsubscriptions ' 
            exec @retcode = @proc  @subscription_type = @subscription_type, @reserved = 1
            if @@ERROR<>0 or @retcode<>0
                return (1)
        end
        fetch next from #cur_db into @current_db, @db_status
    end
    close #cur_db
    deallocate #cur_db

    select  distinct 'publisher'        = publisher,
            'publishing database'    = publisher_db,
            'publication'    = publication,
            'replication type'= replication_type,
            'subscription type'     = subscription_type,
            'last updating time'    = sys.fn_replformatdatetime(last_updated),
            'subscribing database'  = subscriber_db,
            'update_mode'           = update_mode,
            'last sync status'= last_sync_status,
            'last sync summary'= last_sync_summary,
            'last sync time'= sys.fn_replformatdatetime(last_sync_time)
    from #tmp_subscriptions

    return (0)
end
GO
GRANT EXECUTE ON [sys].[sp_MSenumallsubscriptions] TO [public] AS [dbo]
GO
