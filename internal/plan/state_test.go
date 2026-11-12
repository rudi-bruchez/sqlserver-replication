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
	if !reflect.DeepEqual(ops[1].Costs, []Cost{CostOnline}) {
		t.Errorf("pre_creation_cmd costs %v, want online (counted by schema_options, round 2)", ops[1].Costs)
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

// stepOp is testOp in a given step.
func stepOp(t *testing.T, step int, order, change, dir, pub, art string) Operation {
	t.Helper()
	op := testOp(t, order, change, dir, pub, art)
	op.Step = step
	return op
}

func costsOf(ops []Operation) [][]Cost {
	out := make([][]Cost, len(ops))
	for i, op := range ops {
		out[i] = op.Costs
	}
	return out
}

func wantCosts(t *testing.T, what string, ops []Operation, want ...[]Cost) {
	t.Helper()
	if got := costsOf(ops); !reflect.DeepEqual(got, want) {
		t.Errorf("%s: costs %v, want %v", what, got, want)
	}
}

func on(cs ...Cost) []Cost { return cs }

// Fix round 1, item 1: a backup or lsn subscription's rows start at 2
// (10-init-modes I2.backup.create, I3.lsn.create: status=2).
func TestPredictBackupLsnRowsAt2(t *testing.T) {
	for _, syncType := range []string{"initialize with backup", "initialize from lsn"} {
		st := labState(t)
		ops, _ := finish([]Operation{addSubOp(t, "a", "SalesRef", "M_S/m_b", syncType)}, st)
		if got := rowsOf(st, "SalesRef", "M_S/m_b"); !reflect.DeepEqual(got, map[string]int{"Product": 2, "vCustomerFR": 2}) {
			t.Errorf("%s: rows %v, want at 2", syncType, got)
		}
		if !st.Pubs["SalesRef"].Subs["m_s/m_b"].StartAgent {
			t.Errorf("%s: StartAgent false", syncType)
		}
		if st.Pending("SalesRef") {
			t.Errorf("%s: SalesRef pending", syncType)
		}
		wantCosts(t, syncType, ops, on(CostOnline))
	}
}

// Item 2: the first call that drops a ready snapshot of a publication that
// does not keep immediate_sync carries ready_snapshot_dropped.
func TestCostReadySnapshotDroppedFirst(t *testing.T) {
	dropSubArt := stepOp(t, 4, "a", cost.OpDropSubscriptionArticle, "", "SalesPub", "Orders")
	dropSubArt.Affects.Subscriptions = []string{labSub}
	ops, _ := finish([]Operation{
		dropSubArt,
		stepOp(t, 5, "a", cost.OpDropArticle, "", "SalesPub", "Orders"),
		stepOp(t, 6, "a", "publications[SalesPub].immediate_sync", "to_false", "SalesPub", ""),
	}, labState(t))
	wantCosts(t, "drop then immediate_sync false", ops, on(CostOnline), on(CostReadySnapshotDropped), on(CostOnline))
	if tt := totals(ops); tt.Costly != 1 {
		t.Errorf("Costly %d, want 1", tt.Costly)
	}
	ops, _ = finish([]Operation{stepOp(t, 6, "a", "publications[SalesPub].immediate_sync", "to_false", "SalesPub", "")}, labState(t))
	wantCosts(t, "immediate_sync false alone", ops, on(CostReadySnapshotDropped))
	ops, _ = finish([]Operation{
		stepOp(t, 6, "a", "publications[SalesPub].snapshot.alt_folder", "set", "SalesPub", ""),
		stepOp(t, 6, "b", "publications[SalesPub].immediate_sync", "to_false", "SalesPub", ""),
	}, labState(t))
	wantCosts(t, "alt_folder then immediate_sync false", ops, on(CostReadySnapshotDropped), on(CostOnline))
}

// Item 3: every operation has a cost.
func TestCostDefaultOnline(t *testing.T) {
	profile := testOp(t, "a", cost.OpAddProfile, "", "", "")
	profile.Affects.Publications = nil
	job := Operation{Step: 12, Order: "b", Kind: "job_enabled"}
	shared := Operation{Step: 12, Order: "c", Kind: "distributor_property", Costs: []Cost{CostSharedObjectChanged}}
	ops, _ := finish([]Operation{profile, job, shared}, labState(t))
	wantCosts(t, "outside a publication", ops, on(CostOnline), on(CostOnline), on(CostOnline, CostSharedObjectChanged))
}

// Item 4: full_generation_deferred from the end state, whatever the order.
func TestCostFullGenerationEndState(t *testing.T) {
	creation := func(order string) Operation {
		return testOp(t, order, "publications[SalesPub].articles[Orders].creation_script", "set", "SalesPub", "Orders")
	}
	schema := func(order string) Operation {
		return testOp(t, order, "publications[SalesPub].articles[Customer].schema_options", "", "SalesPub", "Customer")
	}
	ops, _ := finish([]Operation{creation("a"), schema("b")}, labState(t))
	wantCosts(t, "creation_script then schema_options", ops, on(CostOnline), on(CostReinitialization, CostNewSnapshot))
	if tt := totals(ops); tt.Costly != 1 {
		t.Errorf("Costly %d, want 1", tt.Costly)
	}
	ops, _ = finish([]Operation{schema("a"), creation("b")}, labState(t))
	wantCosts(t, "schema_options then creation_script", ops, on(CostReinitialization, CostNewSnapshot), on(CostOnline))
	ops, _ = finish([]Operation{creation("a")}, labState(t))
	wantCosts(t, "creation_script alone", ops, on(CostFullGenerationDeferred))
}

// The deferral keeps its deferred full generation: the generate_and_wait
// run comes before the restore of immediate_sync.
func TestCostDeferKeepsDeferred(t *testing.T) {
	st := labState(t)
	st.Pubs["SalesPub"].AllowAnonymous = true
	gen := Operation{Step: 9, Order: "b", Kind: "generate_and_wait"}
	gen.Affects.Publications = []string{"SalesPub"}
	ops, _ := finish([]Operation{
		stepOp(t, 6, "a", "publications[SalesPub].allow_anonymous", "to_false", "SalesPub", ""),
		stepOp(t, 6, "b", "publications[SalesPub].immediate_sync", "to_false", "SalesPub", ""),
		addArticleOp(t, "a", "SalesPub", "m_t9"),
		extendOp(t, "a", "SalesPub", labSub, "m_t9"),
		gen,
		stepOp(t, 9, "c", "publications[SalesPub].immediate_sync", "to_true", "SalesPub", ""),
	}, st)
	// Task 13 fix round 1, item 3: the extension before the generate_and_wait
	// that generates its article is online; the generation carries
	// new_snapshot.
	wantCosts(t, "deferral", ops, on(CostFullGenerationDeferred), on(CostOnline), on(CostOnline), on(CostOnline), on(CostNewSnapshot), on(CostOnline))
	if st.Pending("SalesPub") {
		t.Error("SalesPub pending after generate_and_wait")
	}
}

// Item 5: an article whose rows this plan created at 1 is counted once.
func TestCostArticleCountedOnce(t *testing.T) {
	filter := testOp(t, "b", cost.OpArticleFilter, "", "SalesPub", "m_t9")
	filter.Step = 8
	ops, _ := finish([]Operation{addArticleOp(t, "a", "SalesPub", "m_t9"), filter}, labState(t))
	wantCosts(t, "add then filter on SalesPub", ops, on(CostNewSnapshot), on(CostOnline))

	column := testOp(t, "b", cost.OpArticleColumn, "", "SalesRef", "m_t9")
	column.Step = 9
	ops, _ = finish([]Operation{addArticleOp(t, "a", "SalesRef", "m_t9"), extendOp(t, "a", "SalesRef", labSub, "m_t9"), column}, labState(t))
	wantCosts(t, "add, extend, column on SalesRef", ops, on(CostOnline), on(CostNewSnapshot), on(CostOnline))
}

// Item 6: contracts fail loudly.
func TestPredictContractPanics(t *testing.T) {
	mustPanic := func(what, part string, op Operation) {
		t.Helper()
		defer func() {
			r := recover()
			if r == nil {
				t.Errorf("%s: no panic", what)
				return
			}
			if msg, _ := r.(string); !strings.Contains(msg, part) {
				t.Errorf("%s: panic %v, want it to name %q", what, r, part)
			}
		}()
		finish([]Operation{op}, labState(t))
	}
	unknown := testOp(t, "a", "publications[Nope].retention_hours", "", "Nope", "")
	unknown.Kind, unknown.Path = "publication_property", "publications[Nope].retention_hours"
	mustPanic("unknown publication", "publications[Nope].retention_hours", unknown)
	noArt := testOp(t, "a", "publications[SalesPub].articles[Customer].description", "set", "SalesPub", "")
	mustPanic("article entry without article", "Affects.Articles[0]", noArt)
	noSub := addSubOp(t, "a", "SalesRef", "", "automatic")
	mustPanic("subscription entry without subscription", "Affects.Subscriptions[0]", noSub)
}

func TestPredictSnapshotRecurring(t *testing.T) {
	if !labState(t).Pubs["SalesPub"].SnapshotRecurring {
		t.Error("the lab's every-5-minutes schedule is not recurring")
	}
	sched := func(freq string, jobEnabled bool) *model.Agent {
		return &model.Agent{JobEnabled: &jobEnabled, Schedules: &[]model.Schedule{{Name: "s", Frequency: freq}}}
	}
	for _, c := range []struct {
		freq    string
		enabled bool
		want    bool
	}{{"daily", true, true}, {"daily", false, false}, {"once", true, false}, {"agent_start", true, false}, {"", true, false}, {"idle", true, true}} {
		if got := recurring(sched(c.freq, c.enabled)); got != c.want {
			t.Errorf("%q job enabled %v: recurring %v, want %v", c.freq, c.enabled, got, c.want)
		}
	}
}

// Item 7: the paths the review neutralised without a failure.
func TestPredictAllowAnonymousFalseClearsReady(t *testing.T) {
	st := labState(t)
	st.Pubs["SalesPub"].AllowAnonymous = true
	ops, _ := finish([]Operation{stepOp(t, 6, "a", "publications[SalesPub].allow_anonymous", "to_false", "SalesPub", "")}, st)
	if st.Pubs["SalesPub"].Ready || st.Pubs["SalesPub"].AllowAnonymous {
		t.Errorf("Ready %v AllowAnonymous %v after allow_anonymous false", st.Pubs["SalesPub"].Ready, st.Pubs["SalesPub"].AllowAnonymous)
	}
	wantCosts(t, "allow_anonymous false keeping immediate_sync", ops, on(CostFullGenerationDeferred))
}

func TestPredictDrops(t *testing.T) {
	st := labState(t)
	dsa := stepOp(t, 4, "a", cost.OpDropSubscriptionArticle, "", "SalesRef", "Product")
	dsa.Affects.Subscriptions = []string{labSub}
	finish([]Operation{dsa}, st)
	if got := rowsOf(st, "SalesRef", labSub); !reflect.DeepEqual(got, map[string]int{"vCustomerFR": 2}) {
		t.Errorf("rows after drop_subscription_article %v", got)
	}
	da := stepOp(t, 5, "a", cost.OpDropArticle, "", "SalesRef", "Product")
	finish([]Operation{da}, st)
	if _, ok := st.Pubs["SalesRef"].Articles["Product"]; ok {
		t.Error("Product still an article after drop_article")
	}
	ds := stepOp(t, 4, "a", cost.OpDropSubscription, "", "SalesRef", "")
	ds.Affects.Subscriptions = []string{labSub}
	finish([]Operation{ds}, st)
	if len(st.Pubs["SalesRef"].Subs) != 0 {
		t.Errorf("subscriptions after drop_subscription %v", st.Pubs["SalesRef"].Subs)
	}

	// The drop of the database's last publication removes its log reader
	// (13-transient T02), not the drop of another.
	finish([]Operation{stepOp(t, 5, "a", cost.OpDropPublication, "", "SalesRef", "")}, st)
	if st.Pubs["SalesRef"].Exists || !st.LogReader {
		t.Errorf("after the first publication drop: Exists %v LogReader %v", st.Pubs["SalesRef"].Exists, st.LogReader)
	}
	finish([]Operation{stepOp(t, 5, "a", cost.OpDropPublication, "", "SalesPub", "")}, st)
	if st.LogReader {
		t.Error("LogReader true after the last publication drop")
	}
}

func TestPredictGenerateAndWait(t *testing.T) {
	st := labState(t)
	gen := Operation{Step: 9, Order: "b", Kind: "generate_and_wait"}
	gen.Affects.Publications = []string{"SalesRef"}
	ops, _ := finish([]Operation{addArticleOp(t, "a", "SalesRef", "m_t9"), extendOp(t, "a", "SalesRef", labSub, "m_t9"), gen}, st)
	if got := rowsOf(st, "SalesRef", labSub); !reflect.DeepEqual(got, map[string]int{"Product": 2, "vCustomerFR": 2, "m_t9": 2}) {
		t.Errorf("rows after generate_and_wait %v", got)
	}
	if st.Pending("SalesRef") {
		t.Error("SalesRef pending after generate_and_wait")
	}
	wantCosts(t, "generate_and_wait", ops[2:], on(CostNewSnapshot))
}

func TestPredictAddArticleActiveBit(t *testing.T) {
	st := labState(t)
	finish([]Operation{addArticleOp(t, "a", "SalesRef", "m_t9"), addArticleOp(t, "b", "SalesPub", "m_t9")}, st)
	if st.Pubs["SalesRef"].Articles["m_t9"] {
		t.Error("m_t9 active on SalesRef (no immediate_sync)")
	}
	if !st.Pubs["SalesPub"].Articles["m_t9"] {
		t.Error("m_t9 inactive on SalesPub (immediate_sync sets the bit at once, R12)")
	}
}

func TestPredictExtensionOfSubscribedArticle(t *testing.T) {
	st := labState(t)
	ops, _ := finish([]Operation{extendOp(t, "a", "SalesRef", labSub, "Product")}, st)
	if got := rowsOf(st, "SalesRef", labSub); !reflect.DeepEqual(got, map[string]int{"Product": 2, "vCustomerFR": 2}) {
		t.Errorf("rows %v", got)
	}
	wantCosts(t, "extension of a subscribed article", ops, on(CostOnline))
	if st.Pubs["SalesRef"].Subs[strings.ToLower(labSub)].StartAgent {
		t.Error("StartAgent set by a no-op extension")
	}
}

func TestPredictPublicationAbsentFromFacts(t *testing.T) {
	c, f := loadLab(t)
	f.Publications = f.Publications[1:] // SalesRef only
	f.Subscriptions = f.Subscriptions[1:]
	st := NewState(c, f)
	ps := st.Pubs["SalesPub"]
	if !ps.Ready {
		t.Error("an unobserved immediate_sync publication is not ready")
	}
	if !ps.Articles["Customer"] || !ps.Articles["Orders"] {
		t.Errorf("articles %v, want active", ps.Articles)
	}
	if got := rowsOf(st, "SalesPub", labSub); !reflect.DeepEqual(got, map[string]int{"Customer": 2, "Orders": 2}) {
		t.Errorf("rows %v, want at 2", got)
	}
	if st.Pubs["SalesRef"].Ready {
		t.Error("observed SalesRef ready")
	}
}

func TestCostDropsReadyNotReady(t *testing.T) {
	st := labState(t)
	st.Pubs["SalesPub"].Ready = false
	ops, _ := finish([]Operation{stepOp(t, 6, "a", "publications[SalesPub].immediate_sync", "to_false", "SalesPub", "")}, st)
	wantCosts(t, "immediate_sync false on an unready publication", ops, on(CostOnline))
}

func TestCostAddSubscriptionNotReady(t *testing.T) {
	st := labState(t)
	st.Pubs["SalesPub"].Ready = false
	ops, _ := finish([]Operation{addSubOp(t, "a", "SalesPub", "M_S/m_db", "automatic")}, st)
	if got := rowsOf(st, "SalesPub", "M_S/m_db"); !reflect.DeepEqual(got, map[string]int{"Customer": 1, "Orders": 1}) {
		t.Errorf("rows %v, want at 1", got)
	}
	if st.Pubs["SalesPub"].Subs["m_s/m_db"].StartAgent {
		t.Error("StartAgent on a subscription whose rows are at 1")
	}
	wantCosts(t, "add_subscription on an unready immediate_sync publication", ops, on(CostNewSnapshot))
}

func TestPredictStartAgentRSO(t *testing.T) {
	st := labState(t)
	finish([]Operation{addSubOp(t, "a", "SalesRef", "M_S/m_rso", "replication support only"), addSubOp(t, "b", "SalesRef", "M_S/m_snap", "automatic")}, st)
	if !st.Pubs["SalesRef"].Subs["m_s/m_rso"].StartAgent {
		t.Error("replication support only: StartAgent false")
	}
	if st.Pubs["SalesRef"].Subs["m_s/m_snap"].StartAgent {
		t.Error("snapshot on SalesRef: StartAgent true")
	}
}

func TestPredictAgentFailureBoundary(t *testing.T) {
	const gen = "2026-11-12 04:05:06.657"
	a := state.AgentFacts{Job: &state.JobState{Exists: true}, LastHistory: &state.HistoryRow{Time: gen, RunStatus: 6}, LastFailure: &state.HistoryRow{Time: gen, RunStatus: 6}}
	if got := agentStatus(a, gen); got != "failed" {
		t.Errorf("last_failure at last_generation: %s, want failed (R13: at or after)", got)
	}
}

// Round 2: rows a reinit-flagged change of this plan set to 1 are counted
// by that change; a later change of the same article is online, while the
// rows at 1 observed before the plan still cost pending_snapshot_start.
func TestCostReinitCountedOnce(t *testing.T) {
	schema := testOp(t, "a", "publications[SalesPub].articles[Customer].schema_options", "", "SalesPub", "Customer")
	view := testOp(t, "b", cost.OpArticleView, "", "SalesPub", "Customer")
	ops, _ := finish([]Operation{schema, view}, labState(t))
	wantCosts(t, "schema_options then article_view", ops, on(CostReinitialization, CostNewSnapshot), on(CostOnline))

	wide := testOp(t, "a", "publications[SalesPub].sync_method", "concurrent>native", "SalesPub", "")
	view = testOp(t, "b", cost.OpArticleView, "", "SalesPub", "Orders")
	ops, _ = finish([]Operation{wide, view}, labState(t))
	wantCosts(t, "sync_method then article_view", ops, on(CostReinitialization, CostNewSnapshot), on(CostOnline))

	st := labState(t)
	st.Pubs["SalesPub"].Subs[strings.ToLower(labSub)].Rows["Customer"] = 1
	ops, _ = finish([]Operation{testOp(t, "a", cost.OpArticleView, "", "SalesPub", "Customer")}, st)
	wantCosts(t, "article_view on rows observed at 1", ops, on(CostPendingSnapshotStart))
}
