package apply

import (
	"database/sql"
	"encoding/json"
	"errors"
	"net"
	"os"
	"testing"
	"time"

	mssql "github.com/microsoft/go-mssqldb"

	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
	"github.com/rudi-bruchez/sqlserver-replication/internal/plan"
	"github.com/rudi-bruchez/sqlserver-replication/internal/state"
)

// labFixture is the lab fixture of internal/plan's tests: sales.yaml and
// the capture-time facts.
func labFixture(t *testing.T) (*model.Config, *state.Facts) {
	t.Helper()
	f, err := os.Open("../testdata/lab/sales.yaml")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	c, err := model.Load(f)
	if err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile("../testdata/lab/sales-facts.json")
	if err != nil {
		t.Fatal(err)
	}
	var facts state.Facts
	if err := json.Unmarshal(b, &facts); err != nil {
		t.Fatal(err)
	}
	return c, &facts
}

// fixturePlan builds the plan of the fixture against itself after edit, as
// TestBuildJobOperations (internal/plan) does, and fails on a refusal.
func fixturePlan(t *testing.T, edit func(des *model.Config)) *plan.Plan {
	t.Helper()
	des, facts := labFixture(t)
	cur, _ := labFixture(t)
	edit(des)
	p := plan.Build(plan.Inputs{Desired: des, Current: cur, Facts: facts}, plan.Options{})
	for _, r := range p.Refusals {
		t.Errorf("unexpected refusal %s: %s", r.Path, r.Reason)
	}
	if t.Failed() {
		t.FailNow()
	}
	return p
}

func fixturePub(t *testing.T, c *model.Config, name string) *model.Publication {
	t.Helper()
	for i := range c.Publications {
		if c.Publications[i].Name == name {
			return &c.Publications[i]
		}
	}
	t.Fatalf("no publication %s", name)
	return nil
}

func ofKind(ops []plan.Operation, kind string) []plan.Operation {
	var out []plan.Operation
	for _, op := range ops {
		if op.Kind == kind {
			out = append(out, op)
		}
	}
	return out
}

func firstOf(xs []string) string {
	if len(xs) == 0 {
		return ""
	}
	return xs[0]
}

func TestRestoreFor(t *testing.T) {
	str := func(s string) *string { return &s }
	table := func(name string) model.Article {
		return model.Article{Name: name, Source: model.ObjectName{Schema: "dbo", Name: name}}
	}
	cases := []struct {
		name  string
		edit  func(des *model.Config)
		pub   string // the publication of the one disable
		step  int    // its step
		guard string // the restore's guard
	}{
		{"an article added to SalesRef", func(des *model.Config) {
			p := fixturePub(t, des, "SalesRef")
			p.Articles = append(p.Articles, table("m_t"))
		}, "SalesRef", 0, ""},
		{"a created publication", func(des *model.Config) {
			des.Publications = append(des.Publications, model.Publication{Name: "m_p", Type: str("transactional"),
				Status: str("active"), SyncMethod: str("native"), Articles: []model.Article{table("m_t")}})
		}, "m_p", 8, ""},
		{"a dropped publication (R61)", func(des *model.Config) {
			des.Publications = des.Publications[:1]
			des.Publisher.SharedDistributionAgents = nil
		}, "SalesRef", 0, "@job_id IS NOT NULL"},
	}
	for _, c := range cases {
		p := fixturePlan(t, c.edit)
		disables := ofKind(p.Operations, "job_disable")
		if len(disables) == 0 {
			t.Errorf("%s: no job_disable in the plan", c.name)
			continue
		}
		found := false
		for _, d := range disables {
			r, ok := restoreFor(p, d)
			if !ok {
				t.Errorf("%s: no restore for the disable %d %s", c.name, d.Seq, d.Path)
				continue
			}
			if r.Kind != "job_restore" || r.Path != d.Path || r.Seq <= d.Seq {
				t.Errorf("%s: the disable %d %s maps to %d %s %s", c.name, d.Seq, d.Path, r.Seq, r.Kind, r.Path)
			}
			if firstOf(d.Affects.Publications) == c.pub {
				found = true
				if d.Step != c.step || r.Call.Guard != c.guard {
					t.Errorf("%s: the disable of %s is in step %d and its restore guarded %q, want step %d and %q",
						c.name, c.pub, d.Step, r.Call.Guard, c.step, c.guard)
				}
			}
		}
		if !found {
			t.Errorf("%s: no disable of %s", c.name, c.pub)
		}
	}

	// A disable with no restore of its Path, and an operation that is not a
	// disable, map to nothing.
	p := fixturePlan(t, cases[0].edit)
	d := ofKind(p.Operations, "job_disable")[0]
	d.Path = "publications[m_none].snapshot_agent"
	if r, ok := restoreFor(p, d); ok {
		t.Errorf("a disable of no restored job maps to %d %s", r.Seq, r.Path)
	}
	if r, ok := restoreFor(p, ofKind(p.Operations, "job_restore")[0]); ok {
		t.Errorf("a restore maps to %d %s", r.Seq, r.Path)
	}
}

func TestIdleQuery(t *testing.T) {
	const lookup = "DECLARE @job_id uniqueidentifier;\nSELECT @job_id = job_id FROM msdb.dbo.sysjobs WHERE name = N'm';"
	want := lookup + "\nSELECT CASE WHEN " + plan.JobIdle + " THEN 1 ELSE 0 END;"
	if got := idleQuery(lookup); got != want {
		t.Errorf("idleQuery =\n%s\nwant\n%s", got, want)
	}
	// A lookup ending with a newline gets no blank line.
	if got := idleQuery(lookup + "\n"); got != want {
		t.Errorf("idleQuery of a lookup ending with a newline =\n%s\nwant\n%s", got, want)
	}
}

// TestStartOutcome is the decision of session.start (Task 7 review, minor
// 5): SQL Server Agent stopped cannot be measured on the lab, whose rules
// forbid stopping it, so the decision is tested on the Task 2 wordings.
func TestStartOutcome(t *testing.T) {
	busy := mssql.Error{Number: 22022, Class: 16, Message: busyRunning}
	pending := mssql.Error{Number: 22022, Class: 16, Message: busyPending}
	stopped := mssql.Error{Number: 22022, Class: 16, Message: agentDown}
	other := mssql.Error{Number: 50000, Class: 16, Message: "m"}
	readFailed := errors.New("read @@TRANCOUNT: driver: bad connection")
	cases := []struct {
		name     string
		started  bool
		runErr   error
		n        int
		readErr  error
		want     bool
		wantErr  bool
		tranOpen bool
	}{
		{"busy running", false, busy, 0, nil, false, false, false},
		{"busy pending", false, pending, 0, nil, false, false, false},
		{"busy then 266", false, with266(22022, busyRunning), 0, nil, false, false, false},
		{"busy with a transaction left", false, busy, 1, nil, false, true, false},
		{"busy, the read failed", false, busy, 0, readFailed, false, true, false},
		{"agent stopped", false, stopped, 0, nil, false, true, false},
		{"other error", false, other, 0, nil, false, true, false},
		{"not a driver error", false, errors.New("bad connection"), 0, nil, false, true, false},
		{"started", true, nil, 0, nil, true, false, false},
		{"skipped by the guard", false, nil, 0, nil, false, false, false},
		{"started, a transaction left", true, nil, 1, nil, false, true, true},
		{"started, the read failed", true, nil, 0, readFailed, false, true, false},
	}
	for _, c := range cases {
		got, err := startOutcome(c.started, c.runErr, c.n, c.readErr)
		if got != c.want || (err != nil) != c.wantErr || (c.tranOpen && !errors.Is(err, errTranOpen)) {
			t.Errorf("%s: startOutcome = (%t, %v), want (%t, error %t)", c.name, got, err, c.want, c.wantErr)
		}
	}
}

// TestRestoreForSameName: a publication dropped and one created under the
// same name in another case (Task 7 review, minor 7). Publications are
// matched by their exact name, so the plan drops SalesRef and creates
// SALESREF: two disables whose paths differ only in case, the step 0 one of
// SalesRef and the step 8 one of SALESREF. restoreFor compares paths
// exactly, so each maps to the restore of its own publication: SalesRef's
// to R61's guarded restore, SALESREF's to the file's. Two disables of one
// exact path cannot occur: the same exact name is a matched pair.
func TestRestoreForSameName(t *testing.T) {
	str := func(s string) *string { return &s }
	des, facts := labFixture(t)
	cur, _ := labFixture(t)
	kept := des.Publications[:0]
	for _, p := range des.Publications {
		if p.Name != "SalesRef" {
			kept = append(kept, p)
		}
	}
	des.Publications = append(kept, model.Publication{Name: "SALESREF", Type: str("transactional"), Status: str("active"),
		SyncMethod: str("native"), Articles: []model.Article{{Name: "m_t", Source: model.ObjectName{Schema: "dbo", Name: "m_t"}}}})
	p := plan.Build(plan.Inputs{Desired: des, Current: cur, Facts: facts}, plan.Options{})
	if len(p.Refusals) != 0 {
		t.Fatalf("refused: %v", p.Refusals)
	}
	want := map[string]struct {
		step  int
		guard string
	}{
		"publications[SalesRef].snapshot_agent": {0, "@job_id IS NOT NULL"},
		"publications[SALESREF].snapshot_agent": {8, ""},
	}
	seen := map[string]bool{}
	for _, op := range p.Operations {
		if op.Kind != "job_disable" {
			continue
		}
		w, ok := want[op.Path]
		if !ok || seen[op.Path] {
			t.Errorf("unexpected disable %d step %d %s", op.Seq, op.Step, op.Path)
			continue
		}
		seen[op.Path] = true
		r, ok := restoreFor(p, op)
		if !ok || r.Path != op.Path || op.Step != w.step || r.Call.Guard != w.guard {
			t.Errorf("the disable %d step %d %s maps to %t %d %s guard %q, want step %d, guard %q",
				op.Seq, op.Step, op.Path, ok, r.Seq, r.Path, r.Call.Guard, w.step, w.guard)
		}
	}
	if len(seen) != len(want) {
		t.Errorf("disables %v, want %d", seen, len(want))
	}
}

// TestRestoreBoundSilentServer: a restore at a server that accepts the
// connection and never answers returns within the driver's connection
// timeout, which bounds the connect in place of the restore's deadline
// (restoreRemaining, review probe F), and leaves the job's path disabled.
func TestRestoreBoundSilentServer(t *testing.T) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	var held []net.Conn
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			held = append(held, c) // accepted, never answered
		}
	}()
	db, err := sql.Open("sqlserver", "sqlserver://u:p@"+l.Addr().String()+"?encrypt=disable&connection+timeout=2")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	s := newSession(Servers{"SILENT": db})
	defer s.close()
	op := plan.Operation{Seq: 1, Kind: "job_restore", Path: "jobs[m_silent]", Server: "SILENT", Database: "msdb",
		Call: plan.Call{Procedure: "msdb.dbo.sp_update_job", Params: []plan.Param{{Name: "@job_name", Value: "N'm_silent'"}, {Name: "@enabled", Value: "1"}}}}
	p := &plan.Plan{Operations: []plan.Operation{op}}
	j := jobs{armed: []int{1}}
	begin := time.Now()
	left := j.restoreRemaining(s, p, 500*time.Millisecond, noSecret)
	d := time.Since(begin)
	if len(left) != 1 || left[0] != "jobs[m_silent]" {
		t.Errorf("left %q, want the job's path", left)
	}
	if d > 4*time.Second {
		t.Errorf("the restore took %v, past the connection timeout of 2 s", d)
	}
	t.Logf("restore at a silent server returned after %v", d.Round(10*time.Millisecond))
}
