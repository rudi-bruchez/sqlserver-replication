package plan

import (
	"fmt"
	"sort"
	"strconv"
	"strings"

	"github.com/rudi-bruchez/sqlserver-replication/internal/cost"
	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
	"github.com/rudi-bruchez/sqlserver-replication/internal/normalize"
)

func init() { strategies = append(strategies, subscriptionsStrategy) }

// The Order keys of the subscription operations (finish sorts by (Step,
// Order)), under "<pub>\x00<subscription>\x00":
//
//   - step 4: 1 for sp_droppullsubscription at the subscriber, 2 for
//     sp_dropsubscription @article = N'all' at the publisher (08-pull
//     P3.subscriber-first.*); the drop of one article from a subset is
//     "<pub>\x00<article>\x00<subscription>", as Task 11's;
//   - step 9: "add\x00" then 1 for the first sp_addsubscription, 2 for
//     sp_addpushsubscription_agent, so that nothing sorts between them (spec
//     "Subscriptions"), 3\x00<n> for the other articles of a subset, 4 for
//     sp_addpullsubscription and 5 for sp_addpullsubscription_agent; "ext\x00"
//     then the article for an extension, as Task 11's;
//   - step 10: "chg\x00" then the property's path for an agent property
//     change.

// R21 and R35's texts.
const (
	r35Missing      = "subscription %s misses articles %s; completing it with @article = 'all' loses the rows changed while they were missing (measured); drop the subscription in one plan (remove it from the file) and add it back in the next"
	r21Type         = "a change of type of subscription %s (%s to %s) is refused: drop it in one plan and add it in another (R21)"
	r21PullShared   = "a pull subscription to publication %s, which has no independent_agent, is refused: its shared pull agent is not measured (R21)"
	r21Lsn          = "initialization from an LSN: its precondition check is plan 4's (R21; a wrong LSN is accepted and stops the subscriptions of the database)"
	r21Extension    = "extension of a %s-initialized subscription not measured"
	r21InitNote     = "the initialization of subscription %s of %s changes from %s to %s: it only serves the creation of a subscription, so the plan changes nothing (R21)"
	sharedPullStays = "the shared pull agent job stays at the subscriber after sp_droppullsubscription"
	r12LosesAll     = "subscription %s would lose every article before the new ones are added, which drops it with its agent (measured); drop and add it in two plans"
)

const subPrefix = "publications[*].subscriptions[*]."

// subscriptionsStrategy plans the subscriptions (spec "Strategies",
// Subscriptions, and "Order" steps 4, 9 and 10): those of a publication the
// plan adds are added; on a publication that exists on both sides, those the
// file omits are dropped, those it adds are added, and the kept ones changed
// (their article subset, their agent's properties). The subscriptions of a
// dropped publication are dropped by publicationsStrategy, through
// dropSubscription. Extending a subscription to an article new to the
// publication is articlesStrategy's (Task 11).
//
// The additions are planned in the order of their step 9 Order keys
// (publication, then subscription), so that the first addition to a
// subscriber database creates its shared distribution agent and the later
// ones find it (pushAgent).
func subscriptionsStrategy(b *builder) {
	pairs, desOnly, _ := matchPublications(b.des.Publications, b.cur.Publications)
	type addition struct {
		pub *model.Publication
		sub *model.Subscription
	}
	var adds []addition
	for _, p := range desOnly {
		for _, s := range sortedSubscriptions(p.Subscriptions) {
			adds = append(adds, addition{p, s})
		}
	}
	for _, pp := range pairs {
		for _, s := range b.planSubscriptions(pp) {
			adds = append(adds, addition{pp.Des, s})
		}
	}
	sort.SliceStable(adds, func(i, j int) bool {
		if adds[i].pub.Name != adds[j].pub.Name {
			return adds[i].pub.Name < adds[j].pub.Name
		}
		return subKey(adds[i].sub.Key()) < subKey(adds[j].sub.Key())
	})
	for _, a := range adds {
		b.addSubscription(a.pub, a.sub)
	}
}

// planSubscriptions drops and changes the subscriptions of a publication on
// both sides, and returns those the file adds.
func (b *builder) planSubscriptions(pp pair[model.Publication]) []*model.Subscription {
	pd, pc := pp.Des, pp.Cur
	ppath := pp.path("publications")
	if b.skip(ppath) || b.skip(ppath+".subscriptions") {
		return nil
	}
	spairs, adds, drops := matchSubscriptions(pd.Subscriptions, pc.Subscriptions)
	for _, s := range drops {
		if b.skip(subPath(pc.Name, s)) {
			continue
		}
		// A subscription missing articles (R35) is dropped like any other:
		// the drop needs no completion.
		b.dropSubscription(pc, s, "the file omits the subscription; the subscriber tables are left in place")
	}
	if b.readdPublication(pd, pc) {
		// independent_agent changes (properties.go): every kept subscription
		// is dropped in step 4 and added back in step 9 as the file
		// declares it, so none is changed.
		for _, sp := range spairs {
			if b.readdSubscription(pd, pc, sp) {
				adds = append(adds, sp.Des)
			}
		}
		return adds
	}
	for _, sp := range spairs {
		b.changeSubscription(pd, pc, ppath, sp)
	}
	return adds
}

// articleList is the @article values of the sp_addsubscription calls that
// create s on p: N'all' when the file subscribes every article (nil:
// normalization writes nil for a list of every article, and refuses one
// that names an article twice), otherwise the names of the subset, as the
// publication writes them (normalization refuses a subset where
// SubsetAllowed is false, 14100 and 14122).
func (b *builder) articleList(p *model.Publication, s *model.Subscription, path string) ([]string, bool) {
	if len(s.Articles) == 0 {
		return []string{"all"}, true
	}
	var names []string
	for _, n := range s.Articles {
		found := ""
		for _, a := range p.Articles {
			if strings.EqualFold(a.Name, n) {
				found = a.Name
			}
		}
		if found == "" {
			b.refuse(path+".articles", "article %s of subscription %s is not an article of publication %s", n, s.Key(), p.Name)
			return nil, false
		}
		names = append(names, found)
	}
	return names, true
}

// addSubscription adds a subscription of the file (step 9, spec
// "Subscriptions"). Push: sp_addsubscription, at once followed by
// sp_addpushsubscription_agent (consecutive Order keys: on 2022 the first
// call creates and starts the job, O13), then the other articles of a
// subset. Pull: sp_addsubscription @subscription_type = N'pull' at the
// publisher, then sp_addpullsubscription (@subscription_type = N'pull',
// @independent_agent and @immediate_sync from the publication, R15) and
// sp_addpullsubscription_agent at the subscriber, in the subscription
// database. Only the publisher-side calls carry the add_subscription entry,
// so new_snapshot is counted once (Task 9). R21: initialization from an LSN
// and a pull subscription to a publication without independent_agent are
// refused.
func (b *builder) addSubscription(pd *model.Publication, s *model.Subscription) {
	path := subPath(pd.Name, s)
	pubType := stringOr(pd.Type, "transactional")
	typ := stringOr(s.Type, "push")
	if stringOr(s.Initialization, initSnapshot) == "lsn" {
		b.refuse(path+".initialization", "%s", r21Lsn)
		return
	}
	if typ == "pull" && !boolOf(pd.IndependentAgent) {
		b.refuse(path+".type", r21PullShared, pd.Name)
		return
	}
	articles, ok := b.articleList(pd, s, path)
	if !ok {
		return
	}
	object := "push_subscription"
	if typ == "pull" {
		object = "pull_subscription"
	}
	ctx := normalize.Context{Object: object, PubType: pubType}
	key := pd.Name + sep + subKey(s.Key()) + sep + "add" + sep
	affects := func(art string) Affects {
		a := Affects{Publications: []string{pd.Name}, Subscriptions: []string{s.Key()}}
		if art != "all" {
			a.Articles = []string{art}
		}
		return a
	}
	var later []Param // R36, once the first call has created the subscription
	for i, art := range articles {
		id := subscriptionParams(pd.Name, art, s)
		if typ == "pull" {
			id = append(id, Param{Name: "@subscription_type", Value: literal("pull")})
		}
		order := key + "1"
		if i > 0 {
			if later == nil {
				if later, ok = b.extensionTypes(path, s, s); !ok {
					return
				}
			}
			id = append(id, later...)
			order = fmt.Sprintf("%s3%s%04d", key, sep, i)
		}
		call, err := creationCall("sp_addsubscription", s, ctx, id)
		if err != nil {
			b.refuse(path, "%v", err)
			return
		}
		op := b.newOp(9, order, "subscription", "add", path, call)
		if !b.withEntry(&op, cost.OpAddSubscription, pubType) {
			return
		}
		op.Affects = affects(art)
		op.Reason = "the file declares a subscription that does not exist"
		op.Sources = append(op.Sources, "spec Strategies (Subscriptions)", "spec Order step 9")
		if b.readd[pd.Name+sep+subKey(s.Key())] {
			// Spec "Publication properties" and "Subscriptions": re-added
			// with snapshot initialization, a reinitialization that replaces
			// the data of the articles whose pre_creation_cmd is drop, delete
			// or truncate.
			op.readd = true
			op.Costs = []Cost{CostDropAndReadd}
			op.replacesData = len(subArticles(pd, s, art, destructive)) > 0
			op.keepsRows = subArticles(pd, s, art, func(c *string) bool { return stringOr(c, "") == "none" })
			op.Reason = "the subscription is added back after the change of independent_agent"
			op.Sources = append(op.Sources, "spec Strategies (Publication properties)", "02-matrix P26")
		}
		b.add(op)
		if i == 0 && typ == "push" && !b.pushAgent(pd, s, path, key+"2") {
			return
		}
	}
	if typ == "pull" {
		b.pullSubscription(pd, s, path, key)
	}
}

// subArticles is the articles of a re-add call (art, or every article the
// subscription covers for N'all') whose pre_creation_cmd satisfies cmd.
func subArticles(pd *model.Publication, s *model.Subscription, art string, cmd func(*string) bool) []string {
	var out []string
	for i := range pd.Articles {
		a := &pd.Articles[i]
		if (art == "all" && covers(s, a.Name) || strings.EqualFold(a.Name, art)) && cmd(a.PreCreationCmd) {
			out = append(out, a.Name)
		}
	}
	return out
}

// pushAgent is sp_addpushsubscription_agent, for the subscription's own
// agent or, on a publication without independent_agent, for the shared
// agent of its subscriber database the file declares (lab/setup.sql creates
// SalesRef's that way).
func (b *builder) pushAgent(pd *model.Publication, s *model.Subscription, path, order string) bool {
	pubType := stringOr(pd.Type, "transactional")
	var obj any = s.DistributionAgent
	object := "push_agent"
	if !boolOf(pd.IndependentAgent) {
		// Measured by the Task 12 review: sp_addpushsubscription_agent on an
		// existing shared agent drops and re-creates its job (new job_id,
		// history lost, re-enabled and started, description reset), while
		// sp_addsubscription alone keeps it. So none is emitted when the
		// agent exists or this plan creates it earlier; its property changes
		// are the agents strategy's (Task 14).
		k := subKey(s.Key())
		if b.sharedPushExists(s) {
			return true
		}
		if b.sharedPush == nil {
			b.sharedPush = map[string]bool{}
		}
		b.sharedPush[k] = true
		object = "shared_push_agent"
		var shared *model.DistributionAgent
		for i := range b.des.Publisher.SharedDistributionAgents {
			a := &b.des.Publisher.SharedDistributionAgents[i]
			if strings.EqualFold(a.Subscriber, s.Subscriber) && strings.EqualFold(a.Database, s.Database) {
				shared = &a.DistributionAgent
			}
		}
		obj = shared
	}
	call, err := creationCall("sp_addpushsubscription_agent", obj, normalize.Context{Object: object, PubType: pubType}, []Param{
		{Name: "@publication", Value: literal(pd.Name)},
		{Name: "@subscriber", Value: literal(s.Subscriber)},
		{Name: "@subscriber_db", Value: literal(s.Database)},
	})
	if err != nil {
		b.refuse(path+".distribution_agent", "%v", err)
		return false
	}
	op := b.newOp(9, order, "push_agent", "add", path+".distribution_agent", call)
	op.Affects = Affects{Publications: []string{pd.Name}, Subscriptions: []string{s.Key()}}
	op.Reason = "the distribution agent of the push subscription, right after sp_addsubscription: between the two the job runs under the Agent service account (O13)"
	op.Sources = append(op.Sources, "spec Strategies (Subscriptions)", "note O13")
	b.add(op)
	return true
}

// sharedPushExists tells whether the shared distribution agent of s's
// subscriber database exists at this point of the plan: created by an
// earlier addition of the plan, or current and still serving a current
// subscription the plan does not drop. Measured by the Task 12 review:
// dropping the last push subscription of a shared distribution agent drops
// the agent's row and its job (a shared pull agent stays). Every whole drop
// goes through dropSubscription, which records it, so a strategy that drops
// and re-adds (Task 13) must drop before it adds.
func (b *builder) sharedPushExists(s *model.Subscription) bool {
	if b.sharedPush[subKey(s.Key())] {
		return true
	}
	exists := false
	for _, a := range b.cur.Publisher.SharedDistributionAgents {
		exists = exists || strings.EqualFold(a.Subscriber, s.Subscriber) && strings.EqualFold(a.Database, s.Database)
	}
	if !exists {
		return false
	}
	served := false
	for _, p := range b.cur.Publications {
		if boolOf(p.IndependentAgent) {
			continue
		}
		for _, o := range p.Subscriptions {
			if stringOr(o.Type, "push") != "push" || !strings.EqualFold(o.Subscriber, s.Subscriber) || !strings.EqualFold(o.Database, s.Database) {
				continue
			}
			served = true
			if !b.dropped[p.Name+sep+subKey(o.Key())] {
				return true // a subscription keeps the agent
			}
		}
	}
	// A current shared agent that serves no current subscription (an
	// orphan the export shows) is taken as existing: no row measured it.
	return !served
}

// pubIdentity names the publication in the procedures that run at the
// subscriber.
func (b *builder) pubIdentity(pub string) []Param {
	return []Param{
		{Name: "@publisher", Value: literal(b.des.Publisher.Server)},
		{Name: "@publisher_db", Value: literal(b.des.Publisher.Database)},
		{Name: "@publication", Value: literal(pub)},
	}
}

// atSubscriber moves an operation to the subscriber's subscription
// database.
func atSubscriber(op *Operation, s *model.Subscription) {
	op.Server, op.Database = s.Subscriber, s.Database
}

// pullSubscription is sp_addpullsubscription and sp_addpullsubscription_agent
// at the subscriber. @subscription_type = N'pull' is always passed: left
// out, the subscriber records an anonymous subscription (08-pull P1.omitted).
// @independent_agent and @immediate_sync are the publication's (R15): the
// subscriber stores them with a default of 1.
func (b *builder) pullSubscription(pd *model.Publication, s *model.Subscription, path, key string) {
	pubType := stringOr(pd.Type, "transactional")
	id := append(b.pubIdentity(pd.Name),
		Param{Name: "@independent_agent", Value: literal(strconv.FormatBool(boolOf(pd.IndependentAgent)))},
		Param{Name: "@immediate_sync", Value: literal(strconv.FormatBool(boolOf(pd.ImmediateSync)))},
		Param{Name: "@subscription_type", Value: literal("pull")})
	call, err := creationCall("sp_addpullsubscription", s, normalize.Context{Object: "subscriber_pull_subscription", PubType: pubType}, id)
	if err != nil {
		b.refuse(path, "%v", err)
		return
	}
	affects := Affects{Publications: []string{pd.Name}, Subscriptions: []string{s.Key()}}
	op := b.newOp(9, key+"4", "pull_subscription", "add", path, call)
	atSubscriber(&op, s)
	op.Affects = affects
	op.Reason = "the pull subscription at the subscriber"
	op.Sources = append(op.Sources, "spec Strategies (Subscriptions)", "08-pull P1.named")
	b.add(op)

	// @publication_type is left at its default, 0 (transactional): the
	// add_subscription entry is measured on transactional publications only,
	// so a snapshot publication's subscription is refused before this call.
	call, err = creationCall("sp_addpullsubscription_agent", s.PullAgent, normalize.Context{Object: "pull_agent", PubType: pubType}, b.pubIdentity(pd.Name))
	if err != nil {
		b.refuse(path+".pull_agent", "%v", err)
		return
	}
	op = b.newOp(9, key+"5", "pull_agent", "add", path+".pull_agent", call)
	atSubscriber(&op, s)
	op.Affects = affects
	op.Reason = "the distribution agent of the pull subscription, at the subscriber"
	op.Sources = append(op.Sources, "spec Strategies (Subscriptions)", "08-pull P1.named")
	b.add(op)
}

// dropSubscription drops a whole subscription (step 4): for a pull one,
// sp_droppullsubscription at the subscriber first, then sp_dropsubscription
// @article = N'all' at the publisher, which leaves nothing at either step;
// the other order leaves the pull agent running and logging 21021 (08-pull
// P3.subscriber-first.*, P3.publisher-first.*). A pull subscription that is
// the last of its subscriber database's shared pull agent leaves that job
// behind (warning). It returns false when the drop is refused.
func (b *builder) dropSubscription(pc *model.Publication, s *model.Subscription, reason string) bool {
	sp := subPath(pc.Name, s)
	pubType := stringOr(pc.Type, "transactional")
	key := pc.Name + sep + subKey(s.Key()) + sep
	affects := Affects{Publications: []string{pc.Name}, Subscriptions: []string{s.Key()}}
	if stringOr(s.Type, "push") == "pull" {
		op := b.newOp(4, key+"1", "pull_subscription", "drop", sp,
			Call{Procedure: "sp_droppullsubscription", Params: b.pubIdentity(pc.Name)})
		atSubscriber(&op, s)
		op.Affects = affects
		if b.lastOfSharedPull(pc, s) {
			op.Warnings = append(op.Warnings, sharedPullStays)
			op.Costs = []Cost{CostSubscriberObjectLeft}
		}
		op.Reason = "the pull subscription is dropped at the subscriber first, then at the publisher (08-pull P3.subscriber-first)"
		op.Sources = append(op.Sources, "08-pull P3.subscriber-first.step1", "08-pull P3.subscriber-first.step2")
		b.add(op)
	}
	op := b.newOp(4, key+"2", "subscription", "drop", sp,
		Call{Procedure: "sp_dropsubscription", Params: subscriptionParams(pc.Name, "all", s)})
	if !b.withEntry(&op, cost.OpDropSubscription, pubType) {
		return false
	}
	op.Affects = affects
	op.Costs = []Cost{CostSubscriberObjectLeft}
	op.Reason = reason
	if b.dropped == nil {
		b.dropped = map[string]bool{}
	}
	b.dropped[pc.Name+sep+subKey(s.Key())] = true
	op.Sources = append(op.Sources, "spec Strategies (Subscriptions: @article = N'all')")
	b.add(op)
	return true
}

// lastOfSharedPull tells a pull subscription to a publication without
// independent_agent (its agent is the shared pull agent of its subscriber
// database) that no pull subscription of the file to another such
// publication of the database keeps.
func (b *builder) lastOfSharedPull(pc *model.Publication, s *model.Subscription) bool {
	if stringOr(s.Type, "push") != "pull" || boolOf(pc.IndependentAgent) {
		return false
	}
	for _, p := range b.des.Publications {
		if boolOf(p.IndependentAgent) {
			continue
		}
		for _, o := range p.Subscriptions {
			if p.Name == pc.Name {
				continue // this one is dropped
			}
			if stringOr(o.Type, "push") == "pull" && strings.EqualFold(o.Subscriber, s.Subscriber) && strings.EqualFold(o.Database, s.Database) {
				return false
			}
		}
	}
	return true
}

// extensionTypes is R36's @subscription_type and @sync_type, passed by every
// sp_addsubscription on an existing subscription (an extension to an added
// article, a subset addition) whatever R15 would leave out: without them a
// pull extension creates a push row and a second agent, a replication
// support only one a sync_type 1 row. An existing subscription initialized
// from a backup or an LSN is not extended (R21).
func (b *builder) extensionTypes(path string, des, cur *model.Subscription) ([]Param, bool) {
	init := stringOr(cur.Initialization, initSnapshot)
	syncType, err := encSyncType(init)
	if init == "backup" || init == "lsn" || err != nil {
		b.refuse(path, r21Extension, init)
		return nil, false
	}
	subType := stringOr(des.Type, stringOr(cur.Type, "push"))
	return []Param{
		{Name: "@subscription_type", Value: literal(subType)},
		{Name: "@sync_type", Value: syncType},
	}, true
}

// missingArticles is the current publication's articles a current
// subscription misses, when the reader wrote the incomplete finding at its
// articles (internal/reader/publisher.go: only under immediate_sync or a
// concurrent sync_method, where a subset cannot exist).
func (b *builder) missingArticles(pc *model.Publication, s *model.Subscription) ([]string, bool) {
	path := subPath(pc.Name, s) + ".articles"
	found := false
	for _, f := range b.cur.Findings {
		found = found || (f.Kind == model.FindingIncomplete && f.Path == path)
	}
	if !found {
		return nil, false
	}
	var missing []string
	for _, a := range pc.Articles {
		if !covers(s, a.Name) {
			missing = append(missing, a.Name)
		}
	}
	return missing, true
}

// changeSubscription plans a kept subscription: R35 refuses one that misses
// articles, R21 a type change and notes an initialization change; then the
// changes of its article subset and of its agent's properties.
func (b *builder) changeSubscription(pd, pc *model.Publication, ppath string, sp pair[model.Subscription]) {
	path := sp.path(ppath + ".subscriptions")
	if b.skip(path) {
		return
	}
	d, c := sp.Des, sp.Cur
	if missing, ok := b.missingArticles(pc, c); ok {
		// R35: not completed with @article = N'all', whatever the file says
		// of the missing articles.
		b.refuse(path+".articles", r35Missing, c.Key(), strings.Join(missing, ", "))
		return
	}
	if dt, ct := stringOr(d.Type, "push"), stringOr(c.Type, "push"); dt != ct {
		b.refuse(path+".type", r21Type, c.Key(), ct, dt)
		return
	}
	if di, ci := stringOr(d.Initialization, initSnapshot), stringOr(c.Initialization, initSnapshot); di != ci {
		b.notes = append(b.notes, fmt.Sprintf(r21InitNote, c.Key(), pd.Name, ci, di))
	}
	if b.losesEveryArticle(pd, pc, d, c) {
		b.refuse(path+".articles", r12LosesAll, c.Key())
		return
	}
	if !b.skip(path + ".articles") {
		b.subsetChanges(pd, pc, path, d, c)
	}
	for _, ch := range b.diff(path, d, c) {
		rel := strings.TrimPrefix(ch.Pattern, subPrefix)
		switch {
		case rel == "articles" || rel == "type":
			continue // above
		case agentOwned(rel):
			continue // Task 14: profile binding, schedules, job_enabled (R22, R23, R41)
		}
		b.subscriptionProperty(pd, d, c, path, ch)
	}
}

// losesEveryArticle tells a kept subscription whose every current article
// this plan drops from it, by its subset change or because the publication
// drops the article (Task 11, an R20 replacement included), while it keeps
// or gains others. Measured by the Task 12 review: dropping by name every
// article of a subscription removes the subscription and its distribution
// agent, and the following named sp_addsubscription creates a new
// subscription with an implicit agent under the Agent service account,
// losing its streams, job_login, schedule and profile.
func (b *builder) losesEveryArticle(pd, pc *model.Publication, d, c *model.Subscription) bool {
	had := 0
	for i := range pc.Articles {
		a := &pc.Articles[i]
		if !covers(c, a.Name) {
			continue
		}
		had++
		for j := range pd.Articles {
			x := &pd.Articles[j]
			if x.Name == a.Name && !replaced(x, a) && covers(d, x.Name) {
				return false // a current article it keeps
			}
		}
	}
	if had == 0 {
		return false
	}
	for _, x := range pd.Articles {
		if covers(d, x.Name) {
			return true // it gains others
		}
	}
	return false
}

// agentOwned tells an agent property of a subscription whose change is the
// agents strategy's (Task 14): the profile, the schedules and job_enabled.
func agentOwned(rel string) bool {
	for _, agent := range []string{"distribution_agent.", "pull_agent."} {
		if k, ok := strings.CutPrefix(rel, agent); ok {
			return k == "profile" || k == "job_enabled" || k == "schedules" || strings.HasPrefix(k, "schedules[") || strings.HasPrefix(k, "schedules.")
		}
	}
	return false
}

// subsetChanges plans the change of a kept subscription's articles among the
// articles the publication keeps (an article the plan adds or drops is Task
// 11's): one sp_dropsubscription @article per article removed (step 4), one
// extension by name per article added (step 9, R36), only where a subset is
// allowed (SubsetAllowed: by name is 14100 under concurrent and 14122 under
// immediate_sync).
func (b *builder) subsetChanges(pd, pc *model.Publication, path string, d, c *model.Subscription) {
	pubType := stringOr(pd.Type, "transactional")
	var adds, drops []string
	for _, a := range pc.Articles {
		kept := false
		for _, x := range pd.Articles {
			kept = kept || x.Name == a.Name
		}
		if !kept {
			continue
		}
		switch des, cur := covers(d, a.Name), covers(c, a.Name); {
		case des && !cur:
			adds = append(adds, a.Name)
		case cur && !des:
			drops = append(drops, a.Name)
		}
	}
	for _, art := range drops {
		op := b.newOp(4, pc.Name+sep+art+sep+subKey(c.Key()), "subscription_article_drop", "drop", path,
			Call{Procedure: "sp_dropsubscription", Params: subscriptionParams(pc.Name, art, c)})
		if !b.withEntry(&op, cost.OpDropSubscriptionArticle, pubType) {
			return
		}
		op.Affects = Affects{Publications: []string{pc.Name}, Articles: []string{art}, Subscriptions: []string{c.Key()}}
		op.Costs = []Cost{CostSubscriberObjectLeft}
		op.Changes = []PropertyChange{{Path: path + ".articles", Before: art}}
		op.Reason = "the file removes the article from the subscription; the subscriber table is left in place"
		op.Sources = append(op.Sources, "spec Strategies (Subscriptions)")
		b.add(op)
	}
	if len(adds) == 0 {
		return
	}
	if !pd.SubsetAllowed() {
		b.refuse(path+".articles", "extending subscription %s by name to %s is refused on this publication (14100 under concurrent, 14122 under immediate_sync)", c.Key(), strings.Join(adds, ", "))
		return
	}
	types, ok := b.extensionTypes(path, d, c)
	if !ok {
		return
	}
	for _, art := range adds {
		op := b.newOp(9, pd.Name+sep+subKey(c.Key())+sep+"ext"+sep+art, "subscription_extension", "add", path,
			Call{Procedure: "sp_addsubscription", Params: append(subscriptionParams(pd.Name, art, c), types...)})
		if !b.withEntry(&op, cost.OpExtendSubscription, pubType) {
			return
		}
		op.Affects = Affects{Publications: []string{pd.Name}, Articles: []string{art}, Subscriptions: []string{c.Key()}}
		op.namedExtensionCheck = true
		op.Changes = []PropertyChange{{Path: path + ".articles", After: art}}
		op.Reason = "the file adds the article to the subscription"
		op.Sources = append(op.Sources, "spec Strategies (Subscriptions)", "R36")
		b.add(op)
	}
}

// subscriptionProperty is one change call for one changed property of a
// kept subscription (step 10), its entry from cost.Lookup, refused as not
// measured otherwise: sp_changesubscription at the publisher for a push
// agent (07-changes.sh, the sub helper), sp_change_subscription_properties at
// the subscriber for a pull agent (08-pull.sh, CHANGE_CALL).
func (b *builder) subscriptionProperty(pd *model.Publication, d, c *model.Subscription, path string, ch Change) {
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
	rel := strings.TrimPrefix(ch.Pattern, subPrefix)
	v, ok := resolve(d, rel)
	if !ok {
		b.refuse(ch.Path, "%s has no value to set", ch.Pattern)
		return
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
	tail := []Param{{Name: "@property", Value: literal(e.Property)}, {Name: "@value", Value: lit}}
	order := pd.Name + sep + subKey(c.Key()) + sep + "chg" + sep + ch.Path
	var op Operation
	switch e.Procedure {
	case "sp_changesubscription":
		op = b.newOp(10, order, "agent_property", "change", path,
			Call{Procedure: e.Procedure, Params: append(subscriptionParams(pd.Name, "all", c), tail...)})
	case "sp_change_subscription_properties":
		op = b.newOp(10, order, "agent_property", "change", path,
			Call{Procedure: e.Procedure, Params: append(b.pubIdentity(pd.Name), tail...)})
		atSubscriber(&op, c)
	default:
		b.refuse(ch.Path, "no measured call for %s", ch.Pattern)
		return
	}
	op.entry = &e
	for _, ct := range e.Cites {
		op.Sources = append(op.Sources, ct.Row)
	}
	op.Changes = []PropertyChange{{Path: ch.Path, Before: orEmpty(ch.Before), After: orEmpty(ch.After)}}
	op.Affects = Affects{Publications: []string{pd.Name}, Subscriptions: []string{c.Key()}}
	op.Reason = "the subscription's " + rel + " changes"
	b.add(op)
}
