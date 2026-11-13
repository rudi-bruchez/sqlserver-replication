package apply

import "strings"

// The reads of the deliveries owed (R50), of the pending check of a
// snapshot start (R49) and of immediate_sync_ready (R47). The queries run
// on the distributor have {dist}, the quoted name of the distribution
// database, and {servers}, the server name table; distQuery substitutes
// them as internal/reader's exporter.distQuery does (copied, since apply
// does not import the reader). The queries run at the publisher run in the
// publication database.

// fallbackServers replaces MSreplservers on distributors older than 2016
// SP2 CU3, copied from internal/reader/queries.go: whether the table
// exists is read (qReplServersProbe, error 208), never guessed from the
// version.
const fallbackServers = `(SELECT server_id AS srvid, name AS srvname FROM master.sys.servers)`

// msg208 is "Invalid object name": MSreplservers is absent.
const msg208 = 208

// distQuery substitutes {dist} with the quoted name of the distribution
// database and {servers} with servers, or with that database's
// MSreplservers when servers is empty.
func distQuery(q, distributionDB, servers string) string {
	dist := quoteName(distributionDB)
	if servers == "" {
		servers = dist + ".dbo.MSreplservers"
	}
	return strings.NewReplacer("{dist}", dist, "{servers}", servers).Replace(q)
}

const (
	// Whether the distribution database has MSreplservers: error 208 is
	// absence (internal/reader, replServersExist).
	qReplServersProbe = `SELECT TOP (0) srvid FROM {dist}.dbo.MSreplservers`

	// T and the mark, in one statement (Task 3 review): T is GETDATE() at
	// the distributor, a datetime as MSdistribution_history.time is (a
	// datetime2 T lost a row to rounding, panel XN); the mark is the
	// highest rowversion of the history, 0 for an empty history. A history
	// row is (agent_id, timestamp): the table has no id column.
	qTMark = `
SELECT GETDATE(), ISNULL(MAX(h.[timestamp]), 0x0000000000000000)
FROM {dist}.dbo.MSdistribution_history AS h`

	// The distribution agent of a subscription (R50): its
	// MSdistribution_agents row by publisher, publisher database,
	// subscriber, subscriber database, and the publication or N'ALL' for a
	// shared agent; the servers named through {servers}, whose ids are the
	// distributor's. @p1 publisher, @p2 publisher database, @p3 subscriber,
	// @p4 subscriber database, @p5 publication.
	qAgentRow = `
SELECT a.id
FROM {dist}.dbo.MSdistribution_agents AS a
JOIN {servers} AS ps ON ps.srvid = a.publisher_id
JOIN {servers} AS ss ON ss.srvid = a.subscriber_id
WHERE UPPER(ps.srvname) = UPPER(@p1) AND a.publisher_db = @p2
  AND UPPER(ss.srvname) = UPPER(@p3) AND a.subscriber_db = @p4
  AND (a.publication = @p5 OR a.publication = N'ALL') AND a.subscriber_id >= 0
ORDER BY a.id`

	// The "Delivered snapshot" lines of an agent above a mark. time >= T
	// is compared in Go, on two values the driver decoded from the same
	// datetime type, never on a parameter the server would convert. @p1
	// agent id, @p2 mark.
	qHistoryAfter = `
SELECT h.agent_id, h.[timestamp], h.[time], ISNULL(h.comments, N'')
FROM {dist}.dbo.MSdistribution_history AS h
WHERE h.agent_id = @p1 AND h.[timestamp] > @p2 AND h.comments LIKE N'Delivered snapshot%'
ORDER BY h.[timestamp]`

	// The MSsubscriptions statuses of a subscription (concurrent and
	// concurrent_c, R50): its own rows (subscriber_id >= 0), joined to
	// MSpublications on publisher id, database and publication id. @p1
	// publisher, @p2 publisher database, @p3 publication, @p4 subscriber,
	// @p5 subscriber database.
	qDistSubStatus = `
SELECT CAST(mss.status AS int)
FROM {dist}.dbo.MSsubscriptions AS mss
JOIN {dist}.dbo.MSpublications AS msp
     ON msp.publisher_id = mss.publisher_id AND msp.publisher_db = mss.publisher_db
    AND msp.publication_id = mss.publication_id
JOIN {servers} AS ps ON ps.srvid = mss.publisher_id
JOIN {servers} AS ss ON ss.srvid = mss.subscriber_id
WHERE UPPER(ps.srvname) = UPPER(@p1) AND mss.publisher_db = @p2 AND msp.publication = @p3
  AND UPPER(ss.srvname) = UPPER(@p4) AND mss.subscriber_db = @p5 AND mss.subscriber_id >= 0`

	// The last history row of an agent, for the unconfirmed line (R53):
	// its rowversion, to keep the latest of several agents, and its
	// comments. @p1 agent id.
	qLastHistory = `
SELECT TOP (1) h.[timestamp], ISNULL(h.comments, N'')
FROM {dist}.dbo.MSdistribution_history AS h
WHERE h.agent_id = @p1
ORDER BY h.[timestamp] DESC`

	// The state of an agent's job at the distributor, for the unconfirmed
	// line (R53): running by plan.JobIdle's test, idle, or unknown when
	// msdb has no such job there (a pull agent's job is at its
	// subscriber). @p1 agent id.
	qAgentJobState = `
SELECT CASE
  WHEN j.job_id IS NULL THEN N'unknown'
  WHEN EXISTS (SELECT 1 FROM msdb.dbo.sysjobactivity AS ja
               WHERE ja.job_id = j.job_id
                 AND ja.session_id = (SELECT MAX(ss.session_id) FROM msdb.dbo.syssessions AS ss)
                 AND (ja.run_requested_date IS NOT NULL OR ja.start_execution_date IS NOT NULL)
                 AND ja.stop_execution_date IS NULL) THEN N'running'
  ELSE N'idle' END
FROM {dist}.dbo.MSdistribution_agents AS a
LEFT JOIN msdb.dbo.sysjobs AS j ON j.job_id = CAST(a.job_id AS uniqueidentifier)
WHERE a.id = @p1`

	// The listing of a snapshot root (R50, Task 3 row DL.listing):
	// recursive, 0 rows and no error for a folder missing, unreadable or
	// unreachable. Only the columns the folder rule uses. @p1 the root.
	qListing = `
SELECT full_filesystem_path, parent_directory, file_or_directory_name, CAST(is_directory AS int)
FROM sys.dm_os_enumerate_filesystem(@p1, N'*')`

	// The publisher's working_directory at the distributor (R50b), read at
	// T for a publication whose plan gives no snapshot root: the file
	// omitted working_directory, and the distributor took its default. The
	// name compares without regard to case. @p1 the publisher.
	qPublisherRoot = `
SELECT working_directory FROM msdb.dbo.MSdistpublishers WHERE UPPER(name) = UPPER(@p1)`

	// The failed outcome of a run of a snapshot job that started at or
	// after T (R51a): the job outcome row (step_id 0) with run_status 0,
	// its start read through msdb.dbo.agent_datetime and compared on the
	// distributor with T truncated to the second, since run_date and
	// run_time have no fraction. It follows the job lookup, which sets
	// @job_id (failureQuery). The latest such row: its start, its message,
	// and the message of the last failed step (step_id > 0, run_status 0)
	// of the same run, NULL when there is none. A run's step rows are those
	// of the job between the previous step 0 row and its own (instance_id
	// grows with each row written). @p1 T, passed as a datetime.
	qJobFailedAfter = `
SELECT f.started, f.message, s.message
FROM (SELECT TOP (1) h.instance_id, msdb.dbo.agent_datetime(h.run_date, h.run_time) AS started,
             ISNULL(h.message, N'') AS message
      FROM msdb.dbo.sysjobhistory AS h
      WHERE h.job_id = @job_id AND h.step_id = 0 AND h.run_status = 0
        AND msdb.dbo.agent_datetime(h.run_date, h.run_time) >= DATEADD(millisecond, -DATEPART(millisecond, @p1), @p1)
      ORDER BY h.instance_id DESC) AS f
OUTER APPLY (SELECT TOP (1) ISNULL(st.message, N'') AS message
             FROM msdb.dbo.sysjobhistory AS st
             WHERE st.job_id = @job_id AND st.step_id > 0 AND st.run_status = 0
               AND st.instance_id < f.instance_id
               AND st.instance_id > ISNULL((SELECT MAX(p.instance_id) FROM msdb.dbo.sysjobhistory AS p
                                            WHERE p.job_id = @job_id AND p.step_id = 0
                                              AND p.instance_id < f.instance_id), 0)
             ORDER BY st.instance_id DESC) AS s`
)

// Queries run at the publisher, in the publication database.
const (
	// The subscription rows of a publication, its own (srvid >= 0): the
	// statuses marked reads before and after a call, and the S7 read after
	// a subscription's unit (R50). @p1 publication.
	qSubStatus = `
SELECT s.srvname, s.dest_db, a.name, CAST(s.status AS int)
FROM dbo.syssubscriptions AS s
JOIN dbo.sysextendedarticlesview AS a ON a.artid = s.artid
JOIN dbo.syspublications AS p ON p.pubid = a.pubid
WHERE p.name = @p1 AND s.srvid >= 0 AND s.srvname IS NOT NULL AND s.srvname <> N''`

	// pendingQuery tells whether a snapshot is still pending for a
	// publication (R49, R12): a subscription row at status 1, or, without
	// immediate_sync, a subscribed article without the active bit. 1 or 0.
	// @p1 publication.
	pendingQuery = `
SELECT CASE WHEN EXISTS (
  SELECT 1
  FROM dbo.syssubscriptions AS s
  JOIN dbo.sysextendedarticlesview AS a ON a.artid = s.artid
  JOIN dbo.syspublications AS p ON p.pubid = a.pubid
  WHERE p.name = @p1 AND s.srvid >= 0
    AND (s.status = 1 OR (p.immediate_sync = 0 AND a.status & 1 = 0))
) THEN 1 ELSE 0 END`

	// immediate_sync_ready of a publication (R47), 0 when NULL. @p1
	// publication.
	qImmediateSyncReady = `
SELECT CAST(ISNULL(p.immediate_sync_ready, 0) AS int)
FROM dbo.syspublications AS p
WHERE p.name = @p1`

	// The sync_method code of a publication: 3 concurrent, 4 concurrent_c
	// (internal/decode). @p1 publication.
	qSyncMethod = `
SELECT CAST(p.sync_method AS int)
FROM dbo.syspublications AS p
WHERE p.name = @p1`
)

// applyQueries is every query of this file by name, for the tests.
func applyQueries() map[string]string {
	return map[string]string{
		"qReplServersProbe": qReplServersProbe, "qTMark": qTMark, "qAgentRow": qAgentRow,
		"qHistoryAfter": qHistoryAfter, "qDistSubStatus": qDistSubStatus, "qListing": qListing,
		"qPublisherRoot": qPublisherRoot,
		// It follows a job lookup, which declares @job_id.
		"qJobFailedAfter": "DECLARE @job_id uniqueidentifier;\n" + qJobFailedAfter,
		"qLastHistory":    qLastHistory, "qAgentJobState": qAgentJobState,
		"qSubStatus": qSubStatus, "pendingQuery": pendingQuery,
		"qImmediateSyncReady": qImmediateSyncReady, "qSyncMethod": qSyncMethod,
	}
}
