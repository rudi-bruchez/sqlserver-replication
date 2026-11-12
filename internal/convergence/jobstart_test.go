package convergence

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"testing"

	mssql "github.com/microsoft/go-mssqldb"

	"github.com/rudi-bruchez/sqlserver-replication/internal/plan"
)

// The guard of the printed job_start (final review item 4, anti-goal 2):
// sp_start_job of a job with a run requested or running fails with 22022,
// so the plan's batch starts the job only when msdb.dbo.sysjobactivity
// shows none in the current Agent session. Each case logs what the job's
// activity row holds, what the guard says, and what an unguarded
// sp_start_job gets, then runs the batch as printed, which must succeed.

// jobStart is the job_start operation of p whose path ends with suffix, and
// its statement.
func jobStart(t *testing.T, p *plan.Plan, suffix string) (plan.Operation, plan.Statement) {
	t.Helper()
	for i, st := range p.Statements() {
		if op := p.Operations[i]; op.Kind == "job_start" && strings.HasSuffix(op.Path, suffix) {
			return op, st
		}
	}
	t.Fatalf("no job_start of %s\n%s", suffix, p.Summary())
	return plan.Operation{}, plan.Statement{}
}

// guardCase is one measurement of the guard.
type guardCase struct {
	name       string
	busy       bool // the guard must say the job has a run requested or running
	unguarded  bool // also run an unguarded sp_start_job first
	wantNumber int  // the error number of the unguarded start, 0 for success
}

// measureGuard runs one case on conn, in the statement's database.
func (e *env) measureGuard(t *testing.T, conn *sql.Conn, op plan.Operation, st plan.Statement, c guardCase) {
	t.Helper()
	ctx := context.Background()
	if _, err := conn.ExecContext(ctx, "USE "+quoteName(st.Database)); err != nil {
		t.Fatal(err)
	}
	if op.Call.Guard == "" {
		t.Fatalf("%s: the job_start has no guard\n%s", c.name, st.Text)
	}
	var activity string
	var idle int
	q := op.Call.Prologue + "\nSELECT ISNULL((SELECT TOP (1) CONCAT(N'requested ', CONVERT(nvarchar(30), ja.run_requested_date, 126)," +
		" N', started ', CONVERT(nvarchar(30), ja.start_execution_date, 126), N', stopped ', CONVERT(nvarchar(30), ja.stop_execution_date, 126))" +
		" FROM msdb.dbo.sysjobactivity AS ja WHERE ja.job_id = @job_id ORDER BY ja.session_id DESC), N'no row')," +
		" CASE WHEN " + op.Call.Guard + " THEN 1 ELSE 0 END;"
	if err := conn.QueryRowContext(ctx, q).Scan(&activity, &idle); err != nil {
		t.Fatalf("%s: %v", c.name, err)
	}
	t.Logf("%s: activity %s; guard says %s", c.name, activity, map[int]string{0: "busy, no start", 1: "idle, start"}[idle])
	if busy := idle == 0; busy != c.busy {
		t.Errorf("%s: the guard says busy %v, want %v (%s)", c.name, busy, c.busy, activity)
	}
	if c.unguarded {
		_, err := conn.ExecContext(ctx, op.Call.Prologue+"\nEXEC msdb.dbo.sp_start_job @job_id = @job_id;")
		var me mssql.Error
		number := 0
		if errors.As(err, &me) {
			number = int(me.Number)
		} else if err != nil {
			t.Fatalf("%s: unguarded start: %v", c.name, err)
		}
		t.Logf("%s: unguarded sp_start_job: error %d (%v)", c.name, number, err)
		if number != c.wantNumber {
			t.Errorf("%s: unguarded sp_start_job error %d, want %d", c.name, number, c.wantNumber)
		}
	}
	if _, err := conn.ExecContext(ctx, st.Text); err != nil {
		t.Errorf("%s: the printed job_start failed: %v\n%s", c.name, err, st.Text)
	}
}

// A push subscription: its distribution job just after the plan that
// created it (sp_addpushsubscription_agent starts it, O13), the snapshot job
// that never ran, then the continuous distribution agent running.
func TestLabJobStartGuardPush(t *testing.T) {
	e := labEnv(t, "guardpush")
	p := e.plan(t, e.desired(t, "create.yaml"), plan.Options{})
	refusedFatal(t, p, "create.yaml")
	wantAgents(t, p, e.snapshotAndPush())
	e.run(t, p)
	conn, err := e.master.Conn(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	distOp, distSt := jobStart(t, p, ".distribution_agent")
	e.measureGuard(t, conn, distOp, distSt, guardCase{name: "push job just created", busy: true, unguarded: true, wantNumber: 22022})
	snapOp, snapSt := jobStart(t, p, ".snapshot_agent")
	e.measureGuard(t, conn, snapOp, snapSt, guardCase{name: "snapshot job never run", busy: false})
	e.deliveries = []delivery{{"m_t1", 10}, {"m_t2", 20}}
	e.waitAll(t) // the printed starts deliver
	e.measureGuard(t, conn, distOp, distSt, guardCase{name: "continuous agent running", busy: true, unguarded: true, wantNumber: 22022})
	e.converged(t, e.desired(t, "create.yaml"))
}

// A pull subscription: the pull agent job sp_addpullsubscription_agent
// creates has no schedule and has not run: the guard lets it start.
func TestLabJobStartGuardPull(t *testing.T) {
	e := labEnv(t, "guardpull")
	des := e.desired(t, "pull.yaml")
	p := e.plan(t, des, plan.Options{})
	refusedFatal(t, p, "pull.yaml")
	wantAgents(t, p, []plan.AgentRef{snapshotRef("m_pp"), e.pullRef("m_pp")})
	e.run(t, p)
	conn, err := e.master.Conn(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	pullOp, pullSt := jobStart(t, p, ".pull_agent")
	e.measureGuard(t, conn, pullOp, pullSt, guardCase{name: "pull job idle", busy: false})
	e.measureGuard(t, conn, pullOp, pullSt, guardCase{name: "pull job just started", busy: true})
	e.deliveries = []delivery{{"m_t1", 20}}
	e.startAndWait(t, p)
	e.converged(t, des)
}
