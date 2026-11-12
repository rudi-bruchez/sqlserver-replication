package reader

import (
	"fmt"
	"strings"
)

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
       state_desc, is_in_standby, is_published, is_merge_published, name
FROM sys.databases WHERE name = @p1`

	// sp_replicationdboption 'sync with backup'; NULL when the database is not
	// found.
	qSyncWithBackup = `SELECT CAST(DATABASEPROPERTYEX(@p1, N'IsSyncWithBackup') AS int)`

	// What the publisher records about the distributor: the linked server
	// repl_distributor and its login mappings, lowest local principal first
	// (0 is the mapping for every login). sys.sp_adddistributor builds
	// provider_string through sys.fn_getproviderstring, then appends
	// MultiSubnetFailover=Yes; when asked. provider_string is NULL and
	// sys.linked_logins has no row for a login without ALTER ANY LINKED
	// SERVER (measured, SQL Server 2022 CU27), hence the last column.
	qDistributorLink = `
SELECT s.provider_string,
       CAST(l.uses_self_credential AS int),
       l.remote_name,
       HAS_PERMS_BY_NAME(NULL, NULL, N'ALTER ANY LINKED SERVER')
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
       ISNULL(a.filter, 0),
       ISNULL(a.sync_objid, 0), a.objid,
       ISNULL(OBJECT_SCHEMA_NAME(NULLIF(a.sync_objid, 0)), N''), ISNULL(OBJECT_NAME(NULLIF(a.sync_objid, 0)), N''),
       ISNULL(a.creation_script, N''),
       CAST(ISNULL(a.fire_triggers_on_snapshot, 0) AS int),
       (SELECT COUNT(*) FROM sys.columns AS c WHERE c.object_id = a.objid),
       CASE WHEN a.sync_objid IS NULL OR a.sync_objid = 0 OR a.sync_objid = a.objid THEN NULL
            ELSE OBJECT_DEFINITION(a.sync_objid) END,
       CASE WHEN a.sync_objid IS NULL OR a.sync_objid = 0 OR a.sync_objid = a.objid THEN 0 ELSE 1 END,
       CASE WHEN EXISTS (SELECT 1 FROM sys.identity_columns AS ic
                         WHERE ic.object_id = a.objid AND ic.is_not_for_replication = 1) THEN 1 ELSE 0 END
FROM dbo.sysarticles AS a`

	// The tables whose identity range the publisher manages
	// (@identityrangemanagementoption = 'auto'). The table only exists in
	// some publication databases. Its absence is told by the query's error
	// 208, not by OBJECT_ID, which returns NULL for a table the login cannot
	// see; a login denied the table gets error 229 (both measured, SQL
	// Server 2022 CU27).
	qAutoIdentityRange = `SELECT objid FROM dbo.MSpub_identity_range`

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

	// Facts: immediate_sync_ready of each publication (spec "Inputs").
	qPublicationFacts = `
SELECT p.name, CAST(ISNULL(p.immediate_sync_ready, 0) AS int)
FROM dbo.syspublications AS p`

	// Facts: bit 0x1 of the article status is set by the snapshot generation.
	// A schema article has it too: 16 after sp_addarticle, 17 after the
	// generation, 16 after sp_reinitsubscription, like a table article
	// (measured by two reviewers, SQL Server 2022 CU27).
	qArticleFacts = `
SELECT a.pubid, a.name, a.status & 1 FROM dbo.sysarticles AS a
UNION ALL
SELECT a.pubid, a.name, a.status & 1 FROM dbo.sysschemaarticles AS a`

	// Facts: the status of each article of each real subscription, at the
	// publisher. Status 3 (active, the snapshot delivered) is only ever read
	// in MSsubscriptions (O18).
	qSubscriptionStatus = `
SELECT a.pubid, a.name, s.srvname, s.dest_db, CAST(s.status AS int)
FROM dbo.syssubscriptions AS s
JOIN dbo.sysextendedarticlesview AS a ON a.artid = s.artid
WHERE s.srvid >= 0 AND s.srvname IS NOT NULL AND s.srvname <> N''`
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

	// The version of the distributor instance, which decides whether its
	// distribution databases have MSreplservers (replServersSince). The table
	// is not probed with OBJECT_ID: it returns NULL for a table the login
	// cannot see (measured with DENY SELECT, SQL Server 2022 CU27), and the
	// fallback would then name the servers from master.sys.servers, whose ids
	// differ.
	qDistributorVersion = `SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128))`

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
SELECT msla.id, msla.name, CAST(ISNULL(msla.publisher_security_mode, 1) AS int), ISNULL(msla.publisher_login, N''),
       ISNULL(msla.profile_id, 0),
       ISNULL(CONVERT(nvarchar(36), CONVERT(uniqueidentifier, msla.job_id)), N''),
       ISNULL(CONVERT(nvarchar(36), msla.job_step_uid), N''),
       ISNULL(msla.job_login, N'')
FROM {dist}.dbo.MSlogreader_agents AS msla
WHERE msla.publisher_id = @p1 AND msla.publisher_db = @p2
ORDER BY msla.name`

	qSnapshotAgents = `
SELECT mssa.id, mssa.publication, CAST(ISNULL(mssa.publisher_security_mode, 1) AS int), ISNULL(mssa.publisher_login, N''),
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
SELECT msda.id, msda.publication, rs.srvname, msda.subscriber_db, msda.subscription_type,
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

	// Facts: every time is written as 2006-01-02 15:04:05.000, through
	// timeOpen + expression + timeClose. Style 126 drops the fraction of a
	// datetime whose milliseconds are 0 and gives 7 digits for SYSDATETIME;
	// style 121 on a datetime2(3) always gives three.
	timeOpen  = `CONVERT(nvarchar(23), CAST(`
	timeClose = ` AS datetime2(3)), 121)`

	// Facts: the time the facts are read, at the distributor.
	qReadAt = `SELECT ` + timeOpen + `SYSDATETIME()` + timeClose

	// Facts: MSsubscriptions.status of the subscriptions' own rows. The
	// virtual subscribers (subscriber_id -1 and -2) are left out: the window
	// of the -1 row moves at every run (spec "Inputs"). The subscriber is
	// named through the server table, whose ids differ from the publisher's
	// srvid.
	qDistributorSubscriptionStatus = `
SELECT msp.publication, msa.article, rs.srvname, mss.subscriber_db, CAST(mss.status AS int)
FROM {dist}.dbo.MSsubscriptions AS mss
JOIN {dist}.dbo.MSpublications AS msp
     ON msp.publisher_id = mss.publisher_id AND msp.publisher_db = mss.publisher_db
    AND msp.publication_id = mss.publication_id
JOIN {dist}.dbo.MSarticles AS msa
     ON msa.publisher_id = mss.publisher_id AND msa.publisher_db = mss.publisher_db
    AND msa.publication_id = mss.publication_id AND msa.article_id = mss.article_id
JOIN {servers} AS rs ON rs.srvid = mss.subscriber_id
WHERE mss.publisher_id = @p1 AND mss.publisher_db = @p2 AND mss.subscriber_id >= 0`

	// Facts: the end of the latest run of a snapshot agent that generated a
	// snapshot. A run that finds no subscription to initialize ends with
	// runstatus 2 too, "[0%] A snapshot was not generated because no
	// subscriptions needed initialization.", and no column of its rows tells
	// it from a generation: both write runstatus 1, 3 and 2, delivered
	// counts, delivery_rate and error_id are 0 on both final rows, and the
	// generation's delivered_commands is 0 for an empty table (measured on the
	// lab, SQL Server 2022 CU27). The final row's text does; it assumes the
	// agent writes its messages in English.
	qLastGeneration = `
SELECT TOP (1) ` + timeOpen + `h.time` + timeClose + `
FROM {dist}.dbo.MSsnapshot_history AS h
WHERE h.agent_id = @p1 AND h.runstatus = 2 AND h.comments NOT LIKE N'%not generated%'
ORDER BY h.time DESC, h.timestamp DESC`

	// Facts: the latest history row of an agent, or with @p2 = 1 the latest
	// failure (runstatus 6), with the first error of its error_id.
	qHistorySelect = `
SELECT TOP (1) ` + timeOpen + `h.time` + timeClose + `, h.runstatus, ISNULL(h.comments, N''), ISNULL(e.error_text, N'')
FROM {dist}.dbo.`
	qHistoryRest = ` AS h
OUTER APPLY (SELECT TOP (1) x.error_text FROM {dist}.dbo.MSrepl_errors AS x
             WHERE x.id = h.error_id AND h.error_id <> 0
             ORDER BY x.time, x.id) AS e
WHERE h.agent_id = @p1 AND (@p2 = 0 OR h.runstatus = 6)
ORDER BY h.time DESC, h.timestamp DESC`
	qLogReaderHistory    = qHistorySelect + "MSlogreader_history" + qHistoryRest
	qSnapshotHistory     = qHistorySelect + "MSsnapshot_history" + qHistoryRest
	qDistributionHistory = qHistorySelect + "MSdistribution_history" + qHistoryRest

	// Facts: whether a job is enabled and running. A job runs when its
	// sysjobactivity row of the latest Agent session has a start and no stop.
	// No row: the job_id kept by replication outlived the job.
	qJobState = `
SELECT CAST(sj.enabled AS int), ja.start_execution_date, ja.stop_execution_date
FROM msdb.dbo.sysjobs AS sj
OUTER APPLY (SELECT TOP (1) a.start_execution_date, a.stop_execution_date
             FROM msdb.dbo.sysjobactivity AS a
             WHERE a.job_id = sj.job_id
               AND a.session_id = (SELECT TOP (1) ss.session_id FROM msdb.dbo.syssessions AS ss
                                   ORDER BY ss.agent_start_date DESC, ss.session_id DESC)) AS ja
WHERE sj.job_id = CONVERT(uniqueidentifier, @p1)`

	// Facts: every distribution database of the distributor.
	qDistributionDBs = `SELECT name FROM msdb.dbo.MSdistributiondbs ORDER BY name`
)

// profileUsesQuery builds the query of the agents that use a user-defined
// profile (msdb.dbo.MSagent_profiles.type = 1) in every distribution database
// of dbs. The profiles live in msdb and are shared by all of them, so a
// profile used through another distribution database would otherwise read as
// unused. Each branch joins its distribution agents to its own database's
// MSreplservers (or, with useFallback, to fallbackServers), never to
// {servers}, whose srvid values belong to one distribution database. The
// agents of the virtual subscribers (subscriber_id < 0) are kept, flagged in
// the last column: a profile bound to one still matters to a profile drop.
// The first column is the index of the database in dbs. String columns are
// brought to one collation: the databases may differ.
func profileUsesQuery(dbs []string, useFallback bool) string {
	const c = " COLLATE DATABASE_DEFAULT"
	var b strings.Builder
	for i, db := range dbs {
		d := quoteName(db)
		servers := d + ".dbo.MSreplservers"
		if useFallback {
			servers = fallbackServers
		}
		if i > 0 {
			b.WriteString("\nUNION ALL")
		}
		fmt.Fprintf(&b, `
SELECT %[1]d, mp.profile_name%[2]s, mp.agent_type, ISNULL(ps.srvname, N'')%[2]s, a.publisher_db%[2]s,
       N''%[2]s, N''%[2]s, N''%[2]s, 0
FROM %[3]s.dbo.MSlogreader_agents AS a
JOIN msdb.dbo.MSagent_profiles AS mp ON mp.profile_id = a.profile_id AND mp.type = 1
LEFT JOIN %[4]s AS ps ON ps.srvid = a.publisher_id
UNION ALL
SELECT %[1]d, mp.profile_name%[2]s, mp.agent_type, ISNULL(ps.srvname, N'')%[2]s, a.publisher_db%[2]s,
       a.publication%[2]s, N''%[2]s, N''%[2]s, 0
FROM %[3]s.dbo.MSsnapshot_agents AS a
JOIN msdb.dbo.MSagent_profiles AS mp ON mp.profile_id = a.profile_id AND mp.type = 1
LEFT JOIN %[4]s AS ps ON ps.srvid = a.publisher_id
UNION ALL
SELECT %[1]d, mp.profile_name%[2]s, mp.agent_type, ISNULL(ps.srvname, N'')%[2]s, a.publisher_db%[2]s,
       a.publication%[2]s,
       CASE WHEN a.subscriber_id < 0 THEN N'' ELSE ISNULL(rs.srvname, N'') END%[2]s,
       ISNULL(a.subscriber_db, N'')%[2]s,
       CASE WHEN a.subscriber_id < 0 THEN 1 ELSE 0 END
FROM %[3]s.dbo.MSdistribution_agents AS a
JOIN msdb.dbo.MSagent_profiles AS mp ON mp.profile_id = a.profile_id AND mp.type = 1
LEFT JOIN %[4]s AS ps ON ps.srvid = a.publisher_id
LEFT JOIN %[4]s AS rs ON rs.srvid = a.subscriber_id AND a.subscriber_id >= 0`, i, c, d, servers)
	}
	return b.String()
}

// Queries run on a subscriber, connected to master. {subdb} is replaced by the
// quoted name of the subscription database (subscriberQuery).
const (
	// Whether the subscription database exists: 1 yes, 0 no, 2 the login
	// cannot tell. DB_ID returns NULL for an existing database when the
	// login is denied VIEW ANY DATABASE (measured on the lab, SQL Server
	// 2022 CU27), so NULL means "missing" only with that permission. The
	// replication tables are not probed with OBJECT_ID, which returns NULL
	// for a table that metadata visibility hides: the subscriber query tells
	// them by its error 208.
	qDatabaseExists = `
SELECT CASE WHEN DB_ID(@p1) IS NOT NULL THEN 1
            WHEN HAS_PERMS_BY_NAME(NULL, NULL, N'VIEW ANY DATABASE') = 1 THEN 0
            ELSE 2 END`

	// The join of sp_helppullsubscription.sql:94-176, for one publication.
	// Every subscription_type is returned: type 2 (anonymous) is reported,
	// not exported, and may stand beside a type 1 row since the unique index
	// uc1MSReplication_subscriptions includes subscription_type. agent_id is
	// the job id of the agent in the subscriber's msdb.
	qPullSubscription = `
SELECT rs.subscription_type,
       CAST(ISNULL(rs.independent_agent, 0) AS int), CAST(ISNULL(rs.immediate_sync, 0) AS int),
       ISNULL(rs.description, N''),
       ISNULL(CONVERT(nvarchar(36), CONVERT(uniqueidentifier, rs.agent_id)), N''),
       CASE WHEN sp.publication IS NULL THEN 0 ELSE 1 END,
       ISNULL(sp.distributor, N''),
       CAST(ISNULL(sp.distributor_security_mode, 1) AS int), ISNULL(sp.distributor_login, N''),
       ISNULL(sp.alt_snapshot_folder, N''), ISNULL(sp.working_directory, N''),
       CAST(ISNULL(sp.use_ftp, 0) AS int), CAST(ISNULL(sp.enabled_for_syncmgr, 0) AS int),
       ISNULL(CONVERT(nvarchar(36), sp.job_step_uid), N''),
       ISNULL(sp.dts_package_name, N'')
FROM {subdb}.dbo.MSreplication_subscriptions AS rs
LEFT JOIN {subdb}.dbo.MSsubscription_properties AS sp
       ON UPPER(sp.publisher) = UPPER(rs.publisher) AND sp.publisher_db = rs.publisher_db
      AND sp.publication = rs.publication
WHERE UPPER(rs.publisher) = UPPER(@p1) AND rs.publisher_db = @p2 AND rs.publication = @p3
ORDER BY rs.subscription_type`
)
