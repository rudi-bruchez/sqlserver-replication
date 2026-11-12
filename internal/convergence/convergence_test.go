package convergence

import (
	"os"
	"reflect"
	"strings"
	"testing"

	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
	"github.com/rudi-bruchez/sqlserver-replication/internal/plan"
)

// The plan of the lab fixture against the live Sales is empty (Review Focus
// 1 and 6; the fixture has no schedule dates, R37). Read-only: no statement
// runs.
func TestLabSalesPlanEmpty(t *testing.T) {
	e := newEnv(t)
	var ready bool
	if err := e.master.QueryRow("SELECT immediate_sync_ready FROM Sales.dbo.syspublications WHERE name = N'SalesPub'").Scan(&ready); err != nil {
		t.Fatal(err)
	}
	if !ready {
		t.Fatal("SalesPub's immediate_sync_ready is 0: the lab's first snapshot run has not ended (lab/start.sh)")
	}
	f, err := os.Open("../testdata/lab/sales.yaml")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	des, err := model.Load(f)
	if err != nil {
		t.Fatal(err)
	}
	if p := e.plan(t, des, plan.Options{}); !p.Empty() {
		t.Fatalf("the plan of sales.yaml against Sales is not empty:\n%s", p.Summary())
	}
}

// step is an expected operation: its procedure and the parameters that
// tell it, a value "" meaning the parameter is absent.
type step struct {
	proc   string
	params map[string]string
}

// inOrder checks that the plan's operations hold the steps in this order,
// other operations between them allowed.
func inOrder(t *testing.T, p *plan.Plan, steps []step) {
	t.Helper()
	i := 0
	for _, op := range p.Operations {
		if i < len(steps) && procedure(op) == steps[i].proc && matches(op, steps[i].params) {
			i++
		}
	}
	if i < len(steps) {
		t.Fatalf("step %d (%s %v) not found in order in the plan:\n%s%s", i+1, steps[i].proc, steps[i].params, p.Summary(), p.SQL())
	}
}

// wantAgents checks AgentsToStart exactly, by kind, publication,
// subscriber and database (the names without regard to case, R7).
func wantAgents(t *testing.T, p *plan.Plan, want []plan.AgentRef) {
	t.Helper()
	ok := len(p.AgentsToStart) == len(want)
	for i := 0; ok && i < len(want); i++ {
		g, w := p.AgentsToStart[i], want[i]
		ok = g.Kind == w.Kind && g.Publication == w.Publication &&
			strings.EqualFold(g.Subscriber, w.Subscriber) && strings.EqualFold(g.Database, w.Database)
	}
	if !ok {
		t.Fatalf("AgentsToStart %+v, want %+v\n%s", p.AgentsToStart, want, p.Summary())
	}
}

// snapshotAndPush is the AgentsToStart of a plan that owes m_p's
// subscription a generation: the snapshot agent, then the push agent.
func (e *env) snapshotAndPush() []plan.AgentRef {
	return []plan.AgentRef{
		{Kind: "snapshot", Publication: "m_p"},
		{Kind: "distribution", Publication: "m_p", Subscriber: e.server, Database: e.sub},
	}
}

// jobsAround checks R24's job operations around the plan's article and
// subscription operations: a job_disable before the first, a job_restore
// after the last.
func jobsAround(t *testing.T, p *plan.Plan) {
	t.Helper()
	first, last := -1, -1
	for i, op := range p.Operations {
		if strings.HasPrefix(op.Kind, "article") || strings.HasPrefix(op.Kind, "subscription") {
			if first < 0 {
				first = i
			}
			last = i
		}
	}
	if first < 0 {
		t.Fatalf("no article or subscription operation\n%s", p.Summary())
	}
	disable, restore := false, false
	for i, op := range p.Operations {
		disable = disable || op.Kind == "job_disable" && i < first
		restore = restore || op.Kind == "job_restore" && i > last
	}
	if !disable || !restore {
		t.Fatalf("job_disable before the first article or subscription operation: %v, job_restore after the last: %v\n%s",
			disable, restore, p.Summary())
	}
}

// wantCosts checks an operation's cost list exactly.
func wantCosts(t *testing.T, op plan.Operation, want ...plan.Cost) {
	t.Helper()
	if !reflect.DeepEqual(op.Costs, want) {
		t.Errorf("%d %s %s costs %v, want %v", op.Seq, op.Kind, op.Path, op.Costs, want)
	}
}

// createAndDeliver plans create.yaml, runs it, starts the snapshot and
// waits until the subscriber holds m_t1's 10 rows and m_t2's 20.
func createAndDeliver(t *testing.T, e *env) *plan.Plan {
	t.Helper()
	p := e.plan(t, e.desired(t, "create.yaml"), plan.Options{})
	if len(p.Refusals) > 0 {
		t.Fatalf("create.yaml refused:\n%s", p.Summary())
	}
	wantAgents(t, p, e.snapshotAndPush())
	e.run(t, p)
	e.deliveries = []delivery{{"m_t1", 10}, {"m_t2", 20}}
	e.startAndWait(t, p)
	return p
}

func TestLabCreatePublication(t *testing.T) {
	e := labEnv(t, "create")
	des := e.desired(t, "create.yaml")
	p := e.plan(t, des, plan.Options{})
	if len(p.Refusals) > 0 {
		t.Fatalf("refused:\n%s", p.Summary())
	}
	art := func(name string) string { return "N'" + name + "'" }
	inOrder(t, p, []step{
		{"sp_replicationdboption", nil},
		{"sp_addlogreader_agent", nil},
		{"sp_addpublication", nil},
		{"sp_addpublication_snapshot", nil},
		{"sp_addarticle", map[string]string{"@article": art("m_t1")}},
		{"sp_articlefilter", map[string]string{"@article": art("m_t1")}},
		{"sp_articleview", map[string]string{"@article": art("m_t1")}},
		{"sp_addarticle", map[string]string{"@article": art("m_t2"), "@vertical_partition": ""}},
		{"sp_articlecolumn", map[string]string{"@article": art("m_t2"), "@column": art("b"), "@operation": art("drop")}},
		{"sp_articleview", map[string]string{"@article": art("m_t2"), "@filter_clause": ""}},
		{"sp_addsubscription", nil},
		{"sp_addpushsubscription_agent", nil},
	})
	jobsAround(t, p)
	wantAgents(t, p, e.snapshotAndPush())

	e.run(t, p)
	e.deliveries = []delivery{{"m_t1", 10}, {"m_t2", 20}}
	e.startAndWait(t, p)

	if n := e.count(t, "SELECT COUNT(*) FROM {sub}.dbo.m_t1 WHERE a > 0"); n != 10 {
		t.Errorf("subscriber m_t1: %d rows with a > 0, want all 10", n)
	}
	var cols []string
	rows, err := e.master.Query(e.replace("SELECT name FROM {sub}.sys.columns WHERE object_id = OBJECT_ID(N'{sub}.dbo.m_t2') ORDER BY column_id"))
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var c string
		if err := rows.Scan(&c); err != nil {
			t.Fatal(err)
		}
		cols = append(cols, c)
	}
	rows.Close()
	if want := []string{"id", "a"}; !reflect.DeepEqual(cols, want) {
		t.Errorf("subscriber m_t2 columns %q, want %q", cols, want)
	}

	// The filter holds for the changes the log reader carries.
	if _, err := e.master.Exec(e.replace("INSERT {db}.dbo.m_t1 (id, a, b) VALUES (100, -5, 0), (101, 5, 0)")); err != nil {
		t.Fatal(err)
	}
	e.waitDelivered(t, "m_t1", 11)
	if n := e.count(t, "SELECT COUNT(*) FROM {sub}.dbo.m_t1 WHERE id = 101"); n != 1 {
		t.Errorf("subscriber m_t1 lacks the row 101 (a = 5)")
	}
	if n := e.count(t, "SELECT COUNT(*) FROM {sub}.dbo.m_t1 WHERE id = 100"); n != 0 {
		t.Errorf("subscriber m_t1 holds the row 100 (a = -5)")
	}
	e.converged(t, des)
}

func TestLabAddArticle(t *testing.T) {
	e := labEnv(t, "addarticle")
	createAndDeliver(t, e)

	des := e.desired(t, "add-article.yaml")
	p := e.plan(t, des, plan.Options{})
	if len(p.Refusals) > 0 {
		t.Fatalf("refused:\n%s", p.Summary())
	}
	add, err := find(p, "sp_addarticle", map[string]string{"@article": "N'm_t3'",
		"@force_invalidate_snapshot": "", "@force_reinit_subscription": ""})
	if err != nil {
		t.Fatalf("%v\n%s", err, p.Summary())
	}
	wantCosts(t, add, plan.CostOnline)
	var exts []plan.Operation
	for _, op := range p.Operations {
		if procedure(op) == "sp_addsubscription" {
			exts = append(exts, op)
		}
	}
	if len(exts) != 1 || !matches(exts[0], map[string]string{"@article": "N'm_t3'",
		"@subscription_type": "N'push'", "@sync_type": "N'automatic'"}) {
		t.Fatalf("want one sp_addsubscription @article = N'm_t3', push, automatic\n%s%s", p.Summary(), p.SQL())
	}
	wantCosts(t, exts[0], plan.CostNewSnapshot)
	jobsAround(t, p)
	wantAgents(t, p, e.snapshotAndPush())

	e.run(t, p)
	e.deliveries = []delivery{{"m_t3", 20}}
	e.startAndWait(t, p)
	e.converged(t, des)
}

func TestLabFilterChange(t *testing.T) {
	e := labEnv(t, "filterchange")
	createAndDeliver(t, e)

	des := e.desired(t, "filter-change.yaml")
	p := e.plan(t, des, plan.Options{})
	if len(p.Refusals) > 0 {
		t.Fatalf("refused:\n%s", p.Summary())
	}
	inOrder(t, p, []step{
		{"sp_articlefilter", map[string]string{"@article": "N'm_t1'", "@filter_clause": "N'a > 5'", "@force_reinit_subscription": "1"}},
		{"sp_articleview", map[string]string{"@article": "N'm_t1'", "@filter_clause": "N'a > 5'"}},
	})
	flt, _ := find(p, "sp_articlefilter", nil)
	wantCosts(t, flt, plan.CostReinitialization, plan.CostNewSnapshot, plan.CostSubscriberDataReplaced)
	view, _ := find(p, "sp_articleview", nil)
	wantCosts(t, view, plan.CostOnline)
	jobsAround(t, p)
	wantAgents(t, p, e.snapshotAndPush())

	e.run(t, p)
	e.deliveries = []delivery{{"m_t1", 5}}
	e.startAndWait(t, p)
	if n := e.count(t, "SELECT COUNT(*) FROM {sub}.dbo.m_t1 WHERE a > 5"); n != 5 {
		t.Errorf("subscriber m_t1: %d rows with a > 5, want all 5", n)
	}
	e.converged(t, des)
}

func TestLabDropArticle(t *testing.T) {
	e := labEnv(t, "droparticle")
	createAndDeliver(t, e)

	des := e.desired(t, "drop-article.yaml")
	p := e.plan(t, des, plan.Options{})
	if len(p.Refusals) > 0 {
		t.Fatalf("refused:\n%s", p.Summary())
	}
	inOrder(t, p, []step{
		{"sp_dropsubscription", map[string]string{"@article": "N'm_t2'"}},
		{"sp_droparticle", map[string]string{"@article": "N'm_t2'",
			"@force_invalidate_snapshot": "", "@force_reinit_subscription": ""}},
	})
	dropSub, _ := find(p, "sp_dropsubscription", nil)
	wantCosts(t, dropSub, plan.CostOnline, plan.CostSubscriberObjectLeft)
	dropArt, _ := find(p, "sp_droparticle", nil)
	wantCosts(t, dropArt, plan.CostOnline, plan.CostSubscriberObjectLeft)
	jobsAround(t, p)
	wantAgents(t, p, nil)

	e.run(t, p)
	e.deliveries = nil
	e.startAndWait(t, p)
	if n := e.count(t, "SELECT COUNT(*) FROM {sub}.sys.tables WHERE name = N'm_t2'"); n != 1 {
		t.Errorf("subscriber m_t2 is gone after the drop of the article, want it left behind")
	}
	e.converged(t, des)
}
