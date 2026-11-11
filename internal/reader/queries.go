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

	// What the publisher says about itself and the publication database: the
	// distributor registered at the publisher, then the state of the database.
	// The linked server is always named repl_distributor; the distributor
	// instance is its datasource (sp_adddistributor.sql:148-154,
	// sp_helpdistributor.sql:115-120). Run on master: a connection to an
	// offline or restoring database fails before any query.
	qProbe = `
SELECT ISNULL((SELECT TOP (1) datasource FROM master.dbo.sysservers WHERE srvstatus & 8 <> 0), N''),
       state_desc, is_in_standby, is_published, is_merge_published
FROM sys.databases WHERE name = @p1`

	// sp_replicationdboption 'sync with backup'; NULL when the database is not
	// found.
	qSyncWithBackup = `SELECT CAST(DATABASEPROPERTYEX(@p1, N'IsSyncWithBackup') AS int)`

	// What the publisher records about the distributor: the linked server
	// repl_distributor and its login mappings, lowest local principal first
	// (0 is the mapping for every login). sys.sp_adddistributor builds
	// provider_string through sys.fn_getproviderstring, then appends
	// MultiSubnetFailover=Yes; when asked.
	qDistributorLink = `
SELECT s.provider_string,
       CAST(l.uses_self_credential AS int),
       l.remote_name
FROM sys.servers AS s
LEFT JOIN sys.linked_logins AS l
       ON l.server_id = s.server_id AND l.local_principal_id = 0 -- the mapping for all logins
WHERE s.name = N'repl_distributor'`

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
       CAST(a.filter_clause AS nvarchar(max)),
       ISNULL(OBJECT_SCHEMA_NAME(NULLIF(a.filter, 0)), N''), ISNULL(OBJECT_NAME(NULLIF(a.filter, 0)), N''),
       ISNULL(a.sync_objid, 0), a.objid,
       ISNULL(OBJECT_SCHEMA_NAME(NULLIF(a.sync_objid, 0)), N''), ISNULL(OBJECT_NAME(NULLIF(a.sync_objid, 0)), N''),
       ISNULL(a.creation_script, N''),
       CAST(ISNULL(a.fire_triggers_on_snapshot, 0) AS int),
       (SELECT COUNT(*) FROM sys.columns AS c WHERE c.object_id = a.objid),
       CASE WHEN a.sync_objid IS NULL OR a.sync_objid = 0 OR a.sync_objid = a.objid THEN NULL
            ELSE OBJECT_DEFINITION(a.sync_objid) END,
       CASE WHEN a.sync_objid IS NULL OR a.sync_objid = 0 OR a.sync_objid = a.objid THEN 0 ELSE 1 END
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
       CAST(ISNULL(trusted, 0) AS int), ISNULL(publisher_type, N''),
       CASE WHEN storage_connection_string IS NULL THEN 0 ELSE 1 END
FROM msdb.dbo.MSdistpublishers
WHERE UPPER(name) = UPPER(@p1)`

	qDistributionDB = `
SELECT min_distretention, max_distretention, history_retention,
       ISNULL(deletebatchsize_xact, 0), ISNULL(deletebatchsize_cmd, 0)
FROM msdb.dbo.MSdistributiondbs
WHERE name = @p1`

	// The first data file (type 0) and the first log file (type 1) of the
	// distribution database.
	qDistributionFiles = `
SELECT type, physical_name
FROM sys.master_files
WHERE database_id = DB_ID(@p1) AND type IN (0, 1)
ORDER BY type, file_id`

	qDistributorProperties = `
SELECT property, ISNULL(CAST(value AS nvarchar(4000)), N'')
FROM msdb.dbo.MSdistributor
ORDER BY property`

	// MSreplservers exists since SQL Server 2016 SP2 CU3 and 2017 CU6.
	// The table name is passed as a parameter, not spliced into the literal.
	qHasReplServers = `SELECT CASE WHEN OBJECT_ID(@p1) IS NULL THEN 0 ELSE 1 END`

	// fallbackServers replaces MSreplservers on older distributors.
	fallbackServers = `(SELECT server_id AS srvid, name AS srvname FROM master.sys.servers)`

	// MSsubscriber_info.publisher and subscriber differ in case from the
	// server names on the lab.
	qSubscriberType = `
SELECT TOP (1) CAST(type AS int)
FROM {dist}.dbo.MSsubscriber_info
WHERE UPPER(publisher) = UPPER(@p1) AND UPPER(subscriber) = UPPER(@p2)
ORDER BY type`

	qServerID = `SELECT rs.srvid FROM {servers} AS rs WHERE UPPER(rs.srvname) = UPPER(@p1)`

	qLogReaderAgent = `
SELECT msla.name, CAST(ISNULL(msla.publisher_security_mode, 1) AS int), ISNULL(msla.publisher_login, N''),
       ISNULL(msla.profile_id, 0),
       ISNULL(CONVERT(nvarchar(36), CONVERT(uniqueidentifier, msla.job_id)), N''),
       ISNULL(CONVERT(nvarchar(36), msla.job_step_uid), N''),
       ISNULL(msla.job_login, N'')
FROM {dist}.dbo.MSlogreader_agents AS msla
WHERE msla.publisher_id = @p1 AND msla.publisher_db = @p2
ORDER BY msla.name`

	qSnapshotAgents = `
SELECT mssa.publication, CAST(ISNULL(mssa.publisher_security_mode, 1) AS int), ISNULL(mssa.publisher_login, N''),
       ISNULL(mssa.profile_id, 0),
       ISNULL(CONVERT(nvarchar(36), CONVERT(uniqueidentifier, mssa.job_id)), N''),
       ISNULL(CONVERT(nvarchar(36), mssa.job_step_uid), N''),
       ISNULL(mssa.job_login, N'')
FROM {dist}.dbo.MSsnapshot_agents AS mssa
WHERE mssa.publisher_id = @p1 AND mssa.publisher_db = @p2
  -- sp_addpublication registers a row with local_job = 0 and a job_id of a
  -- job that was never created; the agent exists once sp_addpublication_snapshot
  -- has run (measured, lab/README.md).
  AND mssa.local_job = 1
ORDER BY mssa.publication`

	// A shared agent has publication = N'ALL'
	// (sp_MSenumdistributionagentproperties.sql:57-64).
	qDistributionAgents = `
SELECT msda.publication, rs.srvname, msda.subscriber_db, msda.subscription_type,
       CAST(ISNULL(msda.subscriber_security_mode, 1) AS int), ISNULL(msda.subscriber_login, N''),
       ISNULL(msda.profile_id, 0),
       ISNULL(CONVERT(nvarchar(36), CONVERT(uniqueidentifier, msda.job_id)), N''),
       ISNULL(CONVERT(nvarchar(36), msda.job_step_uid), N''),
       ISNULL(msda.subscriptionstreams, 0), CAST(ISNULL(msda.memory_optimized, 0) AS int),
       ISNULL(msda.job_login, N'')
FROM {dist}.dbo.MSdistribution_agents AS msda
JOIN {servers} AS rs ON rs.srvid = msda.subscriber_id
WHERE msda.publisher_id = @p1 AND msda.publisher_db = @p2 AND msda.subscriber_id >= 0
ORDER BY msda.publication, rs.srvname, msda.subscriber_db`

	// The job_id kept by the replication tables can outlive a deleted job
	// (sp_MSenumdistributionagentproperties.sql:78-93): no row means no job.
	// When the recorded step uid is missing or matches no step of the job,
	// the replication step is found by its subsystem. The last column tells
	// whether a step was found at all.
	qJob = `
SELECT TOP (1) sj.name, CAST(sj.enabled AS int), sjs.proxy_id,
       CASE WHEN sp.proxy_id IS NULL THEN 0 ELSE 1 END, sc.credential_identity,
       ISNULL(sjs.command, N''), CASE WHEN sjs.step_id IS NULL THEN 0 ELSE 1 END
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
