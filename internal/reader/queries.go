package reader

// Queries run in the publication database, on the publisher.
//
// The objects are read in the publication database only: the distribution
// database holds views with the same names that only cover Oracle publishers
// (stored-procedures/sp_MScreate_dist_tables.sql:2102, :2153, :2214).
//
// Bit columns are cast to int: database/sql cannot scan a bit into an int,
// and some of these columns are nullable.
const (
	qServerName = `SELECT @@SERVERNAME`

	// Distributor registered at the publisher (sp_helpdistributor.sql:115-120).
	// The linked server is always named repl_distributor; the distributor
	// instance is its datasource (sp_adddistributor.sql:148-154,
	// sp_helpdistributor.sql:115-120).
	qDistributorName = `SELECT datasource FROM master.dbo.sysservers WHERE srvstatus & 8 <> 0`

	qPublications = `
SELECT p.pubid, p.name, ISNULL(p.description, N''),
       p.repl_freq, p.status, p.sync_method, ISNULL(p.retention, 0),
       CAST(ISNULL(p.independent_agent, 0) AS int),
       CAST(ISNULL(p.immediate_sync, 0) AS int),
       CAST(ISNULL(p.enabled_for_internet, 0) AS int),
       CAST(ISNULL(p.allow_push, 0) AS int),
       CAST(ISNULL(p.allow_pull, 0) AS int),
       CAST(ISNULL(p.allow_anonymous, 0) AS int),
       CAST(ISNULL(p.allow_sync_tran, 0) AS int),
       CAST(ISNULL(p.allow_queued_tran, 0) AS int),
       CAST(ISNULL(p.allow_dts, 0) AS int),
       CAST(ISNULL(p.allow_subscription_copy, 0) AS int),
       CAST(ISNULL(p.allow_initialize_from_backup, 0) AS int),
       CAST(ISNULL(p.replicate_ddl, 0) AS int),
       ISNULL(p.options, 0),
       CAST(ISNULL(p.snapshot_in_defaultfolder, 1) AS int),
       ISNULL(p.alt_snapshot_folder, N''),
       ISNULL(p.pre_snapshot_script, N''),
       ISNULL(p.post_snapshot_script, N''),
       CAST(ISNULL(p.compress_snapshot, 0) AS int),
       ISNULL(p.ftp_address, N''), ISNULL(p.ftp_port, 0),
       ISNULL(p.ftp_subdirectory, N''), ISNULL(p.ftp_login, N'')
FROM dbo.syspublications AS p
ORDER BY p.name`

	qTableArticles = `
SELECT a.pubid, a.artid, a.name, a.type, a.status, a.pre_creation_cmd, a.schema_option,
       ISNULL(a.description, N''),
       ISNULL(OBJECT_SCHEMA_NAME(a.objid), N''), ISNULL(OBJECT_NAME(a.objid), N''),
       ISNULL(a.dest_owner, N''), ISNULL(a.dest_table, N''),
       ISNULL(a.ins_cmd, N''), ISNULL(a.upd_cmd, N''), ISNULL(a.del_cmd, N''),
       ISNULL(CAST(a.filter_clause AS nvarchar(max)), N''),
       ISNULL(OBJECT_SCHEMA_NAME(NULLIF(a.filter, 0)), N''), ISNULL(OBJECT_NAME(NULLIF(a.filter, 0)), N''),
       ISNULL(a.sync_objid, 0), a.objid,
       ISNULL(OBJECT_SCHEMA_NAME(NULLIF(a.sync_objid, 0)), N''), ISNULL(OBJECT_NAME(NULLIF(a.sync_objid, 0)), N''),
       ISNULL(a.creation_script, N''),
       CAST(ISNULL(a.fire_triggers_on_snapshot, 0) AS int),
       (SELECT COUNT(*) FROM sys.columns AS c WHERE c.object_id = a.objid)
FROM dbo.sysarticles AS a`

	qSchemaArticles = `
SELECT a.pubid, a.artid, a.name, a.type, a.pre_creation_cmd, a.schema_option,
       ISNULL(a.description, N''),
       ISNULL(OBJECT_SCHEMA_NAME(a.objid), N''), ISNULL(OBJECT_NAME(a.objid), N''),
       ISNULL(a.dest_owner, N''), ISNULL(a.dest_object, N''),
       ISNULL(a.creation_script, N'')
FROM dbo.sysschemaarticles AS a`

	// Published columns of table articles, in column order.
	qArticleColumns = `
SELECT ac.artid, c.name
FROM dbo.sysarticlecolumns AS ac
JOIN dbo.sysarticles AS a ON a.artid = ac.artid
JOIN sys.columns AS c ON c.object_id = a.objid AND c.column_id = ac.colid
ORDER BY ac.artid, c.column_id`

	// One row per article and subscriber. srvid -1 and -2 are the virtual
	// subscribers (sp_MSadd_subscription.sql:142-143).
	qSubscriptions = `
SELECT a.pubid, a.name, s.srvname, s.dest_db,
       s.subscription_type, s.sync_type, ISNULL(s.nosync_type, 0),
       ISNULL(s.update_mode, 0), CAST(ISNULL(s.loopback_detection, 0) AS int)
FROM dbo.syssubscriptions AS s
JOIN dbo.sysextendedarticlesview AS a ON a.artid = s.artid
WHERE s.srvid >= 0 AND s.srvname IS NOT NULL AND s.srvname <> N''
ORDER BY a.pubid, s.srvname, s.dest_db, a.name`
)

// Queries run on the distributor. {dist} is replaced by the quoted name of the
// distribution database, {servers} by the server name table (see
// serversTable).
const (
	qDistPublisher = `
SELECT distribution_db, ISNULL(working_directory, N''),
       CAST(ISNULL(security_mode, 1) AS int), ISNULL(login, N''),
       CAST(ISNULL(trusted, 0) AS int), ISNULL(publisher_type, N'')
FROM msdb.dbo.MSdistpublishers
WHERE UPPER(name) = UPPER(@p1)`

	qDistributionDB = `
SELECT min_distretention, max_distretention, history_retention
FROM msdb.dbo.MSdistributiondbs
WHERE name = @p1`

	qDistributorProperties = `
SELECT property, ISNULL(CAST(value AS nvarchar(4000)), N'')
FROM msdb.dbo.MSdistributor
ORDER BY property`

	// MSreplservers exists since SQL Server 2016 SP2 CU3 and 2017 CU6.
	// The table name is passed as a parameter, not spliced into the literal.
	qHasReplServers = `SELECT CASE WHEN OBJECT_ID(@p1) IS NULL THEN 0 ELSE 1 END`

	// fallbackServers replaces MSreplservers on older distributors.
	fallbackServers = `(SELECT server_id AS srvid, name AS srvname FROM master.sys.servers)`

	qServerID = `SELECT rs.srvid FROM {servers} AS rs WHERE UPPER(rs.srvname) = UPPER(@p1)`

	qLogReaderAgent = `
SELECT msla.name, CAST(ISNULL(msla.publisher_security_mode, 1) AS int), ISNULL(msla.publisher_login, N''),
       ISNULL(msla.profile_id, 0),
       ISNULL(CONVERT(nvarchar(36), CONVERT(uniqueidentifier, msla.job_id)), N''),
       ISNULL(CONVERT(nvarchar(36), msla.job_step_uid), N'')
FROM {dist}.dbo.MSlogreader_agents AS msla
WHERE msla.publisher_id = @p1 AND msla.publisher_db = @p2`

	qSnapshotAgents = `
SELECT mssa.publication, CAST(ISNULL(mssa.publisher_security_mode, 1) AS int), ISNULL(mssa.publisher_login, N''),
       ISNULL(mssa.profile_id, 0),
       ISNULL(CONVERT(nvarchar(36), CONVERT(uniqueidentifier, mssa.job_id)), N''),
       ISNULL(CONVERT(nvarchar(36), mssa.job_step_uid), N'')
FROM {dist}.dbo.MSsnapshot_agents AS mssa
WHERE mssa.publisher_id = @p1 AND mssa.publisher_db = @p2`

	// A shared agent has publication = N'ALL'
	// (sp_MSenumdistributionagentproperties.sql:57-64).
	qDistributionAgents = `
SELECT msda.publication, rs.srvname, msda.subscriber_db, msda.subscription_type,
       CAST(ISNULL(msda.subscriber_security_mode, 1) AS int), ISNULL(msda.subscriber_login, N''),
       ISNULL(msda.profile_id, 0),
       ISNULL(CONVERT(nvarchar(36), CONVERT(uniqueidentifier, msda.job_id)), N''),
       ISNULL(CONVERT(nvarchar(36), msda.job_step_uid), N''),
       ISNULL(msda.subscriptionstreams, 0), CAST(ISNULL(msda.memory_optimized, 0) AS int)
FROM {dist}.dbo.MSdistribution_agents AS msda
JOIN {servers} AS rs ON rs.srvid = msda.subscriber_id
WHERE msda.publisher_id = @p1 AND msda.publisher_db = @p2 AND msda.subscriber_id >= 0`

	// The job_id kept by the replication tables can outlive a deleted job
	// (sp_MSenumdistributionagentproperties.sql:78-93): no row means no job.
	// When the recorded step uid is missing or matches no step of the job,
	// the replication step is found by its subsystem. The last column tells
	// whether a step was found at all.
	qJob = `
SELECT TOP (1) sj.name, ISNULL(sc.credential_identity, N''), ISNULL(sjs.command, N''),
       CASE WHEN sjs.step_id IS NULL THEN 0 ELSE 1 END
FROM msdb.dbo.sysjobs AS sj
LEFT JOIN msdb.dbo.sysjobsteps AS sjs
       ON sjs.job_id = sj.job_id
      AND (sjs.step_uid = TRY_CONVERT(uniqueidentifier, @p2)
           OR (NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobsteps AS x
                           WHERE x.job_id = sj.job_id AND x.step_uid = TRY_CONVERT(uniqueidentifier, @p2))
               AND sjs.subsystem IN (N'Snapshot', N'LogReader', N'Distribution')))
LEFT JOIN msdb.dbo.sysproxies AS sp ON sp.proxy_id = sjs.proxy_id
LEFT JOIN sys.credentials AS sc ON sc.credential_id = sp.credential_id
WHERE sj.job_id = CONVERT(uniqueidentifier, @p1)
ORDER BY CASE WHEN sjs.step_uid = TRY_CONVERT(uniqueidentifier, @p2) THEN 0 ELSE 1 END, sjs.step_id`

	qJobSchedules = `
SELECT ss.name, CAST(ss.enabled AS int), ss.freq_type, ss.freq_interval,
       ss.freq_subday_type, ss.freq_subday_interval, ss.freq_relative_interval,
       ss.freq_recurrence_factor, ss.active_start_date, ss.active_end_date,
       ss.active_start_time, ss.active_end_time
FROM msdb.dbo.sysjobschedules AS sjs
JOIN msdb.dbo.sysschedules AS ss ON ss.schedule_id = sjs.schedule_id
WHERE sjs.job_id = CONVERT(uniqueidentifier, @p1)
ORDER BY ss.name`

	qAgentProfiles = `
SELECT profile_id, profile_name, agent_type, type, ISNULL(description, N''), CAST(ISNULL(def_profile, 0) AS int)
FROM msdb.dbo.MSagent_profiles`

	qAgentParameters = `
SELECT profile_id, parameter_name, ISNULL(value, N'')
FROM msdb.dbo.MSagent_parameters
ORDER BY profile_id, parameter_name`
)
