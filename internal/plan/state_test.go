package plan

import (
	"encoding/json"
	"os"
	"reflect"
	"strings"
	"testing"

	"github.com/rudi-bruchez/sqlserver-replication/internal/cost"
	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
	"github.com/rudi-bruchez/sqlserver-replication/internal/state"
)

func loadLab(t *testing.T) (*model.Config, *state.Facts) {
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

func labState(t *testing.T) *State {
	t.Helper()
	c, f := loadLab(t)
	return NewState(c, f)
}

// testOp builds an operation of the given step and order, with the entry
// of change (cost.Lookup on a transactional publication).
func testOp(t *testing.T, order string, change, dir, pub, art string, params ...Param) Operation {
	t.Helper()
	e, ok := cost.Lookup(change, dir, "transactional")
	if !ok {
		t.Fatalf("no cost entry for %s %s", change, dir)
	}
	op := Operation{Step: 7, Order: order, Kind: "test", Call: Call{Params: params}, entry: &e}
	op.Affects.Publications = []string{pub}
	if art != "" {
		op.Affects.Articles = []string{art}
	}
	return op
}

func addArticleOp(t *testing.T, order, pub, art string) Operation {
	op := testOp(t, order, cost.OpAddArticle, "", pub, art, Param{Name: "@publication", Value: literal(pub)}, Param{Name: "@article", Value: literal(art)})
	op.Kind, op.Action, op.Step = "article", "add", 8
	return op
}

func addSubOp(t *testing.T, order, pub, key, syncType string) Operation {
	op := testOp(t, order, cost.OpAddSubscription, "", pub, "",
		Param{Name: "@publication", Value: literal(pub)}, Param{Name: "@article", Value: literal("all")},
		Param{Name: "@sync_type", Value: literal(syncType)})
	op.Kind, op.Action, op.Step = "subscription", "add", 9
	op.Affects.Subscriptions = []string{key}
	return op
}

func extendOp(t *testing.T, order, pub, key, art string) Operation {
	op := testOp(t, order, cost.OpExtendSubscription, "", pub, art,
		Param{Name: "@publication", Value: literal(pub)}, Param{Name: "@article", Value: literal(art)})
	op.Kind, op.Action, op.Step = "subscription_extension", "add", 9
	op.Affects.Subscriptions = []string{key}
	return op
}

func hasParam(op Operation, name string) bool {
	for _, p := range op.Call.Params {
		if p.Name == name {
			return p.Value == "1"
		}
	}
	return false
}

func rowsOf(st *State, pub, sub string) map[string]int {
	return st.Pubs[pub].Subs[strings.ToLower(sub)].Rows
}

const labSub = "REPLLAB/SalesSub"

// withSub adds an observed subscription to every article of pub, its rows
// at 2: an add_subscription op is in step 9 and sorts after the step 8
// article additions, so a subscription the add must find is observed.
func withSub(st *State, pub, key, init string) *State {
	ps := st.Pubs[pub]
	sub := &SubState{Key: key, Init: init, Rows: map[string]int{}}
	for a := range ps.Articles {
		sub.Rows[a] = 2
	}
	ps.Subs[strings.ToLower(key)] = sub
	return st
}

func TestNewStateFromFacts(t *testing.T) {
	st := labState(t)
	pub, ref := st.Pubs["SalesPub"], st.Pubs["SalesRef"]
	if pub == nil || ref == nil {
		t.Fatalf("publications: %v", st.Pubs)
	}
	if !pub.Ready || !pub.ImmediateSync {
		t.Errorf("SalesPub: Ready %v ImmediateSync %v, want true true", pub.Ready, pub.ImmediateSync)
	}
	if ref.Ready {
		t.Error("SalesRef: Ready true, want false")
	}
	if !st.LogReader {
		t.Error("LogReader false")
	}
	for name, want := range map[string][]string{"SalesPub": {"Customer", "Orders"}, "SalesRef": {"Product", "vCustomerFR"}} {
		ps := st.Pubs[name]
		if len(ps.Subs) != 1 {
			t.Errorf("%s: %d subscriptions, want 1", name, len(ps.Subs))
		}
		for _, sub := range ps.Subs {
			wantRows := map[string]int{}
			for _, a := range want {
				wantRows[a] = 2
			}
			if !reflect.DeepEqual(sub.Rows, wantRows) {
				t.Errorf("%s %s rows %v, want %v", name, sub.Key, sub.Rows, wantRows)
			}
		}
	}
}

func TestPendingDefinition(t *testing.T) {
	mk := func(imm, active bool, status int) *State {
		return &State{Pubs: map[string]*PubState{"P": {
			Exists: true, ImmediateSync: imm,
			Articles: map[string]bool{"a": active},
			Subs:     map[string]*SubState{"s/d": {Key: "s/d", Init: initSnapshot, Rows: map[string]int{"a": status}}},
		}}}
	}
	if !mk(true, true, 1).Pending("P") {
		t.Error("a row at 1 is not pending")
	}
	if !mk(false, false, 2).Pending("P") {
		t.Error("an inactive subscribed article without immediate_sync is not pending")
	}
	if mk(true, false, 2).Pending("P") {
		t.Error("an inactive article with every row at 2 on an immediate_sync publication is pending")
	}
	if mk(false, true, 2).Pending("P") {
		t.Error("active article, rows at 2: pending")
	}
}

func TestPredictAddArticle(t *testing.T) {
	st := labState(t)
	ops, rs := finish([]Operation{addArticleOp(t, "a", "SalesPub", "m_t9"), addArticleOp(t, "b", "SalesPub", "m_t10")}, st)
	if len(rs) != 0 {
		t.Fatalf("refusals %v", rs)
	}
	if !hasParam(ops[0], paramInvalidate) {
		t.Errorf("first add_article: no %s = 1: %v", paramInvalidate, ops[0].Call.Params)
	}
	if hasParam(ops[0], paramReinit) {
		t.Error("first add_article passes the reinit flag")
	}
	if hasParam(ops[1], paramInvalidate) {
		t.Errorf("second add_article: %s passed on a predicted unready publication", paramInvalidate)
	}
	if st.Pubs["SalesPub"].Ready {
		t.Error("Ready true after the add")
	}
	for _, sub := range st.Pubs["SalesPub"].Subs {
		if sub.Rows["m_t9"] != 1 || sub.Rows["m_t10"] != 1 {
			t.Errorf("%s rows %v, want m_t9 and m_t10 at 1", sub.Key, sub.Rows)
		}
	}
	if ops[0].Seq != 1 || ops[1].Seq != 2 {
		t.Errorf("Seq %d %d", ops[0].Seq, ops[1].Seq)
	}
}

func TestPredictReinitMarks(t *testing.T) {
	st := labState(t)
	schema := testOp(t, "a", "publications[SalesPub].articles[Customer].schema_options", "", "SalesPub", "Customer")
	pre := testOp(t, "b", "publications[SalesPub].articles[Customer].pre_creation_cmd", "", "SalesPub", "Customer")
	ops, _ := finish([]Operation{schema, pre}, st)
	if !hasParam(ops[0], paramInvalidate) || !hasParam(ops[0], paramReinit) {
		t.Errorf("schema_options: params %v, want both flags", ops[0].Call.Params)
	}
	if !reflect.DeepEqual(ops[0].Costs, []Cost{CostReinitialization, CostNewSnapshot}) {
		t.Errorf("schema_options costs %v", ops[0].Costs)
	}
	if !reflect.DeepEqual(ops[0].Affects.Subscriptions, []string{labSub}) {
		t.Errorf("schema_options reinitializes %v", ops[0].Affects.Subscriptions)
	}
	if hasParam(ops[1], paramReinit) {
		t.Error("pre_creation_cmd after schema_options passes the reinit flag")
	}
	if !reflect.DeepEqual(ops[1].Costs, []Cost{CostPendingSnapshotStart}) {
		t.Errorf("pre_creation_cmd costs %v", ops[1].Costs)
	}
	if got := rowsOf(st, "SalesPub", labSub); !reflect.DeepEqual(got, map[string]int{"Customer": 1, "Orders": 2}) {
		t.Errorf("rows %v, want Customer 1 and Orders 2", got)
	}

	st = labState(t)
	sm := testOp(t, "a", "publications[SalesPub].sync_method", "concurrent>native", "SalesPub", "")
	ops, _ = finish([]Operation{sm}, st)
	if !hasParam(ops[0], paramInvalidate) || !hasParam(ops[0], paramReinit) {
		t.Errorf("sync_method: params %v, want both flags", ops[0].Call.Params)
	}
	if got := rowsOf(st, "SalesPub", labSub); !reflect.DeepEqual(got, map[string]int{"Customer": 1, "Orders": 1}) {
		t.Errorf("rows after sync_method %v, want every row at 1", got)
	}
	if st.Pubs["SalesPub"].SyncMethod != "native" {
		t.Errorf("sync_method %s", st.Pubs["SalesPub"].SyncMethod)
	}
}

func TestPredictImmediateSyncFalse(t *testing.T) {
	st := labState(t)
	imm := testOp(t, "a", "publications[SalesPub].immediate_sync", "to_false", "SalesPub", "")
	imm.Step = 6
	ops, _ := finish([]Operation{addArticleOp(t, "a", "SalesPub", "m_t9"), imm}, st)
	if ops[0].entry.Change != "publications[*].immediate_sync" {
		t.Fatalf("not ordered by step: %s first", ops[0].entry.Change)
	}
	if hasParam(ops[1], paramInvalidate) {
		t.Error("add_article after immediate_sync false passes the snapshot flag")
	}
	if !reflect.DeepEqual(ops[0].Costs, []Cost{CostReadySnapshotDropped}) {
		t.Errorf("immediate_sync false costs %v", ops[0].Costs)
	}
	if st.Pubs["SalesPub"].ImmediateSync {
		t.Error("ImmediateSync still true")
	}
	// Without immediate_sync the article is not subscribed by sp_addarticle.
	if _, ok := rowsOf(st, "SalesPub", labSub)["m_t9"]; ok {
		t.Error("m_t9 subscribed by the add on a publication without immediate_sync")
	}
}

func TestPredictAddSubscription(t *testing.T) {
	st := labState(t)
	finish([]Operation{addSubOp(t, "a", "SalesPub", "M_S/m_db", "automatic"), addSubOp(t, "b", "SalesRef", "M_S/m_db", "automatic")}, st)
	if got := rowsOf(st, "SalesPub", "M_S/m_db"); !reflect.DeepEqual(got, map[string]int{"Customer": 2, "Orders": 2}) {
		t.Errorf("SalesPub new rows %v, want at 2 (S7)", got)
	}
	if !st.Pubs["SalesPub"].Subs["m_s/m_db"].StartAgent {
		t.Error("a new subscription at 2 is not marked for its agent start")
	}
	if got := rowsOf(st, "SalesRef", "M_S/m_db"); !reflect.DeepEqual(got, map[string]int{"Product": 1, "vCustomerFR": 1}) {
		t.Errorf("SalesRef new rows %v, want at 1", got)
	}

	st = labState(t)
	finish([]Operation{addSubOp(t, "a", "SalesRef", "M_S/m_rso", "replication support only")}, st)
	if got := rowsOf(st, "SalesRef", "M_S/m_rso"); !reflect.DeepEqual(got, map[string]int{"Product": 2, "vCustomerFR": 2}) {
		t.Errorf("replication support only rows %v, want at 2", got)
	}
	if st.Pending("SalesRef") {
		t.Error("SalesRef pending after a replication support only subscription")
	}

	// An add on an immediate_sync publication with a snapshot and a
	// replication support only subscription.
	st = withSub(labState(t), "SalesPub", "M_S/m_rso", initRSO)
	ops, _ := finish([]Operation{addArticleOp(t, "b", "SalesPub", "m_t9")}, st)
	if rowsOf(st, "SalesPub", labSub)["m_t9"] != 1 || rowsOf(st, "SalesPub", "M_S/m_rso")["m_t9"] != 2 {
		t.Errorf("m_t9 rows: snapshot %v, rso %v", rowsOf(st, "SalesPub", labSub), rowsOf(st, "SalesPub", "M_S/m_rso"))
	}
	want := "the table of article m_t9 must exist at the subscriber of M_S/m_rso: a replication support only subscription receives no snapshot of it"
	if !reflect.DeepEqual(ops[0].Warnings, []string{want}) {
		t.Errorf("warnings %q", ops[0].Warnings)
	}

	// Extensions on a publication without immediate_sync.
	// The subscriptions are observed: the extensions are in step 9 after
	// the step 8 add.
	st = withSub(withSub(labState(t), "SalesRef", "M_S/m_rso", initRSO), "SalesRef", "M_S/m_pull", initSnapshot)
	finish([]Operation{
		addArticleOp(t, "c", "SalesRef", "m_t9"),
		extendOp(t, "d", "SalesRef", "M_S/m_rso", "m_t9"), extendOp(t, "e", "SalesRef", "M_S/m_pull", "m_t9"),
	}, st)
	if rowsOf(st, "SalesRef", "M_S/m_rso")["m_t9"] != 2 {
		t.Errorf("rso extension rows %v", rowsOf(st, "SalesRef", "M_S/m_rso"))
	}
	if rowsOf(st, "SalesRef", "M_S/m_pull")["m_t9"] != 1 {
		t.Errorf("pull extension rows %v", rowsOf(st, "SalesRef", "M_S/m_pull"))
	}
	if _, ok := rowsOf(st, "SalesRef", labSub)["m_t9"]; ok {
		t.Error("the unextended subscription got m_t9")
	}
	if !st.Pending("SalesRef") {
		t.Error("SalesRef not pending after a snapshot-initialized extension")
	}
}

func TestOperationCosts(t *testing.T) {
	costs := func(st *State, ops ...Operation) []Operation {
		t.Helper()
		out, rs := finish(ops, st)
		if len(rs) != 0 {
			t.Fatalf("refusals %v", rs)
		}
		return out
	}
	check := func(what string, op Operation, want ...Cost) {
		t.Helper()
		if !reflect.DeepEqual(op.Costs, want) {
			t.Errorf("%s: costs %v, want %v", what, op.Costs, want)
		}
	}
	bare := func(imm, ready bool) *State {
		return &State{Pubs: map[string]*PubState{"P": {Exists: true, ImmediateSync: imm, Ready: ready, Type: "transactional", SyncMethod: "native",
			Articles: map[string]bool{"a": true}, Subs: map[string]*SubState{}}}}
	}

	check("add_article on ready SalesPub", costs(labState(t), addArticleOp(t, "a", "SalesPub", "m_t9"))[0], CostNewSnapshot)
	check("add_article on SalesRef", costs(labState(t), addArticleOp(t, "a", "SalesRef", "m_t9"))[0], CostOnline)
	check("add_article without subscriptions or immediate_sync", costs(bare(false, false), addArticleOp(t, "a", "P", "m_t9"))[0], CostOnline)
	check("add_article on a ready immediate_sync publication without subscriptions", costs(bare(true, true), addArticleOp(t, "a", "P", "m_t9"))[0], CostFullGenerationDeferred)

	ops := costs(withSub(labState(t), "SalesRef", "M_S/m_rso", initRSO),
		addArticleOp(t, "b", "SalesRef", "m_t9"), extendOp(t, "c", "SalesRef", "M_S/m_rso", "m_t9"), extendOp(t, "d", "SalesRef", labSub, "m_t9"))
	check("rso extension", ops[1], CostOnline)
	if len(ops[1].Warnings) != 1 || !strings.Contains(ops[1].Warnings[0], "receives no snapshot") {
		t.Errorf("rso extension warnings %q", ops[1].Warnings)
	}
	check("extend_subscription on SalesRef", ops[2], CostNewSnapshot)
	check("rso add_subscription on SalesRef", costs(labState(t), addSubOp(t, "a", "SalesRef", "M_S/m_rso", "replication support only"))[0], CostOnline)

	check("add_subscription snapshot on SalesRef", costs(labState(t), addSubOp(t, "a", "SalesRef", "M_S/m_db", "automatic"))[0], CostNewSnapshot)
	check("add_subscription snapshot on ready SalesPub", costs(labState(t), addSubOp(t, "a", "SalesPub", "M_S/m_db", "automatic"))[0], CostOnline)

	// A strategy cost is kept after the computed ones; Totals.Costly counts
	// what is neither online nor shared_object_changed.
	drop := testOp(t, "a", cost.OpDropArticle, "", "SalesRef", "Product")
	drop.Costs = []Cost{CostSubscriberObjectLeft}
	shared := testOp(t, "b", "publications[SalesRef].description", "set", "SalesRef", "")
	shared.Costs = []Cost{CostSharedObjectChanged}
	ops = costs(labState(t), drop, shared)
	check("drop_article on SalesRef", ops[0], CostOnline, CostSubscriberObjectLeft)
	check("shared online change", ops[1], CostOnline, CostSharedObjectChanged)
	if tt := totals(ops); tt.Operations != 2 || tt.Costly != 1 || tt.ByCost[CostOnline] != 2 {
		t.Errorf("totals %+v", tt)
	}
}

func TestAgentStatus(t *testing.T) {
	const gen = "2026-11-12 04:05:06.657"
	job := func(running bool) *state.JobState {
		return &state.JobState{Exists: true, Enabled: true, Running: running}
	}
	hist := func(time string, rs int) *state.HistoryRow { return &state.HistoryRow{Time: time, RunStatus: rs} }
	cases := []struct {
		name string
		a    state.AgentFacts
		want string
	}{
		{"no job", state.AgentFacts{Kind: "distribution"}, "unknown"},
		{"running", state.AgentFacts{Job: job(true), LastHistory: hist("2026-11-12 05:00:00.000", 3)}, "running"},
		{"retrying", state.AgentFacts{Job: job(true), LastHistory: hist("2026-11-12 05:00:00.000", 5)}, "retrying"},
		{"failed", state.AgentFacts{Job: job(false), LastHistory: hist("2026-11-12 05:00:00.000", 6), LastFailure: hist("2026-11-12 05:00:00.000", 6)}, "failed"},
		{"old failure", state.AgentFacts{Job: job(false), LastHistory: hist("2026-11-12 05:00:00.000", 6), LastFailure: hist("2026-11-12 01:00:00.000", 6)}, "stopped"},
	}
	for _, c := range cases {
		if got := agentStatus(c.a, gen); got != c.want {
			t.Errorf("%s: %s, want %s", c.name, got, c.want)
		}
	}
}
