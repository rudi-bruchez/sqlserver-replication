SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_replmonitorhelpsubscription]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_replmonitorhelpsubscription] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_replmonitorhelpsubscription]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@publication_type [int],
	@mode [int],
	@topnum [int],
	@exclude_anonymous [bit],
	@refreshpolicy [tinyint]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on
	declare @retcode int
				,@curdate datetime
	--
	-- constants
	--

	declare @expiration int
				,@latency int
				,@distribution_agentname sysname
				,@mergeexpirationChosen int
				,@mergerundurationChosen int
				,@mergestoppedcontinuousagentChosen int
				,@mergerunspeedChosen int
				,@modeallsubscription tinyint
				,@modeinerroronly tinyint
				,@modeinwarningonly tinyint
				,@modeinerrorandwarningonly tinyint
				,@modetop25worstperforming tinyint
				,@modetop50worstperforming tinyint
				,@modesynchronizing tinyint
				,@modenotsynchronizing tinyint

	--
	-- initialize constants
	--
	select @expiration = 1
				,@latency = 2
				,@mergeexpirationChosen=4
				,@mergerundurationChosen=5
				,@mergestoppedcontinuousagentChosen=6
				,@mergerunspeedChosen=7
				,@modeallsubscription = 0
				,@modeinerroronly = 1
				,@modeinwarningonly = 2
				,@modeinerrorandwarningonly = 3
				,@modetop25worstperforming = 4
				,@modetop50worstperforming = 5
				,@modesynchronizing = 6
				,@modenotsynchronizing = 7

	--
	-- security check : replmonitor
	--
	if not (is_member(N'db_owner') = 1 or isnull(is_member(N'replmonitor'),0) = 1)
	begin
		raiserror(14260, 16, -1)
		return (1)
	end
	--
	-- security: Has to be executed from distribution database
	--
	if sys.fn_MSrepl_isdistdb (db_name()) != 1
	begin
		raiserror (21482, 16, -1, 'sp_replmonitorhelpsubscription', 'distribution')
		return 1
	end
	--
	-- validate @publication_type
	--
	if (@publisher_db is NULL or @publication is NULL) 
		and @publication_type is NULL 
	begin
		raiserror(20587, 16, -1, '@publication_type', 'sp_replmonitorhelpsubscription')
		return (1)
	end
	--
	-- validate @mode
	--
	if (@mode not in (@modeallsubscription,@modeinerroronly,@modeinwarningonly,@modeinerrorandwarningonly
				,@modetop25worstperforming,@modetop50worstperforming,@modesynchronizing,@modenotsynchronizing))
	begin
		raiserror(20587, 16, -1, '@mode', 'sp_replmonitorhelpsubscription')
		return (1)
	end
	--
	-- initialize constants
	--
	select @expiration = 1
				,@latency = 2
				,@curdate = getdate()
				
	--
	-- create temp table to get the monitoring data
	--
	create table #tmp_replication_monitordata  
	(
		publication_id int
		,publisher sysname
		,publisher_srvid int
		,publisher_db sysname 
		,publication sysname 
		,publication_type int
		,agent_type int 
		,agent_name sysname
		,job_id uniqueidentifier
		,status int
		,isagentrunningnow bit
		,warning int                        -- latest session's warning
		,last_distsync datetime        -- last sync time
		,agentstoptime datetime      -- agent stop time
		,distdb sysname null
		,retention int
		,time_stamp datetime null
		,worst_latency int
		,best_latency int
		,avg_latency int
		,cur_latency int 
		,mergePerformance int
		,mergelatestsessionrunduration int
		,mergelatestsessionrunspeed float
		,mergelatestsessionconnectiontype int
		,retention_period_unit tinyint
	)
	if @@error != 0
	begin
		raiserror(20507, 16, 3, '#tmp_replication_monitordata', 'tempdb')
		return 1
	end
	--
	-- build indices
	--
	create nonclustered index nc1tmp_replication_monitordata 
		on #tmp_replication_monitordata(publisher_srvid) 
	create nonclustered index nc2tmp_replication_monitordata 
		on #tmp_replication_monitordata(agent_type) 
	create nonclustered index nc4tmp_replication_monitordata 
		on #tmp_replication_monitordata(publisher) 
	create nonclustered index nc5tmp_replication_monitordata 
		on #tmp_replication_monitordata(publication, publisher_db) 
	create nonclustered index nc6tmp_replication_monitordata 
		on #tmp_replication_monitordata(agent_name) 
	if (@@error != 0)
		return 1

	-- Get publisher without port number
	exec sys.sp_MSget_server_portinfo 
		@name = @publisher, 
		@srvname = @publisher OUTPUT

	--
	-- Get refresh data
	--
	exec @retcode = sys.sp_replmonitorrefreshdata @publisher=@publisher
				,@publisher_db=@publisher_db
				,@publication=@publication
				,@publication_type=@publication_type
				,@refreshpolicy = @refreshpolicy
	if @@error != 0 or @retcode != 0
		return 1
	--
	
	--
	-- set @publication_type for specific publication query
	-- and validate 
	--
	if (@publication_type is null)
	begin
		select @publication_type = publication_type
		from #tmp_replication_monitordata
		where upper(publisher) = upper(@publisher)
			and publisher_db = @publisher_db
			and publication = @publication
	end
	else if (@publication_type not in (0,1,2))
	begin
		raiserror(20587, 16, -1, '@publication_type', 'sp_replmonitorhelpsubscription')
		return (1)
	end
	-- 
	-- Adjust the rows to return
	--
	if (@mode in (@modetop25worstperforming, @modetop50worstperforming))
	begin
		if (@mode = @modetop25worstperforming)
			select @topnum = case when (isnull(@topnum, 30) > 25) then 25 else @topnum end
		else
			select @topnum = case when (isnull(@topnum, 60) > 50) then 50 else @topnum end
	end
	--
	-- process based on publication_type
	--
	if (@publication_type in (0,1))
	begin
		create table #tmp_subscriptiondata
		(
			-- static
			publisher_srvid int
			,publisher_db sysname
			,publication sysname
			,publication_id int
			,subscriber_id int
			,subscriber sysname null
			,subscriber_db sysname
			,publication_type int -- Type of publication: 0 = Transactional, 1 = Snapshot, 2 = Merge
			,subtype int -- Type of subscription: dbo.MSmerge_subscriptions.subscription_type
			-- 0 = Push, 1 = Pull, 2 = Anonymous
			,subscription_time datetime
			-- dynamic
			,status int
			,warning int
			,monitorranking int
			,last_distsync datetime
			-- tran
			,distribution_agentname sysname null
			,logreaderagent_status int null
			,latency int
			,latencythreshold int
			,agentnotrunning int
			,agentnotrunningthreshold int
			,timetoexpiration int
			,expirationthreshold int
			-- merge
			-- fill mergesubscriptionfriendlyname by dbo.MSmerge_subscriptions.description
			,mergesubscriptionfriendlyname sysname null
			,mergeconnectiontype int null
			,mergeagentname sysname null
			,mergeagentlocation sysname null
			-- among all session of this subscription, depending on latest connection type
			-- calc average of run_speed among the subset,
			-- current_run_speed/avg_run_speed
			,mergePerformance int null
			,mergerunspeed float null --latest running session
			,mergerunduration int null --latest running session
			-- Added later - see if we can reorder
			,distributionagentjobid  binary(16) null
			,mergeagentjobid binary(16) null
			,distributionagentid int null
			,distributionagentprofileid int null
			,mergeagentid int null
			,mergeagentprofileid int null
			,logreaderagentname sysname null
			---only for SQL11 or later
			,publisher sysname null
		)

        create clustered index csubscriptiondata on #tmp_subscriptiondata (monitorranking desc)
        create index nc1subscriptiondata on #tmp_subscriptiondata (distribution_agentname)
        create index nc2subscriptiondata on #tmp_subscriptiondata (latency desc)
        create index nc3subscriptiondata on #tmp_subscriptiondata (mergePerformance)
        create index nc4subscriptiondata on #tmp_subscriptiondata (publisher_srvid, publisher_db, publication_id, subscriber_db, subscriber_id)
        create index nc5subscriptiondata on #tmp_subscriptiondata (mergeagentname)
    
        -- **************************************
        -- build #tmp_subscriptiondata for tran
        -- both snaphot and transactional subscriptions will have a distribution agent
        -- Get the subscription details based on the distribution agent
        --
        insert into #tmp_subscriptiondata
        (
            subscriber_id 
            ,subscriber
            ,subscriber_db 
            ,publisher_srvid
            ,publisher_db 
            ,publication 
            ,publication_id 
            ,publication_type
            ,subtype
            ,distribution_agentname
            ,distributionagentjobid
            ,distributionagentid
            ,distributionagentprofileid
            ,publisher
        )
        select distinct s.subscriber_id,
                case when s.anonymous_subid is not null then  -- anonymous subscription
                    upper(s.subscriber_name)    -- name is stored in subscriber_name instead of sys.servers
                else
                    upper(srv.srvname)
                end
                ,s.subscriber_db
                ,r.publisher_srvid
                ,r.publisher_db
                ,r.publication
                ,r.publication_id
                ,r.publication_type
                ,s.subscription_type
                ,r.agent_name
                ,s.job_id
                ,s.id
                ,s.profile_id
                ,r.publisher
        from #tmp_replication_monitordata as r 
            join dbo.MSdistribution_agents as s with (nolock)
                on r.publisher_srvid = s.publisher_id
                and r.publisher_db = s.publisher_db collate database_default
                and (r.publication = s.publication collate database_default or s.publication = 'ALL' collate database_default) 
                and s.subscriber_id >= 0    -- skip the virtual subscriptions
                and (r.agent_type & 3) = 3 -- we select the distribution agent entries to optimize
                and (@exclude_anonymous = 0 or s.anonymous_subid is null) -- anonymous
                and r.job_id = cast(s.job_id as uniqueidentifier)
            join MSreplservers as srv
                on srv.srvid = s.subscriber_id
        --
        -- get the latest subscription_time for the subscription to each publication
        --
        update #tmp_subscriptiondata 
        set subscription_time = (select max(s.subscription_time)
                                            from dbo.MSsubscriptions as s with (nolock)
                                            where subscriber_id = s.subscriber_id
                                                and subscriber_db = s.subscriber_db
                                                and publisher_srvid = s.publisher_id
                                                and publisher_db = s.publisher_db
                                                and publication_id = s.publication_id 
                                                and subtype = s.subscription_type)
        --
        -- The logreader agent status needs to incorporated in the subscription status
        --
        update #tmp_subscriptiondata                                                 
        set logreaderagent_status = isnull(r.status,0)
            ,logreaderagentname = r.agent_name
        from #tmp_subscriptiondata as s
            join #tmp_replication_monitordata as r
                on s.publisher_srvid = r.publisher_srvid
                    and s.publisher_db = r.publisher_db
                    and r.agent_type=2
                    and s.publication_type = 0
        --
        -- set the status of the subscription based on the type of 
        -- publication and agents status that are involved
        -- populate the threshold values
        -- populate other fields from #tmp_replication_monitordata
        --
        update #tmp_subscriptiondata 
        set expirationthreshold = cast(sys.fn_replgetpublicationthreshold(r.publication_id, @expiration) as int)
            ,latencythreshold = cast(sys.fn_replgetpublicationthreshold(r.publication_id, @latency) as int)
            ,warning = r.warning
            ,status = case 
                                -- when snapshot publication - use distribution agent status
                                when (r.publication_type = 1) then r.status
                                -- else we have transactional publication
                                else
                                    case 
                                        -- Error = when any one agent has error
                                        when (r.status = 6 or logreaderagent_status = 6) then 6
                                        -- Retry = when any one agent has retry
                                        when (r.status = 5 or logreaderagent_status = 5) then 5
                                        -- Stopped = when any one agent has stopped
                                        when (r.status = 2 or logreaderagent_status = 2) then 2
                                        -- Idle (Running) = when both agents are idle
                                        when (r.status = 4 and logreaderagent_status = 4) then 4
                                        -- Inprogress (Running) = when any one agent is in progress and the other is still running
                                        when (r.status = 3 and logreaderagent_status in (3, 4) 
                                            or logreaderagent_status = 3 and r.status in (3, 4)) then 3
                                        -- Startup (Running) =  when any one agent is in startup and the other is still running
                                        when (r.status = 1 and logreaderagent_status in (1, 3, 4) 
                                            or logreaderagent_status = 1 and r.status in (1, 3, 4)) then 1
                                        -- we should not come here
                                        else 0
                                    end
                            end
            ,latency = r.cur_latency
            ,agentnotrunning = case when (r.agentstoptime is null) then null else datediff(hour, r.agentstoptime, @curdate) end
            ,last_distsync = r.last_distsync
            ,timetoexpiration = case when (r.retention is null) then null else datediff(hour, @curdate, dateadd(hour, r.retention, subscription_time)) end
        from #tmp_replication_monitordata as r
        where r.agent_name = distribution_agentname 
        --
        -- Set the monitor ranking based on status, warning, publication_type
        --
        update #tmp_subscriptiondata 
        set monitorranking = sys.fn_replmonitorsubscriptionranking(status, warning, publication_type)
        --
        -- set the rowcount if necessary
        --
        if @topnum is not null
            set rowcount @topnum
        --
        -- return the rowset based on mode
        --
        select
            status 
            ,warning 
            ,subscriber 
            ,subscriber_db 
            ,publisher_db 
            ,publication 
            ,publication_type
            ,subtype 
            ,latency 
            ,latencythreshold 
            ,agentnotrunning 
            ,agentnotrunningthreshold 
            ,timetoexpiration 
            ,expirationthreshold 
            ,last_distsync 
            ,distribution_agentname
            ,mergeagentname
            ,mergesubscriptionfriendlyname
            ,mergeagentlocation
            ,mergeconnectiontype
            ,mergePerformance
            ,mergerunspeed
            ,mergerunduration
            ,monitorranking
            ,distributionagentjobid
            ,mergeagentjobid
            ,distributionagentid
            ,distributionagentprofileid
            ,mergeagentid
            ,mergeagentprofileid
            ,logreaderagentname
            ,publisher
        from #tmp_subscriptiondata
        where 
            @mode in (@modeallsubscription, @modetop25worstperforming, @modetop50worstperforming)   -- return all subscriptions
            or (@mode = @modeinerroronly and monitorranking = 60) -- return only ones in error 
            or (@mode = @modeinwarningonly and monitorranking between 50 and 59 ) -- return only ones with warning 
            or (@mode = @modeinerrorandwarningonly and monitorranking between 50 and 60 ) -- return only ones with warning or error
            or (@mode = @modesynchronizing and status in (1,3,4)) -- return only ones with running agents
            or (@mode = @modenotsynchronizing and status not in (1,3,4)) -- return only ones with stopped agents
        order by monitorranking desc  -- highest rank will be shown first 
            ,latency desc -- highest latency first
    end
    else
    begin
        -- ************************************
        -- handle merge subscriptions
        declare @publisher_id smallint
        select @publisher_id = srvid from MSreplservers where
           UPPER(srvname collate database_default) = UPPER(@publisher) collate database_default
        
        --
        -- set the rowcount if necessary
        --
        if @topnum is not null
            set rowcount @topnum
        --
        -- return the rowset based on mode
        --
        select
            sub.status 
            ,sub.warning 
            ,sub.subscriber 
            ,sub.subscriber_db 
            ,sub.publisher_db 
            ,sub.publication
            ,sub.publication_type
            ,sub.subtype 
            ,sub.latency 
            ,sub.latencythreshold 
            ,sub.agentnotrunning 
            ,sub.agentnotrunningthreshold 
            ,timetoexpiration =  case when (sub.retention is null) then null else (case when sub.retention_period_unit = 0 then datediff(hour, @curdate, dateadd(hour, sub.retention, sub.last_distsync)) else (datediff(hour, @curdate, sys.fn_add_units_to_date(sub.retention, sub.retention_period_unit, sub.last_distsync))) end) end 
            ,sub.expirationthreshold 
            ,sub.last_distsync 
            ,sub.distribution_agentname
            ,sub.mergeagentname
            ,sub.mergesubscriptionfriendlyname
            ,sub.mergeagentlocation
            ,sub.mergeconnectiontype
            ,sub.mergePerformance
            ,sub.mergerunspeed
            ,sub.mergerunduration
            ,sub.monitorranking 
            ,sub.distributionagentjobid
            ,sub.mergeagentjobid
            ,sub.distributionagentid
            ,sub.distributionagentprofileid
            ,sub.mergeagentid
            ,sub.mergeagentprofileid
            ,sub.logreaderagentname
            ,sub.publisher
        from 
        (
            select
                -- static
                subscriber = upper(agents.subscriber_name)
                ,subscriber_id = agents.subscriber_id
                ,subscriber_db = agents.subscriber_db
                ,publisher_srvid = r.publisher_srvid
                ,publisher_db = r.publisher_db
                ,publication = r.publication
                ,publication_id = r.publication_id
                ,publication_type = r.publication_type
                ,subtype = case when agents.anonymous_subid is not null then 2 else s.subscription_type end
                -- dynamic    
                ,status = r.status
                ,warning = r.warning
                ,agentnotrunning = case when (r.agentstoptime is null) then null else datediff(hour, @curdate, r.agentstoptime) end
                ,last_distsync = r.last_distsync
                ,subscription_time = s.subscription_time
                -- merge perf
                ,mergeagentname = agents.name
                --,'agentname'
                ,mergeagentlocation = case when s.subscription_type=0 then @publisher else UPPER(agents.subscriber_name) end
                ,mergesubscriptionfriendlyname = s.description 
                ,mergeconnectiontype = mergelatestsessionconnectiontype
                ,mergerunduration = r.mergelatestsessionrunduration
                --2,NULL
                ,mergerunspeed=r.mergelatestsessionrunspeed
                ,mergePerformance = r.mergePerformance
                ,mergeagentjobid = agents.job_id
                ,mergeagentid = agents.id
                ,mergeagentprofileid = agents.profile_id
                ,retention = r.retention
                ,retention_period_unit = r.retention_period_unit
                ,monitorranking = case when (r.status > 5 or r.warning > 0) then sys.fn_replmonitorsubscriptionranking(r.status, r.warning, r.publication_type) else (case when r.status = 0 then 50 else (case when r.status = 5 then 40 else (case when r.status = 2 then 20 else 30 end) end) end) end
                ,latency = NULL
                ,latencythreshold = NULL		
                ,agentnotrunningthreshold = NULL
                ,distribution_agentname = NULL
                ,distributionagentjobid = NULL
                ,distributionagentid = NULL
                ,distributionagentprofileid = NULL
                ,logreaderagentname = NULL
                ,expirationthreshold = NULL
                ,r.publisher
            from #tmp_replication_monitordata as r 
                join dbo.MSmerge_agents agents with (nolock)
                    on agents.name = r.agent_name collate database_default
                    and (@exclude_anonymous = 0 or agents.anonymous_subid is null)
                    and ((@publisher is null and agents.publisher_id is not null) or (agents.publisher_id=@publisher_id))
                    and agents.publisher_db=r.publisher_db collate database_default
                    and agents.publication=r.publication collate database_default
                    and (r.agent_type & 4) = 4 -- for merge only
            
                left outer join dbo.MSmerge_subscriptions as s with (nolock)
                    on r.publisher_srvid = s.publisher_id
                    and r.publisher_db = s.publisher_db collate database_default
                    and r.publication_id = s.publication_id 
                    and s.subscriber is not NULL    -- skip the virtual entries in dbo.MSsubscriptions
                    and UPPER(agents.subscriber_name)=UPPER(s.subscriber) 
                    and agents.subscriber_db=s.subscriber_db 

		) as sub
		where 
			@mode = @modeallsubscription -- return all subscriptions
			or (@mode in (@modetop25worstperforming, @modetop50worstperforming) and sub.mergePerformance is not null)   -- return worst 25/50 subscriptions based on perf.
			or (@mode = @modeinerroronly and sub.monitorranking = 60) -- return only ones in error 
			or (@mode = @modeinwarningonly and sub.monitorranking between 50 and 59 ) -- return only ones with warning 
			or (@mode = @modeinerrorandwarningonly and sub.monitorranking between 50 and 60 ) -- return only ones with warning or error
			or (@mode = @modesynchronizing and sub.status in (1,3,4)) -- return only ones with running agents
			or (@mode = @modenotsynchronizing and sub.status not in (1,3,4)) -- return only ones with stopped agents
		order by sub.monitorranking desc  -- highest rank will be shown first 
			,sub.mergePerformance asc -- lowest mergePerformance first
	end
	--
	-- all done
	--
	return 0
end
GO
GRANT EXECUTE ON [sys].[sp_replmonitorhelpsubscription] TO [public] AS [dbo]
GO
