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

// exportedPull is a pull agent as the export writes one created without
// schedule parameters (the Task 12 review's export of rv_t12s4).
func exportedPull(db string) *model.PullAgent {
	a := &model.PullAgent{
		DistributionAgent: model.DistributionAgent{
			Agent: model.Agent{
				JobName: str("repllab-Sales-SalesRef-repllab-" + db + "-F4197652"), JobEnabled: model.Ptr(true), JobLogin: str(""),
				DistributorConnection: &model.Connection{Security: str("windows")},
				Profile:               str("Default agent profile"), RunAs: str(""),
				Connection: &model.Connection{Security: str("windows")},
				Schedules:  &[]model.Schedule{},
				Command:    str("-Publisher [repllab] -PublisherDB [Sales] -Publication [SalesRef] -Distributor [repllab] -SubscriptionType 1 -Subscriber [repllab] -SubscriberSecurityMode 1 -SubscriberDB [" + db + "]"),
			},
			SubscriptionStreams: model.Ptr(0), MemoryOptimized: model.Ptr(false),
		},
		Distributor: str("repllab"), AltSnapshotFolder: str(""), WorkingDirectory: str(""), UseFTP: model.Ptr(false),
		EnabledForSyncmgr: model.Ptr(false), Description: str(""),
	}
	return a
}

func TestPullExportRoundTrips(t *testing.T) {
	p := buildLab(t, nil, func(des, cur *model.Config) {
		both(des, cur, func(c *model.Config) {
			p := pubOf(t, c, "SalesRef")
			p.IndependentAgent, p.AllowPull = model.Ptr(true), model.Ptr(true)
			s := subOf(t, c, "SalesRef", "SalesSub")
			s.Type, s.PullAgent = str("pull"), exportedPull("SalesSub")
		})
	})
	ops := planned(t, p)
	if len(ops) != 0 {
		t.Errorf("the export as a file plans %d operations:\n%s", len(ops), opsString(ops))
	}
}

// threeOnRef gives SalesRef a third article m_t3 on both sides, and its
// subscription to SalesSub the current subset cur.
// The current m_t3 is the normalized desired one, as an export would write
// its properties.
func threeOnRef(t *testing.T, des, cur *model.Config, curArts ...string) {
	t.Helper()
	addTo(t, des, "SalesRef", newTable("m_t3"))
	n, rs := normalize.Normalize(des, cur)
	for _, r := range rs {
		t.Fatalf("normalization refuses %s: %s", r.Path, r.Reason)
	}
	addTo(t, cur, "SalesRef", *articleOf(t, n, "SalesRef", "m_t3"))
	subOf(t, cur, "SalesRef", "SalesSub").Articles = curArts
}

func TestSubsetChangeOfKeptSubscription(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, cur *model.Config) {
		threeOnRef(t, des, cur, "Product", "vCustomerFR")
		subOf(t, des, "SalesRef", "SalesSub").Articles = []string{"Product", "m_t3"}
	}))
	if len(ops) != 2 {
		t.Fatalf("%d operations, want 2:\n%s", len(ops), opsString(ops))
	}
	drop, ext := ops[0], ops[1]
	if drop.Kind != "subscription_article_drop" || drop.Step != 4 || ext.Kind != "subscription_extension" || ext.Step != 9 {
		t.Fatalf("operations %s step %d, %s step %d", drop.Kind, drop.Step, ext.Kind, ext.Step)
	}
	wantParam(t, drop, "@article", "N'vCustomerFR'")
	wantOpCosts(t, drop, CostOnline, CostSubscriberObjectLeft)
	wantParam(t, ext, "@article", "N'm_t3'")
	wantParam(t, ext, "@subscription_type", "N'push'")
	wantParam(t, ext, "@sync_type", "N'automatic'")
	wantOpCosts(t, ext, CostNewSnapshot)
}

func TestSubscriptionLosingEveryArticleRefused(t *testing.T) {
	const reason = "subscription REPLLAB/SalesSub would lose every article before the new ones are added, which drops it with its agent (measured); drop and add it in two plans"
	const path = "publications[SalesRef].subscriptions[REPLLAB/SalesSub].articles"
	// By its subset change.
	wantRefusal(t, buildLab(t, nil, func(des, cur *model.Config) {
		threeOnRef(t, des, cur, "Product")
		subOf(t, des, "SalesRef", "SalesSub").Articles = []string{"m_t3"}
	}), path, reason)
	// The publication drops every article it has and adds another (Task 11).
	wantRefusal(t, buildLab(t, nil, func(des, _ *model.Config) {
		pubOf(t, des, "SalesRef").Articles = []model.Article{newTable("m_t9")}
	}), path, reason)
	// Product's source changes, so it is dropped and added back (R20), and
	// vCustomerFR is dropped: no current article stays.
	wantRefusal(t, buildLab(t, nil, func(des, _ *model.Config) {
		removeArticle(t, des, "SalesRef", "vCustomerFR")
		articleOf(t, des, "SalesRef", "Product").Source.Name = "Product2"
	}), path, reason)
}

func TestAgentOwnedChangesLeftToAgents(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		a := subOf(t, des, "SalesPub", "SalesSub").DistributionAgent
		a.Profile, a.JobEnabled = str("lab-distrib"), model.Ptr(false)
	}))
	if len(ops) != 0 {
		t.Errorf("profile and job_enabled are Task 14's; operations:\n%s", opsString(ops))
	}
	if !agentOwned("pull_agent.schedules[*].frequency") || agentOwned("distribution_agent.subscription_streams") {
		t.Error("agentOwned: the schedules of a pull agent are Task 14's, its streams are not")
	}
}

func TestPushAgentPropertyChange(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		subOf(t, des, "SalesPub", "SalesSub").DistributionAgent.SubscriptionStreams = model.Ptr(2)
	}))
	op := one(t, ops, "sp_changesubscription")
	if op.Step != 10 || op.Server != "repllab" || op.Database != "Sales" {
		t.Errorf("step %d at %s.%s", op.Step, op.Server, op.Database)
	}
	wantParam(t, op, "@article", "N'all'")
	wantParam(t, op, "@property", "N'subscriptionstreams'")
	wantParam(t, op, "@value", "N'2'")
	wantOpCosts(t, op, CostOnline)
}

func TestPullAgentPropertyChange(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, cur *model.Config) {
		pullOnRef(t, des, cur)
		a := *subOf(t, cur, "SalesRef", "SalesSub").PullAgent
		a.WorkingDirectory = str("/var/opt/mssql/data/m_wd")
		subOf(t, des, "SalesRef", "SalesSub").PullAgent = &a
	}))
	op := one(t, ops, "sp_change_subscription_properties")
	if op.Step != 10 || op.Server != "REPLLAB" || op.Database != "SalesSub" {
		t.Errorf("step %d at %s.%s, want the subscriber", op.Step, op.Server, op.Database)
	}
	wantParam(t, op, "@publisher", "N'repllab'")
	wantParam(t, op, "@publication", "N'SalesRef'")
	wantParam(t, op, "@property", "N'working_directory'")
	wantParam(t, op, "@value", "N'/var/opt/mssql/data/m_wd'")
}

func TestRefusedAgentPropertyChange(t *testing.T) {
	wantRefusal(t, buildLab(t, nil, func(des, _ *model.Config) {
		subOf(t, des, "SalesPub", "SalesSub").DistributionAgent.JobLogin = str(`REPLLAB\m_nobody`)
	}), "publications[SalesPub].subscriptions[REPLLAB/SalesSub].distribution_agent.job_login",
		"publications[*].subscriptions[*].distribution_agent.job_login change refused by the server (14529)")
}

func TestPullImmediateSyncPassed(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		addSub(t, des, "SalesPub", newSub("m_sdb_pull", "pull", "snapshot"))
	}))
	ps := one(t, ops, "sp_addpullsubscription")
	wantParam(t, ps, "@immediate_sync", "N'true'")
	wantParam(t, ps, "@independent_agent", "N'true'")
}

// sharedRef declares the shared distribution agent of SalesRef's new
// subscriptions to db in the file, with a job login sp_addpushsubscription_agent
// would pass.
func sharedRef(des *model.Config, db string) {
	des.Publisher.SharedDistributionAgents = append(des.Publisher.SharedDistributionAgents, model.SharedDistributionAgent{
		Subscriber: "REPLLAB", Database: db,
		DistributionAgent: model.DistributionAgent{Agent: model.Agent{JobLogin: str(`REPLLAB\m_job`)}},
	})
}

func TestSharedPushAgentCreatedOnce(t *testing.T) {
	// No shared agent yet: the file's shared agent is created.
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		sharedRef(des, "m_sdb_shared")
		addSub(t, des, "SalesRef", newSub("m_sdb_shared", "push", "snapshot"))
	}))
	agent := one(t, ops, "sp_addpushsubscription_agent")
	wantParam(t, agent, "@job_login", `N'REPLLAB\m_job'`)
	if len(agent.Warnings) != 0 {
		t.Errorf("warnings %v", agent.Warnings)
	}

	// The shared agent exists: sp_addsubscription alone keeps its job.
	ops = plannedAlone(t, buildLab(t, nil, func(des, cur *model.Config) {
		both(des, cur, func(c *model.Config) { sharedRef(c, "m_sdb_shared") })
		addSub(t, des, "SalesRef", newSub("m_sdb_shared", "push", "snapshot"))
	}))
	if n := len(opsCalling(ops, "sp_addpushsubscription_agent")); n != 0 || len(opsCalling(ops, "sp_addsubscription")) != 1 {
		t.Errorf("an existing shared agent: operations\n%s", opsString(ops))
	}

	// Created earlier in the same plan: by the first addition in plan order
	// (SalesRef before m_p2), right after its sp_addsubscription.
	ops = plannedAlone(t, buildLab(t, nil, func(des, _ *model.Config) {
		sharedRef(des, "m_sdb_shared")
		p := model.Publication{Name: "m_p2", Type: str("transactional"), Status: str("active"), SyncMethod: str("native"),
			IndependentAgent: model.Ptr(false), Articles: []model.Article{newTable("m_t9")},
			Subscriptions: []model.Subscription{newSub("m_sdb_shared", "push", "snapshot")}}
		des.Publications = append(des.Publications, p)
		addSub(t, des, "SalesRef", newSub("m_sdb_shared", "push", "snapshot"))
	}))
	agents := opsCalling(ops, "sp_addpushsubscription_agent")
	if len(agents) != 1 || len(ofSubscription(opsCalling(ops, "sp_addsubscription"), "REPLLAB/m_sdb_shared")) != 2 {
		t.Fatalf("two additions to one shared agent: operations\n%s", opsString(ops))
	}
	var refAdd Operation
	for _, op := range ofSubscription(ops, "REPLLAB/m_sdb_shared") {
		if op.Call.Procedure == "sp_addsubscription" && first(op.Affects.Publications) == "SalesRef" {
			refAdd = op
		}
	}
	if first(agents[0].Affects.Publications) != "SalesRef" || agents[0].Seq != refAdd.Seq+1 {
		t.Errorf("the agent is created by %s at seq %d, want SalesRef's right after its sp_addsubscription (seq %d)",
			first(agents[0].Affects.Publications), agents[0].Seq, refAdd.Seq)
	}
}

func TestPushSubsetAgentPlacement(t *testing.T) {
	const key = "REPLLAB/m_sdb_subset"
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		addTo(t, des, "SalesRef", newTable("m_t9"))
		addSub(t, des, "SalesRef", newSub("m_sdb_subset", "push", "snapshot", "Product", "m_t9"))
	}))
	got := ofSubscription(ops, key)
	var procs []string
	for _, op := range got {
		procs = append(procs, op.Call.Procedure+":"+func() string { v, _ := paramOf(op, "@article"); return v }())
	}
	want := "sp_addsubscription:N'Product',sp_addpushsubscription_agent:,sp_addsubscription:N'm_t9'"
	if strings.Join(procs, ",") != want {
		t.Errorf("order %s, want %s", strings.Join(procs, ","), want)
	}
	if len(got) == 3 && (got[1].Seq != got[0].Seq+1 || got[2].Seq != got[1].Seq+1) {
		t.Errorf("not consecutive: seq %d %d %d", got[0].Seq, got[1].Seq, got[2].Seq)
	}
}

func TestDropPullOfSharedAgentNotLast(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, cur *model.Config) {
		allowPull(t, des, cur)
		both(des, cur, func(c *model.Config) {
			subOf(t, c, "SalesRef", "SalesSub").Type = str("pull")
			// Another publication without independent_agent keeps its pull
			// subscription to SalesSub.
			p := cloneConfig(&model.Config{Publications: []model.Publication{*pubOf(t, c, "SalesRef")}}).Publications[0]
			p.Name = "m_p2"
			c.Publications = append(c.Publications, p)
		})
		cur.Publisher.SharedPullAgents = []model.SharedPullAgent{{Subscriber: "REPLLAB", Database: "SalesSub"}}
		pubOf(t, des, "SalesRef").Subscriptions = nil
	}))
	drop := one(t, ops, "sp_droppullsubscription")
	if first(drop.Affects.Publications) != "SalesRef" || len(drop.Warnings) != 0 {
		t.Errorf("drop of %s, warnings %q: the shared pull agent keeps m_p2's subscription", first(drop.Affects.Publications), drop.Warnings)
	}
	wantOpCosts(t, drop, CostOnline)
}

func TestExtendLsnRefused(t *testing.T) {
	wantRefusal(t, buildLab(t, nil, func(des, cur *model.Config) {
		both(des, cur, func(c *model.Config) { subOf(t, c, "SalesRef", "SalesSub").Initialization = str("lsn") })
		addTo(t, des, "SalesRef", newTable("m_t9"))
	}), "publications[SalesRef].subscriptions[REPLLAB/SalesSub]", "extension of a lsn-initialized subscription not measured")
}

func TestSubsetAdditionRefusedWithoutSubset(t *testing.T) {
	// A current subset on SalesPub without the reader's finding: the
	// extension by name is refused (14100 under concurrent).
	wantRefusal(t, buildLab(t, nil, func(_, cur *model.Config) {
		subOf(t, cur, "SalesPub", "SalesSub").Articles = []string{"Customer"}
	}), "publications[SalesPub].subscriptions[REPLLAB/SalesSub].articles",
		"extending subscription REPLLAB/SalesSub by name to Orders is refused on this publication (14100 under concurrent, 14122 under immediate_sync)")
}

func TestEveryArticleListIsAll(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		addSub(t, des, "SalesRef", newSub("m_sdb_all", "push", "snapshot", "vcustomerfr", "Product"))
	}))
	add := ofSubscription(opsCalling(ops, "sp_addsubscription"), "REPLLAB/m_sdb_all")
	if len(add) != 1 {
		t.Fatalf("%d sp_addsubscription, want one:\n%s", len(add), opsString(ops))
	}
	wantParam(t, add[0], "@article", "N'all'")
}

func TestUnreadableSubscriptionNotDropped(t *testing.T) {
	p := buildLab(t, nil, func(des, cur *model.Config) {
		cur.Findings = append(cur.Findings, model.Finding{Kind: model.FindingUnreadable,
			Path: "publications[SalesRef].subscriptions[REPLLAB/SalesSub]", Message: "m_test"})
		pubOf(t, des, "SalesRef").Subscriptions = nil
	})
	if ops := planned(t, p); len(ops) != 0 {
		t.Errorf("an unreadable subscription is dropped:\n%s", opsString(ops))
	}
}

func TestDropPublicationDropsPullAtSubscriberFirst(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, cur *model.Config) {
		pullOnRef(t, des, cur)
		var keep []model.Publication
		for _, p := range des.Publications {
			if p.Name != "SalesRef" {
				keep = append(keep, p)
			}
		}
		des.Publications = keep
	}))
	var procs []string
	for _, op := range ops {
		procs = append(procs, op.Call.Procedure)
	}
	if want := "sp_droppullsubscription,sp_dropsubscription,sp_droppublication"; strings.Join(procs, ",") != want {
		t.Errorf("operations %s, want %s", strings.Join(procs, ","), want)
	}
	if len(ops) > 0 && (ops[0].Server != "REPLLAB" || ops[0].Database != "SalesSub") {
		t.Errorf("sp_droppullsubscription at %s.%s", ops[0].Server, ops[0].Database)
	}
}

func TestDiffPullEmptySchedules(t *testing.T) {
	des, cur := newSub("SalesSub", "pull", "snapshot"), newSub("SalesSub", "pull", "snapshot")
	des.PullAgent, cur.PullAgent = exportedPull("SalesSub"), exportedPull("SalesSub")
	const path = "publications[SalesRef].subscriptions[REPLLAB/SalesSub]"
	if cs := diffObject(path, &des, &cur, nil); len(cs) != 0 {
		t.Errorf("[] against []: %s", changesString(cs))
	}
	cur.PullAgent.Schedules = &[]model.Schedule{{Name: "s", Frequency: "agent_start"}}
	cs := diffObject(path, &des, &cur, nil)
	if len(cs) != 1 || cs[0].Pattern != "publications[*].subscriptions[*].pull_agent.schedules" || show(cs[0].After) != `"[]"` {
		t.Errorf("[] against one schedule: %s", changesString(cs))
	}
	// The refusal of [] stays for the other agents (R22).
	c := testConfig(testPub("P", testTable("A", "dbo", "T")))
	c.Publications[0].SnapshotAgent = &model.Agent{Schedules: &[]model.Schedule{}}
	c.Publications[0].Subscriptions = []model.Subscription{des}
	rs := scheduleRefusals(c)
	if len(rs) != 1 || rs[0].Path != "publications[P].snapshot_agent.schedules" {
		t.Errorf("refusals %v, want the snapshot agent's [] alone", rs)
	}
}

func TestSharedPushAgentAfterLastDrop(t *testing.T) {
	// SalesRef's subscription to SalesSub is the only one its shared agent
	// serves: dropping it drops the agent (measured by the Task 12 review),
	// so a new subscription of m_p2 to SalesSub in the same plan creates it
	// again.
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		pubOf(t, des, "SalesRef").Subscriptions = nil
		des.Publications = append(des.Publications, model.Publication{Name: "m_p2", Type: str("transactional"), Status: str("active"),
			SyncMethod: str("native"), IndependentAgent: model.Ptr(false), Articles: []model.Article{newTable("m_t9")},
			Subscriptions: []model.Subscription{newSub("SalesSub", "push", "snapshot")}})
	}))
	drop := one(t, ops, "sp_dropsubscription")
	agent := one(t, ops, "sp_addpushsubscription_agent")
	if first(agent.Affects.Publications) != "m_p2" || agent.Seq <= drop.Seq {
		t.Errorf("agent of %s at seq %d, drop at seq %d", first(agent.Affects.Publications), agent.Seq, drop.Seq)
	}
	// Kept: SalesRef keeps its subscription, the agent is not re-created.
	ops = plannedAlone(t, buildLab(t, nil, func(des, _ *model.Config) {
		des.Publications = append(des.Publications, model.Publication{Name: "m_p2", Type: str("transactional"), Status: str("active"),
			SyncMethod: str("native"), IndependentAgent: model.Ptr(false), Articles: []model.Article{newTable("m_t9")},
			Subscriptions: []model.Subscription{newSub("SalesSub", "push", "snapshot")}})
	}))
	if n := len(opsCalling(ops, "sp_addpushsubscription_agent")); n != 0 {
		t.Errorf("%d agent calls while SalesRef keeps the shared agent:\n%s", n, opsString(ops))
	}
}
