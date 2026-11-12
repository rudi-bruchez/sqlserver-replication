-- each operation below is a batch of its own: run them one at a time (sqlrepl apply does); the file does not run as one batch
-- sqlrepl apply may run a job_start again when its job ended before the delivery it owes

-- server repllab
USE [msdb];
-- 1 disable job_disable publications[SalesRef].snapshot_agent: online
DECLARE @job_id uniqueidentifier;
SELECT @job_id = sj.job_id FROM [distribution].dbo.MSsnapshot_agents AS a JOIN [distribution].dbo.MSreplservers AS ps ON ps.srvid = a.publisher_id JOIN msdb.dbo.sysjobs AS sj ON sj.job_id = CONVERT(uniqueidentifier, a.job_id) WHERE UPPER(ps.srvname) = UPPER(N'repllab') AND a.publisher_db = N'Sales' AND a.publication = N'SalesRef' AND a.local_job = 1;
IF @job_id IS NULL THROW 50000, N'the job of publications[SalesRef].snapshot_agent does not exist', 1;
EXEC msdb.dbo.sp_update_job @job_id = @job_id, @enabled = 0;

USE [master];
-- 2 add profile agent_profiles[distribution/m_prof]: online
DECLARE @profile_id int;
EXEC sp_add_agent_profile @profile_id = @profile_id OUTPUT, @profile_name = N'm_prof', @agent_type = 3;

USE [Sales];
-- 3 drop subscription publications[SalesRef].subscriptions[REPLLAB/SalesSub]: online, subscriber_object_left
EXEC sp_dropsubscription @publication = N'SalesRef', @article = N'all', @subscriber = N'REPLLAB', @destination_db = N'SalesSub';

-- 4 drop publication publications[SalesRef]: online, subscriber_object_left
EXEC sp_droppublication @publication = N'SalesRef';

-- 5 add publication publications[m_p]: online
EXEC sp_addpublication @publication = N'm_p', @status = N'active', @independent_agent = N'true';

-- 6 add snapshot_agent publications[m_p].snapshot_agent: online
EXEC sp_addpublication_snapshot @publication = N'm_p';

USE [msdb];
-- 7 disable job_disable publications[m_p].snapshot_agent: online
DECLARE @job_id uniqueidentifier;
SELECT @job_id = sj.job_id FROM [distribution].dbo.MSsnapshot_agents AS a JOIN [distribution].dbo.MSreplservers AS ps ON ps.srvid = a.publisher_id JOIN msdb.dbo.sysjobs AS sj ON sj.job_id = CONVERT(uniqueidentifier, a.job_id) WHERE UPPER(ps.srvname) = UPPER(N'repllab') AND a.publisher_db = N'Sales' AND a.publication = N'm_p' AND a.local_job = 1;
IF @job_id IS NULL THROW 50000, N'the job of publications[m_p].snapshot_agent does not exist', 1;
EXEC msdb.dbo.sp_update_job @job_id = @job_id, @enabled = 0;

USE [Sales];
-- 8 add article publications[m_p].articles[m_t1]: online
EXEC sp_addarticle @publication = N'm_p', @article = N'm_t1', @source_owner = N'dbo', @source_object = N'm_t1';

-- 9 add article_filter publications[m_p].articles[m_t1].filter: online
EXEC sp_articlefilter @publication = N'm_p', @article = N'm_t1', @filter_name = N'[dbo].[m_flt_m_t1]', @filter_clause = N'a > 0';

-- 10 add article_view publications[m_p].articles[m_t1].sync_object: online
EXEC sp_articleview @publication = N'm_p', @article = N'm_t1', @filter_clause = N'a > 0';

-- 11 add article publications[m_p].articles[m_t2]: online
EXEC sp_addarticle @publication = N'm_p', @article = N'm_t2', @source_owner = N'dbo', @source_object = N'm_t2';

-- 12 add subscription publications[m_p].subscriptions[REPLLAB/m_sdb]: new_snapshot
EXEC sp_addsubscription @publication = N'm_p', @article = N'all', @subscriber = N'REPLLAB', @destination_db = N'm_sdb';

-- 13 add push_agent publications[m_p].subscriptions[REPLLAB/m_sdb].distribution_agent: online
EXEC sp_addpushsubscription_agent @publication = N'm_p', @subscriber = N'REPLLAB', @subscriber_db = N'm_sdb';

USE [distribution];
-- 14 change agent_binding publications[m_p].subscriptions[REPLLAB/m_sdb].distribution_agent: online
DECLARE @agent_id int, @profile_id int;
SELECT @agent_id = a.id FROM [distribution].dbo.MSdistribution_agents AS a JOIN [distribution].dbo.MSreplservers AS ps ON ps.srvid = a.publisher_id JOIN [distribution].dbo.MSreplservers AS rs ON rs.srvid = a.subscriber_id WHERE UPPER(ps.srvname) = UPPER(N'repllab') AND a.publisher_db = N'Sales' AND a.publication = N'm_p' AND UPPER(rs.srvname) = UPPER(N'REPLLAB') AND a.subscriber_db = N'm_sdb' AND a.subscription_type = 0;
SELECT @profile_id = profile_id FROM msdb.dbo.MSagent_profiles WHERE profile_name = N'm_prof' AND agent_type = 3;
IF @agent_id IS NULL OR @profile_id IS NULL THROW 50000, N'the agent publications[m_p].subscriptions[REPLLAB/m_sdb].distribution_agent or the profile m_prof (distribution) does not exist', 1;
EXEC [distribution].dbo.sp_update_agent_profile @agent_type = 3, @agent_id = @agent_id, @profile_id = @profile_id;

USE [msdb];
-- 15 restore job_restore publications[SalesRef].snapshot_agent: online
DECLARE @job_id uniqueidentifier;
SELECT @job_id = sj.job_id FROM [distribution].dbo.MSsnapshot_agents AS a JOIN [distribution].dbo.MSreplservers AS ps ON ps.srvid = a.publisher_id JOIN msdb.dbo.sysjobs AS sj ON sj.job_id = CONVERT(uniqueidentifier, a.job_id) WHERE UPPER(ps.srvname) = UPPER(N'repllab') AND a.publisher_db = N'Sales' AND a.publication = N'SalesRef' AND a.local_job = 1;
IF @job_id IS NOT NULL
EXEC msdb.dbo.sp_update_job @job_id = @job_id, @enabled = 1;

-- 16 restore job_restore publications[m_p].snapshot_agent: online
DECLARE @job_id uniqueidentifier;
SELECT @job_id = sj.job_id FROM [distribution].dbo.MSsnapshot_agents AS a JOIN [distribution].dbo.MSreplservers AS ps ON ps.srvid = a.publisher_id JOIN msdb.dbo.sysjobs AS sj ON sj.job_id = CONVERT(uniqueidentifier, a.job_id) WHERE UPPER(ps.srvname) = UPPER(N'repllab') AND a.publisher_db = N'Sales' AND a.publication = N'm_p' AND a.local_job = 1;
IF @job_id IS NULL THROW 50000, N'the job of publications[m_p].snapshot_agent does not exist', 1;
EXEC msdb.dbo.sp_update_job @job_id = @job_id, @enabled = 1;

-- 17 start job_start publications[m_p].snapshot_agent: online
DECLARE @job_id uniqueidentifier;
SELECT @job_id = sj.job_id FROM [distribution].dbo.MSsnapshot_agents AS a JOIN [distribution].dbo.MSreplservers AS ps ON ps.srvid = a.publisher_id JOIN msdb.dbo.sysjobs AS sj ON sj.job_id = CONVERT(uniqueidentifier, a.job_id) WHERE UPPER(ps.srvname) = UPPER(N'repllab') AND a.publisher_db = N'Sales' AND a.publication = N'm_p' AND a.local_job = 1;
IF @job_id IS NULL THROW 50000, N'the job of publications[m_p].snapshot_agent does not exist', 1;
DECLARE @started bit = 0, @rc int;
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobactivity AS ja WHERE ja.job_id = @job_id AND ja.session_id = (SELECT MAX(ss.session_id) FROM msdb.dbo.syssessions AS ss) AND (ja.run_requested_date IS NOT NULL OR ja.start_execution_date IS NOT NULL) AND ja.stop_execution_date IS NULL)
BEGIN
EXEC @rc = msdb.dbo.sp_start_job @job_id = @job_id;
SET @started = CASE WHEN @rc = 0 THEN 1 ELSE 0 END;
END;
SELECT @started AS started;

-- 18 start job_start publications[m_p].subscriptions[REPLLAB/m_sdb].distribution_agent: online
DECLARE @job_id uniqueidentifier;
SELECT @job_id = sj.job_id FROM [distribution].dbo.MSdistribution_agents AS a JOIN [distribution].dbo.MSreplservers AS ps ON ps.srvid = a.publisher_id JOIN [distribution].dbo.MSreplservers AS rs ON rs.srvid = a.subscriber_id JOIN msdb.dbo.sysjobs AS sj ON sj.job_id = CONVERT(uniqueidentifier, a.job_id) WHERE UPPER(ps.srvname) = UPPER(N'repllab') AND a.publisher_db = N'Sales' AND a.publication = N'm_p' AND UPPER(rs.srvname) = UPPER(N'REPLLAB') AND a.subscriber_db = N'm_sdb' AND a.subscription_type = 0;
IF @job_id IS NULL THROW 50000, N'the job of publications[m_p].subscriptions[REPLLAB/m_sdb].distribution_agent does not exist', 1;
DECLARE @started bit = 0, @rc int;
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobactivity AS ja WHERE ja.job_id = @job_id AND ja.session_id = (SELECT MAX(ss.session_id) FROM msdb.dbo.syssessions AS ss) AND (ja.run_requested_date IS NOT NULL OR ja.start_execution_date IS NOT NULL) AND ja.stop_execution_date IS NULL)
BEGIN
EXEC @rc = msdb.dbo.sp_start_job @job_id = @job_id;
SET @started = CASE WHEN @rc = 0 THEN 1 ELSE 0 END;
END;
SELECT @started AS started;
