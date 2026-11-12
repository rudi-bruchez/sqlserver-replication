package plan

import (
	"sort"
	"strings"

	"github.com/rudi-bruchez/sqlserver-replication/internal/cost"
	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
	"github.com/rudi-bruchez/sqlserver-replication/internal/normalize"
)

func init() { strategies = append(strategies, publicationsStrategy) }

// The Order keys of the publication and article operations within a step
// (finish sorts by (Step, Order)):
//
//   - step 3: "logreader" for sp_addlogreader_agent;
//   - step 4: "<pub>\x00<subscription>\x00" then 1 for
//     sp_droppullsubscription and 2 for sp_dropsubscription, the drop of a
//     whole subscription (subscriptions.go), "<pub>\x00<article>\x00<subscription>"
//     for the drop of one article from it;
//   - step 5: "1\x00<pub>\x00<article>" for sp_droparticle and "2\x00<pub>"
//     for sp_droppublication, so every article drop comes before every
//     publication drop (spec "Order" step 5);
//   - step 7: "<pub>\x00<article>\x00" then 1 for a property (and its
//     path), 2 for the filter, 3 for a column (and its rank), 4 for the view
//     (spec "Order" step 7: properties, then filters and columns, then
//     views);
//   - step 8: "" for sp_addlogreader_agent after a drop of the last
//     publication, "<pub>\x00" then 1 for sp_addpublication, 2 for
//     sp_addpublication_snapshot (R24's job_disable sorts after it with a
//     key starting with 2), and 3\x00<article>\x00 then 1 for sp_addarticle,
//     2 the filter, 3 a column, 4 the view;
//   - step 9: "<pub>\x00<subscription>\x00ext\x00<article>" for an extension.
const sep = "\x00"

// publicationsStrategy adds the publications of the file that do not exist
// (step 8, with their snapshot agent and their articles, and the log reader
// they need) and drops the current publications the file omits (steps 4
// and 5) (spec "Strategies", "Order").
func publicationsStrategy(b *builder) {
	_, desOnly, curOnly := matchPublications(b.des.Publications, b.cur.Publications)
	for _, p := range curOnly {
		b.dropPublication(p)
	}
	if len(desOnly) > 0 {
		b.logReaderFor(desOnly, len(curOnly) > 0 && len(curOnly) == len(b.cur.Publications))
	}
	for _, p := range desOnly {
		b.addPublication(p)
	}
}

// newOp is an operation of the publication database at the publisher, with
// the sources of its procedure's context.
func (b *builder) newOp(step int, order, kind, action, path string, call Call) Operation {
	op := Operation{
		Step: step, Order: order, Kind: kind, Action: action, Path: path,
		Server: b.des.Publisher.Server, Database: b.des.Publisher.Database, Call: call,
	}
	if ctx, ok := procContexts[call.Procedure]; ok {
		op.Sources = append(op.Sources, strings.Split(ctx.Source, ", ")...)
	}
	return op
}

// withEntry sets the cost entry of a structural operation, its cites added
// to Sources; false, with a refusal, when the operation is not measured on
// a publication of this type.
func (b *builder) withEntry(op *Operation, change, pubType string) bool {
	e, ok := cost.Lookup(change, "", pubType)
	if !ok {
		b.refuse(op.Path, "cost of %s on a %s publication not measured", change, pubType)
		return false
	}
	op.entry = &e
	for _, c := range e.Cites {
		op.Sources = append(op.Sources, c.Row)
	}
	return true
}

func (b *builder) add(op Operation) { b.ops = append(b.ops, op) }

func pubPath(name string) string { return "publications" + model.Element(name) }

func subPath(pub string, s *model.Subscription) string {
	return pubPath(pub) + ".subscriptions" + model.Element(s.Key())
}

// sortedSubscriptions is a publication's subscriptions by lower-cased key.
func sortedSubscriptions(subs []model.Subscription) []*model.Subscription {
	out := make([]*model.Subscription, len(subs))
	for i := range subs {
		out[i] = &subs[i]
	}
	sort.SliceStable(out, func(i, j int) bool { return subKey(out[i].Key()) < subKey(out[j].Key()) })
	return out
}

// subscriptionParams names a subscription in sp_addsubscription and
// sp_dropsubscription.
func subscriptionParams(pub, article string, s *model.Subscription) []Param {
	return []Param{
		{Name: "@publication", Value: literal(pub)},
		{Name: "@article", Value: literal(article)},
		{Name: "@subscriber", Value: literal(s.Subscriber)},
		{Name: "@destination_db", Value: literal(s.Database)},
	}
}

// logReaderFor adds sp_addlogreader_agent before the publications the plan
// adds, when one of them needs it (model.Config.NeedsLogReader): in step 8
// when step 5 drops the database's last publication, whose drop removes the
// log reader (13-transient T02, R10); in step 3 when the database has none
// (spec "Order" steps 3 and 8).
func (b *builder) logReaderFor(added []*model.Publication, dropsLast bool) {
	needs := false
	for _, p := range added {
		needs = needs || p.Type == nil || *p.Type != "snapshot"
	}
	if !needs {
		return
	}
	step, order := 3, "logreader"
	switch {
	case dropsLast:
		step, order = 8, ""
	case b.st.LogReader:
		return
	}
	const path = "publisher.log_reader_agent"
	call, err := creationCall("sp_addlogreader_agent", b.des.Publisher.LogReaderAgent, normalize.Context{Object: "log_reader_agent"}, nil)
	if err != nil {
		b.refuse(path, "%v", err)
		return
	}
	op := b.newOp(step, order, "log_reader_agent", "add", path, call)
	op.Reason = "the publications this plan adds need the database's log reader agent"
	op.Sources = append(op.Sources, "spec Order steps 3 and 8", "13-transient T02")
	b.add(op)
}

// addPublication: sp_addpublication, then sp_addpublication_snapshot for the
// snapshot agent of the file (its declared schedule, R22), then its articles
// (spec "Order" step 8). The publication starts without subscriptions, so
// its articles need no extension: the subscriptions are added in step 9 for
// every article (Task 12).
func (b *builder) addPublication(p *model.Publication) {
	path := pubPath(p.Name)
	pubType := stringOr(p.Type, "transactional")
	ctx := normalize.Context{Object: "publication", PubType: pubType, SyncMethod: stringOr(p.SyncMethod, "")}
	id := []Param{{Name: "@publication", Value: literal(p.Name)}}
	call, err := creationCall("sp_addpublication", p, ctx, id)
	if err != nil {
		b.refuse(path, "%v", err)
		return
	}
	op := b.newOp(8, p.Name+sep+"1", "publication", "add", path, call)
	op.Affects.Publications = []string{p.Name}
	op.Reason = "the file declares a publication that does not exist"
	op.Sources = append(op.Sources, "spec Order step 8")
	b.add(op)

	snap, err := creationCall("sp_addpublication_snapshot", p.SnapshotAgent,
		normalize.Context{Object: "snapshot_agent", PubType: pubType}, id)
	if err != nil {
		b.refuse(path+".snapshot_agent", "%v", err)
		return
	}
	op = b.newOp(8, p.Name+sep+"2", "snapshot_agent", "add", path+".snapshot_agent", snap)
	op.Affects.Publications = []string{p.Name}
	op.Reason = "the snapshot agent of the publication the plan adds"
	op.Sources = append(op.Sources, "spec Order step 8")
	b.add(op)

	for i := range p.Articles {
		b.addArticle(p, nil, &p.Articles[i])
	}
}

// dropPublication: dropSubscription for each of its subscriptions (step 4),
// then sp_droppublication (step 5), which fails
// with 14005 while a subscription remains (spec "Order" step 5). A snapshot
// agent with a proxy loses it with its job (ledger of plan 2).
func (b *builder) dropPublication(p *model.Publication) {
	path := pubPath(p.Name)
	pubType := stringOr(p.Type, "transactional")
	for _, s := range sortedSubscriptions(p.Subscriptions) {
		// dropSubscription (Task 12): a pull subscription is dropped at the
		// subscriber first (08-pull P3.subscriber-first).
		if !b.dropSubscription(p, s, "the publication is dropped: its subscriptions first (14005); the subscriber tables are left in place") {
			return
		}
	}
	op := b.newOp(5, "2"+sep+p.Name, "publication", "drop", path,
		Call{Procedure: "sp_droppublication", Params: []Param{{Name: "@publication", Value: literal(p.Name)}}})
	if !b.withEntry(&op, cost.OpDropPublication, pubType) {
		return
	}
	op.Affects.Publications = []string{p.Name}
	if len(p.Subscriptions) > 0 {
		op.Costs = []Cost{CostSubscriberObjectLeft}
	}
	for i := range p.Articles {
		if w := dropViewWarning(&p.Articles[i]); w != "" {
			op.Warnings = append(op.Warnings, w)
		}
	}
	if a := p.SnapshotAgent; a != nil && a.RunAs != nil && *a.RunAs != "" {
		op.Warnings = append(op.Warnings, "dropping the publication deletes its snapshot job and the proxy of its job step")
	}
	op.Reason = "the file omits the publication"
	b.add(op)
}
