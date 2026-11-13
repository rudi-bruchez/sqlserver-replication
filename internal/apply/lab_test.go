package apply

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"fmt"
	"net/url"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	mssql "github.com/microsoft/go-mssqldb"

	"github.com/rudi-bruchez/sqlserver-replication/internal/plan"
)

// The lab tests of the session, the execution and the lock. They need the
// lab (lab/gotest.sh) and work on the database m_ap_exec, created and
// dropped by each test; no replication object is touched.

const execDB = "m_ap_exec"

// labServer is the server name the tests give the lab pool in Servers.
const labServer = "LAB"

// labDSN is the lab DSN with its database set to master. The test is
// skipped unless SQLREPL_TEST_LAB is set; once it is set, a missing
// SQLREPL_TEST_DSN is a failure, not a skip.
func labDSN(t *testing.T) string {
	t.Helper()
	if os.Getenv("SQLREPL_TEST_LAB") == "" {
		t.Skip("SQLREPL_TEST_LAB not set (run lab/gotest.sh)")
	}
	d := os.Getenv("SQLREPL_TEST_DSN")
	if d == "" {
		t.Fatal("SQLREPL_TEST_LAB is set but SQLREPL_TEST_DSN is not")
	}
	u, err := url.Parse(d)
	if err != nil {
		t.Fatal("SQLREPL_TEST_DSN is not a URL")
	}
	q := u.Query()
	q.Set("database", "master")
	u.RawQuery = q.Encode()
	return u.String()
}

// labPool opens a new pool of the lab, closed at the end of the test. Each
// call is a pool of its own: a session of one pool is never handed to
// another.
func labPool(t *testing.T) *sql.DB {
	t.Helper()
	db, err := sql.Open("sqlserver", labDSN(t))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	return db
}

// labExecDB creates m_ap_exec (dropping a residue first) and drops it at the
// end of the test, on a pool of its own.
func labExecDB(t *testing.T) {
	t.Helper()
	admin := labPool(t)
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	drop := "IF DB_ID(N'" + execDB + "') IS NOT NULL BEGIN ALTER DATABASE [" + execDB + "] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [" + execDB + "]; END"
	if _, err := admin.ExecContext(ctx, drop); err != nil {
		t.Fatalf("drop residue: %v", err)
	}
	if _, err := admin.ExecContext(ctx, "CREATE DATABASE ["+execDB+"]"); err != nil {
		t.Fatalf("create %s: %v", execDB, err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
		defer cancel()
		if _, err := admin.ExecContext(ctx, drop); err != nil {
			t.Errorf("drop %s: %v", execDB, err)
		}
	})
}

// newLabSession is a session over a new pool of the lab under labServer.
func newLabSession(t *testing.T) (*session, *sql.DB) {
	t.Helper()
	db := labPool(t)
	s := newSession(Servers{labServer: db})
	t.Cleanup(s.close)
	return s, db
}

func stmt(database, text string) plan.Statement {
	return plan.Statement{Seq: 1, Server: labServer, Database: database, Text: text}
}

func noSecret(string) (string, bool) { return "", false }

func tranCountOf(t *testing.T, conn *sql.Conn) int {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	var n int
	if err := conn.QueryRowContext(ctx, "SELECT @@TRANCOUNT").Scan(&n); err != nil {
		t.Fatalf("read @@TRANCOUNT: %v", err)
	}
	return n
}

func TestLabExecRollsBack(t *testing.T) {
	labExecDB(t)
	s, _ := newLabSession(t)
	ctx := context.Background()

	err := s.exec(ctx, stmt(execDB, "BEGIN TRAN; RAISERROR(N'm', 16, 1);"), noSecret)
	var me mssql.Error
	if !errors.As(err, &me) || me.Number != 50000 {
		t.Errorf("refused statement: err = %v, want the RAISERROR (50000)", err)
	}
	if !errors.Is(err, errTranOpen) {
		t.Errorf("refused statement that left a transaction: err = %v, want errTranOpen joined", err)
	}
	conn, err := s.conn(ctx, labServer)
	if err != nil {
		t.Fatal(err)
	}
	if n := tranCountOf(t, conn); n != 0 {
		t.Errorf("@@TRANCOUNT after the refused statement = %d, want 0", n)
	}

	err = s.exec(ctx, stmt(execDB, "BEGIN TRAN;"), noSecret)
	if !errors.Is(err, errTranOpen) {
		t.Errorf("BEGIN TRAN alone: err = %v, want errTranOpen", err)
	}
	if n := tranCountOf(t, conn); n != 0 {
		t.Errorf("@@TRANCOUNT after BEGIN TRAN alone = %d, want 0", n)
	}
}

// otherLock tries the lock from a session of another pool, then releases it
// when taken.
func otherLock(t *testing.T, other *sql.DB, resource string) error {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	conn, err := other.Conn(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	err = lock(ctx, conn, execDB, resource)
	if err == nil {
		if uerr := unlock(ctx, conn, execDB, resource); uerr != nil {
			t.Fatalf("release by the other pool: %v", uerr)
		}
	}
	return err
}

func TestLabAppLock(t *testing.T) {
	labExecDB(t)
	const resource = "m_ap lock TestLabAppLock"
	s, _ := newLabSession(t)
	other := labPool(t)
	ctx := context.Background()

	if err := s.lock(ctx, labServer, execDB, resource); err != nil {
		t.Fatalf("lockBatch as written: %v", err)
	}
	if err := otherLock(t, other, resource); !errors.Is(err, errLocked) {
		t.Fatalf("second pool while held: err = %v, want errLocked", err)
	}

	if err := s.exec(ctx, stmt(execDB, "BEGIN TRAN; RAISERROR(N'm', 16, 1);"), noSecret); err == nil {
		t.Fatal("the refused statement succeeded")
	}
	if err := otherLock(t, other, resource); !errors.Is(err, errLocked) {
		t.Fatalf("after a refused call and its rollback: err = %v, want errLocked", err)
	}

	holder, err := s.conn(ctx, labServer)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := holder.ExecContext(ctx, "USE master"); err != nil {
		t.Fatal(err)
	}
	if err := otherLock(t, other, resource); !errors.Is(err, errLocked) {
		t.Fatalf("after USE master on the holder: err = %v, want errLocked", err)
	}

	if err := s.unlock(ctx, labServer, execDB, resource); err != nil {
		t.Fatalf("unlock from master: %v", err)
	}
	if err := otherLock(t, other, resource); err != nil {
		t.Fatalf("second pool after unlock: %v", err)
	}

	if err := s.lock(ctx, labServer, execDB, resource); err != nil {
		t.Fatalf("lock again: %v", err)
	}
	s.close()
	if len(s.releaseFailures) > 0 {
		t.Fatalf("close reported release failures: %v", s.releaseFailures)
	}
	if err := otherLock(t, other, resource); err != nil {
		t.Fatalf("second pool after close, the holder's pool open: %v", err)
	}
}

// sessionGone reads, from another pool, whether the connection whose
// connection_id is id is still listed, waiting up to ten seconds for it to
// go. The connection_id, not the spid: a spid is reused at once, possibly
// by the reading session itself.
func sessionGone(t *testing.T, other *sql.DB, id string) bool {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		var n int
		err := other.QueryRowContext(ctx, "SELECT COUNT(*) FROM sys.dm_exec_connections WHERE CONVERT(nvarchar(36), connection_id) = @id", sql.Named("id", id)).Scan(&n)
		cancel()
		if err != nil {
			t.Fatalf("read sys.dm_exec_connections: %v", err)
		}
		if n == 0 {
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(200 * time.Millisecond)
	}
}

func TestLabUnlockFailureDiscards(t *testing.T) {
	labExecDB(t)
	const resource = "m_ap lock TestLabUnlockFailureDiscards"
	s, _ := newLabSession(t)
	other := labPool(t)
	ctx := context.Background()

	if err := s.lock(ctx, labServer, execDB, resource); err != nil {
		t.Fatalf("lock: %v", err)
	}
	holder, err := s.conn(ctx, labServer)
	if err != nil {
		t.Fatal(err)
	}
	var spid int
	var id string
	if err := holder.QueryRowContext(ctx, "SELECT @@SPID, CONVERT(nvarchar(36), connection_id) FROM sys.dm_exec_connections WHERE session_id = @@SPID").Scan(&spid, &id); err != nil {
		t.Fatal(err)
	}

	err = s.unlock(ctx, labServer, "master", resource)
	if _, n := classify(err); n != 1223 {
		t.Fatalf("unlock in master: err = %v, want Msg 1223", err)
	}
	s.close()
	if len(s.releaseFailures) != 1 || !strings.Contains(s.releaseFailures[0], "1223") {
		t.Errorf("close kept the failure as %q, want the 1223 release", s.releaseFailures)
	}
	if !sessionGone(t, other, id) {
		t.Errorf("the connection of session %d is still listed in sys.dm_exec_connections after close: discard did not end it", spid)
	}
	if err := otherLock(t, other, resource); err != nil {
		t.Errorf("second pool after the discard, the first pool open: %v", err)
	}
}

func TestLabCancelDuringStatement(t *testing.T) {
	labExecDB(t)
	s, _ := newLabSession(t)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()

	start := time.Now()
	err := s.exec(ctx, stmt(execDB, "BEGIN TRAN; WAITFOR DELAY '00:00:10';"), noSecret)
	t.Logf("cancelled exec returned after %v: %v", time.Since(start).Round(time.Millisecond), err)
	if err == nil {
		t.Fatal("the cancelled statement succeeded")
	}

	pinned, cerr := s.conn(context.Background(), labServer)
	if cerr != nil {
		t.Fatal(cerr)
	}
	probe, pcancel := context.WithTimeout(context.Background(), 30*time.Second)
	var one int
	perr := pinned.QueryRowContext(probe, "SELECT 1").Scan(&one)
	pcancel()
	if perr == nil {
		t.Log("cancelled conn: usable")
	} else {
		t.Logf("cancelled conn: bad connection (%v)", perr)
	}

	conn, replaced, err := s.healthy(context.Background(), labServer)
	if err != nil {
		t.Fatalf("healthy: %v", err)
	}
	t.Logf("healthy replaced the conn: %t", replaced)
	if n := tranCountOf(t, conn); n != 0 {
		t.Errorf("@@TRANCOUNT on the conn healthy gives = %d, want 0", n)
	}
}

func TestLabSecretBinding(t *testing.T) {
	labExecDB(t)
	s, _ := newLabSession(t)
	ctx := context.Background()
	st := stmt(execDB, "IF @secret_1 <> N'a''b;c--d' THROW 50000, N'm', 1;")
	st.Secrets = []plan.StatementSecret{{Var: "@secret_1", Name: "SQLREPL_SQL_M"}}

	right := func(name string) (string, bool) { return "a'b;c--d", name == "SQLREPL_SQL_M" }
	if err := s.exec(ctx, st, right); err != nil {
		t.Errorf("the expected value failed: %v", err)
	}
	wrong := func(name string) (string, bool) { return "other", name == "SQLREPL_SQL_M" }
	err := s.exec(ctx, st, wrong)
	if _, n := classify(err); n != 50000 {
		t.Errorf("another value: err = %v, want 50000", err)
	}
}

// countingConnector wraps the driver's connector and counts the USE
// statements its connections prepare (database/sql prepares every ExecContext
// of go-mssqldb, which has no ExecerContext).
type countingConnector struct {
	driver.Connector
	uses *atomic.Int32
}

func (c countingConnector) Connect(ctx context.Context) (driver.Conn, error) {
	conn, err := c.Connector.Connect(ctx)
	if err != nil {
		return nil, err
	}
	return countingConn{conn.(*mssql.Conn), c.uses}, nil
}

type countingConn struct {
	*mssql.Conn
	uses *atomic.Int32
}

func (c countingConn) count(query string) {
	if strings.HasPrefix(strings.ToUpper(strings.TrimSpace(query)), "USE ") {
		c.uses.Add(1)
	}
}

func (c countingConn) Prepare(query string) (driver.Stmt, error) {
	c.count(query)
	return c.Conn.Prepare(query)
}

func (c countingConn) PrepareContext(ctx context.Context, query string) (driver.Stmt, error) {
	c.count(query)
	return c.Conn.PrepareContext(ctx, query)
}

func TestLabExecUseOnChange(t *testing.T) {
	labExecDB(t)
	connector, err := mssql.NewConnector(labDSN(t))
	if err != nil {
		t.Fatal(err)
	}
	var uses atomic.Int32
	db := sql.OpenDB(countingConnector{connector, &uses})
	t.Cleanup(func() { db.Close() })
	s := newSession(Servers{labServer: db})
	t.Cleanup(s.close)
	ctx := context.Background()

	for i := 0; i < 3; i++ {
		if err := s.exec(ctx, stmt(execDB, "SELECT 1;"), noSecret); err != nil {
			t.Fatalf("statement %d in %s: %v", i+1, execDB, err)
		}
	}
	if err := s.exec(ctx, stmt("master", "SELECT 1;"), noSecret); err != nil {
		t.Fatalf("statement in master: %v", err)
	}
	if n := uses.Load(); n != 2 {
		t.Errorf("USE statements = %d, want 2", n)
	}
}

// A statement that binds a secret runs through sp_executesql, where a
// changed @@TRANCOUNT adds Msg 266 after the real error (Task 6 review
// P1a to P1c).
func TestLabSecretRefusalNumber(t *testing.T) {
	labExecDB(t)
	s, _ := newLabSession(t)
	ctx := context.Background()
	secret := func(name string) (string, bool) { return "m-value", name == "SQLREPL_SQL_M" }
	bound := func(text string) plan.Statement {
		st := stmt(execDB, "DECLARE @v nvarchar(100) = @secret_1; "+text)
		st.Secrets = []plan.StatementSecret{{Var: "@secret_1", Name: "SQLREPL_SQL_M"}}
		return st
	}

	err := s.exec(ctx, bound("BEGIN TRAN; RAISERROR(21854, 16, 1);"), secret)
	var raw mssql.Error
	if errors.As(err, &raw) {
		t.Logf("driver Number %d, entries %d", raw.Number, len(raw.All))
	}
	if c, n := classify(err); c != classGenerating || n != 21854 {
		t.Errorf("refused inside sp_executesql: classify = (%d, %d), want classGenerating 21854; err = %v", c, n, err)
	}
	if !errors.Is(err, errTranOpen) {
		t.Errorf("refused with a transaction open: err = %v, want errTranOpen joined", err)
	}
	if e, ok := driverError(err); !ok || e.Number != 21854 {
		t.Errorf("driverError = %d, want 21854 for the printed failure", e.Number)
	}

	err = s.exec(ctx, bound("BEGIN TRAN;"), secret)
	if !errors.Is(err, errTranOpen) {
		t.Errorf("success that left a transaction inside sp_executesql: err = %v, want errTranOpen", err)
	}
	if _, n := classify(err); n == 266 {
		t.Errorf("the success came back as 266: %v", err)
	}
	conn, err := s.conn(ctx, labServer)
	if err != nil {
		t.Fatal(err)
	}
	if n := tranCountOf(t, conn); n != 0 {
		t.Errorf("@@TRANCOUNT afterwards = %d, want 0", n)
	}
}

func TestLabLockTwice(t *testing.T) {
	labExecDB(t)
	const resource = "m_ap lock TestLabLockTwice"
	s, _ := newLabSession(t)
	other := labPool(t)
	ctx := context.Background()

	for i := 0; i < 2; i++ {
		if err := s.lock(ctx, labServer, execDB, resource); err != nil {
			t.Fatalf("lock %d: %v", i+1, err)
		}
	}
	if len(s.locks) != 1 {
		t.Errorf("the session records %d locks, want 1", len(s.locks))
	}
	if err := s.unlock(ctx, labServer, execDB, resource); err != nil {
		t.Fatalf("unlock: %v", err)
	}
	if err := otherLock(t, other, resource); err != nil {
		t.Errorf("second pool after one unlock of a lock taken twice: %v", err)
	}
}

func TestLabCloseAfterKill(t *testing.T) {
	labExecDB(t)
	const resource = "m_ap lock TestLabCloseAfterKill"
	s, _ := newLabSession(t)
	other := labPool(t)
	ctx := context.Background()

	if err := s.lock(ctx, labServer, execDB, resource); err != nil {
		t.Fatalf("lock: %v", err)
	}
	holder, err := s.conn(ctx, labServer)
	if err != nil {
		t.Fatal(err)
	}
	var spid int
	if err := holder.QueryRowContext(ctx, "SELECT @@SPID").Scan(&spid); err != nil {
		t.Fatal(err)
	}
	if _, err := other.ExecContext(ctx, fmt.Sprintf("KILL %d;", spid)); err != nil {
		t.Fatalf("KILL %d: %v", spid, err)
	}
	s.close()
	if len(s.releaseFailures) != 0 {
		t.Errorf("close reported %q, want the lock lost, not a failed release", s.releaseFailures)
	}
	if len(s.lost) != 1 || s.lost[0].resource != resource {
		t.Errorf("lost = %v, want the lock of %s", s.lost, resource)
	}
	if err := otherLock(t, other, resource); err != nil {
		t.Errorf("second pool after the kill: %v", err)
	}
}

// The lab tests of the jobs (Task 7). They work on a plain msdb job,
// m_ap_job, created and deleted by each test; no replication job is
// touched. Its operations are written by hand in the planner's shape
// (jobLookup and jobOp in internal/plan): a prologue that finds the job by
// name, then sp_update_job or the guarded sp_start_job.

const labJobName = "m_ap_job"

const labJobPath = "jobs[m_ap_job]"

// labJobLookup is the prologue of the job operations, as jobLookup writes
// it, the job found by name.
const labJobLookup = "DECLARE @job_id uniqueidentifier;\n" +
	"SELECT @job_id = sj.job_id FROM msdb.dbo.sysjobs AS sj WHERE sj.name = N'" + labJobName + "';\n" +
	"IF @job_id IS NULL THROW 50000, N'the job of " + labJobPath + " does not exist', 1;"

// labJob creates m_ap_job (one T-SQL step WAITFOR DELAY '00:00:05'),
// deleting a residue first, and deletes it at the end of the test, after
// its run has ended.
func labJob(t *testing.T, admin *sql.DB) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	drop := "IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'" + labJobName + "') EXEC msdb.dbo.sp_delete_job @job_name = N'" + labJobName + "';"
	if _, err := admin.ExecContext(ctx, drop); err != nil {
		t.Fatalf("delete residue: %v", err)
	}
	create := "EXEC msdb.dbo.sp_add_job @job_name = N'" + labJobName + "';\n" +
		"EXEC msdb.dbo.sp_add_jobstep @job_name = N'" + labJobName + "', @step_name = N'wait', @subsystem = N'TSQL', @command = N'WAITFOR DELAY ''00:00:05'';';\n" +
		"EXEC msdb.dbo.sp_add_jobserver @job_name = N'" + labJobName + "';"
	if _, err := admin.ExecContext(ctx, create); err != nil {
		t.Fatalf("create %s: %v", labJobName, err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
		defer cancel()
		q := idleQuery(labJobLookup)
		for i := 0; i < 30; i++ {
			var idle int
			if err := admin.QueryRowContext(ctx, q).Scan(&idle); err != nil || idle == 1 {
				break
			}
			time.Sleep(time.Second)
		}
		if _, err := admin.ExecContext(ctx, drop); err != nil {
			t.Errorf("delete %s: %v", labJobName, err)
		}
	})
}

// labJobOp is an operation on m_ap_job in the planner's shape.
func labJobOp(seq int, kind string) plan.Operation {
	op := plan.Operation{Seq: seq, Kind: kind, Path: labJobPath, Server: labServer, Database: "msdb",
		Call: plan.Call{Procedure: "msdb.dbo.sp_update_job", Prologue: labJobLookup,
			Params: []plan.Param{{Name: "@job_id", Value: "@job_id"}}}}
	switch kind {
	case "job_disable":
		op.Action = "disable"
		op.Call.Params = append(op.Call.Params, plan.Param{Name: "@enabled", Value: "0"})
	case "job_restore":
		op.Action = "restore"
		op.Call.Params = append(op.Call.Params, plan.Param{Name: "@enabled", Value: "1"})
	case "job_start":
		op.Action = "start"
		op.Call.Procedure, op.Call.Guard = "msdb.dbo.sp_start_job", plan.JobIdle
	}
	return op
}

// labJobPlan is a disable, a restore and a start of m_ap_job.
func labJobPlan() *plan.Plan {
	return &plan.Plan{Operations: []plan.Operation{labJobOp(1, "job_disable"), labJobOp(2, "job_restore"), labJobOp(3, "job_start")}}
}

func labJobEnabled(t *testing.T, other *sql.DB) int {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	var n int
	if err := other.QueryRowContext(ctx, "SELECT CONVERT(int, enabled) FROM msdb.dbo.sysjobs WHERE name = N'"+labJobName+"'").Scan(&n); err != nil {
		t.Fatalf("read sysjobs.enabled: %v", err)
	}
	return n
}

func TestLabWaitIdle(t *testing.T) {
	admin := labPool(t)
	labJob(t, admin)
	s, _ := newLabSession(t)
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	stmts := labJobPlan().Statements()
	jobStart := stmts[2]
	if !strings.HasSuffix(jobStart.Text, "SELECT @started AS started;") {
		t.Fatalf("the job_start text is not R62's:\n%s", jobStart.Text)
	}

	started, err := s.start(ctx, jobStart)
	if err != nil || !started {
		t.Fatalf("first start: started %t, err %v; want started", started, err)
	}
	started, err = s.start(ctx, jobStart)
	if err != nil || started {
		t.Fatalf("second start while the step runs: started %t, err %v; want not started, no error", started, err)
	}

	var out strings.Builder
	if err := waitIdle(ctx, s, labServer, labJobName, labJobLookup, &out); err != nil {
		t.Fatalf("waitIdle: %v", err)
	}
	// The server's clock, read when waitIdle returns, against the run's
	// stop_execution_date (R49: no Go time is compared with a server column).
	conn, err := s.conn(ctx, labServer)
	if err != nil {
		t.Fatal(err)
	}
	var after int
	var stop sql.NullString
	q := labJobLookup + "\nSELECT CONVERT(nvarchar(30), ja.stop_execution_date, 121), CASE WHEN GETDATE() >= ja.stop_execution_date THEN 1 ELSE 0 END" +
		" FROM msdb.dbo.sysjobactivity AS ja WHERE ja.job_id = @job_id AND ja.session_id = (SELECT MAX(ss.session_id) FROM msdb.dbo.syssessions AS ss);"
	if err := conn.QueryRowContext(ctx, q).Scan(&stop, &after); err != nil {
		t.Fatalf("read the run's stop_execution_date: %v", err)
	}
	if !stop.Valid || after != 1 {
		t.Errorf("waitIdle returned before the run ended: stop_execution_date %v, GETDATE() >= it: %d", stop, after)
	}
	const line = "waiting for the snapshot job of " + labJobName + " to be idle\n"
	if out.String() != line {
		t.Errorf("waitIdle printed %q, want the wait line once, %q", out.String(), line)
	}

	out.Reset()
	begin := time.Now()
	if err := waitIdle(ctx, s, labServer, labJobName, labJobLookup, &out); err != nil {
		t.Fatalf("waitIdle on an idle job: %v", err)
	}
	if d := time.Since(begin); d >= idlePoll || out.Len() != 0 {
		t.Errorf("waitIdle on an idle job took %v and printed %q, want at once and nothing", d, out.String())
	}
}

func TestLabRestoreAfterCancel(t *testing.T) {
	admin := labPool(t)
	labJob(t, admin)
	s, _ := newLabSession(t)
	p := labJobPlan()
	stmts := p.Statements()
	run, cancel := context.WithCancel(context.Background())
	defer cancel()

	var j jobs
	j.arm(p, p.Operations[0])
	if err := s.exec(run, stmts[0], noSecret); err != nil {
		t.Fatalf("job_disable: %v", err)
	}
	if n := labJobEnabled(t, admin); n != 0 {
		t.Fatalf("enabled after the disable = %d, want 0", n)
	}
	time.AfterFunc(time.Second, cancel)
	if err := s.exec(run, stmt("msdb", "WAITFOR DELAY '00:00:10';"), noSecret); err == nil {
		t.Fatal("the statement of the cancelled run succeeded")
	}
	if run.Err() == nil {
		t.Fatal("the run's context is not cancelled")
	}

	if left := j.restoreRemaining(s, p, 30*time.Second, noSecret); len(left) != 0 {
		t.Errorf("restoreRemaining left %q disabled, want nothing", left)
	}
	if n := labJobEnabled(t, admin); n != 1 {
		t.Errorf("enabled after restoreRemaining = %d, want 1", n)
	}
}

func TestLabRestoreReconnects(t *testing.T) {
	admin := labPool(t)
	labJob(t, admin)
	s, _ := newLabSession(t)
	p := labJobPlan()
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()

	var j jobs
	j.arm(p, p.Operations[0])
	if err := s.exec(ctx, p.Statements()[0], noSecret); err != nil {
		t.Fatalf("job_disable: %v", err)
	}
	pinned, err := s.conn(ctx, labServer)
	if err != nil {
		t.Fatal(err)
	}
	var spid int
	if err := pinned.QueryRowContext(ctx, "SELECT @@SPID").Scan(&spid); err != nil {
		t.Fatal(err)
	}
	if _, err := admin.ExecContext(ctx, fmt.Sprintf("KILL %d;", spid)); err != nil {
		t.Fatalf("KILL %d: %v", spid, err)
	}

	if left := j.restoreRemaining(s, p, 30*time.Second, noSecret); len(left) != 0 {
		t.Errorf("restoreRemaining left %q disabled, want nothing", left)
	}
	if n := labJobEnabled(t, admin); n != 1 {
		t.Errorf("enabled after restoreRemaining = %d, want 1", n)
	}
	if now, err := s.conn(ctx, labServer); err != nil || now == pinned {
		t.Errorf("the restore ran on the killed connection (err %v)", err)
	}
}
