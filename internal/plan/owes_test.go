package plan

import (
	"reflect"
	"strings"
	"testing"

	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
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
