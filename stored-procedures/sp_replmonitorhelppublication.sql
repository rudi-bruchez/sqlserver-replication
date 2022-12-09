SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_replmonitorhelppublication]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_replmonitorhelppublication] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_replmonitorhelppublication]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@publication_type [int],
	@refreshpolicy [tinyint]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on
	set ansi_warnings off
	declare @retcode int
	--
	-- constants
	--
	declare  @status int
				,@warning int
				,@worst_latency int
				,@best_latency int
				,@average_latency int
				,@last_distsync datetime
				,@retention int
				,@subscriptioncount int
				,@runningdistagentcount int
				,@snapshot_agentname sysname 
				,@logreader_agentname sysname 
				,@qreader_agentname sysname 
				,@expiration int
				,@latency int
				,@worst_runspeedPerf int
				,@best_runspeedPerf int
				,@average_runspeedPerf int 
		 
	--
	-- initialize constants
	--
	select @expiration = 1
				,@latency = 2

/*
-- warning bitmap definition
Expiration                      1                    	Threshold to warn expiration of subscription to a transactional publication - percentage of retention in hours
latency                          2                      The time taken to replicate data from the transactional publisher (committed) to the subscriber (committed) - in seconds
mergeexpiration             4                      Threshold to warn expiration of merge subscription to a publication - percentage of retention in hours
mergerunspeedDUN       8                      Merge delivery rate - in rows/seconds for slow connection
mergerunspeedLAN        16                     Merge delivery rate - in rows/seconds for fast connection
mergerundurationDUN    32                     The time taken to finish one merge run - in seconds for slow connection
mergerundurationLAN     64                     The time taken to finish one merge run - in seconds for fast connection.
*/
				
	create table #tmp_publicationdata 
	(
		-- internal use
		publication_id int
		,distribution_db sysname
		-- static
		,publisher_db sysname
		,publication sysname
		,publication_type int
		-- dynamic
		,status int					-- publication status defined as max(status) among all agents
		,subscriptioncount int		-- # of subscription
		,runningdistagentcount int	-- # of running agents
		,last_distsync datetime		-- last sync time
		,warning int 				-- publication warning defined as max(isnull(warning,0)) among all agents
		,retention int				-- retention period
		-- tran specific        
		,snapshot_agentname sysname null
		,logreader_agentname sysname null
		,qreader_agentname sysname null
		,worst_latency int
		,best_latency int
		,average_latency int
		,latencythreshold int
		,expirationthreshold int
		,agentnotrunningthreshold int
		,worst_runspeedPerf int
		,best_runspeedPerf int
		,average_runspeedPerf int 
		,retention_period_unit tinyint
		-- for SQL 11 or later only if user specifies null for publisher name
		,publisher sysname null
	)
	create clustered index cpublicationdata on #tmp_publicationdata (publication, publication_type, publisher_db)

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
		raiserror (21482, 16, -1, 'sp_replmonitorhelppublication', 'distribution')
		return 1
	end
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
		,warning int
		,last_distsync datetime
		,agentstoptime datetime
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
		raiserror(20507, 16, 2, '#tmp_replication_monitordata', 'tempdb')
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
	-- get refresh data
	--
	exec @retcode = sys.sp_replmonitorrefreshdata @publisher = @publisher
					,@publisher_db = @publisher_db
					,@publication = @publication
					,@publication_type = @publication_type
					,@refreshpolicy = @refreshpolicy
	if @@error != 0 or @retcode != 0
		return 1
	
	--
	-- build #tmp_publicationdata
	-- skip entries for publication with name = ALL
	--
	insert into #tmp_publicationdata 
	(
		distribution_db
		,publisher_db 
		,publication 
		,publication_id
		,publication_type
		,publisher 
	)
	select distinct
		distdb
		,publisher_db
		,publication
		,publication_id
		,publication_type
		,publisher 
	from #tmp_replication_monitordata
	where publication != N'ALL'
	--
	-- Now update the other columns
	--
	declare #hcrefreshmonitor cursor local fast_forward for 
		select publisher_db
				,publication
				,publication_type 
		 from #tmp_publicationdata
	open #hcrefreshmonitor
	fetch #hcrefreshmonitor into @publisher_db, @publication, @publication_type
	while (@@fetch_status != -1)
	begin
		--
		-- get the values from all agents
		-- special publication name = ALL for logreader agent
		--
		select @status = max(status)
				,@warning = max(isnull(warning,0))
				,@worst_latency = max(worst_latency)
				,@best_latency = min(best_latency)
				,@average_latency = cast(avg(cast(avg_latency as bigint)) as int)
				,@last_distsync = max(last_distsync)
				,@retention = max(retention)
				,@worst_runspeedPerf = min(mergePerformance)
				,@best_runspeedPerf = max(mergePerformance)
				,@average_runspeedPerf = avg (mergePerformance)
		from #tmp_replication_monitordata
		where publisher_db = @publisher_db
			and (publication = @publication or publication = 'ALL')
			and publication_type = @publication_type
		--
		-- subscriptioncount
		-- count the number dist/merge agents for the publication
		--
		-- @agent_type = 1-Snapshot, 2-Logreader, 3-Distribution, 4-Merge
		select @subscriptioncount = isnull(count(agent_name),0)
		from #tmp_replication_monitordata
		where publisher_db = @publisher_db
			and publication = @publication
			and publication_type = @publication_type
			and ((agent_type & 3) = 3 or (agent_type & 4) = 4)
		--
		-- runningdistagentcount
		-- count the number dist agents for the publication
		-- which are running now
		--
		select @runningdistagentcount = isnull(count(agent_name),0)
		from #tmp_replication_monitordata
		where publisher_db = @publisher_db
			and publication = @publication
			and publication_type = @publication_type
			and (agent_type & 3) = 3
			and isagentrunningnow = 1
		--
		-- Get the agent names
		--
		-- join this with MSsnapshot_agents to make sure that we are getting the agent name
		-- of the regular snapshot agent and not the dynamic snapshot agent
		select @snapshot_agentname = t.agent_name
		from #tmp_replication_monitordata t
			 inner join MSsnapshot_agents a on a.publisher_db = t.publisher_db collate database_default and 
											a.publication = t.publication collate database_default and 
											a.publisher_id = t.publisher_srvid and
											a.publication_type = t.publication_type and
											a.name = t.agent_name collate database_default
		where t.publisher_db = @publisher_db
			and t.publication = @publication
			and t.publication_type = @publication_type
			and t.agent_type = 1
			and a.dynamic_filter_login is NULL 
			and a.dynamic_filter_hostname is NULL
		--
		-- logreader agent is per publisher_db
		--
		select @logreader_agentname = agent_name
		from #tmp_replication_monitordata
		where publisher_db = @publisher_db
			and agent_type = 2
		--
		-- if this is a queued publication
		-- list the queue reader agent
		--
		if exists (select * from dbo.MSpublications with (nolock)
			where publisher_db = @publisher_db
				and publication = @publication
				and publication_type = @publication_type
				and allow_queued_tran = 1)
		begin
			select @qreader_agentname = agent_name
					,@status = case when status > @status then status else @status end
			from #tmp_replication_monitordata
			where agent_type = 9
		end
		--
		-- update now
		--
		update #tmp_publicationdata 
		set status = @status
			,warning = @warning
			,worst_latency = @worst_latency
			,best_latency = @best_latency
			,average_latency = @average_latency
			,last_distsync = @last_distsync
			,retention = @retention
			,subscriptioncount = @subscriptioncount
			,runningdistagentcount = @runningdistagentcount
			,snapshot_agentname = @snapshot_agentname
			,logreader_agentname = @logreader_agentname
			,qreader_agentname = @qreader_agentname
			,worst_runspeedPerf = @worst_runspeedPerf
			,best_runspeedPerf = @best_runspeedPerf
			,average_runspeedPerf = @average_runspeedPerf
		where publisher_db = @publisher_db
			and publication = @publication
			and publication_type = @publication_type
		--
		-- get next row
		--
		fetch #hcrefreshmonitor into @publisher_db, @publication, @publication_type
	end
	close #hcrefreshmonitor
	deallocate #hcrefreshmonitor
	--
	-- populate the threshold values
	-- 
	update #tmp_publicationdata 
	set expirationthreshold = cast(sys.fn_replgetpublicationthreshold(publication_id, @expiration) as int)
		,latencythreshold = cast(sys.fn_replgetpublicationthreshold(publication_id, @latency) as int)
	--
	-- select the result set
	--
	select 
		publisher_db 
		,publication 
		,publication_id
		,publication_type
		,status 
		,warning 
		,worst_latency 
		,best_latency 
		,average_latency 
		,last_distsync 
		,retention 
		,latencythreshold 
		,expirationthreshold 
		,agentnotrunningthreshold 
		,subscriptioncount 
		,runningdistagentcount 
		,snapshot_agentname
		,logreader_agentname
		,qreader_agentname
		,worst_runspeedPerf
		,best_runspeedPerf
		,average_runspeedPerf
		,retention_period_unit
		,publisher
	from #tmp_publicationdata
	order by publisher, publisher_db, publication, publication_type
	--
	-- all done
	--
	return 0
end
GO
GRANT EXECUTE ON [sys].[sp_replmonitorhelppublication] TO [public] AS [dbo]
GO
