package plan

import (
	"fmt"
	"reflect"
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

// refIndependent makes SalesRef independent in the desired file, which then
// no longer declares the shared distribution agent SalesRef alone used
// (Task 14, sharedPlacement).
func refIndependent(t *testing.T, des *model.Config) {
	t.Helper()
	pubOf(t, des, "SalesRef").IndependentAgent = model.Ptr(true)
	des.Publisher.SharedDistributionAgents = nil
}

func TestIndependentAgentDropReadd(t *testing.T) {
	const subscription = "REPLLAB/SalesSub"
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		refIndependent(t, des)
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
	// Its subscription then uses the shared agent of REPLLAB/SalesSub, which
	// the file declares already (Task 14, sharedPlacement).
	subOf(t, des, "SalesPub", "SalesSub").DistributionAgent = nil
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

// characterRef changes SalesRef to character on the desired side, every
// article's destination and commands omitted.
func characterRef(t *testing.T, des *model.Config) {
	p := pubOf(t, des, "SalesRef")
	for i := range p.Articles {
		p.Articles[i].Destination = model.Destination{}
		p.Articles[i].Commands = nil
	}
	p.SyncMethod = str("character")
}

// An existing article keeps the current value of an omitted property whose
// creation default depends on sync_method: destination.schema and the three
// commands (Task 20 fix round 2). sp_changepublication sync_method rewrites
// neither dest_owner nor the commands (measured by the Task 20 review), so
// both plans, before and after the change, must leave them alone.
func TestSyncMethodKeepsArticleValues(t *testing.T) {
	t.Run("first plan", func(t *testing.T) {
		ops := plannedAlone(t, buildLab(t, nil, func(des, _ *model.Config) { characterRef(t, des) }))
		if len(ops) != 1 {
			t.Fatalf("%d operations, want only sp_changepublication sync_method:\n%s", len(ops), opsString(ops))
		}
		op := oneAlone(t, ops, "sp_changepublication")
		wantParam(t, op, "@property", "N'sync_method'")
		wantParam(t, op, "@value", "N'character'")
		wantOpCosts(t, op, CostOnline)
	})
	t.Run("after the change", func(t *testing.T) {
		// The state the first plan leaves: character, dest_owner dbo, the
		// CALL and SCALL commands of the fixture.
		ops := plannedAlone(t, buildLab(t, nil, func(des, cur *model.Config) {
			characterRef(t, des)
			pubOf(t, cur, "SalesRef").SyncMethod = str("character")
		}))
		if len(ops) != 0 {
			t.Fatalf("%d operations after the change, want none:\n%s", len(ops), opsString(ops))
		}
	})
	t.Run("new article", func(t *testing.T) {
		// A new article takes the desired context: under character the
		// default destination owner is NULL and the commands SQL, which
		// sp_addarticle is not passed (R15).
		ops := plannedAlone(t, buildLab(t, nil, func(des, _ *model.Config) {
			characterRef(t, des)
			addTo(t, des, "SalesRef", newTable("m_t1"))
		}))
		op := oneAlone(t, ops, "sp_addarticle")
		wantParam(t, op, "@article", "N'm_t1'")
		for _, name := range []string{"@destination_owner", "@ins_cmd", "@upd_cmd", "@del_cmd"} {
			noParam(t, op, name)
		}
	})
	t.Run("replaced article", func(t *testing.T) {
		// R20: a new source replaces Product, whose add takes the desired
		// context too, not the dropped article's values.
		ops := plannedAlone(t, buildLab(t, nil, func(des, _ *model.Config) {
			characterRef(t, des)
			a := &pubOf(t, des, "SalesRef").Articles[0]
			a.Source.Name, a.Destination.Name = "Product2", str("Product")
		}))
		op := oneAlone(t, ops, "sp_addarticle")
		wantParam(t, op, "@article", "N'Product'")
		for _, name := range []string{"@destination_owner", "@ins_cmd", "@upd_cmd", "@del_cmd"} {
			noParam(t, op, name)
		}
	})
	t.Run("other properties", func(t *testing.T) {
		// The rule covers only the sync_method-dependent properties: an
		// omitted fire_triggers_on_snapshot of an existing article still
		// takes its default, false, a change from the current true.
		ops := plannedAlone(t, buildLab(t, nil, func(des, cur *model.Config) {
			pubOf(t, cur, "SalesRef").Articles[0].FireTriggersOnSnapshot = model.Ptr(true)
			pubOf(t, des, "SalesRef").Articles[0].FireTriggersOnSnapshot = nil
		}))
		op := oneAlone(t, ops, "sp_changearticle")
		wantParam(t, op, "@property", "N'fire_triggers_on_snapshot'")
	})
}

// The keep rule of TestSyncMethodKeepsArticleValues keeps only a current
// value that is some sync method's creation default (Task 20 fix round 3):
// any other is drift, which an omitted property corrects (spec "Omitted
// properties"). SalesRef is native; Product's destination and commands are
// omitted on the desired side.
func TestOmittedArticleDrift(t *testing.T) {
	omit := func(t *testing.T, des *model.Config) *model.Article {
		a := &pubOf(t, des, "SalesRef").Articles[0]
		a.Destination.Schema, a.Commands = nil, nil
		return a
	}
	t.Run("destination archive", func(t *testing.T) {
		ops := plannedAlone(t, buildLab(t, nil, func(des, cur *model.Config) {
			omit(t, des)
			pubOf(t, cur, "SalesRef").Articles[0].Destination.Schema = str("archive")
		}))
		op := oneAlone(t, ops, "sp_changearticle")
		wantParam(t, op, "@property", "N'destination_owner'")
		wantParam(t, op, "@value", "N'dbo'")
		wantParam(t, op, "@force_reinit_subscription", "1")
		wantOpCosts(t, op, CostReinitialization, CostNewSnapshot, CostSubscriberDataReplaced)
	})
	t.Run("ins_cmd SQL kept", func(t *testing.T) {
		// SQL is character's default: kept, the accepted ambiguity.
		ops := plannedAlone(t, buildLab(t, nil, func(des, cur *model.Config) {
			omit(t, des)
			pubOf(t, cur, "SalesRef").Articles[0].Commands.Insert = &model.Command{Mode: "SQL"}
		}))
		if len(ops) != 0 {
			t.Fatalf("%d operations, want none:\n%s", len(ops), opsString(ops))
		}
	})
	t.Run("XCALL refused", func(t *testing.T) {
		p := buildLab(t, nil, func(des, cur *model.Config) {
			omit(t, des)
			pubOf(t, cur, "SalesRef").Articles[0].Commands.Update = &model.Command{Mode: "XCALL",
				Procedure: &model.ObjectName{Schema: "dbo", Name: "m_upd"}}
		})
		path := pubPathOf("SalesRef") + ".articles[Product].commands.update"
		found := false
		for _, r := range p.Refusals {
			found = found || r.Path == path
		}
		if !found {
			t.Fatalf("no refusal at %s; refusals %v\n%s", path, p.Refusals, opsString(p.Operations))
		}
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

// A deferral on a publication whose immediate_sync snapshot is already
// invalid notes the deferral once: planNotes leaves the "full generation
// deferred" note to the deferral's own (Task 20 fix round 2, N21).
func TestDeferNoteAlone(t *testing.T) {
	des, facts := loadLab(t)
	cur, _ := loadLab(t)
	for i := range facts.Publications {
		if facts.Publications[i].Name == "SalesPub" {
			facts.Publications[i].ImmediateSyncReady = false
		}
	}
	deferPub(t, des, cur, "native")
	p := Build(Inputs{Desired: des, Current: cur, Facts: facts}, deferOpt)
	planned(t, p)
	want := []string{"the full generation is deferred to the next run of the snapshot agent of SalesPub"}
	if !reflect.DeepEqual(p.Notes, want) {
		t.Errorf("notes %q, want %q", p.Notes, want)
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
		refIndependent(t, des)
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

// Task 13 fix round 1.

// refusedWith tells a plan with no operation that has a refusal at path with
// reason, whatever other refusals it has.
func refusedWith(t *testing.T, p *Plan, path, reason string) {
	t.Helper()
	for _, r := range p.Refusals {
		if r.Path == path && r.Reason == reason {
			if len(p.Operations) != 0 {
				t.Errorf("a refused plan has operations")
			}
			return
		}
	}
	t.Errorf("refusals %v, want one at %s: %s", p.Refusals, path, reason)
}

func TestDeferSyncMethodChangeRefused(t *testing.T) {
	for _, tc := range []struct{ from, to string }{{"native", "concurrent"}, {"concurrent", "native"}} {
		t.Run(tc.from+">"+tc.to, func(t *testing.T) {
			p := buildLabWith(t, deferOpt, func(des, cur *model.Config) {
				deferPub(t, des, cur, tc.from)
				pubOf(t, des, "SalesPub").SyncMethod = str(tc.to)
			})
			wantRefusal(t, p, pubPathOf("SalesPub")+".sync_method", deferSyncChange)
		})
	}
}

func TestReinitKeepsRowsWarning(t *testing.T) {
	t.Run("drop_readd", func(t *testing.T) {
		ops := plannedAlone(t, buildLab(t, nil, func(des, cur *model.Config) {
			both(des, cur, func(c *model.Config) { articleOf(t, c, "SalesRef", "Product").PreCreationCmd = str("none") })
			refIndependent(t, des)
		}))
		add := oneAlone(t, ops, "sp_addsubscription")
		if len(add.Warnings) != 1 || add.Warnings[0] != fmt.Sprintf(keepsRowsWarning, "Product") {
			t.Errorf("re-add warnings %q, want the one of Product", add.Warnings)
		}
	})
	t.Run("sync_method", func(t *testing.T) {
		ops := plannedAlone(t, buildLab(t, nil, func(des, cur *model.Config) {
			both(des, cur, func(c *model.Config) { articleOf(t, c, "SalesPub", "Orders").PreCreationCmd = str("none") })
			pubOf(t, des, "SalesPub").SyncMethod = str("native")
		}))
		op := oneAlone(t, ops, "sp_changepublication")
		if len(op.Warnings) != 1 || op.Warnings[0] != fmt.Sprintf(keepsRowsWarning, "Orders") {
			t.Errorf("sync_method warnings %q, want the one of Orders", op.Warnings)
		}
	})
	t.Run("not reinitialized", func(t *testing.T) {
		// A description change of the article reinitializes nothing: no
		// warning, though the call names the article.
		ops := plannedAlone(t, buildLab(t, nil, func(des, cur *model.Config) {
			both(des, cur, func(c *model.Config) { articleOf(t, c, "SalesRef", "Product").PreCreationCmd = str("none") })
			articleOf(t, des, "SalesRef", "Product").Description = str("changed")
		}))
		if op := oneAlone(t, ops, "sp_changearticle"); len(op.Warnings) != 0 {
			t.Errorf("warnings %q on a change that reinitializes nothing", op.Warnings)
		}
	})
}

func TestDeferCostsOnGeneration(t *testing.T) {
	ops := planned(t, buildLabWith(t, deferOpt, func(des, cur *model.Config) { deferPub(t, des, cur, "native") }))
	ext := one(t, ops, "sp_addsubscription")
	gen := one(t, ops, "sp_startpublication_snapshot")
	wantOpCosts(t, ext, CostOnline)
	wantOpCosts(t, gen, CostNewSnapshot)
	if n := planCost(ops, CostNewSnapshot); n != 1 {
		t.Errorf("%d operations cost new_snapshot, want 1:\n%s", n, opsString(ops))
	}
}

func planCost(ops []Operation, c Cost) int {
	n := 0
	for _, op := range ops {
		if hasCost(op.Costs, c) {
			n++
		}
	}
	return n
}

func TestDeferAnonymousTurnedOff(t *testing.T) {
	ops := planned(t, buildLabWith(t, deferOpt, func(des, cur *model.Config) {
		deferPub(t, des, cur, "native")
		pubOf(t, des, "SalesPub").AllowAnonymous = model.Ptr(false)
	}))
	if got, want := propertiesString(pubChanges(ops)), "allow_anonymous=false immediate_sync=false immediate_sync=true"; got != want {
		t.Errorf("changes %s, want %s:\n%s", got, want, opsString(ops))
	}
}

func TestDeferMoreRefusals(t *testing.T) {
	pp := pubPathOf("SalesPub")
	t.Run("snapshot publication", func(t *testing.T) {
		p := buildLabWith(t, deferOpt, func(des, cur *model.Config) {
			deferPub(t, des, cur, "native")
			both(des, cur, func(c *model.Config) { pubOf(t, c, "SalesPub").Type = str("snapshot") })
		})
		refusedWith(t, p, pp, deferUnmeasured)
	})
	t.Run("allow_subscription_copy", func(t *testing.T) {
		p := buildLabWith(t, deferOpt, func(des, cur *model.Config) {
			deferPub(t, des, cur, "native")
			both(des, cur, func(c *model.Config) { pubOf(t, c, "SalesPub").AllowSubscriptionCopy = model.Ptr(true) })
		})
		wantRefusal(t, p, pp, deferUnmeasured)
	})
}

func TestDeferNeedsCurrentImmediateSync(t *testing.T) {
	ops := planned(t, buildLabWith(t, deferOpt, func(des, cur *model.Config) {
		deferPub(t, des, cur, "native")
		p := pubOf(t, cur, "SalesPub")
		p.ImmediateSync, p.AllowAnonymous = model.Ptr(false), model.Ptr(false)
	}))
	if n := len(opsCalling(ops, "sp_startpublication_snapshot")); n != 0 {
		t.Errorf("%d generate_and_wait on a publication without immediate_sync:\n%s", n, opsString(ops))
	}
}

func TestDeferReplacedArticle(t *testing.T) {
	ops := planned(t, buildLabWith(t, deferOpt, func(des, cur *model.Config) {
		deferPub(t, des, cur, "native")
		removeArticle(t, des, "SalesPub", "m_t1")
		articleOf(t, des, "SalesPub", "Orders").Source.Name = "Orders2" // R20
	}))
	one(t, ops, "sp_startpublication_snapshot")
}

func TestReaddRefusals(t *testing.T) {
	refPath := func(leaf string) string {
		return subPath("SalesRef", subOf(t, loadLabConfig(t), "SalesRef", "SalesSub")) + "." + leaf
	}
	t.Run("type", func(t *testing.T) {
		p := buildLab(t, nil, func(des, _ *model.Config) {
			d := pubOf(t, des, "SalesRef")
			d.IndependentAgent, d.AllowPull = model.Ptr(true), model.Ptr(true)
			des.Publisher.SharedDistributionAgents = nil // Task 14, sharedPlacement
			subOf(t, des, "SalesRef", "SalesSub").Type = str("pull")
		})
		wantRefusal(t, p, refPath("type"), fmt.Sprintf(r21Type, "REPLLAB/SalesSub", "push", "pull"))
	})
	for _, side := range []string{"current", "desired"} {
		t.Run("initialization "+side, func(t *testing.T) {
			p := buildLab(t, nil, func(des, cur *model.Config) {
				refIndependent(t, des)
				c := cur
				if side == "desired" {
					c = des
				}
				subOf(t, c, "SalesRef", "SalesSub").Initialization = str("replication_support_only")
			})
			wantRefusal(t, p, refPath("initialization"), fmt.Sprintf(readdInit, "REPLLAB/SalesSub", "replication_support_only"))
		})
	}
}

func TestChainDepths(t *testing.T) {
	order := func(rel, after string) string {
		return chainOrder("P", Change{Path: "publications[P]." + rel, Pattern: pubPropPrefix + rel, After: str(after)})
	}
	for _, c := range []struct{ low, high, on, off string }{
		{"immediate_sync", "allow_subscription_copy", "true", "false"},
		{"allow_partition_switch", "replicate_partition_switch", "true", "false"},
		{"snapshot.alt_folder", "snapshot.compress", "/x", ""},
	} {
		highOn, highOff := c.on, c.off
		if c.high == "snapshot.compress" {
			highOn, highOff = "true", "false"
		}
		if !(order(c.low, c.on) < order(c.high, highOn)) {
			t.Errorf("enable: %s does not come before %s", c.low, c.high)
		}
		if !(order(c.high, highOff) < order(c.low, c.off)) {
			t.Errorf("disable: %s does not come before %s", c.high, c.low)
		}
	}
}

func TestNamedExtensionSubsetRefused(t *testing.T) {
	p := buildLab(t, nil, func(des, cur *model.Config) {
		pubOf(t, cur, "SalesRef").SyncMethod = str("concurrent")
		subOf(t, cur, "SalesRef", "SalesSub").Articles = []string{"Product"}
	})
	refusedWith(t, p, subPath("SalesRef", subOf(t, loadLabConfig(t), "SalesRef", "SalesSub")),
		"cost of the snapshot after an extension on a publication reinitialization not measured: change sync_method in one plan and add the articles in another")
}

func TestNamedOnMarkedMethods(t *testing.T) {
	for m, want := range map[string]bool{"native": true, "character": true, "concurrent": false, "database_snapshot": false} {
		ps := &PubState{SyncMethod: m, wideMarked: true, Subs: map[string]*SubState{"s": {Rows: map[string]int{"a": 1}}}}
		if got := namedOnMarked(ps); got != want {
			t.Errorf("namedOnMarked under %s = %v, want %v", m, got, want)
		}
	}
}

func TestPostScriptWarningOnChange(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		pubOf(t, des, "SalesRef").Snapshot.PostScript = str("/var/opt/mssql/data/post.sql")
	}))
	wantWarning(t, one(t, ops, "sp_changepublication"), snapshotScriptWarning)
}
