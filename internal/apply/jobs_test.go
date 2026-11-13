package apply

import (
	"encoding/json"
	"os"
	"testing"

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
