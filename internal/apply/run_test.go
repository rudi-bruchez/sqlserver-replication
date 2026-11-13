package apply

import (
	"bytes"
	"context"
	"database/sql"
	"database/sql/driver"
	"fmt"
	"io"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	mssql "github.com/microsoft/go-mssqldb"

	"github.com/rudi-bruchez/sqlserver-replication/internal/plan"
)

// The fake driver of TestRunRefusals (the pattern of internal/precheck's
// fake_test.go): a server that answers the batches a run sends before its
// first operation, the lock and its release, the USE they issue and the
// probes, and records every batch it receives, with the resource of a lock
// batch. Any other batch is an error: the refusals run no statement.

type fakeServer struct {
	mu      sync.Mutex
	batches []string // in the order received; a lock batch as "lock <resource>"
	// failRestore makes every sp_update_job with @enabled = 1 fail
	// (TestRunFailedRestore).
	failRestore bool
	// failDisable makes every sp_update_job with @enabled = 0 fail, as a
	// disable that committed while its call returned an error
	// (TestRunArmsBeforeDisable).
	failDisable bool
	// echoSecret makes every statement with a bound secret fail with a
	// server message that holds the bound value (TestRunMasksEchoedSecret).
	echoSecret bool
	// rootPublisher and publisherRoot: qPublisherRoot returns publisherRoot
	// for the publisher named rootPublisher (any case), no row for any
	// other name; the listing of qListing is empty
	// (TestListReadsPublisherRoot).
	rootPublisher, publisherRoot string
	// jobFailure, when set, is the row qJobFailedAfter returns (its start,
	// the step 0 message and the last failed step's message or nil); nil,
	// no row. failureErr, when set, is that query's error. The polls of the wait for deliveries
	// are answered for the distribution database "distribution": no agent
	// row, no history line, sync_method native (TestWaitForFailedGeneration).
	jobFailure []driver.Value
	failureErr error
}

func (f *fakeServer) add(b string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.batches = append(f.batches, b)
}

func (f *fakeServer) log() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.batches...)
}

func (f *fakeServer) count(prefix string) int {
	n := 0
	for _, b := range f.log() {
		if strings.HasPrefix(b, prefix) {
			n++
		}
	}
	return n
}

var (
	fakeServersMu sync.Mutex
	fakeServers   = map[string]*fakeServer{}
)

type applyFakeDriver struct{}

func init() { sql.Register("applyfake", applyFakeDriver{}) }

func (applyFakeDriver) Open(name string) (driver.Conn, error) {
	fakeServersMu.Lock()
	defer fakeServersMu.Unlock()
	f, ok := fakeServers[name]
	if !ok {
		return nil, fmt.Errorf("fake: no server %q", name)
	}
	return &applyFakeConn{f: f}, nil
}

type applyFakeConn struct{ f *fakeServer }

func (c *applyFakeConn) Prepare(q string) (driver.Stmt, error) {
	return nil, fmt.Errorf("fake: prepare %q", q)
}
func (*applyFakeConn) Close() error { return nil }

// CheckNamedValue passes every argument as given, mssql.DateTime1
// included, as go-mssqldb does.
func (*applyFakeConn) CheckNamedValue(*driver.NamedValue) error { return nil }
func (*applyFakeConn) Begin() (driver.Tx, error)                { return nil, fmt.Errorf("fake: no transactions") }

func (c *applyFakeConn) ExecContext(_ context.Context, q string, args []driver.NamedValue) (driver.Result, error) {
	if c.f.echoSecret {
		for _, a := range args {
			if strings.HasPrefix(a.Name, "secret_") {
				c.f.add("exec " + q)
				return nil, mssql.Error{Number: 50000, Class: 16, Message: fmt.Sprintf("the value %v is refused", a.Value)}
			}
		}
	}
	if strings.HasPrefix(q, "USE ") {
		c.f.add(q)
		return driver.RowsAffected(0), nil
	}
	if q == distQuery(qReplServersProbe, "distribution", "") {
		c.f.add("servers probe")
		return driver.RowsAffected(0), nil
	}
	if strings.Contains(q, "EXEC msdb.dbo.sp_update_job") {
		// The job operations of TestRunRestoreLogged and TestRunFailedRestore.
		c.f.add("exec " + q)
		if c.f.failRestore && strings.Contains(q, "@enabled = 1") {
			return nil, fmt.Errorf("fake: restore refused")
		}
		if c.f.failDisable && strings.Contains(q, "@enabled = 0") {
			return nil, fmt.Errorf("fake: disable refused")
		}
		return driver.RowsAffected(0), nil
	}
	c.f.add("exec " + q)
	return nil, fmt.Errorf("fake: unexpected exec %q", q)
}

func (c *applyFakeConn) QueryContext(_ context.Context, q string, args []driver.NamedValue) (driver.Rows, error) {
	resource := ""
	for _, a := range args {
		if a.Name == "resource" {
			resource = fmt.Sprint(a.Value)
		}
	}
	switch q {
	case lockBatch:
		c.f.add("lock " + resource)
		return &applyFakeRows{rows: [][]driver.Value{{int64(0)}}}, nil
	case unlockBatch:
		c.f.add("unlock " + resource)
		return &applyFakeRows{rows: [][]driver.Value{{int64(0)}}}, nil
	case "SELECT 1;", "SELECT @@TRANCOUNT;":
		c.f.add(q)
		v := int64(1)
		if q == "SELECT @@TRANCOUNT;" {
			v = 0
		}
		return &applyFakeRows{rows: [][]driver.Value{{v}}}, nil
	}
	switch q {
	case qPublisherRoot:
		name := fmt.Sprint(args[0].Value)
		c.f.add("publisher root " + name)
		if !strings.EqualFold(name, c.f.rootPublisher) {
			return &applyFakeRows{}, nil
		}
		return &applyFakeRows{rows: [][]driver.Value{{c.f.publisherRoot}}}, nil
	case qListing:
		c.f.add(fmt.Sprintf("listing %v", args[0].Value))
		return &applyFakeRows{}, nil
	case distQuery(qAgentRow, "distribution", ""):
		c.f.add("agent rows")
		return &applyFakeRows{}, nil
	case qSyncMethod:
		c.f.add("sync_method")
		return &applyFakeRows{rows: [][]driver.Value{{int64(0)}}}, nil
	}
	if strings.HasSuffix(q, "\n"+qJobFailedAfter) {
		// The T passed must be a datetime, the type it was read as.
		c.f.add(fmt.Sprintf("job failure %T %v", args[0].Value, time.Time(args[0].Value.(mssql.DateTime1)).Format(time.RFC3339Nano)))
		if c.f.failureErr != nil {
			return nil, c.f.failureErr
		}
		if c.f.jobFailure == nil {
			return &applyFakeRows{}, nil
		}
		return &applyFakeRows{rows: [][]driver.Value{c.f.jobFailure}}, nil
	}
	if strings.HasSuffix(q, "SELECT CASE WHEN "+plan.JobIdle+" THEN 1 ELSE 0 END;") {
		c.f.add("idle")
		return &applyFakeRows{rows: [][]driver.Value{{int64(1)}}}, nil
	}
	c.f.add("query " + q)
	return nil, fmt.Errorf("fake: unexpected query %q", q)
}

type applyFakeRows struct{ rows [][]driver.Value }

// Columns is one column, or as many as the first row has.
func (r *applyFakeRows) Columns() []string {
	if len(r.rows) > 0 && len(r.rows[0]) > 1 {
		return make([]string, len(r.rows[0]))
	}
	return []string{"rc"}
}
func (*applyFakeRows) Close() error { return nil }
func (r *applyFakeRows) Next(dest []driver.Value) error {
	if len(r.rows) == 0 {
		return io.EOF
	}
	copy(dest, r.rows[0])
	r.rows = r.rows[1:]
	return nil
}

// newFakeServer registers a fake server under a name unique to the test
// and returns its pool and its log.
func newFakeServer(t *testing.T) (*sql.DB, *fakeServer) {
	t.Helper()
	f := &fakeServer{}
	name := fmt.Sprintf("%s-%d", t.Name(), time.Now().UnixNano())
	fakeServersMu.Lock()
	fakeServers[name] = f
	fakeServersMu.Unlock()
	db, err := sql.Open("applyfake", name)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	return db, f
}

// opOf is a hand-written operation of the plan.
func opOf(seq int, kind, action, path string) plan.Operation {
	return plan.Operation{Seq: seq, Step: 6, Kind: kind, Action: action, Path: path, Server: "REPLLAB", Database: "Sales",
		Call:  plan.Call{Procedure: "sp_changepublication", Params: []plan.Param{{Name: "@publication", Value: "N'SalesPub'"}}},
		Costs: []plan.Cost{plan.CostOnline}}
}

// onePlan is a plan of REPLLAB.Sales with one online operation.
func onePlan() *plan.Plan {
	return &plan.Plan{Publisher: "REPLLAB", Database: "Sales", DistributionDB: "distribution",
		Operations: []plan.Operation{opOf(1, "publication_property", "change", "publications[SalesPub].retention")},
		Totals:     plan.Totals{Operations: 1, ByCost: map[plan.Cost]int{plan.CostOnline: 1}}}
}

// statementSent tells whether the log holds a batch other than the lock,
// its release, their USE and the probes: a statement of the plan.
func statementSent(log []string) bool {
	for _, b := range log {
		switch {
		case strings.HasPrefix(b, "lock "), strings.HasPrefix(b, "unlock "), strings.HasPrefix(b, "USE "),
			b == "SELECT 1;", b == "SELECT @@TRANCOUNT;":
		default:
			return true
		}
	}
	return false
}

func TestRunRefusals(t *testing.T) {
	type tc struct {
		name    string
		plan    func() *plan.Plan
		target  func(*Target)
		secret  func(string) (string, bool)
		confirm func(sig chan os.Signal) func(string) (bool, error)
		want    Outcome
		out     string // a line the output holds
		noWait  bool   // -wait 0
	}
	never := func(called *bool) func(chan os.Signal) func(string) (bool, error) {
		return func(chan os.Signal) func(string) (bool, error) {
			return func(string) (bool, error) { *called = true; return true, nil }
		}
	}
	block := make(chan struct{})
	t.Cleanup(func() { close(block) })
	var called bool
	cases := []tc{
		{name: "refused plan", plan: func() *plan.Plan {
			p := onePlan()
			p.Refusals = []plan.Refusal{{Path: "publications[SalesPub].retention", Reason: "not measured"}}
			return p
		}, want: OutcomeRefused, out: "Plan refused."},
		{name: "failed precondition", plan: func() *plan.Plan {
			p := onePlan()
			p.Preconditions = []plan.Precondition{{Name: "published table", Server: "REPLLAB", Object: "dbo.T", Status: "failed", Detail: "does not exist"}}
			return p
		}, want: OutcomeRefused, out: "refused: precondition published table dbo.T at REPLLAB is failed: does not exist"},
		{name: "unchecked msdb job permission", plan: func() *plan.Plan {
			p := onePlan()
			p.Preconditions = []plan.Precondition{
				{Name: "subscriber database", Server: "GONE", Object: "D", Status: "unchecked"},
				{Name: "msdb job permission", Server: "REPLLAB", Object: "x", Status: "unchecked", Detail: "not read"}}
			return p
		}, want: OutcomeRefused, out: "refused: precondition msdb job permission x at REPLLAB is unchecked: not read"},
		{name: "secret not returned", plan: func() *plan.Plan {
			p := onePlan()
			p.Secrets = []plan.SecretUse{{Name: "SQLREPL_X", Set: true, Operations: []int{1}}}
			return p
		}, secret: func(string) (string, bool) { return "", false }, want: OutcomeRefused, out: "secret SQLREPL_X is not set"},
		{name: "empty plan", plan: func() *plan.Plan {
			return &plan.Plan{Publisher: "REPLLAB", Database: "Sales"}
		}, want: OutcomeEmpty, out: "Plan for REPLLAB.Sales: no changes."},
		{name: "confirm false", plan: onePlan, confirm: func(chan os.Signal) func(string) (bool, error) {
			return func(string) (bool, error) { return false, nil }
		}, want: OutcomeCancelled, out: "Apply cancelled."},
		{name: "interrupt at the prompt", plan: onePlan, confirm: func(sig chan os.Signal) func(string) (bool, error) {
			return func(string) (bool, error) {
				sig <- os.Interrupt
				<-block
				return true, nil
			}
		}, want: OutcomeCancelled, out: "Apply cancelled."},
		{name: "generate_and_wait with -wait 0", plan: func() *plan.Plan {
			p := onePlan()
			p.Operations = append(p.Operations, opOf(2, "generate_and_wait", "start", "publications[SalesPub].snapshot_agent"))
			p.Totals.Operations = 2
			return p
		}, noWait: true, want: OutcomeRefused, out: "refused: -defer-full-snapshot needs -wait above 0"},
		{name: "agent_profiles without the distributor lock", plan: func() *plan.Plan {
			p := onePlan()
			p.Operations = append(p.Operations, opOf(2, "profile", "add", "agent_profiles[m_prof]"))
			p.Totals.Operations = 2
			return p
		}, want: OutcomeRefused, out: "refused: operation 2 changes agent_profiles[m_prof], shared with other publication databases, without the distributor lock"},
	}
	for _, c := range cases {
		db, f := newFakeServer(t)
		called = false
		sig := make(chan os.Signal, 1)
		confirm := never(&called)
		if c.confirm != nil {
			confirm = c.confirm
		}
		var out bytes.Buffer
		tg := Target{Server: "REPLLAB", Database: "Sales", Servers: Servers{"REPLLAB": db},
			Plan: func(context.Context) (*plan.Plan, error) { return c.plan(), nil }}
		secret := c.secret
		if secret == nil {
			secret = func(string) (string, bool) { return "v", true }
		}
		done := make(chan struct{})
		var res *Result
		var err error
		wait := time.Minute
		if c.noWait {
			wait = 0
		}
		go func() {
			defer close(done)
			res, err = Run(context.Background(), tg, Options{Wait: wait, Timeout: 5 * time.Second,
				Confirm: confirm(sig), Secret: secret, Out: &out, Interrupt: sig})
		}()
		select {
		case <-done:
		case <-time.After(10 * time.Second):
			t.Fatalf("%s: Run did not return", c.name)
		}
		if err != nil {
			t.Errorf("%s: %v", c.name, err)
			continue
		}
		if res.Outcome != c.want {
			t.Errorf("%s: outcome %q, want %q\n%s", c.name, res.Outcome, c.want, out.String())
		}
		if !strings.Contains(out.String(), c.out) {
			t.Errorf("%s: output lacks %q:\n%s", c.name, c.out, out.String())
		}
		if c.want != OutcomeCancelled && called {
			t.Errorf("%s: Confirm was called", c.name)
		}
		if statementSent(f.log()) {
			t.Errorf("%s: a statement was sent: %q", c.name, f.log())
		}
		if f.count("lock sqlrepl apply") != 1 || f.count("unlock sqlrepl apply") != 1 {
			t.Errorf("%s: lock and release batches %q, want one of each", c.name, f.log())
		}
		if len(res.Ran) != 0 {
			t.Errorf("%s: ran %v", c.name, res.Ran)
		}
		if code := res.ExitCode(); (c.want == OutcomeEmpty) != (code == 0) {
			t.Errorf("%s: exit code %d", c.name, code)
		}
	}

	// With DistributionDB set, the second lock batch is sent before Plan
	// is called, and the agent_profiles operation is not refused.
	db, f := newFakeServer(t)
	var atPlan []string
	tg := Target{Server: "REPLLAB", Database: "Sales", Distributor: "REPLLAB", DistributionDB: "distribution",
		Servers: Servers{"REPLLAB": db},
		Plan: func(context.Context) (*plan.Plan, error) {
			atPlan = f.log()
			p := onePlan()
			p.Operations = append(p.Operations, opOf(2, "profile", "add", "agent_profiles[m_prof]"))
			p.Totals.Operations = 2
			return p, nil
		}}
	var out bytes.Buffer
	res, err := Run(context.Background(), tg, Options{Wait: time.Minute, Timeout: 5 * time.Second,
		Confirm: func(string) (bool, error) { return false, nil }, Out: &out})
	if err != nil {
		t.Fatal(err)
	}
	if res.Outcome != OutcomeCancelled {
		t.Errorf("with the distributor lock: outcome %q, want cancelled\n%s", res.Outcome, out.String())
	}
	locks := 0
	for _, b := range atPlan {
		if b == "lock "+lockResource || b == "lock "+distributorLockResource {
			locks++
		}
	}
	if locks != 2 || !containsString(atPlan, "lock "+distributorLockResource) {
		t.Errorf("batches before Plan %q, want both lock batches", atPlan)
	}
	if !strings.Contains(out.String(), "lock taken on REPLLAB.master") {
		t.Errorf("output lacks the second lock line:\n%s", out.String())
	}

	if f.count("unlock ") != 2 {
		t.Errorf("release batches %q, want two", f.log())
	}
}

// TestRunDistributorLockInMaster pins R45a: the distributor lock is taken
// and released in master, never in the distribution database, which a run
// may have to create (Task 13: 911 at the lock on a fresh instance).
func TestRunDistributorLockInMaster(t *testing.T) {
	db, f := newFakeServer(t)
	tg := Target{Server: "REPLLAB", Database: "Sales", Distributor: "REPLLAB", DistributionDB: "distribution",
		Servers: Servers{"REPLLAB": db},
		Plan:    func(context.Context) (*plan.Plan, error) { return onePlan(), nil }}
	var out bytes.Buffer
	if _, err := Run(context.Background(), tg, Options{Wait: time.Minute, Timeout: 5 * time.Second,
		Confirm: func(string) (bool, error) { return false, nil }, Out: &out}); err != nil {
		t.Fatal(err)
	}
	log := f.log()
	n := 0
	for i, b := range log {
		if b != "lock "+distributorLockResource && b != "unlock "+distributorLockResource {
			continue
		}
		n++
		if i == 0 || log[i-1] != "USE [master];" {
			t.Errorf("batch %d %q is not right after USE [master];: %q", i, b, log)
		}
	}
	if n != 2 {
		t.Errorf("%d distributor lock and release batches, want 2: %q", n, log)
	}
	if !strings.Contains(out.String(), "lock taken on REPLLAB.master") {
		t.Errorf("output lacks the distributor lock line:\n%s", out.String())
	}
}

func containsString(xs []string, s string) bool {
	for _, x := range xs {
		if x == s {
			return true
		}
	}
	return false
}

func TestApplyRefusesEmptySecret(t *testing.T) {
	db, f := newFakeServer(t)
	called := false
	var out bytes.Buffer
	tg := Target{Server: "REPLLAB", Database: "Sales", Servers: Servers{"REPLLAB": db},
		Plan: func(context.Context) (*plan.Plan, error) {
			p := onePlan()
			p.Secrets = []plan.SecretUse{{Name: "SQLREPL_X", Set: true, Operations: []int{1}}}
			return p, nil
		}}
	res, err := Run(context.Background(), tg, Options{Wait: time.Minute, Timeout: 5 * time.Second,
		Confirm: func(string) (bool, error) { called = true; return true, nil },
		Secret:  func(string) (string, bool) { return "", true }, Out: &out})
	if err != nil {
		t.Fatal(err)
	}
	if res.Outcome != OutcomeRefused || !strings.Contains(out.String(), "secret SQLREPL_X is not set") {
		t.Errorf("outcome %q, output:\n%s", res.Outcome, out.String())
	}
	if called || statementSent(f.log()) {
		t.Errorf("confirm called %v, batches %q", called, f.log())
	}
	if res.ExitCode() != 1 {
		t.Errorf("exit code %d, want 1", res.ExitCode())
	}
}

func TestExitCode(t *testing.T) {
	confirmed := []Delivery{{Publication: "p", Subscription: "S/D", Status: deliveryConfirmed, Run: `F\1`}}
	unconfirmed := []Delivery{{Publication: "p", Subscription: "S/D", Status: deliveryUnconfirmed, Detail: "x"}}
	notAwaited := []Delivery{{Publication: "p", Subscription: "S/D", Status: deliveryNotAwaited}}
	cases := []struct {
		name string
		r    Result
		want int
	}{
		// 0
		{"nothing to do", Result{Outcome: OutcomeEmpty}, 0},
		{"every operation ran, no delivery owed", Result{Outcome: OutcomeApplied, Ran: []int{1, 2}}, 0},
		{"every operation ran, every delivery confirmed", Result{Outcome: OutcomeApplied, Ran: []int{1}, Deliveries: confirmed}, 0},
		// 1
		{"a refusal, a precondition, a secret", Result{Outcome: OutcomeRefused, Remaining: []int{1}}, 1},
		{"Apply cancelled.", Result{Outcome: OutcomeCancelled, Remaining: []int{1}}, 1},
		{"a failed statement", Result{Outcome: OutcomeFailed, Ran: []int{1}, Remaining: []int{2}, Failure: &Failure{Seq: 2, Number: 245}}, 1},
		{"a spent bound before the last operation", Result{Outcome: OutcomeFailed, Ran: []int{1}, Remaining: []int{2}, Failure: &Failure{Seq: 2}}, 1},
		{"interrupt with operations unrun", Result{Outcome: OutcomeInterrupted, Ran: []int{1}, Remaining: []int{2}, Deliveries: confirmed}, 1},
		{"a failed lock release", Result{Outcome: OutcomeApplied, Ran: []int{1}, Deliveries: confirmed,
			LockReleaseFailures: []string{"lock release failed on REPLLAB.Sales: sp_releaseapplock returned -999"}}, 1},
		{"every operation ran, a job left disabled", Result{Outcome: OutcomeApplied, Ran: []int{1}, Deliveries: confirmed,
			JobsLeftDisabled: []string{"publications[p].snapshot_agent"}}, 1},
		{"the deferral's wait timed out, a job left disabled", Result{Outcome: OutcomeUnconfirmed, Ran: []int{1}, Remaining: []int{2},
			Deliveries: unconfirmed, JobsLeftDisabled: []string{"publications[p].snapshot_agent"}}, 1},
		// 3
		{"every operation ran, a delivery unconfirmed", Result{Outcome: OutcomeApplied, Ran: []int{1}, Deliveries: append(confirmed, unconfirmed...)}, 3},
		{"every operation ran, a delivery not awaited", Result{Outcome: OutcomeApplied, Ran: []int{1}, Deliveries: notAwaited}, 3},
		{"interrupt after the last operation", Result{Outcome: OutcomeInterrupted, Ran: []int{1, 2}, Deliveries: unconfirmed}, 3},
		{"the deferral's wait timed out with operations unrun", Result{Outcome: OutcomeUnconfirmed, Ran: []int{1}, Remaining: []int{2, 3},
			Deliveries: unconfirmed, Failure: &Failure{Seq: 1, Message: "timed out"}}, 3},
	}
	for _, c := range cases {
		if got := c.r.ExitCode(); got != c.want {
			t.Errorf("%s: exit code %d, want %d", c.name, got, c.want)
		}
	}
	var nilResult *Result
	if nilResult.ExitCode() != 1 {
		t.Errorf("nil result: exit code %d, want 1", nilResult.ExitCode())
	}
}

func TestUnits(t *testing.T) {
	sub := func(seq int, kind, server, subKey string) plan.Operation {
		op := plan.Operation{Seq: seq, Kind: kind, Action: "add", Server: server, Database: "Sales",
			Path:    "publications[SalesPub].subscriptions[" + subKey + "]",
			Affects: plan.Affects{Publications: []string{"SalesPub"}, Subscriptions: []string{subKey}}}
		return op
	}
	p := &plan.Plan{Operations: []plan.Operation{
		{Seq: 1, Kind: "job_disable", Action: "disable"},
		// a push subscription: sp_addsubscription then its agent
		sub(2, "subscription", "REPLLAB", "REPLLAB/m_push"),
		sub(3, "push_agent", "REPLLAB", "REPLLAB/m_push"),
		// a pull subscription: the publisher's call, the subscriber's two
		sub(4, "subscription", "REPLLAB", "REPLLAB/m_pull"),
		sub(5, "pull_subscription", "REPLLAB", "REPLLAB/m_pull"),
		sub(6, "pull_agent", "REPLLAB", "REPLLAB/m_pull"),
		// an extension of another subscription, then the agent of a third
		sub(7, "subscription", "REPLLAB", "REPLLAB/m_a"),
		sub(8, "push_agent", "REPLLAB", "REPLLAB/m_b"),
		{Seq: 9, Kind: "job_restore", Action: "restore"},
		{Seq: 10, Kind: "job_start", Action: "start"},
	}}
	got := units(p)
	want := [][]int{{1}, {2, 3}, {4}, {5}, {6}, {7}, {8}, {9}, {10}}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("units %v, want %v", got, want)
	}
}

func TestQuestion(t *testing.T) {
	p := &plan.Plan{Publisher: "REPLLAB", Database: "Sales", Totals: plan.Totals{Operations: 5, Costly: 2,
		ByCost: map[plan.Cost]int{plan.CostOnline: 3, plan.CostReinitialization: 1, plan.CostNewSnapshot: 1}}}
	want := "Apply 5 operations to REPLLAB.Sales, 2 costly (new_snapshot 1, reinitialization 1)? Type yes to apply: "
	if got := question(p); got != want {
		t.Errorf("question\n got %q\nwant %q", got, want)
	}
	p.Totals = plan.Totals{Operations: 5, ByCost: map[plan.Cost]int{plan.CostOnline: 5}}
	want = "Apply 5 operations to REPLLAB.Sales, 0 costly? Type yes to apply: "
	if got := question(p); got != want {
		t.Errorf("question\n got %q\nwant %q", got, want)
	}
}

// A restore run on a way out is a printed statement: it is logged with its
// line and its outcome, and counted as ran (fix round 1, Important 1).
func TestRunRestoreLogged(t *testing.T) {
	db, f := newFakeServer(t)
	job := func(seq, step int, kind, action, enabled string) plan.Operation {
		return plan.Operation{Seq: seq, Step: step, Kind: kind, Action: action, Path: "publications[SalesPub].snapshot_agent",
			Server: "REPLLAB", Database: "msdb", Affects: plan.Affects{Publications: []string{"SalesPub"}},
			Call: plan.Call{Procedure: "msdb.dbo.sp_update_job", Prologue: "DECLARE @job_id uniqueidentifier;",
				Params: []plan.Param{{Name: "@job_id", Value: "@job_id"}, {Name: "@enabled", Value: enabled}}},
			Costs: []plan.Cost{plan.CostOnline}}
	}
	p := &plan.Plan{Publisher: "REPLLAB", Database: "Sales", DistributionDB: "distribution",
		SnapshotJobs: map[string]string{"SalesPub": "DECLARE @job_id uniqueidentifier;"},
		Operations: []plan.Operation{
			job(1, 0, "job_disable", "disable", "0"),
			opOf(2, "publication_property", "change", "publications[SalesPub].retention"),
			job(3, 12, "job_restore", "restore", "1"),
		},
		Totals: plan.Totals{Operations: 3, ByCost: map[plan.Cost]int{plan.CostOnline: 3}}}
	var out bytes.Buffer
	tg := Target{Server: "REPLLAB", Database: "Sales", Servers: Servers{"REPLLAB": db},
		Plan: func(context.Context) (*plan.Plan, error) { return p, nil }}
	res, err := Run(context.Background(), tg, Options{Wait: time.Minute, Timeout: 5 * time.Second, AutoApprove: true, Out: &out,
		BeforeStatement: func(seq int) error {
			if seq == 2 {
				return fmt.Errorf("stop at 2")
			}
			return nil
		}})
	if err != nil {
		t.Fatal(err)
	}
	o := out.String()
	if res.Outcome != OutcomeFailed || fmt.Sprint(res.Ran) != "[1 3]" || fmt.Sprint(res.Remaining) != "[2]" {
		t.Errorf("outcome %q, ran %v, remaining %v\n%s", res.Outcome, res.Ran, res.Remaining, o)
	}
	line := "[3/3] restore job_restore publications[SalesPub].snapshot_agent at REPLLAB, database msdb\n  DECLARE @job_id uniqueidentifier;\n  EXEC msdb.dbo.sp_update_job @job_id = @job_id, @enabled = 1;\n  ok ("
	if !strings.Contains(o, line) {
		t.Errorf("output lacks the restore's statement and outcome:\n%s", o)
	}
	if !strings.Contains(o, "Remaining: 2\n") || !strings.Contains(o, "Applied 2 of 3 operations") {
		t.Errorf("output's last lines:\n%s", o)
	}
	if n := f.count("exec "); n != 2 {
		t.Errorf("%d job statements sent, want the disable and the restore: %q", n, f.log())
	}
	if len(res.JobsLeftDisabled) != 0 {
		t.Errorf("jobs left disabled %v", res.JobsLeftDisabled)
	}
}

// A failed record of the deliveries owed before the plan is an error of
// Run, before any operation, with the locks released (fix round 1).
func TestRunOwedBeforeIsAnError(t *testing.T) {
	db, f := newFakeServer(t)
	p := onePlan()
	p.OwedBefore = []plan.Owed{{Publication: "SalesPub", Subscription: "REPLLAB/SalesSub"}}
	tg := Target{Server: "REPLLAB", Database: "Sales", Servers: Servers{"REPLLAB": db},
		Plan: func(context.Context) (*plan.Plan, error) { return p, nil }}
	res, err := Run(context.Background(), tg, Options{Wait: time.Minute, Timeout: 5 * time.Second, AutoApprove: true, Out: io.Discard})
	if err == nil || res != nil || !strings.Contains(err.Error(), "record the deliveries owed before the plan") {
		t.Errorf("result %+v, error %v", res, err)
	}
	if f.count("unlock "+lockResource) != 1 || f.count("exec ") != 0 {
		t.Errorf("batches %q", f.log())
	}
}

func TestDeliveryLine(t *testing.T) {
	cases := []struct {
		d    Delivery
		want string
	}{
		{Delivery{Publication: "p", Subscription: "S/D", Status: deliveryConfirmed, Run: `F\20261113012708`},
			`delivery p to S/D: confirmed (run F\20261113012708)`},
		{Delivery{Publication: "p", Subscription: "S/D", Status: deliveryNotAwaited}, "delivery p to S/D: not awaited"},
		{Delivery{Publication: "p", Subscription: "S/D", Status: deliveryUnconfirmed, Detail: "no Delivered snapshot line of a new run",
			JobState: "running", LastHistory: "Waiting for\r\nthe snapshot"},
			"delivery p to S/D: unconfirmed (no Delivered snapshot line of a new run; job running; last history: Waiting for the snapshot)"},
		{Delivery{Publication: "p", Subscription: "S/D", Status: deliveryUnconfirmed, Detail: "x"},
			"delivery p to S/D: unconfirmed (x; job unknown; last history: none)"},
	}
	for _, c := range cases {
		if got := deliveryLine(c.d); got != c.want {
			t.Errorf("line\n got %q\nwant %q", got, c.want)
		}
	}
}

// failure keeps the text a step wrapped around a server error before its
// number and message (fix round 1).
func TestFailureKeepsStep(t *testing.T) {
	r := &runner{}
	se := mssql.Error{Number: 208, Message: "Invalid object name 'x'."}
	f := r.failure(4, fmt.Errorf("record the deliveries owed by operation 4: %w", se))
	if got := f.text(); got != "record the deliveries owed by operation 4: Msg 208: Invalid object name 'x'." {
		t.Errorf("wrapped: %q", got)
	}
	if got := r.failure(4, se).text(); got != "Msg 208: Invalid object name 'x'." {
		t.Errorf("bare: %q", got)
	}
	if got := r.failure(4, fmt.Errorf("stop at 4")).text(); got != "stop at 4" {
		t.Errorf("not a server error: %q", got)
	}
}

// A job_restore that fails, on the success path and again on the way out,
// never ends the run applied: the statement failed and the job is left
// disabled, exit 1 (R48, R52; Task 11 fix round 2).
func TestRunFailedRestore(t *testing.T) {
	db, f := newFakeServer(t)
	f.failRestore = true
	job := func(seq, step int, kind, action, enabled string) plan.Operation {
		return plan.Operation{Seq: seq, Step: step, Kind: kind, Action: action, Path: "publications[SalesPub].snapshot_agent",
			Server: "REPLLAB", Database: "msdb", Affects: plan.Affects{Publications: []string{"SalesPub"}},
			Call: plan.Call{Procedure: "msdb.dbo.sp_update_job", Prologue: "DECLARE @job_id uniqueidentifier;",
				Params: []plan.Param{{Name: "@job_id", Value: "@job_id"}, {Name: "@enabled", Value: enabled}}},
			Costs: []plan.Cost{plan.CostOnline}}
	}
	p := &plan.Plan{Publisher: "REPLLAB", Database: "Sales", DistributionDB: "distribution",
		SnapshotJobs: map[string]string{"SalesPub": "DECLARE @job_id uniqueidentifier;"},
		Operations: []plan.Operation{
			job(1, 0, "job_disable", "disable", "0"),
			job(2, 12, "job_restore", "restore", "1"),
		},
		Totals: plan.Totals{Operations: 2, ByCost: map[plan.Cost]int{plan.CostOnline: 2}}}
	var out bytes.Buffer
	tg := Target{Server: "REPLLAB", Database: "Sales", Servers: Servers{"REPLLAB": db},
		Plan: func(context.Context) (*plan.Plan, error) { return p, nil }}
	res, err := Run(context.Background(), tg, Options{Wait: time.Minute, Timeout: 2 * time.Second, AutoApprove: true, Out: &out})
	if err != nil {
		t.Fatal(err)
	}
	if res.Outcome == OutcomeApplied || res.ExitCode() != 1 {
		t.Errorf("outcome %q, exit %d, want not applied and exit 1\n%s", res.Outcome, res.ExitCode(), out.String())
	}
	if len(res.JobsLeftDisabled) != 1 {
		t.Errorf("jobs left disabled %v, want the snapshot agent's\n%s", res.JobsLeftDisabled, out.String())
	}
}

// jobPlan is a plan of REPLLAB.Sales: a job_disable of SalesPub's snapshot
// job, an online operation, and the job_restore (Task 12 fix round 2).
func jobPlan() *plan.Plan {
	job := func(seq, step int, kind, action, enabled string) plan.Operation {
		return plan.Operation{Seq: seq, Step: step, Kind: kind, Action: action, Path: "publications[SalesPub].snapshot_agent",
			Server: "REPLLAB", Database: "msdb", Affects: plan.Affects{Publications: []string{"SalesPub"}},
			Call: plan.Call{Procedure: "msdb.dbo.sp_update_job", Prologue: "DECLARE @job_id uniqueidentifier;",
				Params: []plan.Param{{Name: "@job_id", Value: "@job_id"}, {Name: "@enabled", Value: enabled}}},
			Costs: []plan.Cost{plan.CostOnline}}
	}
	return &plan.Plan{Publisher: "REPLLAB", Database: "Sales", DistributionDB: "distribution",
		SnapshotJobs: map[string]string{"SalesPub": "DECLARE @job_id uniqueidentifier;"},
		Operations: []plan.Operation{
			job(1, 0, "job_disable", "disable", "0"),
			opOf(2, "publication_property", "change", "publications[SalesPub].retention"),
			job(3, 12, "job_restore", "restore", "1"),
		},
		Totals: plan.Totals{Operations: 3, ByCost: map[plan.Cost]int{plan.CostOnline: 3}}}
}

// index is the position of the first batch of log that starts with
// prefix and holds part, -1 when there is none.
func index(log []string, prefix, part string) int {
	for i, b := range log {
		if strings.HasPrefix(b, prefix) && strings.Contains(b, part) {
			return i
		}
	}
	return -1
}

// TestRunUnlocksAfterRestores: on a way out, the restores run before the
// lock is released (R45: the unlock runs after the restores).
func TestRunUnlocksAfterRestores(t *testing.T) {
	db, f := newFakeServer(t)
	var out bytes.Buffer
	tg := Target{Server: "REPLLAB", Database: "Sales", Servers: Servers{"REPLLAB": db},
		Plan: func(context.Context) (*plan.Plan, error) { return jobPlan(), nil }}
	res, err := Run(context.Background(), tg, Options{Wait: time.Minute, Timeout: 5 * time.Second, AutoApprove: true, Out: &out,
		BeforeStatement: func(seq int) error {
			if seq == 2 {
				return fmt.Errorf("stop at 2")
			}
			return nil
		}})
	if err != nil {
		t.Fatal(err)
	}
	log := f.log()
	restore := index(log, "exec ", "@enabled = 1")
	unlock := index(log, "unlock ", lockResource)
	if res.Outcome != OutcomeFailed || restore < 0 || unlock < 0 || restore > unlock {
		t.Errorf("outcome %s, restore at %d, unlock at %d, want the restore before the unlock: %q", res.Outcome, restore, unlock, log)
	}
}

// TestRunArmsBeforeDisable: a job_disable whose call returns an error may
// have committed, so its restore is armed before it is sent and runs on
// the way out (R48, panel XD, XN).
func TestRunArmsBeforeDisable(t *testing.T) {
	db, f := newFakeServer(t)
	f.failDisable = true
	var out bytes.Buffer
	tg := Target{Server: "REPLLAB", Database: "Sales", Servers: Servers{"REPLLAB": db},
		Plan: func(context.Context) (*plan.Plan, error) { return jobPlan(), nil }}
	res, err := Run(context.Background(), tg, Options{Wait: time.Minute, Timeout: 5 * time.Second, AutoApprove: true, Out: &out})
	if err != nil {
		t.Fatal(err)
	}
	log := f.log()
	disable := index(log, "exec ", "@enabled = 0")
	restore := index(log, "exec ", "@enabled = 1")
	if res.Outcome != OutcomeFailed || res.Failure == nil || res.Failure.Seq != 1 || disable < 0 || restore < disable {
		t.Errorf("outcome %s, failure %+v, disable at %d, restore at %d, want a failure at 1 and its restore after it: %q\n%s",
			res.Outcome, res.Failure, disable, restore, log, out.String())
	}
	if fmt.Sprint(res.Ran) != "[3]" || len(res.JobsLeftDisabled) != 0 {
		t.Errorf("ran %v, jobs left disabled %v, want [3] and none", res.Ran, res.JobsLeftDisabled)
	}
}

// TestRunMasksEchoedSecret: a server message that echoes a bound value is
// masked in the output and in the Failure (R53).
func TestRunMasksEchoedSecret(t *testing.T) {
	db, f := newFakeServer(t)
	f.echoSecret = true
	const value = "p'w;--d"
	op := opOf(1, "publication_property", "change", "publications[SalesPub].password")
	op.Call.Params = append(op.Call.Params, plan.Param{Name: "@password", Secret: "SQLREPL_SQL_M"})
	p := &plan.Plan{Publisher: "REPLLAB", Database: "Sales", DistributionDB: "distribution",
		Operations: []plan.Operation{op},
		Secrets:    []plan.SecretUse{{Name: "SQLREPL_SQL_M", Set: true, Operations: []int{1}}},
		Totals:     plan.Totals{Operations: 1, ByCost: map[plan.Cost]int{plan.CostOnline: 1}}}
	var out bytes.Buffer
	tg := Target{Server: "REPLLAB", Database: "Sales", Servers: Servers{"REPLLAB": db},
		Plan: func(context.Context) (*plan.Plan, error) { return p, nil }}
	res, err := Run(context.Background(), tg, Options{Wait: time.Minute, Timeout: 5 * time.Second, AutoApprove: true, Out: &out,
		Secret: func(name string) (string, bool) { return value, name == "SQLREPL_SQL_M" }})
	if err != nil {
		t.Fatal(err)
	}
	if index(f.log(), "exec ", "@password = @secret_1") < 0 {
		t.Fatalf("the statement with the secret was not sent: %q", f.log())
	}
	o := out.String()
	if res.Outcome != OutcomeFailed || res.Failure == nil || res.Failure.Number != 50000 {
		t.Fatalf("outcome %s, failure %+v\n%s", res.Outcome, res.Failure, o)
	}
	if strings.Contains(o, value) || strings.Contains(res.Failure.Message, value) {
		t.Errorf("the bound value is printed:\n%s\nfailure %q", o, res.Failure.Message)
	}
	if !strings.Contains(o, "  failed: Msg 50000: the value **** is refused\n") {
		t.Errorf("output lacks the masked failure line:\n%s", o)
	}
}

// waitRunner is a runner at the wait for deliveries, on the fake server db,
// with one pending record of m_p to REPLLAB/m_sdb recorded at at, its
// folder known, and -wait of wait.
func waitRunner(t *testing.T, db *sql.DB, at time.Time, wait time.Duration) (*runner, *record, *bytes.Buffer, func()) {
	t.Helper()
	ctx := context.Background()
	runCtx, cancel := context.WithCancel(ctx)
	waitCtx, cancelWait := context.WithTimeout(runCtx, wait)
	var out bytes.Buffer
	p := &plan.Plan{Publisher: "REPLLAB", Database: "m_pdb", DistributionDB: "distribution",
		SnapshotJobs: map[string]string{"m_p": "DECLARE @job_id uniqueidentifier;"}}
	r := &runner{o: Options{Wait: wait, Timeout: 5 * time.Second}, p: p, out: &out, res: &Result{},
		parent: ctx, runCtx: runCtx, intr: make(chan struct{}), waitCtx: waitCtx,
		distributor: "REPLLAB", s: newSession(Servers{"REPLLAB": db})}
	r.tr = newTracker("REPLLAB", "REPLLAB")
	rec := &record{owed: owed{Publication: "m_p", Subscription: "REPLLAB/m_sdb", T: at,
		Mark: []byte{0, 0, 0, 0, 0, 0, 0x10, 0}, Folder: "REPLLAB_M_PDB_M_P"}}
	r.tr.records = []*record{rec}
	stop := func() {
		cancelWait()
		cancel()
		r.s.close()
	}
	t.Cleanup(stop)
	return r, rec, &out, func() { close(r.intr); cancel() }
}

// TestWaitForFailedGeneration pins R51a: while waiting for a delivery, a
// failed job outcome of the publication's snapshot job for a run started
// at or after T ends the delivery at once, unconfirmed, its detail naming
// the job's message; T is passed as a datetime. Without such a row the
// wait goes on until -wait is spent; an S7 record is not read.
func TestWaitForFailedGeneration(t *testing.T) {
	at := time.Date(2026, 11, 13, 5, 57, 7, 853e6, time.UTC)
	// The messages of the run measured on the lab (final fix report).
	const msg = "The job failed.  The Job was invoked by User sa.  The last step to run was step 3 (Detect nonlogged agent shutdown.)."
	const stepMsg = "Non-SysAdmins have been denied permission to run replication jobsteps without a proxy account.  The step failed."
	started := time.Date(2026, 11, 13, 5, 57, 8, 0, time.UTC)

	db, f := newFakeServer(t)
	f.jobFailure = []driver.Value{started, msg, stepMsg}
	r, rec, _, _ := waitRunner(t, db, at, 10*time.Second)
	t0 := time.Now()
	r.waitFor(func(*record) bool { return true })
	if d := time.Since(t0); d > 3*time.Second {
		t.Errorf("a failed generation was waited for %v: notes %q, batches %q", d, r.res.Notes, f.log())
	}
	// The cause is the failed step's message, not the step 0 row's.
	want := "the snapshot job of m_p failed, run started 2026-11-13 05:57:08: " + stepMsg
	if rec.unlisted != want {
		t.Errorf("detail %q, want %q", rec.unlisted, want)
	}
	if got := r.tr.results(false); len(got) != 1 || got[0].Status != deliveryUnconfirmed || got[0].Detail != want {
		t.Errorf("results %+v", got)
	}
	if !containsString(f.log(), "job failure mssql.DateTime1 2026-11-13T05:57:07.853Z") {
		t.Errorf("T not passed as a datetime: %q", f.log())
	}

	db, f = newFakeServer(t)
	r, rec, _, _ = waitRunner(t, db, at, 1500*time.Millisecond)
	t0 = time.Now()
	r.waitFor(func(*record) bool { return true })
	if d := time.Since(t0); d < time.Second || rec.unlisted != "" {
		t.Errorf("no failed outcome: waited %v, detail %q, want the whole -wait and no detail", d, rec.unlisted)
	}
	if f.count("job failure ") == 0 {
		t.Errorf("the outcome was never read: %q", f.log())
	}

	// No failed step row: the step 0 message.
	db, f = newFakeServer(t)
	f.jobFailure = []driver.Value{started, msg, nil}
	r, rec, _, _ = waitRunner(t, db, at, 10*time.Second)
	r.waitFor(func(*record) bool { return true })
	if want := "the snapshot job of m_p failed, run started 2026-11-13 05:57:08: " + msg; rec.unlisted != want {
		t.Errorf("no failed step: detail %q, want %q", rec.unlisted, want)
	}

	db, f = newFakeServer(t)
	f.jobFailure = []driver.Value{started, msg, stepMsg}
	r, rec, _, _ = waitRunner(t, db, at, 1500*time.Millisecond)
	rec.S7 = true
	r.waitFor(func(*record) bool { return true })
	if rec.unlisted != "" || f.count("job failure ") != 0 {
		t.Errorf("S7: detail %q, batches %q", rec.unlisted, f.log())
	}
}

// TestDeferWaitInterrupted pins M2 of the final review: an interrupt
// during the wait for deliveries prints one line that says so, and the
// outcome is R52's interrupt.
func TestDeferWaitInterrupted(t *testing.T) {
	db, _ := newFakeServer(t)
	r, _, out, interrupt := waitRunner(t, db, time.Date(2026, 11, 13, 5, 57, 7, 0, time.UTC), time.Minute)
	r.deferPub = "m_p"
	time.AfterFunc(300*time.Millisecond, interrupt)
	t0 := time.Now()
	if r.deferWait() {
		t.Fatal("deferWait went on after an interrupt")
	}
	if d := time.Since(t0); d > 5*time.Second {
		t.Errorf("the interrupt was seen after %v", d)
	}
	o := out.String()
	if strings.Count(o, "interrupted while waiting for the deliveries\n") != 1 {
		t.Errorf("output:\n%s", o)
	}
	if r.res.Outcome != OutcomeInterrupted {
		t.Errorf("outcome %q, want %q", r.res.Outcome, OutcomeInterrupted)
	}
}

// TestWaitForFailureUnread: when the read of R51a fails, one line says the
// generation's outcome could not be read, with the error and the bound
// secrets masked, and the wait goes on to the end of -wait.
func TestWaitForFailureUnread(t *testing.T) {
	db, f := newFakeServer(t)
	f.failureErr = mssql.Error{Number: 229, Class: 14, Message: "The SELECT permission was denied on the object 'sysjobhistory' (s3cr3t-value)."}
	r, rec, out, _ := waitRunner(t, db, time.Date(2026, 11, 13, 5, 57, 7, 0, time.UTC), 2500*time.Millisecond)
	r.values = []string{"s3cr3t-value"}
	r.out = maskWriter{w: out, values: &r.values}
	t0 := time.Now()
	r.waitFor(func(*record) bool { return true })
	if d := time.Since(t0); d < 2*time.Second || rec.unlisted != "" {
		t.Errorf("waited %v, detail %q: want the whole -wait and no detail", d, rec.unlisted)
	}
	o := out.String()
	const prefix = "the outcome of the generation could not be read, the wait goes on: read the outcome of the snapshot job of m_p: "
	if strings.Count(o, prefix) != 1 || !strings.Contains(o, "sysjobhistory") {
		t.Errorf("output:\n%s", o)
	}
	if strings.Contains(o, "s3cr3t-value") || !strings.Contains(o, "****") {
		t.Errorf("the secret is not masked:\n%s", o)
	}
	if n := f.count("job failure "); n != 1 {
		t.Errorf("the outcome was read %d times, want once", n)
	}
}
