package plan

import (
	"fmt"
	"strings"

	"github.com/rudi-bruchez/sqlserver-replication/internal/cost"
	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
	"github.com/rudi-bruchez/sqlserver-replication/internal/normalize"
)

func init() { strategies = append(strategies, articlesStrategy) }

// articlesStrategy plans the articles of the publications that exist on
// both sides (spec "Strategies", Articles and "Filters and views"): the
// articles the file omits are dropped (steps 4 and 5), those it adds are
// added (step 8) and the existing subscriptions extended to them (step 9),
// and the kept ones changed (step 7). An article whose type family or
// source changes is dropped and added back (R20). The articles of a
// publication the plan adds or drops are publicationsStrategy's.
func articlesStrategy(b *builder) {
	pairs, _, _ := matchPublications(b.des.Publications, b.cur.Publications)
	for _, pp := range pairs {
		b.planArticles(pp)
	}
}

const artPrefix = "publications[*].articles[*]."

func (b *builder) planArticles(pp pair[model.Publication]) {
	pd, pc := pp.Des, pp.Cur
	ppath := pp.path("publications")
	if b.skip(ppath) || b.skip(ppath+".articles") {
		return
	}
	apairs, adds, drops := matchArticles(pd.Articles, pc.Articles)
	for _, ap := range apairs {
		if b.skip(ap.path(ppath + ".articles")) {
			continue
		}
		if replaced(ap.Des, ap.Cur) {
			// R20 (06-structural C3): a drop under the drop rules, then an
			// add under the add rules. sp_droparticle deletes the article's
			// synchronization view, a user's view passed by sp_addarticle
			// @sync_object included (measured by the Task 11 review): only
			// sp_articleview, for an article with a filter or columns,
			// creates it again.
			if d := ap.Des; d.SyncObject != nil && d.Filter == nil && len(d.Columns) == 0 {
				b.refuse(ap.path(ppath+".articles"), "re-adding the article needs its view %s, which sp_droparticle deletes (measured)", viewName(d.SyncObject))
				continue
			}
			drops = append(drops, ap.Cur)
			adds = append(adds, ap.Des)
			continue
		}
		b.changeArticle(pd, ppath, ap)
	}
	for _, a := range drops {
		b.dropArticle(pd, pc, a)
	}
	var added []*model.Article
	for _, a := range adds {
		if b.addArticle(pd, pc, a) {
			added = append(added, a)
		}
	}
	b.extend(pd, pc, added)
}

// typeFamily is the family of an article type (R20): table (the logbased
// variants), schema_only or proc_exec; an unknown type is its own family.
func typeFamily(t *string) string {
	s := stringOr(t, "logbased")
	switch {
	case strings.HasPrefix(s, "logbased"):
		return "table"
	case strings.HasSuffix(s, "proc_exec"):
		return "proc_exec"
	case strings.HasSuffix(s, "_schema_only"):
		return "schema_only"
	}
	return s
}

// replaced tells an article the plan drops and adds back (R20): its type
// family or its source changes. Only the logbased variants change their
// type in place (the cost table measures them alone, 02-matrix A21); two
// schema-only types are two kinds of objects. The source is compared without
// regard to case (a SQL identifier).
func replaced(d, c *model.Article) bool {
	dt, ct := stringOr(d.Type, "logbased"), stringOr(c.Type, "logbased")
	if typeFamily(d.Type) != typeFamily(c.Type) || (typeFamily(d.Type) != "table" && dt != ct) {
		return true
	}
	return !strings.EqualFold(d.Source.Schema, c.Source.Schema) || !strings.EqualFold(d.Source.Name, c.Source.Name)
}

// articleContext is the defaults context of an article of p.
func articleContext(p *model.Publication, a *model.Article) normalize.Context {
	kind := "table"
	if t := stringOr(a.Type, ""); t != "" && !strings.HasPrefix(t, "logbased") {
		kind = t
	}
	return normalize.Context{Object: "article", PubType: stringOr(p.Type, "transactional"),
		SyncMethod: stringOr(p.SyncMethod, ""), ArticleKind: kind}
}

// createsView tells an article whose declared synchronization view
// sp_articleview creates: a row or a column filter with a declared name.
// Without a filter, a declared sync_object is a view of the user's that
// sp_addarticle @sync_object names.
func createsView(a *model.Article) bool {
	return a.SyncObject != nil && (a.Filter != nil || len(a.Columns) > 0)
}

func destructive(cmd *string) bool {
	switch stringOr(cmd, "") {
	case "drop", "delete", "truncate":
		return true
	}
	return false
}

func withoutParams(c Call, names ...string) Call {
	drop := map[string]bool{}
	for _, n := range names {
		drop[n] = true
	}
	params := c.Params[:0:0]
	for _, p := range c.Params {
		if !drop[p.Name] {
			params = append(params, p)
		}
	}
	c.Params = params
	return c
}

// remaining is the subscriptions of the publication that exist in step 8
// and 9: the current ones the file keeps (a subscription the file omits is
// dropped in step 4, Task 12), each with its desired side.
func remaining(pd, pc *model.Publication) []pair[model.Subscription] {
	if pc == nil {
		return nil
	}
	pairs, _, _ := matchSubscriptions(pd.Subscriptions, pc.Subscriptions)
	return pairs
}

// covers tells whether a subscription's article list covers the article
// (nil is every article; names compared without regard to case).
func covers(s *model.Subscription, art string) bool {
	if len(s.Articles) == 0 {
		return true
	}
	for _, a := range s.Articles {
		if strings.EqualFold(a, art) {
			return true
		}
	}
	return false
}

// addArticle: sp_addarticle from creationCall, never with @filter_clause
// (lab row 12; @filter, @filter_owner and @vertical_partition are never
// passed, neverPassed), so the article starts with every column; then the
// filter (sp_articlefilter), the column drops (sp_articlecolumn) and the
// view (sp_articleview) with the article's clause (spec "Filters and
// views"). pc is nil for a publication the plan adds. It returns whether
// the article is added.
func (b *builder) addArticle(pd, pc *model.Publication, a *model.Article) bool {
	apath := pubPath(pd.Name) + ".articles" + model.Element(a.Name)
	if typeFamily(a.Type) == "proc_exec" {
		b.refuse(apath, "creating a %s article is not measured (R20: no measured defaults or costs)", stringOr(a.Type, ""))
		return false
	}
	pubType := stringOr(pd.Type, "transactional")
	if boolOf(pd.ImmediateSync) {
		// R34: sp_addarticle subscribes such a subscription by itself,
		// which no row measured.
		for _, sp := range remaining(pd, pc) {
			if init := stringOr(sp.Cur.Initialization, initSnapshot); init == "backup" || init == "lsn" {
				b.refuse(apath, "adding an article to a publication with a %s-initialized subscription is not measured", init)
				return false
			}
		}
	}
	ctx := articleContext(pd, a)
	id := []Param{{Name: "@publication", Value: literal(pd.Name)}}
	call, err := creationCall("sp_addarticle", a, ctx, id)
	if err != nil {
		b.refuse(apath, "%v", err)
		return false
	}
	call = withoutParams(call, "@filter_clause")
	if createsView(a) {
		// The view does not exist yet: sp_articleview creates it.
		call = withoutParams(call, "@sync_object", "@sync_object_owner")
	}
	key := pd.Name + sep + "3" + sep + a.Name + sep
	affects := Affects{Publications: []string{pd.Name}, Articles: []string{a.Name}}
	created := pc == nil

	op := b.newOp(8, key+"1", "article", "add", apath, call)
	if !b.articleEntry(&op, cost.OpAddArticle, pubType, created) {
		return false
	}
	op.Affects = affects
	op.wideMarkCheck = !created
	op.Reason = "the file declares an article that does not exist"
	op.Sources = append(op.Sources, "spec Strategies (Articles)", "lab row 12")
	b.add(op)

	var ops []Operation
	if a.Filter != nil {
		fc, err := creationCall("sp_articlefilter", a, ctx, id)
		if err != nil {
			b.refuse(apath+".filter", "%v", err)
			return false
		}
		op := b.newOp(8, key+"2", "article_filter", "add", apath+".filter", fc)
		if !b.articleEntry(&op, cost.OpArticleFilter, pubType, created) {
			return false
		}
		op.Reason = "the row filter of the added article: the filter procedure the log reader uses"
		ops = append(ops, op)
	}
	dropped := 0
	if len(a.Columns) > 0 {
		cols, ok := b.tableColumns(apath, a)
		if !ok {
			return false
		}
		want := map[string]bool{}
		for _, c := range a.Columns {
			want[strings.ToLower(c)] = true
		}
		for _, c := range a.Columns {
			if !hasFold(cols, c) {
				b.refuse(apath+".columns", "column %q is not a column of %s.%s", c, a.Source.Schema, a.Source.Name)
				return false
			}
		}
		for i, c := range cols {
			if want[strings.ToLower(c)] {
				continue
			}
			op := b.columnOp(8, fmt.Sprintf("%s3%s%04d", key, sep, i), apath, pd.Name, a.Name, c, "drop")
			if !b.articleEntry(&op, cost.OpArticleColumn, pubType, created) {
				return false
			}
			ops = append(ops, op)
			dropped++
		}
	}
	if a.Filter != nil || dropped > 0 {
		vc, err := creationCall("sp_articleview", a, ctx, id)
		if err != nil {
			b.refuse(apath+".sync_object", "%v", err)
			return false
		}
		op := b.newOp(8, key+"4", "article_view", "add", apath+".sync_object", vc)
		if !b.articleEntry(&op, cost.OpArticleView, pubType, created) {
			return false
		}
		op.Reason = "the synchronization view the snapshot reads, with the article's clause and columns"
		ops = append(ops, op)
	}
	for _, op := range ops {
		op.Affects = Affects{Publications: []string{pd.Name}, Articles: []string{a.Name}}
		op.Sources = append(op.Sources, "spec Strategies (Filters and views)")
		b.add(op)
	}
	return true
}

// articleEntry is withEntry, except on a publication this plan creates:
// there its articles, filters, columns and views cost online without a
// cost entry, since no snapshot and no subscription exist yet (controller's
// ruling, Task 11 fix round 1). On an existing snapshot publication the
// structural entries are missing, and the operations stay refused.
func (b *builder) articleEntry(op *Operation, change, pubType string, created bool) bool {
	if created {
		op.Sources = append(op.Sources, "controller ruling (Task 11 fix 1): a publication of this plan has no snapshot and no subscription")
		return true
	}
	return b.withEntry(op, change, pubType)
}

// viewName writes a view's name for a message.
func viewName(o *model.ObjectName) string { return o.Schema + "." + o.Name }

func hasFold(xs []string, s string) bool {
	for _, x := range xs {
		if strings.EqualFold(x, s) {
			return true
		}
	}
	return false
}

// tableColumns is the columns of the article's source table read by the
// checks, in column order; refused when they were not read.
func (b *builder) tableColumns(apath string, a *model.Article) ([]string, bool) {
	if b.in.Checks != nil {
		for _, t := range b.in.Checks.Tables {
			if strings.EqualFold(t.Schema, a.Source.Schema) && strings.EqualFold(t.Name, a.Source.Name) && len(t.Columns) > 0 {
				return t.Columns, true
			}
		}
	}
	b.refuse(apath+".columns", "columns of %s.%s not read", a.Source.Schema, a.Source.Name)
	return nil, false
}

// columnOp is one sp_articlecolumn call: operation is add or drop.
func (b *builder) columnOp(step int, order, apath, pub, art, column, operation string) Operation {
	op := b.newOp(step, order, "article_column", operation, apath+".columns", Call{Procedure: "sp_articlecolumn", Params: []Param{
		{Name: "@publication", Value: literal(pub)},
		{Name: "@article", Value: literal(art)},
		{Name: "@column", Value: literal(column)},
		{Name: "@operation", Value: literal(operation)},
	}})
	op.Changes = []PropertyChange{{Path: apath + ".columns", After: operation + " " + column}}
	op.Reason = "the column list of the article: the column filter is applied before the view"
	return op
}

// extend subscribes the remaining subscriptions to the added articles on a
// publication without immediate_sync (step 9): by name under native,
// character and database snapshot, one call with @article = N'all' per
// subscription under concurrent and concurrent_c, a named one being 14100
// (spec "Strategies", Articles). Every call passes @subscription_type and
// @sync_type (R36). On an immediate_sync publication sp_addarticle has
// subscribed them (C.*.addarticle), and an extension is refused (14058,
// 14122).
func (b *builder) extend(pd, pc *model.Publication, added []*model.Article) {
	if len(added) == 0 || boolOf(pd.ImmediateSync) {
		return
	}
	pubType := stringOr(pd.Type, "transactional")
	method := stringOr(pd.SyncMethod, "native")
	all := method == "concurrent" || method == "concurrent_c"
	for _, sp := range remaining(pd, pc) {
		var arts []string
		for _, a := range added {
			if covers(sp.Des, a.Name) {
				arts = append(arts, a.Name)
			}
		}
		if len(arts) == 0 {
			continue
		}
		cur := sp.Cur
		path := subPath(pd.Name, cur)
		types, ok := b.extensionTypes(path, sp.Des, cur) // R36, R21
		if !ok {
			continue
		}
		names := arts
		if all {
			names = []string{"all"}
		}
		for _, name := range names {
			params := append(subscriptionParams(pd.Name, name, cur), types...)
			first := name
			if all {
				first = arts[0]
			}
			op := b.newOp(9, pd.Name+sep+subKey(cur.Key())+sep+"ext"+sep+first, "subscription_extension", "add", path,
				Call{Procedure: "sp_addsubscription", Params: params})
			if !b.withEntry(&op, cost.OpExtendSubscription, pubType) {
				return
			}
			op.Affects = Affects{Publications: []string{pd.Name}, Articles: []string{first}, Subscriptions: []string{cur.Key()}}
			op.Reason = "the subscription is extended to the added articles " + strings.Join(arts, ", ")
			op.Sources = append(op.Sources, "spec Strategies (Articles)", "R36")
			b.add(op)
		}
	}
}

// dropArticle: sp_dropsubscription @article for each remaining subscription
// to it (step 4), then sp_droparticle (step 5), which refuses a subscribed
// article with 14046; both leave the subscriber table in place (spec
// "Strategies", anti-goal 4). A subscription the file omits is dropped
// whole in step 4 (Task 12).
func (b *builder) dropArticle(pd, pc *model.Publication, a *model.Article) {
	apath := pubPath(pc.Name) + ".articles" + model.Element(a.Name)
	pubType := stringOr(pc.Type, "transactional")
	subscribed := false
	for _, s := range pc.Subscriptions {
		subscribed = subscribed || covers(&s, a.Name)
	}
	for _, sp := range remaining(pd, pc) {
		if !covers(sp.Cur, a.Name) {
			continue
		}
		op := b.newOp(4, pc.Name+sep+a.Name+sep+subKey(sp.Cur.Key()), "subscription_article_drop", "drop", subPath(pc.Name, sp.Cur),
			Call{Procedure: "sp_dropsubscription", Params: subscriptionParams(pc.Name, a.Name, sp.Cur)})
		if !b.withEntry(&op, cost.OpDropSubscriptionArticle, pubType) {
			return
		}
		op.Affects = Affects{Publications: []string{pc.Name}, Articles: []string{a.Name}, Subscriptions: []string{sp.Cur.Key()}}
		op.Costs = []Cost{CostSubscriberObjectLeft}
		op.Reason = "the article is dropped: its subscriptions first (14046); the subscriber table is left in place"
		op.Sources = append(op.Sources, "spec Strategies (Articles)")
		b.add(op)
	}
	op := b.newOp(5, "1"+sep+pc.Name+sep+a.Name, "article", "drop", apath, Call{Procedure: "sp_droparticle", Params: []Param{
		{Name: "@publication", Value: literal(pc.Name)},
		{Name: "@article", Value: literal(a.Name)},
	}})
	if !b.withEntry(&op, cost.OpDropArticle, pubType) {
		return
	}
	op.Affects = Affects{Publications: []string{pc.Name}, Articles: []string{a.Name}}
	if subscribed {
		op.Costs = []Cost{CostSubscriberObjectLeft}
	}
	if w := dropViewWarning(a); w != "" {
		op.Warnings = append(op.Warnings, w)
	}
	op.Reason = "the file omits the article"
	op.Sources = append(op.Sources, "spec Strategies (Articles)")
	b.add(op)
}

// changeArticle plans a kept article (step 7): one sp_changearticle per
// changed property, then the filter, the columns and the view (spec "Filters
// and views").
func (b *builder) changeArticle(pd *model.Publication, ppath string, ap pair[model.Article]) {
	apath := ap.path(ppath + ".articles")
	d, c := ap.Des, ap.Cur
	pubType := stringOr(pd.Type, "transactional")
	key := pd.Name + sep + d.Name + sep
	changes := b.diff(apath, d, c)
	var props []Change
	for _, ch := range changes {
		rel := strings.TrimPrefix(ch.Pattern, artPrefix)
		switch {
		case rel == "columns" || rel == "filter" || strings.HasPrefix(rel, "filter."):
			continue // below
		case rel == "sync_object" && ch.Before != nil && strings.EqualFold(*ch.Before, *ch.After):
			continue // a SQL identifier (Task 10)
		}
		props = append(props, ch)
	}
	filterChanged := !b.skip(apath+".filter") && d.Filter != nil &&
		(c.Filter == nil || d.Filter.Clause != c.Filter.Clause || !sameObject(d.Filter.Procedure, c.Filter.Procedure))
	filterDropped := !b.skip(apath+".filter") && d.Filter == nil && c.Filter != nil
	var adds, drops []string
	if !b.skip(apath + ".columns") {
		var ok bool
		if adds, drops, ok = b.columnChanges(apath, d, c); !ok {
			return
		}
	}
	if typeFamily(d.Type) == "proc_exec" {
		if len(props) > 0 || filterChanged || filterDropped || len(adds)+len(drops) > 0 {
			b.refuse(apath, "changing a %s article is not measured (R20: no measured defaults or costs)", stringOr(d.Type, ""))
		}
		return
	}
	if d.SyncObject == nil && c.SyncObject != nil && !b.skip(apath+".sync_object") {
		b.refuse(apath+".sync_object", "returning to a generated view is not measured (R31)")
		return
	}
	replaces := destructive(d.PreCreationCmd)
	for _, ch := range props {
		isView := strings.TrimPrefix(ch.Pattern, artPrefix) == "sync_object"
		if isView && (d.Filter != nil || len(d.Columns) > 0 || c.Filter != nil || len(c.Columns) > 0) {
			// sp_articleview makes this view; sp_changearticle sync_object
			// fails with 15001 when the new view does not exist, and a
			// rename through sp_articleview was not measured (Task 11
			// review).
			b.refuse(ch.Path, "change of the synchronization view name of %s not measured", d.Name)
			continue
		}
		n := len(b.ops)
		b.articleProperty(pd, d, ch, key, replaces)
		if isView && len(b.ops) > n {
			// Plan 4's precheck checks it.
			b.ops[n].Warnings = append(b.ops[n].Warnings, fmt.Sprintf("view %s must exist at the publisher before apply", viewName(d.SyncObject)))
		}
	}

	ctx := articleContext(pd, d)
	id := []Param{{Name: "@publication", Value: literal(pd.Name)}}
	affects := func() Affects { return Affects{Publications: []string{pd.Name}, Articles: []string{d.Name}} }
	var ops []Operation
	switch {
	case filterChanged:
		fc, err := creationCall("sp_articlefilter", d, ctx, id)
		if err != nil {
			b.refuse(apath+".filter", "%v", err)
			return
		}
		op := b.newOp(7, key+"2", "article_filter", "change", apath+".filter", fc)
		op.Changes = filterChanges(apath, d.Filter, c.Filter)
		op.Reason = "the row filter changes: the filter procedure, then the view with the same clause"
		ops = append(ops, op)
	case filterDropped:
		params := []Param{
			{Name: "@publication", Value: literal(pd.Name)},
			{Name: "@article", Value: literal(d.Name)},
		}
		if c.Filter.Procedure != nil && c.Filter.Procedure.Name != "" {
			name, err := encQualifiedName(c.Filter.Procedure)
			if err != nil {
				b.refuse(apath+".filter", "%v", err)
				return
			}
			params = append(params, Param{Name: "@filter_name", Value: name})
		}
		params = append(params, Param{Name: "@filter_clause", Value: "NULL"})
		op := b.newOp(7, key+"2", "article_filter", "drop", apath+".filter", Call{Procedure: "sp_articlefilter", Params: params})
		op.Changes = filterChanges(apath, nil, c.Filter)
		op.Reason = "the row filter is dropped: @filter_clause = NULL drops the filter procedure, then the view"
		ops = append(ops, op)
	}
	for i, col := range adds {
		ops = append(ops, b.columnOp(7, fmt.Sprintf("%s3%s1%04d", key, sep, i), apath, pd.Name, d.Name, col, "add"))
	}
	for i, col := range drops {
		ops = append(ops, b.columnOp(7, fmt.Sprintf("%s3%s2%04d", key, sep, i), apath, pd.Name, d.Name, col, "drop"))
	}
	if len(ops) > 0 {
		// The view is re-issued after every filter or column change, with the
		// article's clause: without it, sp_articleview rebuilds the view
		// unfiltered and clears filter_clause while the procedure keeps
		// filtering (14-filter-view F4); after a column change it costs
		// nothing and does not depend on the rebuild sp_articlecolumn makes
		// only for a subscribed article (F6, F6s, F6u).
		vc, err := creationCall("sp_articleview", d, ctx, id)
		if err != nil {
			b.refuse(apath+".sync_object", "%v", err)
			return
		}
		if filterDropped {
			vc.Params = append(vc.Params, Param{Name: "@filter_clause", Value: "NULL"})
		}
		op := b.newOp(7, key+"4", "article_view", "change", apath+".sync_object", vc)
		op.Reason = "the synchronization view follows the article's clause and columns"
		if d.SyncObject != nil {
			// A view the user made and passed by @sync_object cannot be
			// told from one sp_articleview made.
			op.Warnings = append(op.Warnings, fmt.Sprintf("sp_articleview replaces the definition of view %s with the generated one (published columns and clause)", viewName(d.SyncObject)))
		}
		ops = append(ops, op)
	}
	for _, op := range ops {
		change := map[string]string{"article_filter": cost.OpArticleFilter, "article_column": cost.OpArticleColumn, "article_view": cost.OpArticleView}[op.Kind]
		if !b.withEntry(&op, change, pubType) {
			return
		}
		op.Affects = affects()
		op.replacesData = replaces
		op.Sources = append(op.Sources, "spec Strategies (Filters and views)", "14-filter-view F4")
		b.add(op)
	}
}

// dropViewWarning: sp_droparticle deletes the article's synchronization
// view, the user's own included (measured by the Task 11 review).
func dropViewWarning(a *model.Article) string {
	if a.SyncObject == nil {
		return ""
	}
	return fmt.Sprintf("dropping article %s deletes its synchronization view %s", a.Name, viewName(a.SyncObject))
}

func sameObject(a, b *model.ObjectName) bool {
	if a == nil || b == nil {
		return a == b
	}
	return strings.EqualFold(a.Schema, b.Schema) && strings.EqualFold(a.Name, b.Name)
}

func filterChanges(apath string, d, c *model.Filter) []PropertyChange {
	str := func(f *model.Filter) (clause, proc string) {
		if f == nil {
			return "", ""
		}
		if f.Procedure != nil {
			proc = quoteName(f.Procedure.Schema) + "." + quoteName(f.Procedure.Name)
		}
		return f.Clause, proc
	}
	dc, dp := str(d)
	cc, cp := str(c)
	var out []PropertyChange
	if dc != cc {
		out = append(out, PropertyChange{Path: apath + ".filter.clause", Before: cc, After: dc})
	}
	if !strings.EqualFold(dp, cp) {
		out = append(out, PropertyChange{Path: apath + ".filter.procedure", Before: cp, After: dp})
	}
	return out
}

// columnChanges is the columns to add and to drop, in table order when the
// table was read: nil columns are every column (R30), so a nil side needs
// the table's columns, refused when they were not read.
func (b *builder) columnChanges(apath string, d, c *model.Article) (adds, drops []string, ok bool) {
	if len(d.Columns) == 0 && len(c.Columns) == 0 {
		return nil, nil, true
	}
	var table []string
	if len(d.Columns) == 0 || len(c.Columns) == 0 {
		if table, ok = b.tableColumns(apath, d); !ok {
			return nil, nil, false
		}
	} else if b.in.Checks != nil {
		for _, t := range b.in.Checks.Tables {
			if strings.EqualFold(t.Schema, d.Source.Schema) && strings.EqualFold(t.Name, d.Source.Name) {
				table = t.Columns
			}
		}
	}
	des, cur := d.Columns, c.Columns
	if len(des) == 0 {
		des = table
	}
	if len(cur) == 0 {
		cur = table
	}
	for _, col := range des {
		if len(table) > 0 && !hasFold(table, col) {
			b.refuse(apath+".columns", "column %q is not a column of %s.%s", col, d.Source.Schema, d.Source.Name)
			return nil, nil, false
		}
	}
	order := des
	if len(table) > 0 {
		order = table
	}
	for _, col := range order {
		if hasFold(des, col) && !hasFold(cur, col) {
			adds = append(adds, col)
		}
	}
	order = cur
	if len(table) > 0 {
		order = table
	}
	for _, col := range order {
		if hasFold(cur, col) && !hasFold(des, col) {
			drops = append(drops, col)
		}
	}
	return adds, drops, true
}

// directions are the cost table directions a change can be keyed by (R8),
// tried in order: to_true or to_false for a boolean, set or clear for a
// string, then none.
func directions(ch Change) []string {
	after := ""
	if ch.After != nil {
		after = *ch.After
	}
	switch after {
	case "true":
		return []string{"to_true", ""}
	case "false":
		return []string{"to_false", ""}
	case "":
		return []string{"clear", ""}
	}
	return []string{"set", ""}
}

// articleProperty is one sp_changearticle for one changed property (R2),
// its entry from cost.Lookup, refused as not measured otherwise. A change
// of pre_creation_cmd replaces subscriber data, and so does any
// reinitialization of an article whose pre_creation_cmd is drop, delete or
// truncate (spec anti-goal 4): finish adds the cost when the call is
// reinit-flagged.
func (b *builder) articleProperty(pd *model.Publication, d *model.Article, ch Change, key string, replaces bool) {
	pubType := stringOr(pd.Type, "transactional")
	var e cost.Entry
	found := false
	for _, dir := range directions(ch) {
		if e, found = cost.Lookup(ch.Path, dir, pubType); found {
			break
		}
	}
	if !found {
		b.unmeasured(ch)
		return
	}
	switch e.Class {
	case cost.Refused, cost.DropReadd:
		b.refuse(ch.Path, "%s change refused by the server (%d)", ch.Pattern, e.Error)
		return
	}
	rel := strings.TrimPrefix(ch.Pattern, artPrefix)
	v, ok := resolve(d, rel)
	if !ok {
		b.refuse(ch.Path, "%s has no value to set", ch.Pattern)
		return
	}
	if e.Property == "status" {
		w, err := articleStatusWord(rel, ch.After != nil && *ch.After == "true")
		if err != nil {
			b.refuse(ch.Path, "%v", err)
			return
		}
		v = w
	}
	enc, ok := valueEncoders[[2]string{e.Procedure, e.Property}]
	if !ok {
		b.refuse(ch.Path, "no measured @value form for %s %s", e.Procedure, e.Property)
		return
	}
	lit, err := enc(v)
	if err != nil {
		b.refuse(ch.Path, "%v", err)
		return
	}
	op := b.newOp(7, key+"1"+sep+ch.Path, "article_property", "change", pubPath(pd.Name)+".articles"+model.Element(d.Name),
		Call{Procedure: e.Procedure, Params: []Param{
			{Name: "@publication", Value: literal(pd.Name)},
			{Name: "@article", Value: literal(d.Name)},
			{Name: "@property", Value: literal(e.Property)},
			{Name: "@value", Value: lit},
		}})
	op.entry = &e
	for _, c := range e.Cites {
		op.Sources = append(op.Sources, c.Row)
	}
	op.Changes = []PropertyChange{{Path: ch.Path, Before: orEmpty(ch.Before), After: orEmpty(ch.After)}}
	op.Affects = Affects{Publications: []string{pd.Name}, Articles: []string{d.Name}}
	op.replacesData = replaces
	if rel == "pre_creation_cmd" {
		op.Costs = []Cost{CostSubscriberDataReplaced}
	}
	op.Reason = "the article's " + rel + " changes"
	b.add(op)
}

func orEmpty(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}
