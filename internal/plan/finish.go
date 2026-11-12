package plan

import (
	"fmt"
	"sort"

	"github.com/rudi-bruchez/sqlserver-replication/internal/cost"
)

// keepsRowsWarning is the warning of an operation whose reinitialization
// covers an article with pre_creation_cmd none (Operation.keepsRows).
const keepsRowsWarning = "article %s keeps its rows at the subscriber (pre_creation_cmd none): the snapshot's bulk copy fails on duplicate keys unless the table is emptied first (measured)"

// strategyCosts are the costs a strategy sets and finish keeps (R34): the
// others are computed here, from the entry and the predicted state.
var strategyCosts = map[Cost]bool{
	CostNewSnapshot:            true,
	CostDropAndReadd:           true,
	CostSubscriberDataReplaced: true,
	CostSubscriberObjectLeft:   true,
	CostSharedObjectChanged:    true,
}

// finish orders ops by (Step, Order), then walks them in that order:
// computes each op's flag params and costs from its entry and the
// predicted state, applies the transition, and numbers Seq. The refusals
// are the combinations only the predicted state shows (Tasks 11 and 13).
//
// add_publication and generate_and_wait have no cost entry: finish costs
// them directly, online and new_snapshot.
func finish(ops []Operation, st *State) ([]Operation, []Refusal) {
	sort.SliceStable(ops, func(i, j int) bool {
		if ops[i].Step != ops[j].Step {
			return ops[i].Step < ops[j].Step
		}
		return ops[i].Order < ops[j].Order
	})
	finalImm := finalImmediateSync(ops, st)
	lastGen := map[string]int{}
	for i := range ops {
		if ops[i].Kind == "generate_and_wait" {
			lastGen[first(ops[i].Affects.Publications)] = i + 1
		}
	}
	var refusals []Refusal
	for i := range ops {
		op := &ops[i]
		if op.wideMarkCheck && everyRowMarked(st.Pubs[first(op.Affects.Publications)]) {
			// Spec "Strategies", Articles: no campaign row measured the
			// snapshot and delivery after this combination (campaign item
			// 15; O7 measured only that the call is accepted).
			refusals = append(refusals, Refusal{Path: op.Path, Reason: "cost of the snapshot after sp_addarticle on a publication reinitialization not measured"})
		}
		if op.namedExtensionCheck && namedOnMarked(st.Pubs[first(op.Affects.Publications)]) {
			// Spec "Strategies", Articles: a named extension on a native or
			// character publication whose every row a sync_method change of
			// this plan marked is accepted (O7), but no seat ran the snapshot
			// and delivery that follow (campaign item 15).
			refusals = append(refusals, Refusal{Path: op.Path, Reason: "cost of the snapshot after an extension on a publication reinitialization not measured: change sync_method in one plan and add the articles in another"})
		}
		var computed []Cost
		switch {
		case op.Kind == "publication" && op.Action == "add":
			computed = []Cost{CostOnline}
		case op.Kind == "generate_and_wait":
			st.resolve(op)
			computed = []Cost{CostNewSnapshot} // R25, R34
		case op.entry != nil && scopeOf(op.entry) != scopeNone:
			computed = flagsAndCosts(op, st.resolve(op), finalImm[first(op.Affects.Publications)])
			if op.entry.Change == cost.OpExtendSubscription && i+1 < lastGen[first(op.Affects.Publications)] {
				// -defer-full-snapshot: the extension creates the status 1
				// rows and the generate_and_wait after it generates the added
				// articles alone, which carries their new_snapshot (fix round
				// 1 of Task 13, measured).
				computed = []Cost{CostOnline}
			}
		}
		if op.readd {
			// A subscription added back after its drop for a drop_readd
			// property: the plan announces a reinitialization (spec
			// "Subscriptions").
			computed = append([]Cost{CostReinitialization}, computed...)
		}
		if len(computed) == 0 {
			// Every operation has a cost (spec "What a plan is"): the
			// operations outside a publication and those without an entry
			// are online.
			computed = []Cost{CostOnline}
		}
		if op.replacesData && hasCost(computed, CostReinitialization) {
			op.Costs = append(op.Costs, CostSubscriberDataReplaced) // anti-goal 4
		}
		if hasCost(computed, CostReinitialization) {
			for _, a := range op.keepsRows {
				op.Warnings = append(op.Warnings, fmt.Sprintf(keepsRowsWarning, a))
			}
		}
		op.Costs = mergeCosts(computed, op.Costs)
		st.apply(op)
		op.Seq = i + 1
	}
	owedAtEnd(ops, st)
	return ops, refusals
}

// everyRowMarked tells an immediate_sync publication whose every
// subscription row is at 1 after a publication-wide reinitialization of
// this plan (a sync_method change from or to concurrent or concurrent_c).
func everyRowMarked(ps *PubState) bool {
	return ps != nil && ps.ImmediateSync && allRowsMarked(ps)
}

// namedOnMarked tells a native or character publication whose every
// subscription row is at 1 after a publication-wide reinitialization of
// this plan: the state a named extension is refused in.
func namedOnMarked(ps *PubState) bool {
	return ps != nil && (ps.SyncMethod == "native" || ps.SyncMethod == "character") && allRowsMarked(ps)
}

// allRowsMarked tells a publication whose every subscription row is at 1,
// at least one, after a publication-wide reinitialization of this plan.
func allRowsMarked(ps *PubState) bool {
	if !ps.wideMarked {
		return false
	}
	rows := 0
	for _, sub := range ps.Subs {
		for _, s := range sub.Rows {
			if s != 1 {
				return false
			}
			rows++
		}
	}
	return rows > 0
}

func hasCost(cs []Cost, c Cost) bool {
	for _, x := range cs {
		if x == c {
			return true
		}
	}
	return false
}

// owedAtEnd turns full_generation_deferred into online for the
// publications whose plan ends with a generation owed: a row at 1 or an
// inactive subscribed article (State.Pending after the last operation), or
// an operation after the publication's last generate_and_wait that carries
// new_snapshot or reinitialization. That generation is counted by the
// operation that owes it, and it generates every article, so nothing is
// deferred (Task 9 fix round 1, item 4: the cost line does not depend on the
// order of the operations). A generate_and_wait does not count: its run
// comes before the restore of immediate_sync, and the full generation after
// that restore is still deferred (spec, -defer-full-snapshot).
func owedAtEnd(ops []Operation, st *State) {
	owed := map[string]bool{}
	for name := range st.Pubs {
		owed[name] = st.Pending(name)
	}
	lastGen := map[string]int{}
	for i := range ops {
		if ops[i].Kind == "generate_and_wait" {
			lastGen[first(ops[i].Affects.Publications)] = i + 1
		}
	}
	for i := range ops {
		op := &ops[i]
		pub := first(op.Affects.Publications)
		if op.Kind == "generate_and_wait" || i+1 <= lastGen[pub] {
			continue
		}
		for _, c := range op.Costs {
			if c == CostNewSnapshot || c == CostReinitialization {
				owed[pub] = true
			}
		}
	}
	for i := range ops {
		op := &ops[i]
		if !owed[first(op.Affects.Publications)] {
			continue
		}
		for j, c := range op.Costs {
			if c == CostFullGenerationDeferred {
				op.Costs[j] = CostOnline
			}
		}
		op.Costs = mergeCosts(op.Costs, nil)
	}
}

// flagsAndCosts sets the flag parameters of an operation that has an entry
// and returns its computed costs, both from the state before it.
func flagsAndCosts(op *Operation, ps *PubState, keepsImm bool) []Cost {
	e := *op.entry
	art := first(op.Affects.Articles)
	wide := e.Wide || art == ""
	inv, re := cost.Flags(e, cost.FlagState{Ready: ps.Ready, At2: rowsAt(ps, art, wide, 2)})
	setFlag(op, paramInvalidate, inv)
	setFlag(op, paramReinit, re)

	// dropped is the cost of the call that drops a ready snapshot and marks
	// nothing: the end state's (spec "Publication properties"). When the
	// publication keeps immediate_sync, the next run generates every
	// article; when it does not, the first call that drops the snapshot
	// carries "ready snapshot dropped" and the later ones are online, the
	// state being no longer ready.
	dropped := func() []Cost {
		if keepsImm {
			return []Cost{CostFullGenerationDeferred}
		}
		return []Cost{CostReadySnapshotDropped}
	}

	// R34: the structural operations, whatever their class.
	switch e.Change {
	case cost.OpAddArticle:
		if ps.ImmediateSync {
			for _, sub := range ps.Subs {
				if sub.Init == initSnapshot {
					return []Cost{CostNewSnapshot} // its status 1 rows
				}
			}
			if ps.Ready {
				return dropped()
			}
		}
		return []Cost{CostOnline} // the extension carries the snapshot
	case cost.OpAddSubscription:
		if !rowsStartAt2(syncTypeInit(op)) && !(ps.ImmediateSync && ps.Ready) {
			return []Cost{CostNewSnapshot}
		}
		// Rows at 2 (05-snapshot-flag S7) or no snapshot at all.
		return []Cost{CostOnline}
	case cost.OpExtendSubscription:
		sub := ps.Subs[subKey(first(op.Affects.Subscriptions))]
		if sub != nil && !rowsStartAt2(sub.Init) && len(callArticles(op, ps, sub)) > 0 {
			return []Cost{CostNewSnapshot}
		}
		return []Cost{CostOnline}
	case cost.OpDropArticle:
		if inv {
			return dropped() // R11, C.*.droparticle
		}
		return []Cost{CostOnline}
	case cost.OpDropSubscription, cost.OpDropSubscriptionArticle, cost.OpDropPublication:
		return []Cost{CostOnline}
	}

	// A property change: its class.
	switch e.Class {
	case cost.Snapshot:
		if inv {
			return dropped() // R11
		}
	case cost.SnapshotReinit:
		if re {
			op.Affects.Subscriptions = subsAt(ps, art, wide, 2)
			return []Cost{CostReinitialization, CostNewSnapshot}
		}
		if rowsAt(ps, art, wide, 1) {
			if !wide && ps.counted[art] {
				// The add or extension of this plan that created these rows
				// counted the article's snapshot (R34: once).
				return []Cost{CostOnline}
			}
			return []Cost{CostPendingSnapshotStart}
		}
		// No row at 2 and none at 1: the article has no subscription. The
		// snapshot flag alone marks nothing, R11's case.
		if inv {
			return dropped()
		}
	case cost.DropsReady:
		// Spec "Publication properties": not online when the snapshot is
		// ready.
		if ps.Ready {
			return dropped()
		}
	}
	return []Cost{CostOnline}
}

// finalImmediateSync is each publication's immediate_sync after the last
// operation: whether the publication "keeps immediate_sync" (spec
// "Publication properties"; under -defer-full-snapshot it is restored, and
// the full generation is deferred).
func finalImmediateSync(ops []Operation, st *State) map[string]bool {
	m := map[string]bool{}
	for name, ps := range st.Pubs {
		m[name] = ps.ImmediateSync
	}
	for i := range ops {
		op := &ops[i]
		pub := first(op.Affects.Publications)
		switch {
		case op.Kind == "publication" && op.Action == "add":
			v, _ := paramString(op, "@immediate_sync")
			m[pub] = v == "true"
		case op.entry != nil && op.entry.Change == "publications[*].immediate_sync":
			m[pub] = op.entry.Dir == "to_true"
		}
	}
	return m
}

// rowsAt tells whether a row of the article, or any row when wide, is at
// status.
func rowsAt(ps *PubState, art string, wide bool, status int) bool {
	return len(subsAt(ps, art, wide, status)) > 0
}

// subsAt is the keys of the subscriptions with a row of the article, or any
// row when wide, at status, sorted.
func subsAt(ps *PubState, art string, wide bool, status int) []string {
	var keys []string
	for _, sub := range sortedSubs(ps) {
		for a, s := range sub.Rows {
			if s == status && (wide || a == art) {
				keys = append(keys, sub.Key)
				break
			}
		}
	}
	return keys
}

// setFlag passes a flag as 1 exactly when it is needed (spec "Costs and
// unmeasured changes": never both by default).
func setFlag(op *Operation, name string, on bool) {
	params := op.Call.Params[:0:0]
	for _, p := range op.Call.Params {
		if p.Name != name {
			params = append(params, p)
		}
	}
	if on {
		params = append(params, Param{Name: name, Value: "1"})
	}
	op.Call.Params = params
}

// mergeCosts is the computed costs followed by the strategy costs the
// operation carries, without repeats.
func mergeCosts(computed, carried []Cost) []Cost {
	var out []Cost
	seen := map[Cost]bool{}
	for _, c := range computed {
		if !seen[c] {
			out = append(out, c)
			seen[c] = true
		}
	}
	for _, c := range carried {
		if strategyCosts[c] && !seen[c] {
			out = append(out, c)
			seen[c] = true
		}
	}
	return out
}

// totals counts the operations, the costly ones (any cost other than online
// and shared_object_changed) and the operations per cost.
func totals(ops []Operation) Totals {
	t := Totals{Operations: len(ops), ByCost: map[Cost]int{}}
	for _, op := range ops {
		costly := false
		for _, c := range op.Costs {
			t.ByCost[c]++
			if c != CostOnline && c != CostSharedObjectChanged {
				costly = true
			}
		}
		if costly {
			t.Costly++
		}
	}
	return t
}

func sortedSubs(ps *PubState) []*SubState {
	keys := make([]string, 0, len(ps.Subs))
	for k := range ps.Subs {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	out := make([]*SubState, len(keys))
	for i, k := range keys {
		out[i] = ps.Subs[k]
	}
	return out
}

func sortedKeys(m map[string]bool) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
