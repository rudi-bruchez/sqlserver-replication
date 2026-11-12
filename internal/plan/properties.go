package plan

import (
	"fmt"
	"strings"

	"github.com/rudi-bruchez/sqlserver-replication/internal/cost"
	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
)

func init() { strategies = append(strategies, propertiesStrategy) }

// The Order keys of the publication property changes (step 6), under
// "<pub>\x00": 1 for a change that disables a property, then its rank from
// the top of its chain; 2 for any other change, then its rank from the
// bottom; then the property's path (spec "Publication properties": enable
// from the bottom up, disable from the top down). Every disable comes before
// every enable: no measured chain needs the other order, and a disable and
// an enable of the same chain are a combination rule 7 refuses.
const pubPropPrefix = "publications[*]."

// chainDepth is a property's rank from the bottom of its chain (spec
// "Publication properties", rule 7 of normalization): allow_anonymous and
// allow_subscription_copy need immediate_sync (20011, 21210), which needs
// independent_agent (21022); compress needs alt_folder (21157);
// enabled_for_internet needs ftp.address (21158); replicate_partition_switch
// needs allow_partition_switch (21866). A property outside a chain is at 0.
//
// 18-reverse (Task 1) showed no further chain: every reverse row was
// accepted, alt_snapshot_folder cleared (NULL and ”) with
// snapshot_in_defaultfolder false among them (RV.I and RV.N), so no
// snapshot_in_defaultfolder change is ordered before an alt_folder clear.
var chainDepth = map[string]int{
	"independent_agent":             0,
	"immediate_sync":                1,
	"allow_anonymous":               2,
	"allow_subscription_copy":       2,
	"snapshot.alt_folder":           0,
	"snapshot.compress":             1,
	"snapshot.ftp.address":          0,
	"snapshot.enabled_for_internet": 1,
	"allow_partition_switch":        0,
	"replicate_partition_switch":    1,
}

// disables tells a change that turns a property off: a boolean to false, a
// string cleared.
func disables(ch Change) bool {
	return ch.After == nil || *ch.After == "false" || *ch.After == ""
}

// chainOrder is the Order key of a step 6 change of pub.
func chainOrder(pub string, ch Change) string {
	rel := strings.TrimPrefix(ch.Pattern, pubPropPrefix)
	depth := chainDepth[rel]
	if disables(ch) {
		return fmt.Sprintf("%s%s1%s%d%s%s", pub, sep, sep, 9-depth, sep, ch.Path)
	}
	return fmt.Sprintf("%s%s2%s%d%s%s", pub, sep, sep, depth, sep, ch.Path)
}

// snapshotScriptWarning is the warning of an operation that gives a
// publication a pre or post snapshot script, at creation (addPublication) or
// by a change (step 6).
const snapshotScriptWarning = "on a Linux distributor the distribution agent cannot apply a snapshot with pre or post scripts (registry lookup of the SQL utilities path fails, measured 18-reverse setup)"

// hasSnapshotScript tells a publication of the file with a pre or post
// snapshot script.
func hasSnapshotScript(p *model.Publication) bool {
	s := p.Snapshot
	return s != nil && (stringOr(s.PreScript, "") != "" || stringOr(s.PostScript, "") != "")
}

// propertiesStrategy changes the properties of the publications on both
// sides (step 6, spec "Publication properties"): one sp_changepublication per
// change, its entry from cost.Lookup, in the order of the chains. The
// properties of a publication the plan defers (deferStrategy) that the
// deferral sets itself, immediate_sync and allow_anonymous, are left to it.
// A drop_readd property (independent_agent) changes in step 6 after its
// subscriptions are dropped in step 4, and they are re-added in step 9
// (subscriptions.go, readdPublication).
func propertiesStrategy(b *builder) {
	pairs, _, _ := matchPublications(b.des.Publications, b.cur.Publications)
	for _, pp := range pairs {
		b.planProperties(pp)
	}
}

// publicationChanges is the changes of a matched publication's own
// properties: not its articles, subscriptions or snapshot agent (Task 14).
func (b *builder) publicationChanges(pp pair[model.Publication]) []Change {
	var out []Change
	for _, ch := range b.diff(pp.path("publications"), pp.Des, pp.Cur) {
		rel := strings.TrimPrefix(ch.Pattern, pubPropPrefix)
		if rel == "snapshot_agent" || strings.HasPrefix(rel, "snapshot_agent.") {
			continue
		}
		out = append(out, ch)
	}
	return out
}

// pubDirections are the cost table directions of a publication change:
// sync_method is keyed by its pair (R19), the others by directions.
func pubDirections(ch Change) []string {
	if strings.TrimPrefix(ch.Pattern, pubPropPrefix) == "sync_method" {
		return []string{orEmpty(ch.Before) + ">" + orEmpty(ch.After)}
	}
	return directions(ch)
}

func (b *builder) planProperties(pp pair[model.Publication]) {
	pd, pc := pp.Des, pp.Cur
	ppath := pp.path("publications")
	if b.skip(ppath) {
		return
	}
	pubType := stringOr(pd.Type, "transactional")
	deferred := b.deferred(pd.Name)
	for _, ch := range b.publicationChanges(pp) {
		rel := strings.TrimPrefix(ch.Pattern, pubPropPrefix)
		if deferred && (rel == "allow_anonymous" || rel == "immediate_sync") {
			continue // deferStrategy sets them
		}
		var e cost.Entry
		found := false
		for _, dir := range pubDirections(ch) {
			if e, found = cost.Lookup(ch.Path, dir, pubType); found {
				break
			}
		}
		if !found {
			b.unmeasured(ch)
			continue
		}
		switch e.Class {
		case cost.Refused:
			b.refuse(ch.Path, "%s change refused by the server (%d)", ch.Pattern, e.Error)
			continue
		case cost.DropReadd:
			if rel != "independent_agent" && len(remaining(pd, pc)) > 0 {
				// enabled_for_het_sub: normalization refuses true (out of
				// scope); no drop and re-add of it was measured.
				b.refuse(ch.Path, "%s change refused by the server while subscriptions exist (%d)", ch.Pattern, e.Error)
				continue
			}
		}
		op, ok := b.propertyOp(pd, ch, e, chainOrder(pd.Name, ch))
		if !ok {
			continue
		}
		if e.Class == cost.DropReadd && len(remaining(pd, pc)) > 0 {
			op.Reason += "; its subscriptions are dropped in step 4 and added back in step 9 (20013 while they exist)"
		}
		if e.Wide && e.Class == cost.SnapshotReinit {
			// Every subscribed article is reinitialized: those whose
			// pre_creation_cmd is drop, delete or truncate replace subscriber
			// data (anti-goal 4).
			op.replacesData = replacesAny(pd, pc)
		}
		b.add(op)
	}
}

// propertyOp is the sp_changepublication of one change, in step 6 with
// order.
func (b *builder) propertyOp(pd *model.Publication, ch Change, e cost.Entry, order string) (Operation, bool) {
	rel := strings.TrimPrefix(ch.Pattern, pubPropPrefix)
	v, ok := resolve(pd, rel)
	if !ok {
		b.refuse(ch.Path, "%s has no value to set", ch.Pattern)
		return Operation{}, false
	}
	enc, ok := valueEncoders[[2]string{e.Procedure, e.Property}]
	if !ok {
		b.refuse(ch.Path, "no measured @value form for %s %s", e.Procedure, e.Property)
		return Operation{}, false
	}
	lit, err := enc(v)
	if err != nil {
		b.refuse(ch.Path, "%v", err)
		return Operation{}, false
	}
	op := b.newOp(6, order, "publication_property", "change", pubPath(pd.Name), Call{Procedure: e.Procedure, Params: []Param{
		{Name: "@publication", Value: literal(pd.Name)},
		{Name: "@property", Value: literal(e.Property)},
		{Name: "@value", Value: lit},
	}})
	op.entry = &e
	for _, c := range e.Cites {
		op.Sources = append(op.Sources, c.Row)
	}
	op.Sources = append(op.Sources, "spec Strategies (Publication properties)", "spec Order step 6")
	op.Changes = []PropertyChange{{Path: ch.Path, Before: orEmpty(ch.Before), After: orEmpty(ch.After)}}
	op.Affects = Affects{Publications: []string{pd.Name}}
	if (rel == "snapshot.pre_script" || rel == "snapshot.post_script") && !disables(ch) {
		op.Warnings = append(op.Warnings, snapshotScriptWarning)
	}
	op.Reason = "the publication's " + rel + " changes"
	return op, true
}

// replacesAny tells a publication with a subscribed article whose desired
// pre_creation_cmd is drop, delete or truncate.
func replacesAny(pd, pc *model.Publication) bool {
	for i := range pd.Articles {
		a := &pd.Articles[i]
		if !destructive(a.PreCreationCmd) {
			continue
		}
		for j := range pc.Subscriptions {
			if covers(&pc.Subscriptions[j], a.Name) {
				return true
			}
		}
	}
	return false
}

// readdPublication tells a publication on both sides whose subscriptions
// the file keeps and whose independent_agent changes: the server refuses
// the change while they exist (20013, 02-matrix P26), so they are dropped
// in step 4 and re-added in step 9 (spec "Publication properties").
func (b *builder) readdPublication(pd, pc *model.Publication) bool {
	if pc == nil || len(remaining(pd, pc)) == 0 || b.skip(pubPath(pc.Name)+".independent_agent") {
		return false
	}
	return pd.IndependentAgent != nil && boolOf(pd.IndependentAgent) != boolOf(pc.IndependentAgent)
}

// The refusals of a drop and re-add (spec "Subscriptions").
const (
	readdInit   = "re-adding subscription %s, initialized with %s, for the change of independent_agent loses the changes made between the drop and the re-add (10-init-modes I1.support-only.gap, I2.backup.gap-original, I3.lsn.gap-original); re-create it from a fresh COPY_ONLY backup restored over the subscriber, or with initialize from lsn and the subscriber's transaction_timestamp"
	readdSubset = "subscription %s to a subset of articles cannot be re-added by name on publication %s (14100 under concurrent, 14122 under immediate_sync)"
)

// readdSubscription drops a kept subscription of a publication whose
// independent_agent changes (step 4) and returns true when it is to be
// re-added (step 9, by addSubscription, which reads b.readd). Refused when
// it is not snapshot-initialized, or its subset cannot be re-added.
func (b *builder) readdSubscription(pd, pc *model.Publication, sp pair[model.Subscription]) bool {
	d, c := sp.Des, sp.Cur
	path := sp.path(pubPath(pc.Name) + ".subscriptions")
	for _, init := range []string{stringOr(c.Initialization, initSnapshot), stringOr(d.Initialization, initSnapshot)} {
		if init != initSnapshot {
			b.refuse(path+".initialization", readdInit, c.Key(), init)
			return false
		}
	}
	if dt, ct := stringOr(d.Type, "push"), stringOr(c.Type, "push"); dt != ct {
		b.refuse(path+".type", r21Type, c.Key(), ct, dt)
		return false
	}
	if len(d.Articles) > 0 && !pd.SubsetAllowed() {
		b.refuse(path+".articles", readdSubset, c.Key(), pd.Name)
		return false
	}
	if !b.dropSubscription(pc, c, "independent_agent changes, which the server refuses while the subscription exists (20013): it is dropped and added back in step 9") {
		return false
	}
	if b.readd == nil {
		b.readd = map[string]bool{}
	}
	b.readd[pd.Name+sep+subKey(d.Key())] = true
	return true
}
