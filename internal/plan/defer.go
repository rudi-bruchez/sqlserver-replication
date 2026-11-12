package plan

import (
	"fmt"

	"github.com/rudi-bruchez/sqlserver-replication/internal/cost"
	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
)

func init() { strategies = append(strategies, deferStrategy) }

// The texts of the deferral (spec "Strategies", -defer-full-snapshot).
const (
	deferUnmeasured = "cost of deferred snapshot not measured"
	deferRecurring  = "the deferral would last until the next scheduled run: the snapshot agent of %s has a recurring schedule; change its schedule in one plan and defer in the next"
	deferMadeRecur  = "the deferral would last until the next scheduled run: the file makes the snapshot agent of %s recurring; change its schedule in one plan and defer in another"
	deferNoWait     = "-defer-full-snapshot needs -wait: the generate and wait step waits for the deliveries of the added articles (R25)"
	deferNote       = "the full generation is deferred to the next run of the snapshot agent of %s"
)

// The Order keys of the deferral's operations at the end of step 9: a
// leading 0xff byte, which no UTF-8 publication name starts with, sorts
// them after every other step 9 operation; then the publication, and 1 for
// generate_and_wait, 2 for immediate_sync true, 3 for allow_anonymous true.
const endOfStep = "\xff"

// deferred tells a publication the -defer-full-snapshot sequence applies
// to: the option is set, the publication exists on both sides with
// immediate_sync, and the plan adds an article to it (a new one, or one
// replaced under R20). articlesStrategy reads it to plan the add and the
// extension by the rules without immediate_sync.
func (b *builder) deferred(pub string) bool {
	if !b.opt.DeferFullSnapshot {
		return false
	}
	if v, ok := b.deferrals[pub]; ok {
		return v
	}
	v := false
	pairs, _, _ := matchPublications(b.des.Publications, b.cur.Publications)
	for _, pp := range pairs {
		if pp.Des.Name == pub {
			v = boolOf(pp.Des.ImmediateSync) && boolOf(pp.Cur.ImmediateSync) && addsArticle(pp.Des, pp.Cur)
		}
	}
	if b.deferrals == nil {
		b.deferrals = map[string]bool{}
	}
	b.deferrals[pub] = v
	return v
}

// addsArticle tells whether the plan adds an article to a publication on
// both sides: one the file adds, or one it replaces (R20).
func addsArticle(pd, pc *model.Publication) bool {
	pairs, adds, _ := matchArticles(pd.Articles, pc.Articles)
	if len(adds) > 0 {
		return true
	}
	for _, ap := range pairs {
		if replaced(ap.Des, ap.Cur) {
			return true
		}
	}
	return false
}

// deferStrategy is the -defer-full-snapshot sequence for each deferred
// publication (spec "Strategies"): allow_anonymous false when it is true,
// then immediate_sync false (step 6); the article added and the
// subscriptions extended by the rules without immediate_sync
// (articlesStrategy, steps 8 and 9); generate_and_wait (R25); then
// immediate_sync true and allow_anonymous true where the file has it (end
// of step 9). Measured by 15-snapshot-scope phase B under native and
// concurrent only.
func deferStrategy(b *builder) {
	pairs, _, _ := matchPublications(b.des.Publications, b.cur.Publications)
	for _, pp := range pairs {
		if !b.deferred(pp.Des.Name) || b.skip(pp.path("publications")) {
			continue
		}
		b.deferPublication(pp.Des, pp.Cur)
	}
}

func (b *builder) deferPublication(pd, pc *model.Publication) {
	path := pubPath(pd.Name)
	pubType := stringOr(pd.Type, "transactional")
	refused := false
	for _, m := range []string{stringOr(pc.SyncMethod, "native"), stringOr(pd.SyncMethod, "native")} {
		if m != "native" && m != "concurrent" {
			b.refuse(path+".sync_method", "%s", deferUnmeasured)
			refused = true
			break
		}
	}
	if pubType != "transactional" || boolOf(pc.AllowSubscriptionCopy) || boolOf(pd.AllowSubscriptionCopy) {
		// Phase B measured transactional publications without
		// allow_subscription_copy, which needs immediate_sync (21210).
		b.refuse(path, "%s", deferUnmeasured)
		refused = true
	}
	switch {
	case recurring(pc.SnapshotAgent):
		b.refuse(path+".snapshot_agent.schedules", deferRecurring, pd.Name)
		refused = true
	case recurring(pd.SnapshotAgent):
		b.refuse(path+".snapshot_agent.schedules", deferMadeRecur, pd.Name)
		refused = true
	}
	if b.opt.Wait == 0 {
		b.refuse(path, "%s", deferNoWait)
		refused = true
	}
	if refused {
		return
	}

	// The step 6 calls are ordered by the chains (order ""); the restores
	// at the end of step 9.
	type step struct {
		rel, after, order string
	}
	steps := []step{}
	if boolOf(pc.AllowAnonymous) {
		steps = append(steps, step{"allow_anonymous", "false", ""})
	}
	steps = append(steps,
		step{"immediate_sync", "false", ""},
		step{"immediate_sync", "true", endOfStep + pd.Name + sep + "2"})
	if boolOf(pd.AllowAnonymous) {
		steps = append(steps, step{"allow_anonymous", "true", endOfStep + pd.Name + sep + "3"})
	}
	for _, s := range steps {
		before := "true"
		if s.after == "true" {
			before = "false"
		}
		ch := Change{Path: path + "." + s.rel, Pattern: pubPropPrefix + s.rel, Before: &before, After: model.Ptr(s.after)}
		e, ok := cost.Lookup(ch.Path, "to_"+s.after, pubType)
		if !ok {
			b.unmeasured(ch)
			return
		}
		step, order := 9, s.order
		if order == "" {
			step, order = 6, chainOrder(pd.Name, ch) // spec "Publication properties": top down
		}
		v := s.after == "true"
		call := Call{Procedure: e.Procedure, Params: []Param{
			{Name: "@publication", Value: literal(pd.Name)},
			{Name: "@property", Value: literal(e.Property)},
		}}
		lit, err := chgBool(&v)
		if err != nil {
			b.refuse(ch.Path, "%v", err)
			return
		}
		call.Params = append(call.Params, Param{Name: "@value", Value: lit})
		op := b.newOp(step, order, "publication_property", "change", path, call)
		op.entry = &e
		for _, c := range e.Cites {
			op.Sources = append(op.Sources, c.Row)
		}
		op.Sources = append(op.Sources, "spec Strategies (-defer-full-snapshot)")
		op.Changes = []PropertyChange{{Path: ch.Path, Before: before, After: s.after}}
		op.Affects = Affects{Publications: []string{pd.Name}}
		if step == 6 {
			op.Reason = fmt.Sprintf("-defer-full-snapshot: %s is turned off, so that the added articles are generated alone", s.rel)
		} else {
			op.Reason = fmt.Sprintf("-defer-full-snapshot: %s is restored once the added articles are delivered", s.rel)
		}
		b.add(op)
		if s.rel == "immediate_sync" && s.after == "false" {
			b.generateAndWait(pd)
		}
	}
	b.notes = append(b.notes, fmt.Sprintf(deferNote, pd.Name))
}

// generateAndWait is R25's operation: sp_startpublication_snapshot, whose
// run generates the added articles alone (15-snapshot-scope B.*.3), and the
// wait for their deliveries, which is plan 4's.
func (b *builder) generateAndWait(pd *model.Publication) {
	op := b.newOp(9, endOfStep+pd.Name+sep+"1", "generate_and_wait", "start", pubPath(pd.Name)+".snapshot_agent",
		Call{Procedure: "sp_startpublication_snapshot", Params: []Param{{Name: "@publication", Value: literal(pd.Name)}}})
	op.Affects = Affects{Publications: []string{pd.Name}}
	op.Reason = "-defer-full-snapshot: the snapshot agent generates the added articles alone; apply waits for their delivery before restoring immediate_sync"
	op.Sources = append(op.Sources, "R25", "spec Strategies (-defer-full-snapshot)")
	b.add(op)
}
