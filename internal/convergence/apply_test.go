package convergence

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"math/big"
	"os"
	"strings"
	"syscall"
	"testing"
	"time"

	mssql "github.com/microsoft/go-mssqldb"

	"github.com/rudi-bruchez/sqlserver-replication/internal/apply"
	"github.com/rudi-bruchez/sqlserver-replication/internal/plan"
)

// The scenarios of what is specific to apply (plan 4, Task 12): a bound
// secret, the initialization from an LSN and its refusal, the lock that
// refuses a second apply, -wait 0, resuming after a failure, an interrupt
// that restores the jobs, a snapshot already running, and a delivery owed
// before the plan.

// wantLine fails the test unless one of lines is exactly line.
func wantLine(t *testing.T, lines []string, line string) {
	t.Helper()
	for _, l := range lines {
		if l == line {
			return
		}
	}
	t.Errorf("no line %q in the output of apply", line)
}

// noLinePrefix fails the test when a line of lines starts with prefix.
func noLinePrefix(t *testing.T, lines []string, prefix string) {
	t.Helper()
	for _, l := range lines {
		if strings.HasPrefix(l, prefix) {
			t.Errorf("apply printed %q", l)
		}
	}
}

// opSeq returns the Seq of the first operation of p calling proc, 0 when
// there is none.
func opSeq(p *plan.Plan, proc string) int {
	for _, op := range p.Operations {
		if procedure(op) == proc {
			return op.Seq
		}
	}
	return 0
}

// jobEnabled reads msdb.dbo.sysjobs.enabled of the job a lookup (a batch
// prologue that sets @job_id) finds.
func (e *env) jobEnabled(t *testing.T, lookup string) int {
	t.Helper()
	var enabled int
	if err := e.master.QueryRow(lookup + "\nSELECT enabled FROM msdb.dbo.sysjobs WHERE job_id = @job_id;").Scan(&enabled); err != nil {
		t.Fatalf("read whether the job is enabled: %v", err)
	}
	return enabled
}

// snapshotJobsDisabled counts the snapshot jobs of {db} that are disabled,
// and returns how many there are.
func (e *env) snapshotJobsDisabled(t *testing.T) (disabled, all int) {
	t.Helper()
	q := e.replace(`SELECT ISNULL(SUM(CASE WHEN j.enabled = 0 THEN 1 ELSE 0 END), 0), COUNT(*)
FROM distribution.dbo.MSsnapshot_agents AS a
JOIN msdb.dbo.sysjobs AS j ON j.job_id = CONVERT(uniqueidentifier, a.job_id)
WHERE a.publisher_db = N'{db}'`)
	if err := e.master.QueryRow(q).Scan(&disabled, &all); err != nil {
		t.Fatal(err)
	}
	return disabled, all
}

// subscriptions counts the subscriptions of {db} to {sub}, at the
// publisher and at the distributor.
func (e *env) subscriptions(t *testing.T) int {
	t.Helper()
	return e.count(t, `SELECT (SELECT COUNT(*) FROM {db}.dbo.syssubscriptions WHERE srvid >= 0)
 + (SELECT COUNT(*) FROM distribution.dbo.MSsubscriptions WHERE publisher_db = N'{db}' AND subscriber_db = N'{sub}' AND subscriber_id >= 0)`)
}

// TestLabApplySecret: a push agent that connects to the subscriber as a
// SQL login whose password, bound from SQLREPL_SQL_M_LOGIN (R54), holds
// ', ; and --. The run delivers, converges, and no line it prints holds
// the password.
func TestLabApplySecret(t *testing.T) {
	e := labEnv(t, "secret")
	suffix := make([]byte, 6)
	if _, err := rand.Read(suffix); err != nil {
		t.Fatal(err)
	}
	pw := "m'Pw;" + hex.EncodeToString(suffix) + "--x"
	if _, err := e.master.Exec(`DECLARE @s nvarchar(max) = N'CREATE LOGIN ' + QUOTENAME(@login) + N' WITH PASSWORD = '
 + QUOTENAME(@pw, N'''') + N', CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF;';
EXEC (@s);`, sql.Named("login", e.login()), sql.Named("pw", pw)); err != nil {
		t.Fatal("create the login: " + strings.ReplaceAll(err.Error(), pw, "<password>"))
	}
	if _, err := e.master.Exec(e.replace(`EXEC {sub}.sys.sp_executesql N'CREATE USER [{login}] FOR LOGIN [{login}]; ALTER ROLE db_owner ADD MEMBER [{login}];'`)); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SQLREPL_SQL_M_LOGIN", pw)

	des := e.desired(t, "secret.yaml")
	res, lines, err := e.applyRun(t, des, plan.Options{}, nil)
	e.wantRun(t, res, err, apply.OutcomeApplied)
	if len(res.Plan.Secrets) != 1 || res.Plan.Secrets[0].Name != "SQLREPL_SQL_M_LOGIN" || len(res.Plan.Secrets[0].Operations) == 0 {
		t.Fatalf("secrets of the plan %+v, want SQLREPL_SQL_M_LOGIN passed by an operation", res.Plan.Secrets)
	}
	e.wantDelivered(t, res, "m_p")
	e.deliveries = []delivery{{"m_t1", 20}}
	e.checkDelivered(t)
	// The agent connects as the login: the delivery proves the bound
	// password right.
	if n := e.count(t, `SELECT COUNT(*) FROM distribution.dbo.MSdistribution_agents
WHERE publisher_db = N'{db}' AND subscriber_db = N'{sub}' AND subscriber_security_mode = 0 AND subscriber_login = N'{login}'`); n != 1 {
		t.Errorf("%d distribution agents of {sub} connect as %s with SQL Server authentication, want 1", n, e.login())
	}
	for _, v := range []string{pw, strings.ReplaceAll(pw, "'", "''")} {
		for _, l := range lines {
			if strings.Contains(l, v) {
				t.Errorf("a line of apply holds the password: %q", strings.ReplaceAll(l, v, "<password>"))
			}
		}
	}
	e.converged(t, des)
}

// lsnOfBackup is the last_lsn of the latest backup to the file @file,
// converted to binary(10) with the arithmetic of 10-init-modes.sh lines
// 194 to 199, written 0x and 20 hexadecimal digits.
const lsnOfBackup = `DECLARE @lsn numeric(25,0) = (SELECT TOP (1) b.last_lsn FROM msdb.dbo.backupset AS b
JOIN msdb.dbo.backupmediafamily AS f ON f.media_set_id = b.media_set_id
WHERE f.physical_device_name = @file ORDER BY b.backup_set_id DESC);
DECLARE @vlf bigint = CONVERT(bigint, (@lsn - @lsn % 1000000000000000) / 1000000000000000),
        @blk bigint = CONVERT(bigint, (@lsn % 1000000000000000 - @lsn % 100000) / 100000),
        @slot bigint = CONVERT(bigint, @lsn % 100000);
DECLARE @b binary(10) = SUBSTRING(CONVERT(binary(8), @vlf), 5, 4) + SUBSTRING(CONVERT(binary(8), @blk), 5, 4) + SUBSTRING(CONVERT(binary(8), @slot), 7, 2);
SELECT CONVERT(varchar(30), @b, 1);`

// lsnLogEnd is the log end of {db} as binary(10), 10-init-modes.sh's
// log_end_bin.
const lsnLogEnd = `SELECT CONVERT(varchar(30), CONVERT(binary(4), N'0x' + LEFT(e, 8), 1) + CONVERT(binary(4), N'0x' + SUBSTRING(e, 10, 8), 1)
 + CONVERT(binary(2), N'0x' + RIGHT(e, 4), 1), 1)
FROM (SELECT CONVERT(nvarchar(30), log_end_lsn) AS e FROM sys.dm_db_log_stats(DB_ID(N'{db}'))) AS x`

// lsnSetup applies lsn.yaml without its subscription, so that the
// publication exists before the backup (10-init-modes I3), then runs
// lsn-setup.sql: {db} backed up COPY_ONLY and restored over {sub}.
func (e *env) lsnSetup(t *testing.T) {
	t.Helper()
	e.vars = map[string]string{"{lsn}": "0x00000000000000000000"}
	des := e.desired(t, "lsn.yaml")
	des.Publications[0].Subscriptions = nil
	res := e.apply(t, des, plan.Options{}, apply.OutcomeApplied)
	e.wantDelivered(t, res)
	conn, err := e.master.Conn(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if err := e.script(conn, "lsn-setup.sql"); err != nil {
		t.Fatalf("lsn-setup.sql: %v", err)
	}
}

// TestLabApplyLSN: a push subscription initialized from the last_lsn of
// the backup restored over {sub} (R57): one sp_addsubscription
// initialize from lsn, no snapshot, and the rows inserted afterwards
// reach {sub}.
func TestLabApplyLSN(t *testing.T) {
	e := labEnv(t, "lsn")
	e.lsnSetup(t)
	var lsn string
	if err := e.master.QueryRow(lsnOfBackup, sql.Named("file", e.backupFile())).Scan(&lsn); err != nil {
		t.Fatalf("the LSN of the backup: %v", err)
	}
	t.Logf("last_lsn of %s: %s", e.backupFile(), lsn)
	e.vars["{lsn}"] = lsn
	// A row held only at the subscriber: a snapshot would drop it with the
	// table (pre_creation_cmd drop).
	if _, err := e.master.Exec(e.replace("INSERT {sub}.dbo.m_t1 (id, a, b) VALUES (5000, 1, 1)")); err != nil {
		t.Fatal(err)
	}

	des := e.desired(t, "lsn.yaml")
	p := e.plan(t, des, plan.Options{})
	refusedFatal(t, p, "lsn.yaml")
	if n := countProc(p, "sp_addsubscription"); n != 1 {
		t.Fatalf("%d sp_addsubscription, want 1\n%s", n, p.Summary())
	}
	if _, err := find(p, "sp_addsubscription", map[string]string{"@sync_type": "N'initialize from lsn'",
		"@subscriptionlsn": lsn, "@article": "N'all'"}); err != nil {
		t.Fatalf("%v\n%s%s", err, p.Summary(), p.SQL())
	}
	res := e.apply(t, des, plan.Options{}, apply.OutcomeApplied)
	e.wantDelivered(t, res) // an LSN subscription is owed no snapshot
	if n := e.count(t, `SELECT COUNT(*) FROM distribution.dbo.MSsnapshot_history AS h
JOIN distribution.dbo.MSsnapshot_agents AS a ON a.id = h.agent_id WHERE a.publisher_db = N'{db}'`); n != 0 {
		t.Errorf("%d snapshot history rows of {db}, want none: no snapshot", n)
	}
	if _, err := e.master.Exec(e.replace("INSERT {db}.dbo.m_t1 (id, a, b) VALUES (1000, 1, 1), (1001, 2, 2)")); err != nil {
		t.Fatal(err)
	}
	e.waitDelivered(t, "m_t1", 23)
	if n := e.count(t, "SELECT COUNT(*) FROM {sub}.dbo.m_t1 WHERE id IN (1000, 1001, 5000)"); n != 3 {
		t.Errorf("{sub}.dbo.m_t1 holds %d of the rows 1000, 1001 and 5000, want 3", n)
	}
	e.converged(t, des)
}

// TestLabApplyLSNRefused: the same file with an LSN one above the log end
// of {db}: the plan refuses it (R57), and the hook fails the test at the
// first statement, so that a wrong LSN never reaches the lab (lab/README.md,
// "Initialization without a snapshot").
func TestLabApplyLSNRefused(t *testing.T) {
	e := labEnv(t, "lsnrefused")
	e.lsnSetup(t)
	var end string
	if err := e.master.QueryRow(e.replace(lsnLogEnd)).Scan(&end); err != nil {
		t.Fatalf("the log end of {db}: %v", err)
	}
	n, ok := new(big.Int).SetString(strings.TrimPrefix(end, "0x"), 16)
	if !ok {
		t.Fatalf("log end %q", end)
	}
	lsn := fmt.Sprintf("0x%020X", n.Add(n, big.NewInt(1)))
	t.Logf("log end of {db} %s, LSN %s", end, lsn)
	e.vars["{lsn}"] = lsn

	des := e.desired(t, "lsn.yaml")
	sent := 0
	e.stop = func(op plan.Operation) error {
		sent++
		t.Errorf("operation %d %s %s %s about to be sent with the LSN %s", op.Seq, op.Action, op.Kind, op.Path, lsn)
		return errors.New("the test stops apply before its first statement")
	}
	res, _, err := e.applyRun(t, des, plan.Options{}, nil)
	e.stop = nil
	if err != nil {
		t.Fatalf("apply: %v", err)
	}
	if res.Outcome != apply.OutcomeRefused || res.ExitCode() != 1 || len(res.Ran) != 0 || sent != 0 {
		t.Fatalf("apply ended %s, exit %d, ran %v, %d statements reached the hook; want refused, 1, none, 0",
			res.Outcome, res.ExitCode(), res.Ran, sent)
	}
	found := false
	for _, r := range res.Plan.Refusals {
		found = found || strings.Contains(fmt.Sprint(r), "R57")
	}
	if !found {
		t.Errorf("no R57 refusal in the plan\n%s", res.Plan.Summary())
	}
	if n := e.subscriptions(t); n != 0 {
		t.Errorf("%d subscription rows of {db} to {sub} after the refusal, want 0", n)
	}
}

// TestLabApplyLockRefusesSecond: a first apply held at its question keeps
// the lock (R45); a second apply of the same file is refused with the
// lock's message; released, the first applies; then, the harness pool
// still open, a session of another pool takes the lock.
func TestLabApplyLockRefusesSecond(t *testing.T) {
	e := labEnv(t, "lock")
	des := e.desired(t, "create.yaml")
	type run struct {
		res   *apply.Result
		lines []string
		err   error
	}
	asked := make(chan struct{})
	answer := make(chan bool, 1)
	first := make(chan run, 1)
	go func() {
		res, lines, err := e.applyRun(t, des, plan.Options{}, func(o *apply.Options) {
			o.AutoApprove = false
			o.Confirm = func(string) (bool, error) {
				close(asked)
				return <-answer, nil
			}
		})
		first <- run{res, lines, err}
	}()
	answered := false
	t.Cleanup(func() {
		// On a failure, the first apply is cancelled and awaited before
		// the teardown.
		if !answered {
			answer <- false
			<-first
		}
	})
	select {
	case <-asked:
	case r := <-first:
		answered = true
		t.Fatalf("the first apply returned before its question: %v", r.err)
	case <-time.After(pollTimeout):
		t.Fatal("the first apply did not reach its question")
	}

	res, lines, err := e.applyRun(t, des, plan.Options{}, nil)
	want := "another sqlrepl apply holds the lock on " + des.Publisher.Server + "." + des.Publisher.Database
	if res != nil || err == nil || !errors.Is(err, apply.ErrLocked) || err.Error() != want {
		t.Errorf("second apply: result %v, error %v, want no result and %q", res, err, want)
	}
	noLinePrefix(t, lines, "[")

	answer <- true
	answered = true
	r := <-first
	e.wantRun(t, r.res, r.err, apply.OutcomeApplied)
	e.wantDelivered(t, r.res, "m_p")
	e.deliveries = []delivery{{"m_t1", 10}, {"m_t2", 20}}
	e.checkDelivered(t)

	// R45: a session of another pool, the harness pool open (the same pool
	// could hand back the holder's session, where the lock is reentrant).
	u := *e.dsn
	q := u.Query()
	q.Set("database", e.db)
	u.RawQuery = q.Encode()
	other, err := sql.Open("sqlserver", u.String())
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close()
	ctx := context.Background()
	conn, err := other.Conn(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	var rc int
	if err := conn.QueryRowContext(ctx, `DECLARE @rc int; EXEC @rc = sp_getapplock @Resource = N'sqlrepl apply',
 @LockMode = N'Exclusive', @LockOwner = N'Session', @LockTimeout = 0; SELECT @rc;`).Scan(&rc); err != nil {
		t.Fatal(err)
	}
	if rc < 0 {
		t.Errorf("sp_getapplock from another pool after the first apply returned %d: the lock is still held", rc)
	} else if _, err := conn.ExecContext(ctx, "EXEC sp_releaseapplock @Resource = N'sqlrepl apply', @LockOwner = N'Session';"); err != nil {
		t.Error(err)
	}
	e.converged(t, des)
}

// TestLabApplyWaitZero: -wait 0 runs every operation and every start and
// awaits no delivery: exit 3, the delivery not awaited (R52); once the
// delivery has come, the same file plans nothing.
func TestLabApplyWaitZero(t *testing.T) {
	e := labEnv(t, "waitzero")
	des := e.desired(t, "create.yaml")
	res, lines, err := e.applyRun(t, des, plan.Options{}, func(o *apply.Options) { o.Wait = 0 })
	if err != nil {
		t.Fatalf("apply: %v", err)
	}
	if res.Outcome != apply.OutcomeApplied || res.ExitCode() != 3 || len(res.Remaining) != 0 ||
		len(res.Ran) != len(res.Plan.Operations) {
		t.Fatalf("apply ended %s, exit %d, ran %d of %d, remaining %v; want applied, 3, all, none",
			res.Outcome, res.ExitCode(), len(res.Ran), len(res.Plan.Operations), res.Remaining)
	}
	sub := e.server + "/" + e.sub
	if len(res.Deliveries) != 1 || res.Deliveries[0].Status != "not_awaited" || !strings.EqualFold(res.Deliveries[0].Subscription, sub) {
		t.Fatalf("deliveries %+v, want m_p to %s not awaited", res.Deliveries, sub)
	}
	wantLine(t, lines, "delivery m_p to "+res.Deliveries[0].Subscription+": not awaited")
	e.deliveries = []delivery{{"m_t1", 10}, {"m_t2", 20}}
	e.waitAll(t)
	e.apply(t, des, plan.Options{}, apply.OutcomeEmpty)
}

// TestLabApplyResumesAfterFailure: a run stopped before its
// sp_addsubscription fails with exit 1, restores the snapshot job (R48)
// and lists the rest as remaining; a second run applies the remainder.
func TestLabApplyResumesAfterFailure(t *testing.T) {
	e := labEnv(t, "resume")
	des := e.desired(t, "create.yaml")
	e.stop = func(op plan.Operation) error {
		if procedure(op) == "sp_addsubscription" {
			return errors.New("the test stops apply before sp_addsubscription")
		}
		return nil
	}
	res, lines, err := e.applyRun(t, des, plan.Options{}, nil)
	e.stop = nil
	if err != nil {
		t.Fatalf("apply: %v", err)
	}
	add := opSeq(res.Plan, "sp_addsubscription")
	if res.Outcome != apply.OutcomeFailed || res.ExitCode() != 1 || res.Failure == nil || res.Failure.Seq != add {
		t.Fatalf("apply ended %s, exit %d, failure %+v; want failed, 1, at operation %d", res.Outcome, res.ExitCode(), res.Failure, add)
	}
	ran := map[int]bool{}
	for _, s := range res.Ran {
		ran[s] = true
	}
	for _, op := range res.Plan.Operations {
		if op.Seq < add && !ran[op.Seq] {
			t.Errorf("operation %d, before the failure, did not run", op.Seq)
		}
	}
	if len(res.Remaining) == 0 || res.Remaining[0] != add || len(res.Ran)+len(res.Remaining) != len(res.Plan.Operations) {
		t.Errorf("ran %v, remaining %v, want the remaining to start at %d and cover the rest", res.Ran, res.Remaining, add)
	}
	lookup, ok := res.Plan.SnapshotJobLookup("m_p")
	if !ok {
		t.Fatal("no snapshot job lookup for m_p")
	}
	if en := e.jobEnabled(t, lookup); en != 1 {
		t.Errorf("the snapshot job of m_p has enabled %d after the failure, want 1 (R48)", en)
	}
	noLinePrefix(t, lines, "job left disabled")

	// The second run. m_p exists before its plan and has never generated a
	// snapshot, so its folder is absent at T: R50 makes the delivery
	// unconfirmed ("For a publication that exists before the plan, a
	// listing at T that does not find its folder makes the delivery
	// unconfirmed"), exit 3, which the brief's "delivered" contradicts
	// (Task 12 report, for a ruling). The data arrives all the same.
	res, _, err = e.applyRun(t, des, plan.Options{}, nil)
	if err != nil {
		t.Fatalf("apply: %v", err)
	}
	if res.Outcome != apply.OutcomeApplied || len(res.Remaining) != 0 {
		t.Fatalf("the second run ended %s, remaining %v; want applied, none", res.Outcome, res.Remaining)
	}
	if opSeq(res.Plan, "sp_addpublication") != 0 || opSeq(res.Plan, "sp_addsubscription") == 0 {
		t.Errorf("the second run is not the remainder of the first\n%s", res.Plan.Summary())
	}
	folder := "snapshot folder of m_p cannot be listed at "
	if len(res.Deliveries) != 1 || res.Deliveries[0].Status != "unconfirmed" || !strings.HasPrefix(res.Deliveries[0].Detail, folder) ||
		res.ExitCode() != 3 {
		t.Errorf("deliveries %+v, exit %d; want m_p unconfirmed, %q (R50), exit 3", res.Deliveries, res.ExitCode(), folder)
	}
	e.deliveries = []delivery{{"m_t1", 10}, {"m_t2", 20}}
	e.waitAll(t)
	e.converged(t, des)
}

// TestLabApplyInterruptRestores: SIGINT once the first job_disable has
// committed: exit 1, operations remaining, every snapshot job of {db}
// enabled again (R48), and no job left disabled.
func TestLabApplyInterruptRestores(t *testing.T) {
	e := labEnv(t, "interrupt")
	createAndDeliver(t, e)
	des := e.desired(t, "add-article.yaml")
	sig := make(chan os.Signal, 1)
	hooked := 0
	e.hook = func(op plan.Operation) {
		ops := e.applied.Operations
		var disable plan.Operation
		for i, o := range ops {
			if o.Kind == "job_disable" {
				if i+1 < len(ops) && ops[i+1].Seq == op.Seq {
					disable = o
				}
				break
			}
		}
		if disable.Seq == 0 {
			return
		}
		hooked++
		if en := e.jobEnabled(t, disable.Call.Prologue); en != 0 {
			t.Errorf("job of %s enabled %d after its job_disable, want 0", disable.Path, en)
		}
		sig <- syscall.SIGINT
	}
	res, lines, err := e.applyRun(t, des, plan.Options{}, func(o *apply.Options) { o.Interrupt = sig })
	e.hook = nil
	if err != nil {
		t.Fatalf("apply: %v", err)
	}
	if hooked != 1 {
		t.Fatalf("the statement after the first job_disable reached the hook %d times, want 1", hooked)
	}
	if res.Outcome != apply.OutcomeInterrupted || res.ExitCode() != 1 || len(res.Remaining) == 0 {
		t.Fatalf("apply ended %s, exit %d, remaining %v; want interrupted, 1, some", res.Outcome, res.ExitCode(), res.Remaining)
	}
	if disabled, all := e.snapshotJobsDisabled(t); disabled != 0 || all == 0 {
		t.Errorf("%d of the %d snapshot jobs of {db} disabled after the interrupt, want none", disabled, all)
	}
	if len(res.JobsLeftDisabled) != 0 {
		t.Errorf("jobs left disabled %q", res.JobsLeftDisabled)
	}
	noLinePrefix(t, lines, "job left disabled")
}

// TestLabApplySnapshotAlreadyRunning: a generation of m_p started by the
// test runs when apply plans running-add.yaml. Apply waits for it (the
// line proves the wait), and confirms the delivery by a run whose folder,
// a server timestamp, is later than the end of the test's run: a run in
// progress at T is never accepted (R50).
func TestLabApplySnapshotAlreadyRunning(t *testing.T) {
	e := labEnv(t, "running")
	t0 := time.Now()
	if _, err := e.master.Exec(e.replace(`EXEC {db}.sys.sp_executesql N'CREATE TABLE dbo.m_big (id int PRIMARY KEY, a int, b int);
WITH n AS (SELECT TOP (2000000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS id FROM sys.all_objects AS x CROSS JOIN sys.all_objects AS y CROSS JOIN sys.all_objects AS z)
INSERT dbo.m_big (id, a, b) SELECT id, id, id FROM n;'`)); err != nil {
		t.Fatal(err)
	}
	t.Logf("m_big: 2 000 000 rows in %s", time.Since(t0).Round(time.Millisecond))
	des := e.desired(t, "running.yaml")
	res := e.apply(t, des, plan.Options{}, apply.OutcomeApplied)
	e.wantDelivered(t, res, "m_p")
	e.deliveries = []delivery{{"m_t1", 10}, {"m_t2", 20}, {"m_big", 2000000}}
	e.checkDelivered(t)

	lookup, ok := e.applied.SnapshotJobLookup("m_p")
	if !ok {
		t.Fatal("no snapshot job lookup for m_p")
	}
	idle := func() int {
		var v int
		if err := e.master.QueryRow(lookup + "\nSELECT CASE WHEN " + plan.JobIdle + " THEN 1 ELSE 0 END;").Scan(&v); err != nil {
			t.Fatal(err)
		}
		return v
	}
	started := time.Now()
	e.startSnapshot(t, e.db, "m_p")
	for idle() == 1 {
		if time.Since(started) > pollTimeout {
			t.Fatal("the snapshot job of m_p never read busy after its start")
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Logf("the snapshot job of m_p reads busy %s after the test's start", time.Since(started).Round(time.Millisecond))

	// The end of the test's run, read when apply starts its own: the job
	// has been idle since the wait after the job_disable, and nothing else
	// has started it.
	var stop time.Time
	hooked := 0
	e.hook = func(op plan.Operation) {
		if op.Kind != "job_start" || !strings.HasSuffix(op.Path, ".snapshot_agent") {
			return
		}
		hooked++
		var s sql.NullTime
		if err := e.master.QueryRow(lookup + `
SELECT TOP (1) ja.stop_execution_date FROM msdb.dbo.sysjobactivity AS ja WHERE ja.job_id = @job_id ORDER BY ja.session_id DESC;`).Scan(&s); err != nil || !s.Valid {
			t.Errorf("the end of the test's run of m_p: %v (valid %v)", err, s.Valid)
			return
		}
		stop = s.Time
	}
	des = e.desired(t, "running-add.yaml")
	res, lines, err := e.applyRun(t, des, plan.Options{}, nil)
	e.hook = nil
	e.wantRun(t, res, err, apply.OutcomeApplied)
	if hooked != 1 {
		t.Fatalf("the snapshot agent's job_start reached the hook %d times, want 1", hooked)
	}
	wantLine(t, lines, "waiting for the snapshot job of m_p to be idle")
	e.wantDelivered(t, res, "m_p")
	run := res.Deliveries[0].Run
	i := strings.LastIndexAny(run, `\/`)
	at, perr := time.Parse("20060102150405", run[i+1:])
	if perr != nil {
		t.Fatalf("the confirmed run %q: %v", run, perr)
	}
	t.Logf("the test's run ended %s; the confirmed run %s", stop.Format("15:04:05.000"), run)
	if !at.After(stop) {
		t.Errorf("the confirmed run %s does not start after the end %s of the run in progress when apply planned",
			run, stop.Format(time.RFC3339Nano))
	}
	e.deliveries = []delivery{{"m_t3", 20}}
	e.checkDelivered(t)
	e.converged(t, des)
}

// TestLabApplyOwedBefore: a subscription marked for reinitialization while
// its agent is stopped is pending before the plan (R50): the plan has it
// in OwedBefore, apply starts the agents and confirms its delivery.
func TestLabApplyOwedBefore(t *testing.T) {
	e := labEnv(t, "owedbefore")
	createAndDeliver(t, e)
	e.stopPushJob(t, "m_p")
	// sp_reinitsubscription with the log reader running can return 18752
	// and complete all the same (O14, measured here): the status read that
	// follows is what tells.
	if _, err := e.open(t, e.db).Exec(`EXEC sp_reinitsubscription @publication = N'm_p', @article = N'all',
 @subscriber = @@SERVERNAME, @destination_db = @sub`, sql.Named("sub", e.sub)); err != nil {
		var me mssql.Error
		if !errors.As(err, &me) || me.Number != 18752 {
			t.Fatal(err)
		}
		t.Logf("sp_reinitsubscription: %v", err)
	}
	if n := e.count(t, "SELECT COUNT(*) FROM {db}.dbo.syssubscriptions WHERE srvid >= 0 AND status <> 1"); n != 0 {
		t.Fatalf("%d subscription rows of {db} not at status 1 after sp_reinitsubscription", n)
	}
	// A row held only at the subscriber: the snapshot owed replaces the
	// table, which tells its delivery from none.
	if _, err := e.master.Exec(e.replace("INSERT {sub}.dbo.m_t1 (id, a, b) VALUES (5000, 1, 1)")); err != nil {
		t.Fatal(err)
	}

	des := e.desired(t, "create.yaml")
	p := e.plan(t, des, plan.Options{})
	refusedFatal(t, p, "create.yaml")
	sub := e.server + "/" + e.sub
	if len(p.OwedBefore) != 1 || p.OwedBefore[0].Publication != "m_p" || !strings.EqualFold(p.OwedBefore[0].Subscription, sub) {
		t.Fatalf("OwedBefore %+v, want m_p to %s\n%s", p.OwedBefore, sub, p.Summary())
	}
	wantAgents(t, p, e.snapshotAndPush())
	res := e.apply(t, des, plan.Options{}, apply.OutcomeApplied)
	if len(res.Plan.OwedBefore) != 1 {
		t.Fatalf("OwedBefore of the plan apply ran: %+v", res.Plan.OwedBefore)
	}
	e.wantDelivered(t, res, "m_p")
	e.deliveries = []delivery{{"m_t1", 10}, {"m_t2", 20}}
	e.checkDelivered(t)
	if n := e.count(t, "SELECT COUNT(*) FROM {sub}.dbo.m_t1 WHERE id = 5000"); n != 0 {
		t.Errorf("the row held only at the subscriber is still there: the snapshot owed was not delivered")
	}
	e.converged(t, des)
}
