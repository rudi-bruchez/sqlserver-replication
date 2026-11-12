package plan

import (
	"strings"
	"testing"

	"github.com/rudi-bruchez/sqlserver-replication/internal/cost"
	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
	"github.com/rudi-bruchez/sqlserver-replication/internal/state"
)

// buildLab builds a plan from the lab fixture and its facts, the desired
// and the current sides changed by edit.
func buildLab(t *testing.T, checks *state.Checks, edit func(des, cur *model.Config)) *Plan {
	t.Helper()
	des, facts := loadLab(t)
	cur, _ := loadLab(t)
	if edit != nil {
		edit(des, cur)
	}
	return Build(Inputs{Desired: des, Current: cur, Facts: facts, Checks: checks}, Options{})
}

// planned is a plan's operations without R24's job operations (Task 15),
// which the tests of the strategies leave to build_test.go; it stops the
// test on a refusal.
func planned(t *testing.T, p *Plan) []Operation {
	t.Helper()
	for _, r := range p.Refusals {
		t.Errorf("unexpected refusal %s: %s", r.Path, r.Reason)
	}
	if t.Failed() {
		t.FailNow()
	}
	return withoutJobOps(p.Operations)
}

// withoutJobOps leaves out R24's job operations, keeping the Seq of the
// others.
func withoutJobOps(ops []Operation) []Operation {
	var out []Operation
	for _, op := range ops {
		if op.Kind != "job_disable" && op.Kind != "job_restore" && op.Kind != "job_start" {
			out = append(out, op)
		}
	}
	return out
}

func opsCalling(ops []Operation, proc string) []Operation {
	var out []Operation
	for _, op := range ops {
		if op.Call.Procedure == proc {
			out = append(out, op)
		}
	}
	return out
}

func one(t *testing.T, ops []Operation, proc string) Operation {
	t.Helper()
	got := opsCalling(ops, proc)
	if len(got) != 1 {
		t.Fatalf("%d %s operations, want 1; plan:\n%s", len(got), proc, opsString(ops))
	}
	return got[0]
}

func opsString(ops []Operation) string {
	var b strings.Builder
	for _, op := range ops {
		b.WriteString(strings.Join([]string{op.Kind, op.Action, op.Call.Procedure}, " "))
		for _, p := range op.Call.Params {
			b.WriteString(" " + p.Name + "=" + p.Value)
		}
		b.WriteString(" costs=")
		for _, c := range op.Costs {
			b.WriteString(string(c) + ",")
		}
		b.WriteString("\n")
	}
	return b.String()
}

func paramOf(op Operation, name string) (string, bool) {
	for _, p := range op.Call.Params {
		if p.Name == name {
			return p.Value, true
		}
	}
	return "", false
}

func wantParam(t *testing.T, op Operation, name, value string) {
	t.Helper()
	if v, ok := paramOf(op, name); !ok || v != value {
		t.Errorf("%s %s = %q (passed %v), want %s; params %v", op.Call.Procedure, name, v, ok, value, op.Call.Params)
	}
}

func noParam(t *testing.T, op Operation, name string) {
	t.Helper()
	if v, ok := paramOf(op, name); ok {
		t.Errorf("%s passes %s = %s", op.Call.Procedure, name, v)
	}
}

// wantFlags checks the two flag parameters of an operation.
func wantFlags(t *testing.T, op Operation, invalidate, reinit bool) {
	t.Helper()
	if hasParam(op, paramInvalidate) != invalidate || hasParam(op, paramReinit) != reinit {
		t.Errorf("%s %s: flags invalidate=%v reinit=%v, want %v %v", op.Call.Procedure, op.Path,
			hasParam(op, paramInvalidate), hasParam(op, paramReinit), invalidate, reinit)
	}
}

func wantOpCosts(t *testing.T, op Operation, want ...Cost) {
	t.Helper()
	if strings.Join(costStrings(op.Costs), ",") != strings.Join(costStrings(want), ",") {
		t.Errorf("%s %s: costs %v, want %v", op.Call.Procedure, op.Path, op.Costs, want)
	}
}

func costStrings(cs []Cost) []string {
	out := make([]string, len(cs))
	for i, c := range cs {
		out[i] = string(c)
	}
	return out
}

func wantSource(t *testing.T, op Operation, src string) {
	t.Helper()
	for _, s := range op.Sources {
		if s == src {
			return
		}
	}
	t.Errorf("%s: no source %q in %v", op.Call.Procedure, src, op.Sources)
}

func wantAffects(t *testing.T, op Operation, pub, art string) {
	t.Helper()
	if first(op.Affects.Publications) != pub || first(op.Affects.Articles) != art {
		t.Errorf("%s: affects %v, want publication %s article %s", op.Call.Procedure, op.Affects, pub, art)
	}
}

func newTable(name string) model.Article {
	return model.Article{Name: name, Source: model.ObjectName{Schema: "dbo", Name: name}}
}

func addTo(t *testing.T, c *model.Config, pub string, a model.Article) {
	p := pubOf(t, c, pub)
	p.Articles = append(p.Articles, a)
}

func removeArticle(t *testing.T, c *model.Config, pub, name string) {
	p := pubOf(t, c, pub)
	var keep []model.Article
	for _, a := range p.Articles {
		if a.Name != name {
			keep = append(keep, a)
		}
	}
	p.Articles = keep
}

func TestAddArticleImmediateSync(t *testing.T) {
	p := buildLab(t, nil, func(des, _ *model.Config) { addTo(t, des, "SalesPub", newTable("m_t9")) })
	ops := planned(t, p)
	add := one(t, ops, "sp_addarticle")
	// sp_addarticle subscribes the subscription itself: the operation and
	// its summary line name it (minor 6 of the final review).
	if strings.Join(add.Affects.Subscriptions, ",") != labSub {
		t.Errorf("sp_addarticle affects subscriptions %v, want %s", add.Affects.Subscriptions, labSub)
	}
	if line := "add article publications[SalesPub].articles[m_t9]: new_snapshot (subscriptions " + labSub + ")\n"; !strings.Contains(p.Summary(), line) {
		t.Errorf("summary lacks %q:\n%s", line, p.Summary())
	}
	if add.Kind != "article" || add.Action != "add" || add.Step != 8 {
		t.Errorf("sp_addarticle is %s %s in step %d", add.Kind, add.Action, add.Step)
	}
	wantFlags(t, add, true, false)
	wantOpCosts(t, add, CostNewSnapshot)
	wantAffects(t, add, "SalesPub", "m_t9")
	wantSource(t, add, "05-snapshot-flag S1.O1")
	if subs := opsCalling(ops, "sp_addsubscription"); len(subs) != 0 {
		t.Errorf("an extension on an immediate_sync publication:\n%s", opsString(subs))
	}
	if len(ops) != 1 {
		t.Errorf("%d operations, want 1:\n%s", len(ops), opsString(ops))
	}
}

func TestAddArticleNonImmediateNative(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) { addTo(t, des, "SalesRef", newTable("m_t9")) }))
	add := one(t, ops, "sp_addarticle")
	wantFlags(t, add, false, false)
	wantOpCosts(t, add, CostOnline)
	wantAffects(t, add, "SalesRef", "m_t9")
	ext := one(t, ops, "sp_addsubscription")
	if ext.Kind != "subscription_extension" || ext.Step != 9 || ext.Seq <= add.Seq {
		t.Errorf("extension %s step %d seq %d after sp_addarticle seq %d", ext.Kind, ext.Step, ext.Seq, add.Seq)
	}
	wantParam(t, ext, "@article", "N'm_t9'")
	wantParam(t, ext, "@subscriber", "N'REPLLAB'")
	wantParam(t, ext, "@destination_db", "N'SalesSub'")
	wantParam(t, ext, "@subscription_type", "N'push'")
	wantParam(t, ext, "@sync_type", "N'automatic'")
	wantFlags(t, ext, false, false)
	wantOpCosts(t, ext, CostNewSnapshot)
	if strings.Join(ext.Affects.Subscriptions, ",") != labSub {
		t.Errorf("extension affects %v", ext.Affects)
	}
	wantSource(t, ext, "R36")
}

func TestAddArticleNonImmediateConcurrent(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, cur *model.Config) {
		pubOf(t, des, "SalesRef").SyncMethod = str("concurrent")
		pubOf(t, cur, "SalesRef").SyncMethod = str("concurrent")
		addTo(t, des, "SalesRef", newTable("m_t8"))
		addTo(t, des, "SalesRef", newTable("m_t9"))
	}))
	if n := len(opsCalling(ops, "sp_addarticle")); n != 2 {
		t.Errorf("%d sp_addarticle, want 2", n)
	}
	// One extension per subscription: a named one is 14100.
	ext := one(t, ops, "sp_addsubscription")
	wantParam(t, ext, "@article", "N'all'")
	wantParam(t, ext, "@subscription_type", "N'push'")
	wantParam(t, ext, "@sync_type", "N'automatic'")
	wantOpCosts(t, ext, CostNewSnapshot)
}

func TestAddArticleAfterWideMarkRefused(t *testing.T) {
	withStrategy(t, func(b *builder) {
		e, ok := cost.Lookup("publications[SalesPub].sync_method", "concurrent>native", "transactional")
		if !ok {
			t.Fatal("no entry for sync_method concurrent>native")
		}
		op := b.newOp(6, "SalesPub", "publication_property", "change", "publications[SalesPub]",
			Call{Procedure: "sp_changepublication", Params: []Param{{Name: "@publication", Value: "N'SalesPub'"}}})
		op.entry = &e
		op.Affects.Publications = []string{"SalesPub"}
		b.add(op)
	})
	p := buildLab(t, nil, func(des, _ *model.Config) {
		pubOf(t, des, "SalesPub").SyncMethod = str("native")
		addTo(t, des, "SalesPub", newTable("m_t9"))
	})
	const msg = "cost of the snapshot after sp_addarticle on a publication reinitialization not measured"
	if len(p.Refusals) != 1 || p.Refusals[0].Reason != msg || p.Refusals[0].Path != "publications[SalesPub].articles[m_t9]" {
		t.Errorf("refusals %v, want one: %s", p.Refusals, msg)
	}
	if len(p.Operations) != 0 {
		t.Errorf("a refused plan has operations:\n%s", opsString(p.Operations))
	}
}

func TestDropArticle(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) { removeArticle(t, des, "SalesRef", "Product") }))
	if len(ops) != 2 {
		t.Fatalf("%d operations, want 2:\n%s", len(ops), opsString(ops))
	}
	sub, art := ops[0], ops[1]
	if sub.Call.Procedure != "sp_dropsubscription" || sub.Step != 4 || art.Call.Procedure != "sp_droparticle" || art.Step != 5 {
		t.Fatalf("operations:\n%s", opsString(ops))
	}
	wantParam(t, sub, "@article", "N'Product'")
	wantParam(t, sub, "@subscriber", "N'REPLLAB'")
	wantParam(t, sub, "@destination_db", "N'SalesSub'")
	wantOpCosts(t, sub, CostOnline, CostSubscriberObjectLeft)
	wantFlags(t, art, false, false)
	wantOpCosts(t, art, CostOnline, CostSubscriberObjectLeft)
	wantAffects(t, art, "SalesRef", "Product")
	wantSource(t, art, "06-structural C2.nonimm-native")

	ops = planned(t, buildLab(t, nil, func(des, _ *model.Config) { removeArticle(t, des, "SalesPub", "Orders") }))
	art = one(t, ops, "sp_droparticle")
	wantFlags(t, art, true, false)
	wantOpCosts(t, art, CostFullGenerationDeferred, CostSubscriberObjectLeft)
	wantSource(t, art, "05-snapshot-flag S1.O2")
}

func TestArticleSourceChangeIsDropAndAdd(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		articleOf(t, des, "SalesRef", "Product").Source.Name = "Product2"
	}))
	drop, add := one(t, ops, "sp_droparticle"), one(t, ops, "sp_addarticle")
	if drop.Step != 5 || add.Step != 8 || drop.Seq >= add.Seq {
		t.Errorf("drop step %d seq %d, add step %d seq %d", drop.Step, drop.Seq, add.Step, add.Seq)
	}
	wantParam(t, add, "@source_object", "N'Product2'")
	wantAffects(t, drop, "SalesRef", "Product")
	wantAffects(t, add, "SalesRef", "Product")
	// The subscription is dropped from the article, then extended to it again.
	if n := len(opsCalling(ops, "sp_dropsubscription")); n != 1 {
		t.Errorf("%d sp_dropsubscription, want 1:\n%s", n, opsString(ops))
	}
	ext := one(t, ops, "sp_addsubscription")
	wantParam(t, ext, "@article", "N'Product'")
}

func TestFilterChangeSequence(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		articleOf(t, des, "SalesPub", "Customer").Filter.Clause = "Country = 'DE'"
	}))
	if len(ops) != 2 {
		t.Fatalf("%d operations, want 2:\n%s", len(ops), opsString(ops))
	}
	f, v := ops[0], ops[1]
	if f.Call.Procedure != "sp_articlefilter" || v.Call.Procedure != "sp_articleview" || v.Seq != f.Seq+1 || f.Step != 7 {
		t.Fatalf("not adjacent sp_articlefilter then sp_articleview:\n%s", opsString(ops))
	}
	const clause = "N'Country = ''DE'''"
	wantParam(t, f, "@filter_clause", clause)
	wantParam(t, f, "@filter_name", "N'[dbo].[FLTR_Customer]'")
	wantParam(t, v, "@filter_clause", clause)
	wantParam(t, v, "@view_name", "N'SYNC_Customer'")
	wantFlags(t, f, true, true)
	wantFlags(t, v, false, false)
	if !hasCost(f.Costs, CostReinitialization) || strings.Join(f.Affects.Subscriptions, ",") != labSub {
		t.Errorf("sp_articlefilter costs %v affects %v, want reinitialization of %s", f.Costs, f.Affects, labSub)
	}
	if f.Kind != "article_filter" || v.Kind != "article_view" {
		t.Errorf("kinds %s, %s", f.Kind, v.Kind)
	}
	wantAffects(t, f, "SalesPub", "Customer")
	wantSource(t, f, "02-matrix F01")
	wantSource(t, v, "14-filter-view F4")
}

func TestFilterDrop(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		articleOf(t, des, "SalesPub", "Customer").Filter = nil
	}))
	if len(ops) != 2 {
		t.Fatalf("%d operations, want 2:\n%s", len(ops), opsString(ops))
	}
	f, v := ops[0], ops[1]
	if f.Call.Procedure != "sp_articlefilter" || v.Call.Procedure != "sp_articleview" || f.Action != "drop" {
		t.Fatalf("operations:\n%s", opsString(ops))
	}
	wantParam(t, f, "@filter_clause", "NULL")
	wantParam(t, v, "@filter_clause", "NULL")
}

// customerChecks reads the four columns of the lab's Customer table
// (lab/setup.sql: the article publishes three, Notes dropped).
func customerChecks(names ...string) *state.Checks {
	c := &state.Checks{}
	for _, n := range names {
		c.Tables = append(c.Tables, state.TableCheck{Schema: "dbo", Name: n, Exists: true, HasPrimaryKey: true,
			Columns: []string{"CustomerID", "Name", "Country", "Notes"}, KeyColumns: []string{"CustomerID"}})
	}
	return c
}

func TestColumnChangeReissuesView(t *testing.T) {
	ops := planned(t, buildLab(t, customerChecks("Customer"), func(des, _ *model.Config) {
		a := articleOf(t, des, "SalesPub", "Customer")
		a.Columns = append(a.Columns, "Notes")
	}))
	if len(ops) != 2 {
		t.Fatalf("%d operations, want 2:\n%s", len(ops), opsString(ops))
	}
	c, v := ops[0], ops[1]
	if c.Call.Procedure != "sp_articlecolumn" || v.Call.Procedure != "sp_articleview" || v.Seq != c.Seq+1 {
		t.Fatalf("operations:\n%s", opsString(ops))
	}
	wantParam(t, c, "@column", "N'Notes'")
	wantParam(t, c, "@operation", "N'add'")
	wantFlags(t, c, true, true)
	wantParam(t, v, "@filter_clause", "N'Country = ''FR'''")
	wantParam(t, v, "@view_name", "N'SYNC_Customer'")
	wantFlags(t, v, false, false)
	wantAffects(t, v, "SalesPub", "Customer")
}

func TestNeverAddArticleFilterClause(t *testing.T) {
	filtered := func() model.Article {
		a := newTable("m_t9")
		a.Filter = &model.Filter{Clause: "a > 0", Procedure: &model.ObjectName{Name: "m_flt9"}}
		return a
	}
	cases := map[string]struct {
		checks *state.Checks
		edit   func(des, cur *model.Config)
	}{
		"added to SalesRef": {nil, func(des, _ *model.Config) { addTo(t, des, "SalesRef", filtered()) }},
		"Customer's source changed": {customerChecks("Customer2"), func(des, _ *model.Config) {
			articleOf(t, des, "SalesPub", "Customer").Source.Name = "Customer2"
		}},
		"in a publication the plan adds": {nil, func(des, _ *model.Config) {
			des.Publications = append(des.Publications, model.Publication{Name: "m_p", Type: str("transactional"),
				Status: str("active"), SyncMethod: str("native"), Articles: []model.Article{filtered()}})
		}},
	}
	for name, c := range cases {
		ops := planned(t, buildLab(t, c.checks, c.edit))
		adds := opsCalling(ops, "sp_addarticle")
		if len(adds) == 0 || len(opsCalling(ops, "sp_articlefilter")) != 1 || len(opsCalling(ops, "sp_articleview")) != 1 {
			t.Errorf("%s: operations\n%s", name, opsString(ops))
		}
		for _, op := range adds {
			noParam(t, op, "@filter_clause")
		}
		for _, op := range opsCalling(ops, "sp_articleview") {
			if _, ok := paramOf(op, "@filter_clause"); !ok {
				t.Errorf("%s: sp_articleview without the clause", name)
			}
		}
	}
}

func TestArticlePropertyFlags(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		a := articleOf(t, des, "SalesPub", "Orders")
		var opts []string
		for _, o := range *a.SchemaOptions {
			if o != "nonclustered_indexes" {
				opts = append(opts, o)
			}
		}
		a.SchemaOptions = &opts
	}))
	op := one(t, ops, "sp_changearticle")
	if op.Kind != "article_property" || op.Step != 7 {
		t.Errorf("%s in step %d", op.Kind, op.Step)
	}
	wantParam(t, op, "@property", "N'schema_option'")
	wantParam(t, op, "@value", "N'0x0000000000030033'") // 0x30073 without nonclustered_indexes (0x40)
	wantFlags(t, op, true, true)
	// Orders' pre_creation_cmd is truncate (the fixture).
	wantOpCosts(t, op, CostReinitialization, CostNewSnapshot, CostSubscriberDataReplaced)
	wantSource(t, op, "02-matrix A12")

	ops = planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		articleOf(t, des, "SalesPub", "Orders").Description = str("changed")
	}))
	op = one(t, ops, "sp_changearticle")
	wantParam(t, op, "@property", "N'description'")
	wantFlags(t, op, false, false)
	wantOpCosts(t, op, CostOnline)
}

func TestAddArticleRefusedWithBackupSubscription(t *testing.T) {
	backup := func(pub string) func(des, cur *model.Config) {
		return func(des, cur *model.Config) {
			for _, c := range []*model.Config{des, cur} {
				pubOf(t, c, pub).Subscriptions[0].Initialization = str("backup")
			}
			addTo(t, des, pub, newTable("m_t9"))
		}
	}
	for pub, msg := range map[string]string{
		"SalesPub": "adding an article to a publication with a backup-initialized subscription is not measured",
		"SalesRef": "extension of a backup-initialized subscription not measured",
	} {
		p := buildLab(t, nil, backup(pub))
		if len(p.Refusals) != 1 || p.Refusals[0].Reason != msg {
			t.Errorf("%s: refusals %v, want one: %s", pub, p.Refusals, msg)
		}
		if len(p.Operations) != 0 {
			t.Errorf("%s: a refused plan has operations:\n%s", pub, opsString(p.Operations))
		}
	}
}

func TestColumnsWithoutFilter(t *testing.T) {
	checks := &state.Checks{Tables: []state.TableCheck{{Schema: "dbo", Name: "m_t9", Exists: true, HasPrimaryKey: true, Columns: []string{"id", "a", "b"}}}}
	ops := planned(t, buildLab(t, checks, func(des, _ *model.Config) {
		a := newTable("m_t9")
		a.Columns = []string{"id", "a"}
		addTo(t, des, "SalesRef", a)
	}))
	add, col, view := one(t, ops, "sp_addarticle"), one(t, ops, "sp_articlecolumn"), one(t, ops, "sp_articleview")
	if !(add.Seq < col.Seq && col.Seq < view.Seq) || add.Step != 8 || view.Step != 8 {
		t.Errorf("order:\n%s", opsString(ops))
	}
	noParam(t, add, "@vertical_partition")
	wantParam(t, col, "@column", "N'b'")
	wantParam(t, col, "@operation", "N'drop'")
	noParam(t, view, "@filter_clause")
	wantAffects(t, col, "SalesRef", "m_t9")
}

func TestMoveArticle(t *testing.T) {
	cur := normalized(t, testConfig(testPub("P1", testTable("A", "dbo", "A"), testTable("B", "dbo", "B")), testPub("P2", testTable("C", "dbo", "C"))))
	des := testConfig(testPub("P1", testTable("B", "dbo", "B")), testPub("P2", testTable("A", "dbo", "A"), testTable("C", "dbo", "C")))
	ops := planned(t, Build(Inputs{Desired: des, Current: cur}, Options{}))
	if len(ops) != 2 {
		t.Fatalf("%d operations, want 2:\n%s", len(ops), opsString(ops))
	}
	drop, add := one(t, ops, "sp_droparticle"), one(t, ops, "sp_addarticle")
	if drop.Step != 5 || add.Step != 8 {
		t.Errorf("drop in step %d, add in step %d", drop.Step, add.Step)
	}
	wantAffects(t, drop, "P1", "A")
	wantAffects(t, add, "P2", "A")
	wantParam(t, drop, "@publication", "N'P1'")
	wantParam(t, add, "@publication", "N'P2'")
}

func TestDropPublicationProxyWarning(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, cur *model.Config) {
		pubOf(t, cur, "SalesRef").SnapshotAgent.RunAs = str(`DOMAIN\svc`)
		var keep []model.Publication
		for _, p := range des.Publications {
			if p.Name != "SalesRef" {
				keep = append(keep, p)
			}
		}
		des.Publications = keep
	}))
	if len(ops) != 2 {
		t.Fatalf("%d operations, want 2:\n%s", len(ops), opsString(ops))
	}
	sub, pub := ops[0], ops[1]
	if sub.Call.Procedure != "sp_dropsubscription" || sub.Step != 4 || pub.Call.Procedure != "sp_droppublication" || pub.Step != 5 {
		t.Fatalf("operations:\n%s", opsString(ops))
	}
	wantParam(t, sub, "@article", "N'all'")
	const warning = "dropping the publication deletes its snapshot job and the proxy of its job step"
	if strings.Join(pub.Warnings, "|") != warning {
		t.Errorf("warnings %v, want %q", pub.Warnings, warning)
	}
	wantOpCosts(t, pub, CostOnline, CostSubscriberObjectLeft)
	wantSource(t, pub, "06-structural C5.nonimm-native")
}

// Task 11 fix round 1.

func wantRefusal(t *testing.T, p *Plan, path, reason string) {
	t.Helper()
	if len(p.Refusals) != 1 || p.Refusals[0].Path != path || p.Refusals[0].Reason != reason {
		t.Errorf("refusals %v, want one at %s: %s", p.Refusals, path, reason)
	}
	if len(p.Operations) != 0 {
		t.Errorf("a refused plan has operations:\n%s", opsString(p.Operations))
	}
}

func wantWarning(t *testing.T, op Operation, w string) {
	t.Helper()
	for _, x := range op.Warnings {
		if x == w {
			return
		}
	}
	t.Errorf("%s %s: warnings %v, want %q", op.Call.Procedure, op.Path, op.Warnings, w)
}

func filteredTable(name string) model.Article {
	a := newTable(name)
	a.Filter = &model.Filter{Clause: "a > 0", Procedure: &model.ObjectName{Name: "m_flt_" + name}}
	return a
}

func TestNewSnapshotPublicationArticles(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		des.Publications = append(des.Publications, model.Publication{Name: "m_s", Type: str("snapshot"),
			Status: str("active"), SyncMethod: str("native"), Articles: []model.Article{filteredTable("m_t9")}})
	}))
	for _, proc := range []string{"sp_addpublication", "sp_addpublication_snapshot", "sp_addarticle", "sp_articlefilter", "sp_articleview"} {
		op := one(t, ops, proc)
		wantOpCosts(t, op, CostOnline)
		wantFlags(t, op, false, false)
	}
	if len(ops) != 5 {
		t.Errorf("%d operations, want 5 (no log reader for a snapshot publication):\n%s", len(ops), opsString(ops))
	}
	// On an existing snapshot publication the structural entries are missing.
	p := buildLab(t, nil, func(des, cur *model.Config) {
		for _, c := range []*model.Config{des, cur} {
			pubOf(t, c, "SalesRef").Type = str("snapshot")
		}
		addTo(t, des, "SalesRef", newTable("m_t9"))
	})
	wantRefusal(t, p, "publications[SalesRef].articles[m_t9]", "cost of add_article on a snapshot publication not measured")
}

func TestAddArticleCreatesItsView(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		a := filteredTable("m_t9")
		a.SyncObject = &model.ObjectName{Name: "m_v9"}
		addTo(t, des, "SalesRef", a)
		b := newTable("m_t8")
		b.SyncObject = &model.ObjectName{Schema: "s", Name: "m_v8"}
		addTo(t, des, "SalesRef", b)
	}))
	for _, add := range opsCalling(ops, "sp_addarticle") {
		switch first(add.Affects.Articles) {
		case "m_t9": // sp_articleview creates the view
			noParam(t, add, "@sync_object")
			noParam(t, add, "@sync_object_owner")
		case "m_t8": // the user's view, named by sp_addarticle
			wantParam(t, add, "@sync_object", "N'm_v8'")
			wantParam(t, add, "@sync_object_owner", "N's'")
		}
	}
	v := one(t, ops, "sp_articleview")
	wantParam(t, v, "@view_name", "N'm_v9'")
	wantAffects(t, v, "SalesRef", "m_t9")
}

func TestFilterAndColumnOpsReplaceData(t *testing.T) {
	// Customer's pre_creation_cmd is drop (the fixture).
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		articleOf(t, des, "SalesPub", "Customer").Filter.Clause = "Country = 'DE'"
	}))
	wantOpCosts(t, one(t, ops, "sp_articlefilter"), CostReinitialization, CostNewSnapshot, CostSubscriberDataReplaced)
	// The view follows the reinitialization of the same plan and is online.
	wantOpCosts(t, one(t, ops, "sp_articleview"), CostOnline)
	ops = planned(t, buildLab(t, customerChecks("Customer"), func(des, _ *model.Config) {
		a := articleOf(t, des, "SalesPub", "Customer")
		a.Columns = append(a.Columns, "Notes")
	}))
	wantOpCosts(t, one(t, ops, "sp_articlecolumn"), CostReinitialization, CostNewSnapshot, CostSubscriberDataReplaced)
}

func TestArticleIdentifiersIgnoringCase(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		a := articleOf(t, des, "SalesPub", "Customer")
		a.SyncObject.Name = "sync_customer"
		a.Source.Name = "CUSTOMER"
		a.Filter.Procedure.Name = "fltr_customer"
	}))
	if len(ops) != 0 {
		t.Errorf("a change of case planned:\n%s", opsString(ops))
	}
	// A clause is SQL text, compared exactly.
	ops = planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		articleOf(t, des, "SalesPub", "Customer").Filter.Clause = "country = 'FR'"
	}))
	wantParam(t, one(t, ops, "sp_articlefilter"), "@filter_clause", "N'country = ''FR'''")
}

func TestReturnToGeneratedViewRefused(t *testing.T) {
	p := buildLab(t, nil, func(des, _ *model.Config) { articleOf(t, des, "SalesPub", "Customer").SyncObject = nil })
	wantRefusal(t, p, "publications[SalesPub].articles[Customer].sync_object", "returning to a generated view is not measured (R31)")
}

func TestSchemaOnlyTypeChangeIsDropAndAdd(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		articleOf(t, des, "SalesRef", "vCustomerFR").Type = str("proc_schema_only")
	}))
	drop, add := one(t, ops, "sp_droparticle"), one(t, ops, "sp_addarticle")
	if drop.Step != 5 || add.Step != 8 {
		t.Errorf("drop in step %d, add in step %d", drop.Step, add.Step)
	}
	wantParam(t, add, "@type", "N'proc schema only'")
	if n := len(opsCalling(ops, "sp_changearticle")); n != 0 {
		t.Errorf("%d sp_changearticle for a schema-only type change", n)
	}
}

func TestDropAndExtendFollowCoverage(t *testing.T) {
	subset := func(c *model.Config, arts ...string) { pubOf(t, c, "SalesRef").Subscriptions[0].Articles = arts }
	ops := planned(t, buildLab(t, nil, func(des, cur *model.Config) {
		subset(des, "vCustomerFR")
		subset(cur, "vCustomerFR")
		removeArticle(t, des, "SalesRef", "Product")
	}))
	if len(ops) != 1 {
		t.Fatalf("%d operations, want sp_droparticle alone:\n%s", len(ops), opsString(ops))
	}
	// Not subscribed: no subscriber object is left.
	wantOpCosts(t, one(t, ops, "sp_droparticle"), CostOnline)
	ops = planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		subset(des, "Product", "vCustomerFR")
		addTo(t, des, "SalesRef", newTable("m_t9"))
	}))
	if n := len(opsCalling(ops, "sp_addsubscription")); n != 0 {
		t.Errorf("a subscription that does not list the article is extended:\n%s", opsString(ops))
	}
}

func TestPullExtension(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, cur *model.Config) {
		for _, c := range []*model.Config{des, cur} {
			p := pubOf(t, c, "SalesRef")
			p.AllowPull = model.Ptr(true)
			p.Subscriptions[0].Type = str("pull")
		}
		addTo(t, des, "SalesRef", newTable("m_t9"))
	}))
	ext := one(t, ops, "sp_addsubscription")
	wantParam(t, ext, "@subscription_type", "N'pull'")
	wantParam(t, ext, "@sync_type", "N'automatic'")
}

func TestAddArticleColumnNotInTable(t *testing.T) {
	checks := &state.Checks{Tables: []state.TableCheck{{Schema: "dbo", Name: "m_t9", Exists: true, HasPrimaryKey: true, Columns: []string{"id", "a"}}}}
	p := buildLab(t, checks, func(des, _ *model.Config) {
		a := newTable("m_t9")
		a.Columns = []string{"id", "x"}
		addTo(t, des, "SalesRef", a)
	})
	wantRefusal(t, p, "publications[SalesRef].articles[m_t9].columns", `column "x" is not a column of dbo.m_t9`)
}

func TestColumnsNotRead(t *testing.T) {
	// Every column against three: the table's columns are needed.
	p := buildLab(t, nil, func(des, _ *model.Config) { articleOf(t, des, "SalesPub", "Customer").Columns = nil })
	wantRefusal(t, p, "publications[SalesPub].articles[Customer].columns", "columns of dbo.Customer not read")
}

func TestLogReaderOfAddedPublications(t *testing.T) {
	newPub := func(name, typ string) model.Publication {
		return model.Publication{Name: name, Type: str(typ), Status: str("active"), SyncMethod: str("native"), Articles: []model.Article{newTable("m_t9")}}
	}
	// The database has its log reader: none is added (21831).
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		des.Publications = append(des.Publications, newPub("m_p", "transactional"))
	}))
	if n := len(opsCalling(ops, "sp_addlogreader_agent")); n != 0 {
		t.Errorf("%d sp_addlogreader_agent on a database that has one", n)
	}
	// No log reader: in step 3 for a transactional publication, none for a
	// snapshot one.
	cur := normalized(t, testConfig())
	for typ, want := range map[string]int{"transactional": 1, "snapshot": 0} {
		des := testConfig(newPub("m_p", typ))
		ops := planned(t, Build(Inputs{Desired: des, Current: cur}, Options{}))
		lr := opsCalling(ops, "sp_addlogreader_agent")
		if len(lr) != want {
			t.Errorf("%s: %d sp_addlogreader_agent, want %d:\n%s", typ, len(lr), want, opsString(ops))
		}
		// After sp_replicationdboption publish, which a database without a
		// publication gets first (Task 14).
		if want == 1 && (lr[0].Step != 3 || lr[0].Seq != 2 || ops[0].Call.Procedure != "sp_replicationdboption") {
			t.Errorf("log reader in step %d, seq %d:\n%s", lr[0].Step, lr[0].Seq, opsString(ops))
		}
	}
	// Every current publication dropped: step 5 removes the log reader
	// (13-transient T02), step 8 adds it back before the publication.
	ops = planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		des.Publications = []model.Publication{newPub("m_p", "transactional")}
	}))
	lr, pub := one(t, ops, "sp_addlogreader_agent"), one(t, ops, "sp_addpublication")
	if lr.Step != 8 || lr.Seq+1 != pub.Seq {
		t.Errorf("log reader step %d seq %d, sp_addpublication seq %d", lr.Step, lr.Seq, pub.Seq)
	}
}

func TestFilterProcedureChangeAlone(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		articleOf(t, des, "SalesPub", "Customer").Filter.Procedure.Name = "FLTR_Customer2"
	}))
	f := one(t, ops, "sp_articlefilter")
	wantParam(t, f, "@filter_name", "N'[dbo].[FLTR_Customer2]'")
	wantParam(t, f, "@filter_clause", "N'Country = ''FR'''")
	wantParam(t, one(t, ops, "sp_articleview"), "@filter_clause", "N'Country = ''FR'''")
}

func TestFilterDropNamesProcedure(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) { articleOf(t, des, "SalesPub", "Customer").Filter = nil }))
	f := one(t, ops, "sp_articlefilter")
	// The form of 14-filter-view F3.
	wantParam(t, f, "@filter_name", "N'[dbo].[FLTR_Customer]'")
	wantParam(t, f, "@filter_clause", "NULL")
}

func TestProcExecArticles(t *testing.T) {
	// Every property written: no default of a proc_exec article is
	// measured, so normalization would refuse an omitted one.
	cmd := func(m string) *model.Command { return &model.Command{Mode: m} }
	px := model.Article{Name: "m_px", Type: str("proc_exec"), Source: model.ObjectName{Schema: "dbo", Name: "m_px"},
		Destination: model.Destination{Schema: str("dbo"), Name: str("m_px")}, Description: str(""),
		PreCreationCmd: str("drop"), SchemaOptions: &[]string{"object_creation"}, CreationScript: str(""),
		InsertColumnNames: model.Ptr(false), Parameterized: model.Ptr(false), FireTriggersOnSnapshot: model.Ptr(false),
		Commands: &model.Commands{Insert: cmd("SQL"), Update: cmd("SQL"), Delete: cmd("SQL")}}
	p := buildLab(t, nil, func(des, cur *model.Config) {
		addTo(t, cur, "SalesRef", px)
		d := px
		d.Description = str("changed")
		addTo(t, des, "SalesRef", d)
	})
	wantRefusal(t, p, "publications[SalesRef].articles[m_px]", "changing a proc_exec article is not measured (R20: no measured defaults or costs)")
	p = buildLab(t, nil, func(des, _ *model.Config) { addTo(t, des, "SalesRef", px) })
	wantRefusal(t, p, "publications[SalesRef].articles[m_px]", "creating a proc_exec article is not measured (R20: no measured defaults or costs)")
}

func TestColumnDropsBeforeView(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		articleOf(t, des, "SalesPub", "Customer").Columns = []string{"CustomerID", "Name"}
	}))
	c, v := one(t, ops, "sp_articlecolumn"), one(t, ops, "sp_articleview")
	wantParam(t, c, "@column", "N'Country'")
	wantParam(t, c, "@operation", "N'drop'")
	if c.Seq >= v.Seq || c.Step != 7 || v.Step != 7 {
		t.Errorf("column seq %d step %d, view seq %d step %d", c.Seq, c.Step, v.Seq, v.Step)
	}
}

func TestReaddUserViewRefused(t *testing.T) {
	p := buildLab(t, nil, func(des, cur *model.Config) {
		for _, c := range []*model.Config{des, cur} {
			articleOf(t, c, "SalesPub", "Orders").SyncObject = &model.ObjectName{Schema: "dbo", Name: "vOrders"}
		}
		articleOf(t, des, "SalesPub", "Orders").Source.Name = "Orders2"
	})
	wantRefusal(t, p, "publications[SalesPub].articles[Orders]", "re-adding the article needs its view dbo.vOrders, which sp_droparticle deletes (measured)")
}

func TestDropArticleWarnsView(t *testing.T) {
	const w = "dropping article Customer deletes its synchronization view dbo.SYNC_Customer"
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) { removeArticle(t, des, "SalesPub", "Customer") }))
	wantWarning(t, one(t, ops, "sp_droparticle"), w)
	ops = planned(t, buildLab(t, nil, func(des, _ *model.Config) { des.Publications = des.Publications[1:] }))
	wantWarning(t, one(t, ops, "sp_droppublication"), w)
}

func TestSyncObjectChange(t *testing.T) {
	p := buildLab(t, nil, func(des, _ *model.Config) { articleOf(t, des, "SalesPub", "Customer").SyncObject.Name = "SYNC_Other" })
	wantRefusal(t, p, "publications[SalesPub].articles[Customer].sync_object", "change of the synchronization view name of Customer not measured")
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		articleOf(t, des, "SalesPub", "Orders").SyncObject = &model.ObjectName{Schema: "dbo", Name: "vOrders"}
	}))
	op := one(t, ops, "sp_changearticle")
	wantParam(t, op, "@property", "N'sync_object'")
	wantParam(t, op, "@value", "N'[dbo].[vOrders]'")
	wantWarning(t, op, "view dbo.vOrders must exist at the publisher before apply")
}

func TestViewChangeWarnsReplacement(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		articleOf(t, des, "SalesPub", "Customer").Filter.Clause = "Country = 'DE'"
	}))
	wantWarning(t, one(t, ops, "sp_articleview"), "sp_articleview replaces the definition of view dbo.SYNC_Customer with the generated one (published columns and clause)")
}

// TestCreatedPublicationArticleState: an article added to a publication of
// this plan has no cost entry, and still enters the predicted state, so a
// subscription the plan adds with @article = N'all' gets its row.
func TestCreatedPublicationArticleState(t *testing.T) {
	st := labState(t)
	pub := Operation{Step: 8, Order: "m_p\x001", Kind: "publication", Action: "add",
		Call: Call{Params: []Param{{Name: "@publication", Value: "N'm_p'"}}}}
	pub.Affects.Publications = []string{"m_p"}
	art := Operation{Step: 8, Order: "m_p\x003", Kind: "article", Action: "add"}
	art.Affects = Affects{Publications: []string{"m_p"}, Articles: []string{"m_t9"}}
	ops, rs := finish([]Operation{pub, art, addSubOp(t, "m_p\x009", "m_p", "S/D", "automatic")}, st)
	if len(rs) != 0 {
		t.Fatalf("refusals %v", rs)
	}
	wantOpCosts(t, ops[1], CostOnline)
	if got := rowsOf(st, "m_p", "S/D"); len(got) != 1 || got["m_t9"] != 1 {
		t.Errorf("rows %v, want m_t9 at 1", got)
	}
}

// Minor 7: a column added to an article whose subscriber table keeps its
// columns (pre_creation_cmd delete, truncate or none) warns; with drop the
// table is created again with the column.
func TestColumnAddWarnsPreCreation(t *testing.T) {
	warning := "the subscriber table of Customer keeps its columns: the delivery fails with Invalid column name until the column is added there"
	for _, cmd := range []string{"delete", "truncate", "none", "drop"} {
		ops := plannedAlone(t, buildLab(t, customerChecks("Customer"), func(des, cur *model.Config) {
			both(des, cur, func(c *model.Config) { articleOf(t, c, "SalesPub", "Customer").PreCreationCmd = str(cmd) })
			a := articleOf(t, des, "SalesPub", "Customer")
			a.Columns = append(a.Columns, "Notes")
		}))
		col := one(t, ops, "sp_articlecolumn")
		if got := hasString(col.Warnings, warning); got != (cmd != "drop") {
			t.Errorf("pre_creation_cmd %s: warnings %q, want the column warning %v", cmd, col.Warnings, cmd != "drop")
		}
	}
}

// Minor 11: a destination that differs only in case keeps its cost and
// warns that the subscriber table is dropped and created again.
func TestDestinationCaseOnlyWarns(t *testing.T) {
	ops := plannedAlone(t, buildLab(t, nil, func(des, cur *model.Config) {
		both(des, cur, func(c *model.Config) { articleOf(t, c, "SalesPub", "Customer").Destination.Name = str("t1") })
		articleOf(t, des, "SalesPub", "Customer").Destination.Name = str("T1")
	}))
	op := one(t, ops, "sp_changearticle")
	wantParam(t, op, "@property", "N'dest_table'")
	if !hasCost(op.Costs, CostSubscriberDataReplaced) {
		t.Errorf("costs %v, want subscriber_data_replaced kept", op.Costs)
	}
	want := "destination T1 differs only in case: the subscriber table is dropped and created again"
	if !hasString(op.Warnings, want) {
		t.Errorf("warnings %q, want %q", op.Warnings, want)
	}
}
