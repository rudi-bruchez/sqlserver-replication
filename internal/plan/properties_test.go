package plan

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
)

// buildLabWith is buildLab with options.
func buildLabWith(t *testing.T, opt Options, edit func(des, cur *model.Config)) *Plan {
	t.Helper()
	des, facts := loadLab(t)
	cur, _ := loadLab(t)
	if edit != nil {
		edit(des, cur)
	}
	return Build(Inputs{Desired: des, Current: cur, Facts: facts}, opt)
}

// pubChanges is the sp_changepublication operations of a plan, in plan
// order.
func pubChanges(ops []Operation) []Operation { return opsCalling(ops, "sp_changepublication") }

// propertyOf is the @property of an sp_changepublication, unquoted, and its
// @value.
func propertyOf(op Operation) string {
	p, _ := paramString(&op, "@property")
	v, _ := paramString(&op, "@value")
	return p + "=" + v
}

func propertiesString(ops []Operation) string {
	var out []string
	for _, op := range ops {
		out = append(out, propertyOf(op))
	}
	return strings.Join(out, " ")
}

func TestChainOrder(t *testing.T) {
	noSubs := func(des, cur *model.Config) {
		both(des, cur, func(c *model.Config) { pubOf(t, c, "SalesRef").Subscriptions = nil })
	}
	set := func(c *model.Config, v bool) {
		p := pubOf(t, c, "SalesRef")
		p.IndependentAgent, p.ImmediateSync, p.AllowAnonymous = model.Ptr(v), model.Ptr(v), model.Ptr(v)
	}
	for _, tc := range []struct {
		name     string
		from, to bool
		want     string
	}{
		{"enable", false, true, "independent_agent=true immediate_sync=true allow_anonymous=true"},
		{"disable", true, false, "allow_anonymous=false immediate_sync=false independent_agent=false"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ops := plannedAlone(t, buildLab(t, nil, func(des, cur *model.Config) {
				noSubs(des, cur)
				set(cur, tc.from)
				set(des, tc.to)
			}))
			if len(ops) != 3 {
				t.Fatalf("%d operations, want 3:\n%s", len(ops), opsString(ops))
			}
			if got := propertiesString(pubChanges(ops)); got != tc.want {
				t.Errorf("order %s, want %s", got, tc.want)
			}
			for _, op := range ops {
				if op.Step != 6 || op.Kind != "publication_property" {
					t.Errorf("%s in step %d kind %s, want step 6 publication_property", propertyOf(op), op.Step, op.Kind)
				}
			}
		})
	}
}

func TestIndependentAgentDropReadd(t *testing.T) {
	const subscription = "REPLLAB/SalesSub"
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		pubOf(t, des, "SalesRef").IndependentAgent = model.Ptr(true)
	}))
	drop := one(t, ops, "sp_dropsubscription")
	change := one(t, ops, "sp_changepublication")
	add := one(t, ops, "sp_addsubscription")
	if drop.Step != 4 || change.Step != 6 || add.Step != 9 {
		t.Errorf("steps %d, %d, %d, want 4, 6, 9:\n%s", drop.Step, change.Step, add.Step, opsString(ops))
	}
	if !(drop.Seq < change.Seq && change.Seq < add.Seq) {
		t.Errorf("seq %d, %d, %d not in order", drop.Seq, change.Seq, add.Seq)
	}
	for _, op := range []Operation{drop, add} {
		if !strings.EqualFold(first(op.Affects.Subscriptions), subscription) || first(op.Affects.Publications) != "SalesRef" {
			t.Errorf("%s affects %v", op.Call.Procedure, op.Affects)
		}
	}
	wantParam(t, drop, "@article", "N'all'")
	wantParam(t, change, "@property", "N'independent_agent'")
	wantParam(t, change, "@value", "N'true'")
	wantFlags(t, change, false, false)
	wantParam(t, add, "@article", "N'all'")
	// Product and vCustomerFR have pre_creation_cmd drop: the
	// reinitialization replaces their subscriber tables (carried decision).
	wantOpCosts(t, add, CostReinitialization, CostNewSnapshot, CostDropAndReadd, CostSubscriberDataReplaced)
	// SalesRef becomes independent: the subscription gets an agent of its
	// own, right after it.
	agent := one(t, ops, "sp_addpushsubscription_agent")
	if agent.Seq != add.Seq+1 {
		t.Errorf("sp_addpushsubscription_agent seq %d, want %d", agent.Seq, add.Seq+1)
	}
}

// anonymousPub gives SalesPub allow_anonymous true on the current side (it
// has independent_agent and immediate_sync) and sets the three to false on
// the desired side, allow_anonymous to keepAnon.
func anonymousPub(t *testing.T, des, cur *model.Config, keepAnon bool) {
	pubOf(t, cur, "SalesPub").AllowAnonymous = model.Ptr(true)
	p := pubOf(t, des, "SalesPub")
	p.IndependentAgent, p.ImmediateSync, p.AllowAnonymous = model.Ptr(false), model.Ptr(false), model.Ptr(keepAnon)
}

func TestIndependentAgentDropReaddAnonymous(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, cur *model.Config) { anonymousPub(t, des, cur, false) }))
	drop := one(t, ops, "sp_dropsubscription")
	add := one(t, ops, "sp_addsubscription")
	changes := pubChanges(ops)
	if got, want := propertiesString(changes), "allow_anonymous=false immediate_sync=false independent_agent=false"; got != want {
		t.Fatalf("step 6 %s, want %s:\n%s", got, want, opsString(ops))
	}
	if drop.Step != 4 || add.Step != 9 {
		t.Errorf("drop in step %d, re-add in step %d, want 4 and 9", drop.Step, add.Step)
	}
	for _, c := range changes {
		if c.Step != 6 || c.Seq < drop.Seq || c.Seq > add.Seq {
			t.Errorf("%s step %d seq %d, want step 6 between %d and %d", propertyOf(c), c.Step, c.Seq, drop.Seq, add.Seq)
		}
	}
	wantParam(t, add, "@article", "N'all'")
	if !hasCost(add.Costs, CostDropAndReadd) || !hasCost(add.Costs, CostReinitialization) || !hasCost(add.Costs, CostNewSnapshot) {
		t.Errorf("re-add costs %v", add.Costs)
	}

	p := buildLab(t, nil, func(des, cur *model.Config) { anonymousPub(t, des, cur, true) })
	wantRefusal(t, p, pubPathOf("SalesPub")+".allow_anonymous", "allow_anonymous requires immediate_sync (20011)")
}

func TestDropReaddRefusedForNonSnapshotInit(t *testing.T) {
	p := buildLab(t, nil, func(des, cur *model.Config) {
		anonymousPub(t, des, cur, false)
		both(des, cur, func(c *model.Config) {
			subOf(t, c, "SalesPub", "SalesSub").Initialization = str("replication_support_only")
		})
	})
	_, cur := labPair(t)
	path := subPath("SalesPub", subOf(t, cur, "SalesPub", "SalesSub")) + ".initialization"
	reason := fmt.Sprintf(readdInit, "REPLLAB/SalesSub", "replication_support_only")
	wantRefusal(t, p, path, reason)
	for _, way := range []string{"COPY_ONLY", "initialize from lsn"} {
		if !strings.Contains(reason, way) {
			t.Errorf("the refusal does not name %s", way)
		}
	}
}

func TestImmediateSyncFalseCosts(t *testing.T) {
	t.Run("immediate_sync", func(t *testing.T) {
		ops := plannedAlone(t, buildLab(t, nil, func(des, _ *model.Config) {
			pubOf(t, des, "SalesPub").ImmediateSync = model.Ptr(false)
		}))
		op := oneAlone(t, ops, "sp_changepublication")
		wantFlags(t, op, false, false)
		wantOpCosts(t, op, CostReadySnapshotDropped)
	})
	t.Run("allow_anonymous", func(t *testing.T) {
		ops := plannedAlone(t, buildLab(t, nil, func(des, cur *model.Config) {
			pubOf(t, cur, "SalesPub").AllowAnonymous = model.Ptr(true)
			pubOf(t, des, "SalesPub").AllowAnonymous = model.Ptr(false)
		}))
		op := oneAlone(t, ops, "sp_changepublication")
		wantFlags(t, op, false, false)
		wantOpCosts(t, op, CostFullGenerationDeferred)
	})
	t.Run("both", func(t *testing.T) {
		ops := plannedAlone(t, buildLab(t, nil, func(des, cur *model.Config) {
			pubOf(t, cur, "SalesPub").AllowAnonymous = model.Ptr(true)
			p := pubOf(t, des, "SalesPub")
			p.AllowAnonymous, p.ImmediateSync = model.Ptr(false), model.Ptr(false)
		}))
		cs := pubChanges(ops)
		if len(cs) != 2 || propertiesString(cs) != "allow_anonymous=false immediate_sync=false" {
			t.Fatalf("changes %s, want allow_anonymous then immediate_sync:\n%s", propertiesString(cs), opsString(ops))
		}
		wantOpCosts(t, cs[0], CostReadySnapshotDropped)
		wantOpCosts(t, cs[1], CostOnline)
	})
}

func TestSyncMethodCosts(t *testing.T) {
	t.Run("concurrent>native", func(t *testing.T) {
		ops := plannedAlone(t, buildLab(t, nil, func(des, _ *model.Config) {
			pubOf(t, des, "SalesPub").SyncMethod = str("native")
		}))
		op := oneAlone(t, ops, "sp_changepublication")
		wantParam(t, op, "@value", "N'native'")
		wantFlags(t, op, true, true)
		if got := strings.Join(op.Affects.Subscriptions, ","); got != "REPLLAB/SalesSub" {
			t.Errorf("reinitialized subscriptions %q, want every subscription of SalesPub", got)
		}
		// Customer (drop) and Orders (truncate) replace subscriber data.
		wantOpCosts(t, op, CostReinitialization, CostNewSnapshot, CostSubscriberDataReplaced)
	})
	t.Run("native>character", func(t *testing.T) {
		ops := plannedAlone(t, buildLab(t, nil, func(des, _ *model.Config) {
			pubOf(t, des, "SalesRef").SyncMethod = str("character")
		}))
		op := oneAlone(t, ops, "sp_changepublication")
		wantFlags(t, op, false, false)
		wantOpCosts(t, op, CostOnline)
	})
}

func TestSyncMethodUnmeasuredRefused(t *testing.T) {
	p := buildLab(t, nil, func(des, _ *model.Config) {
		pubOf(t, des, "SalesRef").SyncMethod = str("concurrent_c")
	})
	wantRefusal(t, p, pubPathOf("SalesRef")+".sync_method", "cost of publications[*].sync_method change not measured")
}

// deferPub makes SalesPub a native publication with allow_anonymous true and
// a snapshot agent that runs once, on both sides, and adds article m_t1 on
// the desired side.
func deferPub(t *testing.T, des, cur *model.Config, method string) {
	both(des, cur, func(c *model.Config) {
		p := pubOf(t, c, "SalesPub")
		p.SyncMethod, p.AllowAnonymous = str(method), model.Ptr(true)
		s := (*p.SnapshotAgent.Schedules)[0]
		s.Frequency, s.Interval, s.Subday, s.SubdayInterval, s.RelativeInterval = "once", 0, "", 0, 0
		p.SnapshotAgent.Schedules = &[]model.Schedule{s}
	})
	addTo(t, des, "SalesPub", newTable("m_t1"))
}

var deferOpt = Options{DeferFullSnapshot: true, Wait: time.Minute}

func TestDeferSequence(t *testing.T) {
	p := buildLabWith(t, deferOpt, func(des, cur *model.Config) { deferPub(t, des, cur, "native") })
	ops := planned(t, p)
	want := []string{
		"sp_changepublication allow_anonymous=false",
		"sp_changepublication immediate_sync=false",
		"sp_addarticle",
		"sp_addsubscription",
		"sp_startpublication_snapshot",
		"sp_changepublication immediate_sync=true",
		"sp_changepublication allow_anonymous=true",
	}
	var got []string
	for _, op := range ops {
		g := op.Call.Procedure
		if g == "sp_changepublication" {
			g += " " + propertyOf(op)
		}
		got = append(got, g)
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("operations:\n%s\nwant:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
	wantFlags(t, ops[2], false, false) // the snapshot is no longer ready
	wantParam(t, ops[3], "@article", "N'm_t1'")
	if ops[4].Kind != "generate_and_wait" || ops[4].Step != 9 {
		t.Errorf("generate_and_wait: kind %s step %d", ops[4].Kind, ops[4].Step)
	}
	wantParam(t, ops[4], "@publication", "N'SalesPub'")
	// The first call drops the ready snapshot; the publication ends with
	// immediate_sync, so the full generation is deferred.
	wantOpCosts(t, ops[0], CostFullGenerationDeferred)
	note := "the full generation is deferred to the next run of the snapshot agent of SalesPub"
	if len(p.Notes) != 1 || p.Notes[0] != note {
		t.Errorf("notes %q, want %q", p.Notes, note)
	}
}

func TestDeferRefusals(t *testing.T) {
	pp := pubPathOf("SalesPub")
	for _, tc := range []struct {
		name   string
		opt    Options
		edit   func(des, cur *model.Config)
		path   string
		reason string
	}{
		{"character", deferOpt, func(des, cur *model.Config) { deferPub(t, des, cur, "character") },
			pp + ".sync_method", deferUnmeasured},
		{"recurring", deferOpt, func(des, cur *model.Config) {
			both(des, cur, func(c *model.Config) {
				p := pubOf(t, c, "SalesPub")
				p.SyncMethod = str("native")
			})
			addTo(t, des, "SalesPub", newTable("m_t1"))
		}, pp + ".snapshot_agent.schedules", fmt.Sprintf(deferRecurring, "SalesPub")},
		{"made daily", deferOpt, func(des, cur *model.Config) {
			both(des, cur, func(c *model.Config) { pubOf(t, c, "SalesPub").SyncMethod = str("native") })
			pubOf(t, cur, "SalesPub").SnapshotAgent.Schedules = &[]model.Schedule{} // on demand
			addTo(t, des, "SalesPub", newTable("m_t1"))
		}, pp + ".snapshot_agent.schedules", fmt.Sprintf(deferMadeRecur, "SalesPub")},
		{"no wait", Options{DeferFullSnapshot: true}, func(des, cur *model.Config) { deferPub(t, des, cur, "native") },
			pp, deferNoWait},
	} {
		t.Run(tc.name, func(t *testing.T) {
			wantRefusal(t, buildLabWith(t, tc.opt, tc.edit), tc.path, tc.reason)
		})
	}
}

func TestOnlinePropertyChange(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		pubOf(t, des, "SalesPub").RetentionHours = model.Ptr(100)
	}))
	if len(ops) != 1 {
		t.Fatalf("%d operations, want 1:\n%s", len(ops), opsString(ops))
	}
	op := ops[0]
	wantParam(t, op, "@property", "N'retention'")
	wantParam(t, op, "@value", "N'100'")
	wantFlags(t, op, false, false)
	wantOpCosts(t, op, CostOnline)
	if op.Step != 6 {
		t.Errorf("step %d, want 6", op.Step)
	}
}

func TestSnapshotClassCost(t *testing.T) {
	for _, tc := range []struct {
		pub  string
		flag bool
		cost Cost
	}{
		{"SalesPub", true, CostFullGenerationDeferred}, // ready, keeps immediate_sync
		{"SalesRef", false, CostOnline},
	} {
		t.Run(tc.pub, func(t *testing.T) {
			ops := plannedAlone(t, buildLab(t, nil, func(des, _ *model.Config) {
				pubOf(t, des, tc.pub).Snapshot.AltFolder = str("/var/opt/mssql/data/ReplAlt")
			}))
			op := oneAlone(t, ops, "sp_changepublication")
			wantParam(t, op, "@property", "N'alt_snapshot_folder'")
			wantFlags(t, op, tc.flag, false)
			wantOpCosts(t, op, tc.cost)
		})
	}
}

// Outside the brief's filter: the carried decisions of Tasks 9 and 11.

func TestNamedExtensionAfterSyncMethodRefused(t *testing.T) {
	p := buildLab(t, nil, func(des, cur *model.Config) {
		pubOf(t, cur, "SalesRef").SyncMethod = str("concurrent")
		addTo(t, des, "SalesRef", newTable("m_t1"))
	})
	path := subPath("SalesRef", subOf(t, loadLabConfig(t), "SalesRef", "SalesSub"))
	wantRefusal(t, p, path, "cost of the snapshot after an extension on a publication reinitialization not measured: change sync_method in one plan and add the articles in another")
}

func loadLabConfig(t *testing.T) *model.Config {
	c, _ := loadLab(t)
	return c
}

func TestSnapshotScriptWarning(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		pubOf(t, des, "SalesRef").Snapshot.PreScript = str("/var/opt/mssql/data/pre.sql")
		des.Publications = append(des.Publications, model.Publication{Name: "m_scripts", Status: str("active"),
			SyncMethod: str("native"), Snapshot: &model.Snapshot{PostScript: str("/var/opt/mssql/data/post.sql")}})
	}))
	for _, op := range ops {
		switch {
		case op.Kind == "publication_property", op.Kind == "publication" && op.Action == "add":
			wantWarning(t, op, snapshotScriptWarning)
		}
	}
	if len(opsCalling(ops, "sp_addpublication")) != 1 || len(pubChanges(ops)) != 1 {
		t.Errorf("plan:\n%s", opsString(ops))
	}
}

func TestReaddWithArticleChanges(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		pubOf(t, des, "SalesRef").IndependentAgent = model.Ptr(true)
		addTo(t, des, "SalesRef", newTable("m_t1"))
		removeArticle(t, des, "SalesRef", "vCustomerFR")
	}))
	// The whole subscription is dropped in step 4 and added back with
	// N'all' in step 9: no call names it for one article.
	subs := opsCalling(ops, "sp_dropsubscription")
	adds := opsCalling(ops, "sp_addsubscription")
	if len(subs) != 1 || len(adds) != 1 {
		t.Fatalf("%d sp_dropsubscription and %d sp_addsubscription, want 1 and 1:\n%s", len(subs), len(adds), opsString(ops))
	}
	wantParam(t, subs[0], "@article", "N'all'")
	wantParam(t, adds[0], "@article", "N'all'")
	if !adds[0].readd {
		t.Errorf("the sp_addsubscription is not the re-add")
	}
}
