package plan

import (
	"fmt"
	"strings"
	"testing"

	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
	"github.com/rudi-bruchez/sqlserver-replication/internal/normalize"
)

// newSub is a subscription of the file to a database of the lab subscriber.
func newSub(db, typ, init string, arts ...string) model.Subscription {
	return model.Subscription{Subscriber: "REPLLAB", Database: db, Type: str(typ), SubscriberType: str("sql_server"),
		Initialization: str(init), Articles: arts}
}

func addSub(t *testing.T, c *model.Config, pub string, s model.Subscription) {
	p := pubOf(t, c, pub)
	p.Subscriptions = append(p.Subscriptions, s)
}

// subOf is the subscription of pub to the database db.
func subOf(t *testing.T, c *model.Config, pub, db string) *model.Subscription {
	t.Helper()
	p := pubOf(t, c, pub)
	for i := range p.Subscriptions {
		if strings.EqualFold(p.Subscriptions[i].Database, db) {
			return &p.Subscriptions[i]
		}
	}
	t.Fatalf("no subscription of %s to %s", pub, db)
	return nil
}

// both applies f to the desired and the current side.
func both(des, cur *model.Config, f func(c *model.Config)) { f(des); f(cur) }

// refPull makes SalesRef accept pull subscriptions with its own agents
// (independent_agent, allow_pull) on both sides, without its push
// subscription: a push subscription of an independent publication would get
// a distribution agent the current side lacks.
func refPull(t *testing.T, des, cur *model.Config) {
	both(des, cur, func(c *model.Config) {
		p := pubOf(t, c, "SalesRef")
		p.IndependentAgent, p.AllowPull, p.Subscriptions = model.Ptr(true), model.Ptr(true), nil
	})
}

// samePullAgent writes into the current subscription of pub to db the pull
// agent the normalization of the desired file gives, so that only what a
// test changes differs.
func samePullAgent(t *testing.T, des, cur *model.Config, pub, db string) {
	t.Helper()
	n, rs := normalize.Normalize(des, cur)
	for _, r := range rs {
		t.Fatalf("normalization refuses %s: %s", r.Path, r.Reason)
	}
	a := *subOf(t, n, pub, db).PullAgent
	subOf(t, cur, pub, db).PullAgent = &a
}

func ofSubscription(ops []Operation, key string) []Operation {
	var out []Operation
	for _, op := range ops {
		if strings.EqualFold(first(op.Affects.Subscriptions), key) {
			out = append(out, op)
		}
	}
	return out
}

func TestAddPushSubscriptionUnit(t *testing.T) {
	const key = "REPLLAB/m_sdb_unit"
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		addSub(t, des, "SalesPub", newSub("m_sdb_unit", "push", "snapshot"))
		addTo(t, des, "SalesRef", newTable("m_t9")) // another publication's article and extension
	}))
	got := ofSubscription(ops, key)
	if len(got) != 2 {
		t.Fatalf("%d operations of %s, want 2:\n%s", len(got), key, opsString(ops))
	}
	add, agent := got[0], got[1]
	if add.Call.Procedure != "sp_addsubscription" || agent.Call.Procedure != "sp_addpushsubscription_agent" {
		t.Fatalf("operations %s, %s", add.Call.Procedure, agent.Call.Procedure)
	}
	if agent.Seq != add.Seq+1 || add.Step != 9 || agent.Step != 9 {
		t.Errorf("sp_addsubscription seq %d step %d, sp_addpushsubscription_agent seq %d step %d: not one unit:\n%s",
			add.Seq, add.Step, agent.Seq, agent.Step, opsString(ops))
	}
	wantParam(t, add, "@article", "N'all'")
	wantParam(t, add, "@subscriber", "N'REPLLAB'")
	wantParam(t, add, "@destination_db", "N'm_sdb_unit'")
	wantParam(t, agent, "@subscriber_db", "N'm_sdb_unit'")
	for _, op := range got {
		if op.Server != "repllab" || op.Database != "Sales" {
			t.Errorf("%s runs at %s.%s, want the publisher in the publication database", op.Call.Procedure, op.Server, op.Database)
		}
	}
	// SalesPub is ready with immediate_sync: the rows start at 2 (S7).
	wantOpCosts(t, add, CostOnline)
	if n := len(opsCalling(ops, "sp_addarticle")); n != 1 {
		t.Errorf("%d sp_addarticle, want SalesRef's m_t9", n)
	}
}

func TestAddPullSubscription(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, cur *model.Config) {
		refPull(t, des, cur)
		addSub(t, des, "SalesRef", newSub("m_sdb_pull", "pull", "snapshot"))
	}))
	if len(ops) != 3 {
		t.Fatalf("%d operations, want 3:\n%s", len(ops), opsString(ops))
	}
	pub, ps, pa := ops[0], ops[1], ops[2]
	for i, want := range []string{"sp_addsubscription", "sp_addpullsubscription", "sp_addpullsubscription_agent"} {
		if ops[i].Call.Procedure != want || ops[i].Step != 9 {
			t.Errorf("operation %d is %s in step %d, want %s in step 9", i+1, ops[i].Call.Procedure, ops[i].Step, want)
		}
	}
	if pub.Server != "repllab" || pub.Database != "Sales" {
		t.Errorf("sp_addsubscription runs at %s.%s, want the publisher's publication database", pub.Server, pub.Database)
	}
	for _, op := range []Operation{ps, pa} {
		if op.Server != "REPLLAB" || op.Database != "m_sdb_pull" {
			t.Errorf("%s runs at %s.%s, want the subscriber's subscription database", op.Call.Procedure, op.Server, op.Database)
		}
		wantParam(t, op, "@publisher", "N'repllab'")
		wantParam(t, op, "@publisher_db", "N'Sales'")
		wantParam(t, op, "@publication", "N'SalesRef'")
	}
	wantParam(t, pub, "@subscription_type", "N'pull'")
	wantParam(t, pub, "@article", "N'all'")
	wantParam(t, ps, "@subscription_type", "N'pull'")
	wantParam(t, ps, "@immediate_sync", "N'false'")
	wantParam(t, ps, "@independent_agent", "N'true'")
	noParam(t, pa, "@subscription_type") // sp_addpullsubscription_agent has none
	// Only the publisher-side call carries the snapshot (Task 9).
	wantOpCosts(t, pub, CostNewSnapshot)
	wantOpCosts(t, ps, CostOnline)
	wantOpCosts(t, pa, CostOnline)
}

// pullOnRef is the lab with SalesRef's subscription to SalesSub a pull one
// on both sides.
func pullOnRef(t *testing.T, des, cur *model.Config) {
	both(des, cur, func(c *model.Config) {
		p := pubOf(t, c, "SalesRef")
		p.IndependentAgent, p.AllowPull = model.Ptr(true), model.Ptr(true)
		subOf(t, c, "SalesRef", "SalesSub").Type = str("pull")
	})
	samePullAgent(t, des, cur, "SalesRef", "SalesSub")
}

func TestDropPullOrder(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, cur *model.Config) {
		pullOnRef(t, des, cur)
		pubOf(t, des, "SalesRef").Subscriptions = nil
	}))
	if len(ops) != 2 {
		t.Fatalf("%d operations, want 2:\n%s", len(ops), opsString(ops))
	}
	sub, pub := ops[0], ops[1]
	if sub.Call.Procedure != "sp_droppullsubscription" || pub.Call.Procedure != "sp_dropsubscription" {
		t.Fatalf("drop order %s, %s; want sp_droppullsubscription first (08-pull P3.subscriber-first)", sub.Call.Procedure, pub.Call.Procedure)
	}
	if sub.Server != "REPLLAB" || sub.Database != "SalesSub" || pub.Server != "repllab" || pub.Database != "Sales" {
		t.Errorf("places %s.%s and %s.%s", sub.Server, sub.Database, pub.Server, pub.Database)
	}
	wantParam(t, pub, "@article", "N'all'")
	wantSource(t, sub, "08-pull P3.subscriber-first.step1")
}

func TestDropWholeSubscription(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) { pubOf(t, des, "SalesRef").Subscriptions = nil }))
	drop := one(t, ops, "sp_dropsubscription")
	if len(ops) != 1 {
		t.Errorf("%d operations, want 1:\n%s", len(ops), opsString(ops))
	}
	if drop.Step != 4 || drop.Kind != "subscription" || drop.Action != "drop" {
		t.Errorf("drop is %s %s in step %d", drop.Kind, drop.Action, drop.Step)
	}
	wantParam(t, drop, "@article", "N'all'")
	wantParam(t, drop, "@destination_db", "N'SalesSub'")
	wantOpCosts(t, drop, CostOnline, CostSubscriberObjectLeft)
}

func TestSubsetRules(t *testing.T) {
	p := buildLab(t, nil, func(des, _ *model.Config) {
		addSub(t, des, "SalesPub", newSub("m_sdb_subset", "push", "snapshot", "Customer"))
	})
	wantRefusal(t, p, "publications[SalesPub].subscriptions[REPLLAB/m_sdb_subset].articles",
		"a subscription to a subset of the articles of a concurrent publication is refused (14100)")

	p = buildLab(t, nil, func(des, cur *model.Config) {
		both(des, cur, func(c *model.Config) { pubOf(t, c, "SalesPub").SyncMethod = str("native") })
		addSub(t, des, "SalesPub", newSub("m_sdb_subset", "push", "snapshot", "Customer"))
	})
	wantRefusal(t, p, "publications[SalesPub].subscriptions[REPLLAB/m_sdb_subset].articles",
		"a subscription to a subset of the articles of an immediate_sync publication is refused (14122)")

	const key = "REPLLAB/m_sdb_subset"
	ops := plannedAlone(t, buildLab(t, nil, func(des, _ *model.Config) {
		addTo(t, des, "SalesRef", newTable("m_t9"))
		addSub(t, des, "SalesRef", newSub("m_sdb_subset", "push", "snapshot", "Product", "m_t9"))
	}))
	var adds []Operation
	for _, op := range ofSubscription(ops, key) {
		if op.Call.Procedure == "sp_addsubscription" {
			adds = append(adds, op)
		}
	}
	if len(adds) != 2 {
		t.Fatalf("%d sp_addsubscription of %s, want one per article:\n%s", len(adds), key, opsString(ops))
	}
	wantParam(t, adds[0], "@article", "N'Product'")
	wantParam(t, adds[1], "@article", "N'm_t9'")
	// The second call is on the subscription the first created (R36).
	wantParam(t, adds[1], "@subscription_type", "N'push'")
	wantParam(t, adds[1], "@sync_type", "N'automatic'")
}

// The incomplete finding the reader writes at a subscription's articles
// (internal/reader/publisher.go).
func missingOrders(cur *model.Config, t *testing.T) {
	subOf(t, cur, "SalesPub", "SalesSub").Articles = []string{"Customer"}
	cur.Findings = append(cur.Findings, model.Finding{
		Kind: model.FindingIncomplete,
		Path: "publications[SalesPub].subscriptions[REPLLAB/SalesSub].articles",
		Message: fmt.Sprintf("%s: lists %d of the %d articles of the publication, but a subset cannot exist with immediate_sync or sync_method concurrent, concurrent_c",
			"publication SalesPub, subscription REPLLAB.SalesSub", 1, 2),
	})
}

func TestIntermediateSubscriptionRefused(t *testing.T) {
	p := buildLab(t, nil, func(_, cur *model.Config) { missingOrders(cur, t) })
	wantRefusal(t, p, "publications[SalesPub].subscriptions[REPLLAB/SalesSub].articles",
		"subscription REPLLAB/SalesSub misses articles Orders; completing it with @article = 'all' loses the rows changed while they were missing (measured); drop the subscription in one plan (remove it from the file) and add it back in the next")

	ops := plannedAlone(t, buildLab(t, nil, func(des, cur *model.Config) {
		missingOrders(cur, t)
		pubOf(t, des, "SalesPub").Subscriptions = nil
	}))
	drop := oneAlone(t, ops, "sp_dropsubscription")
	wantParam(t, drop, "@article", "N'all'")
	if len(ops) != 1 {
		t.Errorf("%d operations, want the drop alone:\n%s", len(ops), opsString(ops))
	}
}

// plannedAlone is planned for a test with several cases: it stops on this
// plan's refusals only, not on an earlier case's failure (planned stops on
// any), so every case is checked.
func plannedAlone(t *testing.T, p *Plan) []Operation {
	t.Helper()
	for _, r := range p.Refusals {
		t.Errorf("unexpected refusal %s: %s", r.Path, r.Reason)
	}
	if len(p.Refusals) > 0 {
		t.FailNow()
	}
	return p.Operations
}

// oneAlone is one without stopping the test: an empty Operation when the
// count is wrong.
func oneAlone(t *testing.T, ops []Operation, proc string) Operation {
	t.Helper()
	got := opsCalling(ops, proc)
	if len(got) != 1 {
		t.Errorf("%d %s operations, want 1; plan:\n%s", len(got), proc, opsString(ops))
		return Operation{}
	}
	return got[0]
}

func TestExtendPassesTypes(t *testing.T) {
	ops := plannedAlone(t, buildLab(t, nil, func(des, cur *model.Config) {
		pullOnRef(t, des, cur)
		addTo(t, des, "SalesRef", newTable("m_t9"))
	}))
	ext := oneAlone(t, ops, "sp_addsubscription")
	wantParam(t, ext, "@article", "N'm_t9'")
	wantParam(t, ext, "@subscription_type", "N'pull'")
	wantParam(t, ext, "@sync_type", "N'automatic'")

	ops = plannedAlone(t, buildLab(t, nil, func(des, cur *model.Config) {
		both(des, cur, func(c *model.Config) {
			subOf(t, c, "SalesRef", "SalesSub").Initialization = str("replication_support_only")
		})
		addTo(t, des, "SalesRef", newTable("m_t9"))
	}))
	ext = oneAlone(t, ops, "sp_addsubscription")
	wantParam(t, ext, "@subscription_type", "N'push'")
	wantParam(t, ext, "@sync_type", "N'replication support only'")

	p := buildLab(t, nil, func(des, cur *model.Config) {
		both(des, cur, func(c *model.Config) { subOf(t, c, "SalesRef", "SalesSub").Initialization = str("backup") })
		addTo(t, des, "SalesRef", newTable("m_t9"))
	})
	wantRefusal(t, p, "publications[SalesRef].subscriptions[REPLLAB/SalesSub]", "extension of a backup-initialized subscription not measured")
}

// allowPull sets allow_pull on SalesRef, which keeps its shared agents.
func allowPull(t *testing.T, des, cur *model.Config) {
	both(des, cur, func(c *model.Config) { pubOf(t, c, "SalesRef").AllowPull = model.Ptr(true) })
}

func TestPullNonIndependentRefused(t *testing.T) {
	p := buildLab(t, nil, func(des, cur *model.Config) {
		allowPull(t, des, cur)
		addSub(t, des, "SalesRef", newSub("m_sdb_pull", "pull", "snapshot"))
	})
	wantRefusal(t, p, "publications[SalesRef].subscriptions[REPLLAB/m_sdb_pull].type",
		"a pull subscription to publication SalesRef, which has no independent_agent, is refused: its shared pull agent is not measured (R21)")
}

func TestLsnInitializationRefused(t *testing.T) {
	p := buildLab(t, nil, func(des, _ *model.Config) {
		s := newSub("m_sdb_lsn", "push", "lsn")
		s.LSN = str("0x0000002A000001F00003")
		addSub(t, des, "SalesRef", s)
	})
	wantRefusal(t, p, "publications[SalesRef].subscriptions[REPLLAB/m_sdb_lsn].initialization",
		"initialization from an LSN: its precondition check is plan 4's (R21; a wrong LSN is accepted and stops the subscriptions of the database)")
}

func TestTypeChangeRefused(t *testing.T) {
	p := buildLab(t, nil, func(des, cur *model.Config) {
		allowPull(t, des, cur)
		subOf(t, des, "SalesRef", "SalesSub").Type = str("pull")
	})
	wantRefusal(t, p, "publications[SalesRef].subscriptions[REPLLAB/SalesSub].type",
		"a change of type of subscription REPLLAB/SalesSub (push to pull) is refused: drop it in one plan and add it in another (R21)")
}

func TestInitializationChangeNote(t *testing.T) {
	p := buildLab(t, nil, func(des, _ *model.Config) {
		subOf(t, des, "SalesRef", "SalesSub").Initialization = str("replication_support_only")
	})
	ops := planned(t, p)
	if len(ops) != 0 {
		t.Errorf("%d operations, want none:\n%s", len(ops), opsString(ops))
	}
	const note = "the initialization of subscription REPLLAB/SalesSub of SalesRef changes from snapshot to replication_support_only: it only serves the creation of a subscription, so the plan changes nothing (R21)"
	if len(p.Notes) != 1 || p.Notes[0] != note {
		t.Errorf("notes %q, want one: %s", p.Notes, note)
	}
}

func TestDropLastPullOfSharedAgentWarns(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, cur *model.Config) {
		allowPull(t, des, cur)
		subOf(t, cur, "SalesRef", "SalesSub").Type = str("pull")
		// As the reader exports it; the file cannot declare one (no
		// measured default of a shared pull agent).
		cur.Publisher.SharedPullAgents = []model.SharedPullAgent{{Subscriber: "REPLLAB", Database: "SalesSub"}}
		pubOf(t, des, "SalesRef").Subscriptions = nil
	}))
	drop := one(t, ops, "sp_droppullsubscription")
	if len(drop.Warnings) != 1 || drop.Warnings[0] != "the shared pull agent job stays at the subscriber after sp_droppullsubscription" {
		t.Errorf("warnings %q", drop.Warnings)
	}
	wantOpCosts(t, drop, CostOnline, CostSubscriberObjectLeft)
	if pub := one(t, ops, "sp_dropsubscription"); pub.Seq <= drop.Seq {
		t.Errorf("sp_dropsubscription seq %d before sp_droppullsubscription seq %d", pub.Seq, drop.Seq)
	}
}
