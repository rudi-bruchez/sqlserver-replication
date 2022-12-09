SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_replmonitorhelpmergesubscriptionmoreinfo]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_replmonitorhelpmergesubscriptionmoreinfo] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_replmonitorhelpmergesubscriptionmoreinfo]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname]
WITH EXECUTE AS CALLER
AS
begin
    declare @publisher_id smallint
    --
    -- security check
    -- only replmonitor can execute this
    --
    if not (is_member(N'db_owner') = 1 or isnull(is_member(N'replmonitor'),0) = 1)
    begin
        raiserror(14260, 16, -1)
        return (1)
    end
    
    select @publisher_id = srvid from MSreplservers where
       UPPER(srvname) = UPPER(@publisher)

    if @@rowcount < 1 or @@error <> 0
    begin
        raiserror(25002, 16, -1)
        return (1)
    end

    select sub.subscriber_db as SubscriberDatabase,
       @publisher+'.'+@publisher_db as PublicationLocation, 
    sub.subscription_type as SubscriptionType,
    case when sub.subscription_type=1 then @publisher else UPPER(servers.srvname) end as MergeAgentLocation,
    agents.name as AgentName,
    sys.fn_add_units_to_date(pub.retention, pub.retention_period_unit, sessions.start_time) as TimeToExpire,
    (
    select ss1.start_time
    from dbo.MSmerge_sessions ss1
    where ss1.agent_id=agents.id and ss1.runstatus=8 -- REPL_STATUS_VALIDATION_PASS
    and ss1.timestamp = (
    select max(ss2.timestamp)
            from dbo.MSmerge_sessions ss2 
            where ss2.agent_id=agents.id and ss2.runstatus=8)) as LastSuccessfullValidationTime,
    (
    select ss1.start_time
    from dbo.MSmerge_sessions ss1
    where ss1.agent_id=agents.id and ss1.runstatus in (7,8) 
    and ss1.timestamp = (
    select max(ss2.timestamp)
            from dbo.MSmerge_sessions ss2 
            where ss2.agent_id=agents.id and ss2.runstatus in (7,8))) as LastAttemptedValidationTime
     from dbo.MSpublications pub, 
        dbo.MSmerge_subscriptions sub, 
        master.dbo.sysservers servers, 
        dbo.MSmerge_agents agents,
        dbo.MSmerge_sessions sessions,
    (
    select agent_id, max(start_time) as maxtime 
    from MSmerge_sessions group by agent_id
    ) as latest        
    where pub.publisher_id=@publisher_id and
        pub.publication=@publication and 
        pub.publisher_db=@publisher_db and
        pub.publication_type=2 and --merge
        sub.publisher_id=pub.publisher_id and
        sub.publisher_db=pub.publisher_db and
        sub.publication_id=pub.publication_id and 
        UPPER(sub.subscriber)=UPPER(@subscriber) and
        sub.subscriber_db=@subscriber_db and
        agents.publisher_id=@publisher_id and
        agents.publisher_db=pub.publisher_db and
        agents.publication=pub.publication and 
        UPPER(agents.subscriber_name)=UPPER(sub.subscriber) and 
    agents.subscriber_db=sub.subscriber_db and
    sessions.timestamp = (select max(timestamp)from dbo.MSmerge_sessions where agent_id=agents.id) and
    sessions.agent_id=agents.id and
    sessions.agent_id=latest.agent_id and 
    latest.maxtime=sessions.start_time and
    UPPER(servers.srvname) <> 'REPL_DISTRIBUTOR'
    order by agents.name
end
GO
GRANT EXECUTE ON [sys].[sp_replmonitorhelpmergesubscriptionmoreinfo] TO [public] AS [dbo]
GO
