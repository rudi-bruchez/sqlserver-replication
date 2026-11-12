package plan

import (
	"strings"
	"testing"

	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
)

// withArticle is the operation of ops calling proc whose @article is art.
func withArticle(t *testing.T, ops []Operation, proc, art string) Operation {
	t.Helper()
	var got []Operation
	for _, op := range opsCalling(ops, proc) {
		if v, _ := paramOf(op, "@article"); v == "N'"+art+"'" {
			got = append(got, op)
		}
	}
	if len(got) != 1 {
		t.Fatalf("%d %s @article = N'%s', want 1:\n%s", len(got), proc, art, opsString(ops))
	}
	return got[0]
}

// noObjectLeft fails on every operation of ops that costs
// subscriber_object_left.
func noObjectLeft(t *testing.T, ops []Operation) {
	t.Helper()
	for _, op := range ops {
		if hasCost(op.Costs, CostSubscriberObjectLeft) {
			t.Errorf("%s %s %s claims its subscriber table left, while the plan delivers it again: %v", op.Action, op.Kind, op.Path, op.Costs)
		}
	}
}

// An article renamed, its source and destination kept: dropped, added back
// and the subscription extended to it, which delivers Product again, and
// pre_creation_cmd drop replaces it (final review item 1, measured).
func TestRenamedArticleReplacesData(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		articleOf(t, des, "SalesRef", "Product").Name = "ProductX"
	}))
	wantOpCosts(t, withArticle(t, ops, "sp_dropsubscription", "Product"), CostOnline)
	wantOpCosts(t, withArticle(t, ops, "sp_droparticle", "Product"), CostOnline)
	wantOpCosts(t, withArticle(t, ops, "sp_addarticle", "ProductX"), CostOnline)
	wantOpCosts(t, withArticle(t, ops, "sp_addsubscription", "ProductX"), CostNewSnapshot, CostSubscriberDataReplaced)
	noObjectLeft(t, ops)

	// Another destination: nothing is delivered again, the table is left.
	ops = planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		a := articleOf(t, des, "SalesRef", "Product")
		a.Name, a.Destination.Name = "ProductX", str("ProductX")
	}))
	wantOpCosts(t, withArticle(t, ops, "sp_dropsubscription", "Product"), CostOnline, CostSubscriberObjectLeft)
	wantOpCosts(t, withArticle(t, ops, "sp_droparticle", "Product"), CostOnline, CostSubscriberObjectLeft)
	wantOpCosts(t, withArticle(t, ops, "sp_addsubscription", "ProductX"), CostNewSnapshot)

	// pre_creation_cmd none: the table and its rows are kept, the bulk copy
	// meets them (keepsRowsWarning).
	ops = planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		a := articleOf(t, des, "SalesRef", "Product")
		a.Name, a.PreCreationCmd = "ProductX", str("none")
	}))
	ext := withArticle(t, ops, "sp_addsubscription", "ProductX")
	wantOpCosts(t, ext, CostNewSnapshot)
	if !hasWarning(ext.Warnings, "article ProductX keeps its rows at the subscriber") {
		t.Errorf("extension warnings %q, want the keeps-rows warning of ProductX", ext.Warnings)
	}
}

// A publication renamed by case only is two publications (R7: a
// publication name is compared exactly): the old one dropped with its
// subscription, the new one added with it, which delivers Product and
// vCustomerFR again, both pre_creation_cmd drop.
func TestRenamedPublicationReplacesData(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		pubOf(t, des, "SalesRef").Name = "SALESREF"
	}))
	add := withArticle(t, ops, "sp_addsubscription", "all")
	if !hasCost(add.Costs, CostSubscriberDataReplaced) {
		t.Errorf("sp_addsubscription of SALESREF costs %v, want subscriber_data_replaced", add.Costs)
	}
	wantOpCosts(t, withArticle(t, ops, "sp_dropsubscription", "all"), CostOnline)
	wantOpCosts(t, one(t, ops, "sp_droppublication"), CostOnline)
	noObjectLeft(t, ops)
}

// An article moved from SalesRef to SalesPub, to the same subscriber table:
// on the immediate_sync SalesPub sp_addarticle subscribes the subscription
// itself, so it is the call that delivers the table again.
func TestMovedArticleReplacesData(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		a := *articleOf(t, des, "SalesRef", "Product")
		removeArticle(t, des, "SalesRef", "Product")
		addTo(t, des, "SalesPub", a)
	}))
	add := withArticle(t, ops, "sp_addarticle", "Product")
	wantOpCosts(t, add, CostNewSnapshot, CostSubscriberDataReplaced)
	if !strings.Contains(add.Reason, "pre_creation_cmd drop") {
		t.Errorf("sp_addarticle reason %q does not say why the data is replaced", add.Reason)
	}
	wantOpCosts(t, withArticle(t, ops, "sp_dropsubscription", "Product"), CostOnline)
	wantOpCosts(t, withArticle(t, ops, "sp_droparticle", "Product"), CostOnline)
	noObjectLeft(t, ops)
}

// A NULL destination owner ("") matches any schema: the renamed article
// delivers to dbo the table its predecessor delivered to the agent's
// default schema, which may be dbo (concern 5 of the final fix round).
func TestRedeliveredNullOwnerMatchesAnySchema(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, cur *model.Config) {
		articleOf(t, cur, "SalesRef", "Product").Destination.Schema = str("")
		a := articleOf(t, des, "SalesRef", "Product")
		a.Name, a.Destination.Schema = "ProductX", str("dbo")
	}))
	wantOpCosts(t, withArticle(t, ops, "sp_addsubscription", "ProductX"), CostNewSnapshot, CostSubscriberDataReplaced)
	noObjectLeft(t, ops)
}
