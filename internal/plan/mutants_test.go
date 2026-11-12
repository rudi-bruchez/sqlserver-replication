package plan

import (
	"strings"
	"testing"

	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
	"github.com/rudi-bruchez/sqlserver-replication/internal/state"
)

// The tests of the mutants the final review of plan 3 found alive and
// reachable (final-fix item 10): each pins a behaviour no other test held.

// A change of pre_creation_cmd costs subscriber_data_replaced, to none too:
// the call is reinit-flagged on a subscribed article, whose
// reinitialization runs under the command the article had (articles.go,
// articleProperty).
func TestPreCreationCmdToNoneReplacesData(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		articleOf(t, des, "SalesRef", "Product").PreCreationCmd = str("none")
	}))
	chg := one(t, ops, "sp_changearticle")
	wantParam(t, chg, "@property", "N'pre_creation_cmd'")
	if !hasCost(chg.Costs, CostSubscriberDataReplaced) {
		t.Errorf("pre_creation_cmd drop to none costs %v, want subscriber_data_replaced", chg.Costs)
	}
}

// keepsRowsOn tells whether op warns that article art keeps its rows.
func keepsRowsOn(op Operation, art string) bool {
	return hasWarning(op.Warnings, "article "+art+" keeps its rows at the subscriber")
}

// An article with pre_creation_cmd none whose filter change reinitializes
// it warns on the filter call, and one whose property change reinitializes
// it warns on the sp_changearticle (keepsRowsWarning on both article paths).
func TestKeepsRowsOnArticlePaths(t *testing.T) {
	none := func(des, cur *model.Config) {
		both(des, cur, func(c *model.Config) { articleOf(t, c, "SalesPub", "Customer").PreCreationCmd = str("none") })
	}
	ops := planned(t, buildLab(t, nil, func(des, cur *model.Config) {
		none(des, cur)
		articleOf(t, des, "SalesPub", "Customer").Filter.Clause = "Country = 'DE'"
	}))
	flt := one(t, ops, "sp_articlefilter")
	if !hasCost(flt.Costs, CostReinitialization) || !keepsRowsOn(flt, "Customer") {
		t.Errorf("filter change: costs %v, warnings %q, want reinitialization and the keeps-rows warning of Customer", flt.Costs, flt.Warnings)
	}

	ops = planned(t, buildLab(t, nil, func(des, cur *model.Config) {
		none(des, cur)
		a := articleOf(t, des, "SalesPub", "Customer")
		opts := append(append([]string{}, *a.SchemaOptions...), "nonclustered_indexes")
		a.SchemaOptions = &opts
	}))
	chg := one(t, ops, "sp_changearticle")
	if !hasCost(chg.Costs, CostReinitialization) || !keepsRowsOn(chg, "Customer") {
		t.Errorf("schema_option change: costs %v, warnings %q, want reinitialization and the keeps-rows warning of Customer", chg.Costs, chg.Warnings)
	}
}

// A column list of an existing article that names a column the table does
// not have is refused, the table's columns read.
func TestExistingArticleUnknownColumnRefused(t *testing.T) {
	p := buildLab(t, labChecks(), func(des, _ *model.Config) {
		articleOf(t, des, "SalesRef", "Product").Columns = []string{"ID", "nope"}
	})
	wantRefusal(t, p, "publications[SalesRef].articles[Product].columns", `column "nope" is not a column of dbo.Product`)
}

// A subscription the file adds whose article list names an article the
// publication does not have is refused.
func TestSubsetUnknownArticleRefused(t *testing.T) {
	p := buildLab(t, labChecks(), func(des, _ *model.Config) {
		addSub(t, des, "SalesRef", newSub("m_sdb2", "push", "snapshot", "Product", "nope"))
	})
	wantRefusal(t, p, "publications[SalesRef].subscriptions[REPLLAB/m_sdb2].articles",
		"article nope of subscription REPLLAB/m_sdb2 is not an article of publication SalesRef")
}

// A change of the view name of an article that has a filter now, even when
// the file drops it, is refused: sp_articleview made the current view.
func TestSyncObjectChangeRefusedOnCurrentFilter(t *testing.T) {
	p := buildLab(t, labChecks(), func(des, _ *model.Config) {
		a := articleOf(t, des, "SalesPub", "Customer")
		a.Filter, a.Columns = nil, nil
		a.SyncObject = &model.ObjectName{Schema: "dbo", Name: "m_view"}
	})
	wantRefusal(t, p, "publications[SalesPub].articles[Customer].sync_object", "change of the synchronization view name of Customer not measured")
}

// A subscription whose shared pull agent owes a delivery is not listed
// among the agents to start: a warning says why (lists.go r24SharedPull).
func TestSharedPullAgentNotStarted(t *testing.T) {
	p := buildFull(t, nil, func(f *state.Facts) { f.Subscriptions[1].Rows[0].PublisherStatus = 1 }, func(des, cur *model.Config) {
		allowPull(t, des, cur)
		both(des, cur, func(c *model.Config) {
			subOf(t, c, "SalesRef", "SalesSub").Type = str("pull")
			c.Publisher.SharedDistributionAgents = nil
			c.Publisher.SharedPullAgents = []model.SharedPullAgent{{Subscriber: "REPLLAB", Database: "SalesSub", PullAgent: *exportedPull("SalesSub")}}
		})
	})
	withJobs(t, p)
	for _, r := range p.AgentsToStart {
		if r.Kind == "pull_distribution" {
			t.Errorf("the shared pull agent is listed: %+v", r)
		}
	}
	w := "the shared pull agent of REPLLAB/SalesSub is not started by apply: its job lookup at the subscriber is not measured; the delivery waits for its next run"
	if !hasString(p.Warnings, w) {
		t.Errorf("warnings %q, want %q", p.Warnings, w)
	}
}

// A publication pending after the plan (a row at 1 the plan leaves) owes a
// full generation: the ready snapshot a drop of an article invalidates is
// not deferred, the next run generates every article anyway (owedAtEnd).
func TestOwedAtEndPending(t *testing.T) {
	p := buildFull(t, nil, func(f *state.Facts) {
		for i := range f.Subscriptions {
			if f.Subscriptions[i].Publication == "SalesPub" {
				for j := range f.Subscriptions[i].Rows {
					if f.Subscriptions[i].Rows[j].Article == "Customer" {
						f.Subscriptions[i].Rows[j].PublisherStatus = 1
					}
				}
			}
		}
	}, func(des, _ *model.Config) { removeArticle(t, des, "SalesPub", "Orders") })
	art := one(t, withJobs(t, p), "sp_droparticle")
	if hasCost(art.Costs, CostFullGenerationDeferred) || !strings.Contains(costList(art.Costs), "online") {
		t.Errorf("sp_droparticle costs %v on a publication pending after the plan, want online", art.Costs)
	}
}
