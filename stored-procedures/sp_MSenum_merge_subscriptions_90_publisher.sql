SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenum_merge_subscriptions_90_publisher]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenum_merge_subscriptions_90_publisher] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenum_merge_subscriptions_90_publisher]
	@publisher [sysname],
	@topNum [int],
	@exclude_anonymous [bit]
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

	if @topNum is not null
		SET ROWCOUNT @topNum

	select resultset.* from 
	(
	select pub.publisher_db as PublicationDatabase,
		pub.publication as PublicationName,
		UPPER(sub.subscriber) as SubscriberName,
		sub.subscriber_db as SubscriberDatabase,
		isnull(sessions.runstatus,0) as Status,
		sessions.start_time as LastSyncTime,
		DATEDIFF(minute, sessions.start_time, getdate()) as merge_SyncExpireTime,
		convert(int, sys.fn_convert_to_seconds(pub.retention, pub.retention_period_unit)*convert(int, sys.fn_replgetpublicationthreshold(pub.publication_id, 4))/100.0) as merge_SyncExpireTimeThreshold,
		ISNULL(sessions.duration, DATEDIFF(minute, sessions.start_time, getdate())) as merge_RunDuration,
		sys.fn_replgetpublicationthreshold(pub.publication_id, 5) as merge_FastRunDurationThreshold,
		sys.fn_replgetpublicationthreshold(pub.publication_id, 6) as merge_SlowRunDurationThreshold
	from dbo.MSpublications pub, 
		dbo.MSmerge_subscriptions sub, 
		dbo.MSmerge_agents agents,
		dbo.MSmerge_sessions sessions,
	(
	select agent_id, max(start_time) as maxtime 
	from dbo.MSmerge_sessions group by agent_id
	) as latest
	where pub.publisher_id=@publisher_id and
		pub.publication_type=2 and -- merge
		sub.publisher_id=pub.publisher_id and
		sub.publisher_db=pub.publisher_db and
		sub.publication_id=pub.publication_id and 
		agents.publisher_id=@publisher_id and
		agents.publisher_db=pub.publisher_db and
		agents.publication=pub.publication and 
		UPPER(agents.subscriber_name)=UPPER(sub.subscriber) and 
	agents.subscriber_db=sub.subscriber_db and
	sessions.session_id = (select top 1 session_id from dbo.MSmerge_sessions where agent_id=agents.id order by session_id desc) and
	sessions.agent_id=agents.id and
	sessions.agent_id=latest.agent_id and 
	latest.maxtime=sessions.start_time and
	(@exclude_anonymous = 0 or agents.anonymous_subid is null) 
	) as resultset 
	order by resultset.Status, resultset.merge_RunDuration, resultset.merge_SyncExpireTime, SubscriberName
end
GO
GRANT EXECUTE ON [sys].[sp_MSenum_merge_subscriptions_90_publisher] TO [public] AS [dbo]
GO
