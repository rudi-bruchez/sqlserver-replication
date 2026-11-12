package plan

import (
	"reflect"
	"strings"
	"testing"

	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
	"github.com/rudi-bruchez/sqlserver-replication/internal/normalize"
	"github.com/rudi-bruchez/sqlserver-replication/internal/state"
)

// wantOwes checks the deliveries an operation owes (R50).
func wantOwes(t *testing.T, op Operation, at string, keys ...string) {
	t.Helper()
	if strings.Join(op.Owes, ",") != strings.Join(keys, ",") || op.OwesAt != at {
		t.Errorf("%s %s %s owes %v at %q, want %v at %q", op.Action, op.Kind, op.Call.Procedure, op.Owes, op.OwesAt, keys, at)
	}
}

// A new snapshot-initialized subscription owes its key: a push one before
// its unit, on sp_addsubscription; a pull one after the publisher-side
// sp_addsubscription; a replication support only one nothing.
func TestOwesSubscriptionCreation(t *testing.T) {
	const pushKey = "REPLLAB/m_sdb_owe"
	ops := plannedAlone(t, buildLab(t, nil, func(des, _ *model.Config) {
		addSub(t, des, "SalesRef", newSub("m_sdb_owe", "push", "snapshot"))
	}))
	got := ofSubscription(ops, pushKey)
	if len(got) != 2 || got[0].Call.Procedure != "sp_addsubscription" || got[1].Call.Procedure != "sp_addpushsubscription_agent" {
		t.Fatalf("operations of %s:\n%s", pushKey, opsString(got))
	}
	wantOwes(t, got[0], "before", pushKey)
	wantOwes(t, got[1], "")

	const pullKey = "REPLLAB/m_sdb_owep"
	ops = plannedAlone(t, buildLab(t, nil, func(des, cur *model.Config) {
		refPull(t, des, cur)
		addSub(t, des, "SalesRef", newSub("m_sdb_owep", "pull", "snapshot"))
	}))
	if len(ops) != 3 {
		t.Fatalf("%d operations, want 3:\n%s", len(ops), opsString(ops))
	}
	wantOwes(t, ops[0], "after", pullKey)
	wantOwes(t, ops[1], "")
	wantOwes(t, ops[2], "")

	ops = plannedAlone(t, buildLab(t, nil, func(des, _ *model.Config) {
		addSub(t, des, "SalesRef", newSub("m_sdb_ower", "push", "replication_support_only"))
	}))
	if len(ofSubscription(ops, "REPLLAB/m_sdb_ower")) == 0 {
		t.Fatalf("no operation of the replication support only subscription:\n%s", opsString(ops))
	}
	for _, op := range ops {
		wantOwes(t, op, "")
	}
}

// An article added to a ready immediate_sync publication owes every
// subscription it gives a status 1 row, after the call; on a publication
// without immediate_sync the extension owes its subscription.
func TestOwesAddArticle(t *testing.T) {
	ops := plannedAlone(t, buildLab(t, nil, func(des, _ *model.Config) { addTo(t, des, "SalesPub", newTable("m_t9")) }))
	wantOwes(t, one(t, ops, "sp_addarticle"), "after", "REPLLAB/SalesSub")

	ops = plannedAlone(t, buildLab(t, nil, func(des, _ *model.Config) { addTo(t, des, "SalesRef", newTable("m_t9")) }))
	wantOwes(t, one(t, ops, "sp_addarticle"), "")
	ext := one(t, ops, "sp_addsubscription")
	if ext.Kind != "subscription_extension" {
		t.Fatalf("sp_addsubscription is a %s, want subscription_extension", ext.Kind)
	}
	wantOwes(t, ext, "after", "REPLLAB/SalesSub")
}

// A reinit-flagged change owes the subscriptions it marks, read by apply as
// those whose rows went from 2 to 1 (R50, marked).
func TestOwesReinitMarked(t *testing.T) {
	ops := plannedAlone(t, buildLab(t, nil, func(des, _ *model.Config) {
		a := articleOf(t, des, "SalesPub", "Customer")
		opts := append(append([]string{}, *a.SchemaOptions...), "nonclustered_indexes")
		a.SchemaOptions = &opts
	}))
	op := one(t, ops, "sp_changearticle")
	wantFlags(t, op, true, true)
	if len(op.Affects.Subscriptions) == 0 {
		t.Fatalf("the reinitialization names no subscription")
	}
	wantOwes(t, op, "marked", op.Affects.Subscriptions...)
}

// OwedBefore is the subscriptions with a row at 1 before the plan.
func TestOwedBefore(t *testing.T) {
	p := buildFull(t, nil, func(f *state.Facts) { f.Subscriptions[0].Rows[0].PublisherStatus = 1 }, nil)
	// The fixture's first subscription facts are SalesPub's.
	want := []Owed{{Publication: "SalesPub", Subscription: "REPLLAB/SalesSub"}}
	if !reflect.DeepEqual(p.OwedBefore, want) {
		t.Errorf("OwedBefore %+v, want %+v", p.OwedBefore, want)
	}
	if p := buildFull(t, nil, nil, nil); len(p.OwedBefore) != 0 {
		t.Errorf("the fixture as is: OwedBefore %+v, want none", p.OwedBefore)
	}
}

// The deferral's generate_and_wait names the subscriptions extended before
// it, and owes nothing itself: apply waits for their deliveries (R51).
func TestGenerateAndWaitNamesSubscriptions(t *testing.T) {
	p := buildLabWith(t, deferOpt, func(des, cur *model.Config) { deferPub(t, des, cur, "native") })
	ops := planned(t, p)
	gw := ofKind(ops, "generate_and_wait")
	if len(gw) != 1 {
		t.Fatalf("%d generate_and_wait, want 1", len(gw))
	}
	if want := []string{"REPLLAB/SalesSub"}; !reflect.DeepEqual(gw[0].Affects.Subscriptions, want) {
		t.Errorf("generate_and_wait affects subscriptions %v, want %v", gw[0].Affects.Subscriptions, want)
	}
	wantOwes(t, gw[0], "")
}

// The distribution database and each publication's snapshot root: its
// alt_snapshot_folder when set, else the distributor's working directory.
func TestPlanDistributionAndRoots(t *testing.T) {
	const wd = "/var/opt/mssql/data/ReplData"
	p := buildLab(t, nil, nil)
	if p.DistributionDB != "distribution" {
		t.Errorf("DistributionDB %q, want distribution", p.DistributionDB)
	}
	if want := map[string]string{"SalesPub": wd, "SalesRef": wd}; !reflect.DeepEqual(p.SnapshotRoots, want) {
		t.Errorf("SnapshotRoots %v, want %v", p.SnapshotRoots, want)
	}
	p = buildLab(t, nil, func(des, cur *model.Config) {
		both(des, cur, func(c *model.Config) { pubOf(t, c, "SalesRef").Snapshot.AltFolder = str("/alt/ref") })
	})
	if want := map[string]string{"SalesPub": wd, "SalesRef": "/alt/ref"}; !reflect.DeepEqual(p.SnapshotRoots, want) {
		t.Errorf("with an alt folder: SnapshotRoots %v, want %v", p.SnapshotRoots, want)
	}
}

// Fix round 1, Important 1: a subscription pending before the plan that the
// plan drops, alone or with its publication, is owed nothing before.
func TestOwedBeforeDropped(t *testing.T) {
	atOne := func(f *state.Facts) { f.Subscriptions[0].Rows[0].PublisherStatus = 1 } // SalesPub's
	p := buildFull(t, nil, atOne, func(des, _ *model.Config) {
		removePub(des, "SalesPub")
	})
	if len(p.Refusals) > 0 || len(p.OwedBefore) != 0 {
		t.Errorf("SalesPub dropped: refusals %v, OwedBefore %+v, want none", p.Refusals, p.OwedBefore)
	}
	p = buildFull(t, nil, atOne, func(des, _ *model.Config) {
		pubOf(t, des, "SalesPub").Subscriptions = nil
	})
	if len(ofKind(p.Operations, "subscription")) == 0 {
		t.Fatalf("the subscription is not dropped:\n%s", opsString(p.Operations))
	}
	if len(p.Refusals) > 0 || len(p.OwedBefore) != 0 {
		t.Errorf("subscription dropped: refusals %v, OwedBefore %+v, want none", p.Refusals, p.OwedBefore)
	}
}

// Fix round 1, Important 2: the root before the plan is the current one,
// the desired root may differ, and a created publication has no root before.
func TestSnapshotRootsBefore(t *testing.T) {
	const wd = "/var/opt/mssql/data/ReplData"
	p := buildLab(t, nil, func(des, _ *model.Config) {
		pubOf(t, des, "SalesPub").Snapshot.AltFolder = str("/alt/new")
	})
	if got, want := p.SnapshotRootsBefore["SalesPub"], wd; got != want {
		t.Errorf("SnapshotRootsBefore[SalesPub] %q, want %q", got, want)
	}
	if got, want := p.SnapshotRoots["SalesPub"], "/alt/new"; got != want {
		t.Errorf("SnapshotRoots[SalesPub] %q, want %q", got, want)
	}
	p = buildLab(t, nil, func(des, _ *model.Config) {
		des.Publications = append(des.Publications, testPub("m_p", newTable("m_t")))
	})
	if _, ok := p.SnapshotRootsBefore["m_p"]; ok || p.SnapshotRoots["m_p"] != wd {
		t.Errorf("created m_p: before %v, after %v; want no before entry and the working directory after", p.SnapshotRootsBefore, p.SnapshotRoots)
	}
}

// Fix round 1, Minor 3: a reinitialization does not mark a replication
// support only subscription (measured by the review of Task 4: status 2
// kept, sp_reinitsubscription refuses it), so it is neither named nor
// started.
func TestReinitSkipsReplicationSupportOnly(t *testing.T) {
	const rso = "REPLLAB/m_sdb_rso"
	p := buildLab(t, nil, func(des, cur *model.Config) {
		both(des, cur, func(c *model.Config) {
			addSub(t, c, "SalesPub", newSub("m_sdb_rso", "push", "replication_support_only"))
		})
		sameSubscription(t, des, cur, "SalesPub", "m_sdb_rso")
		a := articleOf(t, des, "SalesPub", "Customer")
		opts := append(append([]string{}, *a.SchemaOptions...), "nonclustered_indexes")
		a.SchemaOptions = &opts
	})
	ops := plannedAlone(t, p)
	op := one(t, ops, "sp_changearticle")
	if want := []string{"REPLLAB/SalesSub"}; !reflect.DeepEqual(op.Affects.Subscriptions, want) {
		t.Errorf("Affects.Subscriptions %v, want %v", op.Affects.Subscriptions, want)
	}
	wantOwes(t, op, "marked", "REPLLAB/SalesSub")
	for _, a := range p.AgentsToStart {
		if a.Subscriber+"/"+a.Database == rso {
			t.Errorf("AgentsToStart lists %+v", a)
		}
	}
	if strings.Contains(p.Summary(), "m_sdb_rso)") || strings.Contains(p.Summary(), "m_sdb_rso, ") {
		t.Errorf("the summary names the replication support only subscription:\n%s", p.Summary())
	}
}

// Fix round 1, Minors 4 and 5: the deferral's summary names the
// subscriptions generate_and_wait waits for; -json shows owes and owes_at,
// and owed_before as [] when empty.
func TestOwesRendered(t *testing.T) {
	p := buildLabWith(t, deferOpt, func(des, cur *model.Config) { deferPub(t, des, cur, "native") })
	planned(t, p)
	if want := "start generate_and_wait publications[SalesPub].snapshot_agent: new_snapshot (subscriptions REPLLAB/SalesSub)\n"; !strings.Contains(p.Summary(), want) {
		t.Errorf("summary lacks %q:\n%s", want, p.Summary())
	}
	p = buildLab(t, nil, func(des, _ *model.Config) {
		addSub(t, des, "SalesRef", newSub("m_sdb_owe", "push", "snapshot"))
	})
	planned(t, p)
	js, err := p.JSON()
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"\"owes\": [\n        \"REPLLAB/m_sdb_owe\"\n      ],\n      \"owes_at\": \"before\"", "\"owed_before\": []"} {
		if !strings.Contains(string(js), want) {
			t.Errorf("JSON lacks %q", want)
		}
	}
}

// sameSubscription writes into the current subscription of pub to db the
// subscription the normalization of the desired file gives, so that only
// what a test changes differs.
func sameSubscription(t *testing.T, des, cur *model.Config, pub, db string) {
	t.Helper()
	n, rs := normalize.Normalize(des, cur)
	for _, r := range rs {
		t.Fatalf("normalization refuses %s: %s", r.Path, r.Reason)
	}
	*subOf(t, cur, pub, db) = *subOf(t, n, pub, db)
}
