SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenumsubscriptions]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenumsubscriptions] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenumsubscriptions]
	@subscription_type [nvarchar](5),
	@publisher [sysname],
	@publisher_db [sysname],
	@reserved [bit]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on

    declare @dbname                    sysname
                ,@category                 int
                ,@proc                    nvarchar(200)
                ,@retcode                int
                ,@cur_db                    sysname
                ,@type_value                int
                ,@subscriptiontype_anon    int

    -- Security check.  If not 'db_owner' return without querying
    if is_member('db_owner') <> 1
        return(0)
    select @subscriptiontype_anon= 2
            ,@cur_db = db_name()
            ,@type_value = case 
                    when (LOWER(@subscription_type)=N'push') then 0
                    when (LOWER(@subscription_type)=N'pull') then 1
                    when (LOWER(@subscription_type)=N'both') then 2
                    else 100 end
    --
    -- If we are being invoked by sp_MSenumallsubscriptions
    -- we can skip creation of the temp table, for other cases
    -- create the temp table
    --
    if (@reserved = 0)
    begin
        create table #tmp_subscriptions (
                        publisher            sysname not null,
                        publisher_db        sysname not null,
                        publication            sysname null,
                        replication_type    int not NULL,
                        subscription_type    int not NULL,
                        last_updated        datetime null,
                        subscriber_db        sysname not null,
                        update_mode            smallint null,
                        last_sync_status    int null,
                        last_sync_summary    sysname null,
                        last_sync_time        datetime null
                        )
    end

    if object_id(N'dbo.sysmergesubscriptions') is not NULL
    begin
        -- return all subscriptions that this database is a subscriber to
        -- suppress all subscriptions that originate from this database.
        insert into #tmp_subscriptions 
        select p.publisher
                ,p.publisher_db
                ,p.name
                ,2
                ,s.subscription_type
                ,s.last_sync_date
                ,s.db_name
                ,cast(NULL as smallint)
                ,s.last_sync_status
                ,s.last_sync_summary
                ,s.last_sync_date
            from dbo.sysmergepublications as p
                join dbo.sysmergesubscriptions as s 
                    on p.pubid = s.pubid
                        and s.pubid <> s.subid
						and lower(s.subscriber_server) collate database_default = lower(@@servername) collate database_default 
            where  (s.subscription_type=@type_value OR @type_value=2) 
                and ((@publisher = N'%') or (p.publisher = @publisher))
                and ((@publisher_db = N'%') or ( p.publisher_db = @publisher_db))
                and s.db_name = @cur_db
                and p.pubid not in 
                (select pubid from dbo.sysmergepublications pubs where 
                    lower(pubs.publisher) = LOWER(publishingservername()) AND
                    pubs.publisher_db = @cur_db)
    end

    if object_id(N'dbo.MSreplication_subscriptions') is not NULL
    begin
        if object_id(N'dbo.MSsubscription_properties') is not NULL and
            object_id(N'dbo.MSsubscription_agents') is not NULL
        begin
            -- update_mode in MSreplication_subscriptions table is not reliable.
            insert into #tmp_subscriptions 
            select s.publisher
                    ,s.publisher_db
                    ,s.publication
                    ,case isnull(p.publication_type,0) when 0 then 0 else 1 end
                    ,s.subscription_type
                    ,s.time
                    ,@cur_db 
                    -- NOTE: For Queued case: we will always return 2/3 for the 4/5 case
                    -- since we overload update_mode based on queue_type
                    ,case when isnull(a.update_mode,0) = 4 then 2
                            when isnull(a.update_mode,0) = 5 then 3
                            else isnull(a.update_mode,0) end
                    ,a.last_sync_status
                    ,a.last_sync_summary
                    ,a.last_sync_time
            from dbo.MSreplication_subscriptions s with (NOLOCK) 
                left outer join dbo.MSsubscription_agents a with (NOLOCK) 
                    on (UPPER(s.publisher) = UPPER(a.publisher) and 
                        s.publisher_db = a.publisher_db and 
                        ((s.publication = a.publication and 
                        s.independent_agent = 1 and
                        a.publication <> N'ALL') or
                        (a.publication = N'ALL' and s.independent_agent = 0)) and
                        s.subscription_type = a.subscription_type)
                left outer join dbo.MSsubscription_properties p with (NOLOCK)
                    on (UPPER(s.publisher) = UPPER(p.publisher) and 
                        s.publisher_db = p.publisher_db and 
                        s.publication = p.publication and
                        -- don't use property table for push. 
                        s.subscription_type <> 0) 
                where
                    ((@publisher = N'%') OR (UPPER(s.publisher) = UPPER(@publisher))) AND
                    ((@publisher_db = N'%') or ( s.publisher_db = @publisher_db)) and
                    -- eliminate duplicate entries for agents using multiple subscription streams
                    s.transaction_timestamp = (SELECT MAX(t.transaction_timestamp) FROM dbo.MSreplication_subscriptions t
                                                            WHERE t.publisher = s.publisher
                                                                AND t.publisher_db = s.publisher_db
                                                                AND t.publication = s.publication) and
                    ((s.subscription_type = 0 and @type_value = 0) or
                    -- For pull, return both pull and anonymous
                    (s.subscription_type <> 0 and @type_value = 1) or
                    @type_value = 2) 
        end
        -- Property table does not exists.
        else if object_id(N'dbo.MSsubscription_agents') is not NULL
        begin
            -- update_mode in MSreplication_subscriptions table is not reliable.
            insert into #tmp_subscriptions 
            select s.publisher
                    ,s.publisher_db
                    ,s.publication
                    -- Property table does not exists. Say transactional.
                    ,0
                    ,s.subscription_type
                    ,s.time, @cur_db
                    -- NOTE: For Queued case: we will always return 2/3 for the 4/5 case
                    -- since we overload update_mode based on queue_type
                    ,case when isnull(a.update_mode,0) = 4 then 2
                            when isnull(a.update_mode,0) = 5 then 3
                            else isnull(a.update_mode,0) end
                    ,a.last_sync_status
                    ,a.last_sync_summary
                    ,a.last_sync_time
            from dbo.MSreplication_subscriptions s with (NOLOCK) 
                left outer join dbo.MSsubscription_agents a with (NOLOCK) 
                    on (UPPER(s.publisher) = UPPER(a.publisher) and 
                        s.publisher_db = a.publisher_db and 
                        ((s.publication = a.publication and 
                        s.independent_agent = 1 and
                        a.publication <> N'ALL') or
                        (a.publication = N'ALL' and s.independent_agent = 0)) and
                        s.subscription_type = a.subscription_type)
                where
                    ((@publisher = N'%') OR (UPPER(s.publisher) = UPPER(@publisher))) AND
                    ((@publisher_db = N'%') or ( s.publisher_db = @publisher_db)) and
                    -- eliminate duplicate entries for agents using multiple subscription streams
                    s.transaction_timestamp = (SELECT MAX(t.transaction_timestamp) FROM dbo.MSreplication_subscriptions t
                                                            WHERE t.publisher = s.publisher
                                                                AND t.publisher_db = s.publisher_db
                                                                AND t.publication = s.publication) and
                    ((s.subscription_type = 0 and @type_value = 0) or
                    -- For pull, return both pull and anonymous
                    (s.subscription_type <> 0 and @type_value = 1) or
                    @type_value = 2)             
        end
        -- Agents table does not exists.
        else if object_id(N'dbo.MSsubscription_properties')  is not NULL
        begin
            -- update_mode in MSreplication_subscriptions table is not reliable.
            insert into #tmp_subscriptions 
            select s.publisher
                    ,s.publisher_db
                    ,s.publication
                    ,case isnull(p.publication_type,0) when 0 then 0 else 1 end
                    ,s.subscription_type
                    ,s.time
                    ,@cur_db 
                    -- NOTE: For Queued case: we will always return 2/3 for the 4/5 case
                    -- since we overload update_mode based on queue_type
                    ,case when isnull(s.update_mode,0) = 4 then 2
                            when isnull(s.update_mode,0) = 5 then 3
                            else isnull(s.update_mode,0) end
                    ,NULL --a.last_sync_status,
                    ,NULL --a.last_sync_summary,
                    ,NULL  --a.last_sync_time    
            from dbo.MSreplication_subscriptions s with (NOLOCK) 
                left outer join dbo.MSsubscription_properties p with (NOLOCK)
                    on (UPPER(s.publisher) = UPPER(p.publisher) and 
                        s.publisher_db = p.publisher_db and 
                        s.publication = p.publication and
                        -- don't use property table for push. 
                        s.subscription_type <> 0) 
                where
                    ((@publisher = N'%') OR (UPPER(s.publisher) = UPPER(@publisher))) AND
                    ((@publisher_db = N'%') or ( s.publisher_db = @publisher_db)) and
                     -- eliminate duplicate entries for agents using multiple subscription streams
                    s.transaction_timestamp = (SELECT MAX(t.transaction_timestamp) FROM dbo.MSreplication_subscriptions t
                                                            WHERE t.publisher = s.publisher
                                                                AND t.publisher_db = s.publisher_db
                                                                AND t.publication = s.publication) and
                    ((s.subscription_type = 0 and @type_value = 0) or
                    -- For pull, return both pull and anonymous
                    (s.subscription_type <> 0 and @type_value = 1) or
                    @type_value = 2) 
        end
        -- Both table does not exists
        else
        begin
            -- update_mode in MSreplication_subscriptions table is not reliable.
            insert into #tmp_subscriptions 
            select s.publisher
                    ,s.publisher_db
                    ,s.publication
                    ,0
                    ,s.subscription_type
                    ,s.time
                    ,@cur_db
                    -- NOTE: For Queued case: we will always return 2/3 for the 4/5 case
                    -- since we overload update_mode based on queue_type
                    ,case when isnull(s.update_mode,0) = 4 then 2
                            when isnull(s.update_mode,0) = 5 then 3
                            else isnull(s.update_mode,0) end
                    ,NULL  -- a.last_sync_status,
                    ,NULL  -- a.last_sync_summary
                    ,NULL  -- a.last_sync_time
            from dbo.MSreplication_subscriptions s with (NOLOCK)
                where
                    ((@publisher = N'%') OR (UPPER(s.publisher) = UPPER(@publisher))) AND
                    ((@publisher_db = N'%') or ( s.publisher_db = @publisher_db)) and
                    -- eliminate duplicate entries for agents using multiple subscription streams
                    s.transaction_timestamp = (SELECT MAX(t.transaction_timestamp) FROM dbo.MSreplication_subscriptions t
                                                        WHERE t.publisher = s.publisher
                                                            AND t.publisher_db = s.publisher_db
                                                            AND t.publication = s.publication) and
                    ((s.subscription_type = 0 and @type_value = 0) or
                    -- For pull, return both pull and anonymous
                    (s.subscription_type <> 0 and @type_value = 1) or
                    @type_value = 2) 
        end
    end
    --
    -- If we are being invoked by sp_MSenumallsubscriptions
    -- we can skip select of the temp table, for other cases
    -- select from the temp table
    --
    if (@reserved = 0)
    begin
        select * from #tmp_subscriptions
    end
    --
    -- all done
    --
    return (0)
end
GO
GRANT EXECUTE ON [sys].[sp_MSenumsubscriptions] TO [public] AS [dbo]
GO
