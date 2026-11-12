package plan

import (
	"sort"

	"github.com/rudi-bruchez/sqlserver-replication/internal/cost"
)

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
	for i := range ops {
		op := &ops[i]
		pub := first(op.Affects.Publications)
		ps := st.Pubs[pub]
		var computed []Cost
		switch {
		case op.Kind == "publication" && op.Action == "add":
			computed = []Cost{CostOnline}
		case op.Kind == "generate_and_wait":
			computed = []Cost{CostNewSnapshot} // R25, R34
		case op.entry != nil && ps != nil:
			computed = flagsAndCosts(op, ps, finalImm[pub])
		case len(op.Costs) == 0:
			computed = []Cost{CostOnline}
		}
		op.Costs = mergeCosts(computed, op.Costs)
		st.apply(op)
		op.Seq = i + 1
	}
	return ops, nil
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
				return []Cost{CostFullGenerationDeferred}
			}
		}
		return []Cost{CostOnline} // the extension carries the snapshot
	case cost.OpAddSubscription:
		if syncTypeInit(op) == initSnapshot && !(ps.ImmediateSync && ps.Ready) {
			return []Cost{CostNewSnapshot}
		}
		// Rows at 2 (05-snapshot-flag S7) or no snapshot at all.
		return []Cost{CostOnline}
	case cost.OpExtendSubscription:
		sub := ps.Subs[subKey(first(op.Affects.Subscriptions))]
		if sub != nil && sub.Init == initSnapshot && len(callArticles(op, ps, sub)) > 0 {
			return []Cost{CostNewSnapshot}
		}
		return []Cost{CostOnline}
	case cost.OpDropArticle:
		if inv && keepsImm {
			return []Cost{CostFullGenerationDeferred} // R11, C.*.droparticle
		}
		return []Cost{CostOnline}
	case cost.OpDropSubscription, cost.OpDropSubscriptionArticle, cost.OpDropPublication:
		return []Cost{CostOnline}
	}

	// A property change: its class.
	switch e.Class {
	case cost.Snapshot:
		if inv && keepsImm {
			return []Cost{CostFullGenerationDeferred} // R11
		}
	case cost.SnapshotReinit:
		if re {
			op.Affects.Subscriptions = subsAt(ps, art, wide, 2)
			return []Cost{CostReinitialization, CostNewSnapshot}
		}
		if rowsAt(ps, art, wide, 1) {
			return []Cost{CostPendingSnapshotStart}
		}
		// No row at 2 and none at 1: the article has no subscription. The
		// snapshot flag alone marks nothing, R11's case.
		if inv && keepsImm {
			return []Cost{CostFullGenerationDeferred}
		}
	case cost.DropsReady:
		// Spec "Publication properties": not online when the snapshot is
		// ready. The end state decides between the two costs.
		if ps.Ready {
			if keepsImm {
				return []Cost{CostFullGenerationDeferred}
			}
			return []Cost{CostReadySnapshotDropped}
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
	out := append([]Cost(nil), computed...)
	seen := map[Cost]bool{}
	for _, c := range out {
		seen[c] = true
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
