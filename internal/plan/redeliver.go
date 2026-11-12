package plan

import (
	"fmt"
	"strings"

	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
)

// subscriberTable is a destination table at a subscriber database: what a
// drop operation stops maintaining (Operation.leaves) or an addition
// delivers by snapshot (Operation.delivers).
type subscriberTable struct {
	subscriber, database, schema, name string
	// article and cmd are the delivering article and its pre_creation_cmd,
	// on an addition.
	article, cmd string
}

// same tells two tables that may be one, names compared without regard to
// case (SQL identifiers, R7). A NULL destination owner ("") matches any
// schema: the table lands in the agent's default schema, which the plan
// does not know, and an unannounced data loss costs more than a false
// subscriber_data_replaced (controller's ruling on concern 5 of the final
// fix round).
func (t subscriberTable) same(u subscriberTable) bool {
	return strings.EqualFold(t.subscriber, u.subscriber) && strings.EqualFold(t.database, u.database) &&
		strings.EqualFold(t.name, u.name) && (t.schema == "" || u.schema == "" || strings.EqualFold(t.schema, u.schema))
}

// tableOf is the subscriber table of article a in subscription s: its
// destination, the source's names where the destination omits them.
func tableOf(s *model.Subscription, a *model.Article) subscriberTable {
	t := subscriberTable{subscriber: s.Subscriber, database: s.Database, schema: a.Source.Schema, name: a.Source.Name,
		article: a.Name, cmd: stringOr(a.PreCreationCmd, "")}
	if a.Destination.Schema != nil {
		t.schema = *a.Destination.Schema
	}
	if a.Destination.Name != nil {
		t.name = *a.Destination.Name
	}
	return t
}

// tablesOf is the subscriber tables of the articles of p that s covers,
// only art unless it is "all".
func tablesOf(p *model.Publication, s *model.Subscription, art string) []subscriberTable {
	var out []subscriberTable
	for i := range p.Articles {
		a := &p.Articles[i]
		if covers(s, a.Name) && (art == "all" || strings.EqualFold(a.Name, art)) {
			out = append(out, tableOf(s, a))
		}
	}
	return out
}

// articleNamed is the article of p named name, nil when p has none.
func articleNamed(p *model.Publication, name string) *model.Article {
	for i := range p.Articles {
		if p.Articles[i].Name == name {
			return &p.Articles[i]
		}
	}
	return nil
}

// The texts of the redeliveries.
const (
	redeliveredReason = " The subscriber table is delivered again by this plan: it is not left behind."
	replacedReason    = " It delivers again a subscriber table this plan drops from another article, whose rows the snapshot replaces (pre_creation_cmd %s)."
)

// redeliveriesStrategy runs after every other strategy (spec anti-goal 4,
// final review item 1). A plan that drops an article and delivers its
// subscriber table again to the same subscription (an article renamed, its
// publication renamed even by case only, an R20 replacement, an article
// moved between publications) does not leave that table: the snapshot of
// the new article replaces it. Measured by the final review: the renamed
// article's push subscription, pre_creation_cmd drop, dropped and created
// the subscriber table again, and a row held only at the subscriber was
// lost. So the delivering operation costs subscriber_data_replaced when the
// new article's pre_creation_cmd is drop, delete or truncate, and warns as a
// reinitialization does when it is none (keepsRowsWarning); a drop
// operation all of whose tables the plan delivers again loses its
// subscriber_object_left.
func redeliveriesStrategy(b *builder) {
	var left, delivered []subscriberTable
	for i := range b.ops {
		left = append(left, b.ops[i].leaves...)
	}
	matches := func(t subscriberTable, in []subscriberTable) bool {
		for _, u := range in {
			if t.same(u) {
				return true
			}
		}
		return false
	}
	for i := range b.ops {
		op := &b.ops[i]
		for _, t := range op.delivers {
			if !matches(t, left) {
				continue
			}
			delivered = append(delivered, t)
			switch {
			case destructive(&t.cmd):
				if !hasCost(op.Costs, CostSubscriberDataReplaced) {
					op.Costs = append(op.Costs, CostSubscriberDataReplaced)
					op.Reason += fmt.Sprintf(replacedReason, t.cmd)
					op.Sources = append(op.Sources, "spec anti-goal 4", "final review item 1 (measured)")
				}
			case t.cmd == "none":
				if w := fmt.Sprintf(keepsRowsWarning, t.article); !hasString(op.Warnings, w) {
					op.Warnings = append(op.Warnings, w)
				}
			}
		}
	}
	for i := range b.ops {
		op := &b.ops[i]
		if len(op.leaves) == 0 || !hasCost(op.Costs, CostSubscriberObjectLeft) {
			continue
		}
		all := true
		for _, t := range op.leaves {
			all = all && matches(t, delivered)
		}
		if !all {
			continue
		}
		var costs []Cost
		for _, c := range op.Costs {
			if c != CostSubscriberObjectLeft {
				costs = append(costs, c)
			}
		}
		op.Costs = costs
		op.Reason += redeliveredReason
	}
}
