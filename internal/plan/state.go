package plan

import (
	"strings"

	"github.com/rudi-bruchez/sqlserver-replication/internal/cost"
	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
	"github.com/rudi-bruchez/sqlserver-replication/internal/state"
)

// State is the runtime state the plan predicts, operation after operation
// (R10): the flags and the costs of each call are computed from the state
// the earlier operations of the same plan leave, not from the state
// observed before it (spec "Strategies").
type State struct {
	Pubs      map[string]*PubState // by publication name
	LogReader bool
}

// PubState is the predicted state of one publication.
type PubState struct {
	Exists, ImmediateSync, AllowAnonymous, Ready bool
	Type, SyncMethod                             string
	Articles                                     map[string]bool      // name to active bit
	Subs                                         map[string]*SubState // by lower-cased Subscription.Key()
	SnapshotRecurring                            bool                 // R25 refusals read it
	// counted is the articles whose status 1 rows an add or an extension of
	// this plan created and costed new_snapshot: a later change of the
	// article does not count its snapshot again (R34).
	counted map[string]bool
	// wideMarked: a publication-wide reinitialization entry (sync_method
	// from or to concurrent or concurrent_c) was applied by this plan.
	wideMarked bool
}

// SubState is the predicted state of one subscription.
type SubState struct {
	Rows map[string]int // article to publisher status
	// Key is Subscription.Key() as the file or the reader writes it, for the
	// warnings and Affects.
	Key string
	// Init is the subscription's initialization (snapshot,
	// replication_support_only, backup, lsn): it decides the status of the
	// rows an article addition or an extension gives it (R10).
	Init string
	// StartAgent is set whenever an operation of the plan adds rows at 2 to
	// the subscription (a new subscription on a ready immediate_sync
	// publication, 05-snapshot-flag S7; a replication support only, backup
	// or lsn subscription; an article added to or extended into a
	// replication support only subscription): no generation is owed, so its
	// distribution agent has to be started for the delivery (R34). The
	// AgentsToStart list reads it after finish.
	StartAgent bool
}

// Subscription initializations, as the model writes them.
const (
	initSnapshot = "snapshot"
	initRSO      = "replication_support_only"
)

// rowsStartAt2 tells whether a subscription of this initialization gets its
// rows at 2: no snapshot is generated for it. Replication support only:
// D.sp_addsubscription.push.rso.@status; backup and lsn: 10-init-modes
// I2.backup.create and I3.lsn.create, status=2 (R10 as amended by the
// controller, Task 9 fix round 1).
func rowsStartAt2(init string) bool { return init != initSnapshot }

// NewState is the state observed before the plan: the configuration read
// from the servers and its facts. Without facts, the state is the one in
// which every call succeeds: an immediate_sync publication is ready and
// every row of the configuration's subscriptions is at 2, so both flags are
// passed where they may be needed (an unneeded flag is accepted,
// 05-snapshot-flag S2.O1 f10; a missing one fails).
func NewState(cur *model.Config, f *state.Facts) *State {
	st := &State{Pubs: map[string]*PubState{}}
	if cur == nil {
		return st
	}
	st.LogReader = cur.Publisher.LogReaderAgent != nil
	pubFacts := map[string]state.PublicationFacts{}
	subFacts := map[string]state.SubscriptionFacts{}
	if f != nil {
		for _, p := range f.Publications {
			pubFacts[p.Name] = p
		}
		for _, s := range f.Subscriptions {
			subFacts[s.Publication+"\x00"+subKey(s.Subscriber+"/"+s.Database)] = s
		}
		for _, a := range f.Agents {
			if a.Kind == "log_reader" {
				st.LogReader = true
			}
		}
	}
	for _, p := range cur.Publications {
		ps := &PubState{
			Exists:            true,
			ImmediateSync:     boolOf(p.ImmediateSync),
			AllowAnonymous:    boolOf(p.AllowAnonymous),
			Type:              stringOr(p.Type, "transactional"),
			SyncMethod:        stringOr(p.SyncMethod, "native"),
			Articles:          map[string]bool{},
			Subs:              map[string]*SubState{},
			SnapshotRecurring: recurring(p.SnapshotAgent),
		}
		pf, known := pubFacts[p.Name]
		if !known {
			// Not observed: ready if it can be, so the flag is passed.
			ps.Ready = ps.ImmediateSync
		} else {
			ps.Ready = pf.ImmediateSyncReady
		}
		active := map[string]bool{}
		for _, a := range pf.Articles {
			active[a.Name] = a.Active
		}
		for _, a := range p.Articles {
			ps.Articles[a.Name] = active[a.Name] || !known
		}
		for _, s := range p.Subscriptions {
			ss := &SubState{Rows: map[string]int{}, Key: s.Key(), Init: stringOr(s.Initialization, initSnapshot)}
			if sf, ok := subFacts[p.Name+"\x00"+subKey(s.Key())]; ok {
				for _, r := range sf.Rows {
					ss.Rows[r.Article] = r.PublisherStatus
				}
			} else {
				// No observed rows: at 2, the state in which every call
				// succeeds.
				for _, a := range subscribed(p, s) {
					ss.Rows[a] = 2
				}
			}
			ps.Subs[subKey(s.Key())] = ss
		}
		st.Pubs[p.Name] = ps
	}
	return st
}

// subscribed is the articles a subscription of the configuration covers.
func subscribed(p model.Publication, s model.Subscription) []string {
	if len(s.Articles) > 0 {
		return s.Articles
	}
	var names []string
	for _, a := range p.Articles {
		names = append(names, a.Name)
	}
	return names
}

func subKey(k string) string { return strings.ToLower(k) }

func boolOf(b *bool) bool { return b != nil && *b }

func stringOr(s *string, def string) string {
	if s == nil || *s == "" {
		return def
	}
	return *s
}

// recurring tells whether a snapshot agent's job starts it again by
// itself (R25): the job is enabled and has an enabled schedule whose
// frequency is neither once (one time) nor agent_start, nor empty (on
// demand: the model has no frequency name for it). An unknown frequency
// counts as recurring, the cautious reading for the deferral refusal.
func recurring(a *model.Agent) bool {
	if a == nil || a.Schedules == nil || (a.JobEnabled != nil && !*a.JobEnabled) {
		return false
	}
	for _, s := range *a.Schedules {
		if s.Enabled != nil && !*s.Enabled {
			continue
		}
		switch s.Frequency {
		case "once", "agent_start", "":
			continue
		}
		return true
	}
	return false
}

// Pending tells whether a snapshot is pending for a publication (R12): a
// subscription row is at publisher status 1, or, on a publication without
// immediate_sync, a subscribed article is inactive. On an immediate_sync
// publication sp_addarticle sets the active bit at once, so only status 1
// signals there.
func (s *State) Pending(pub string) bool {
	ps := s.Pubs[pub]
	if ps == nil || !ps.Exists {
		return false
	}
	for _, sub := range ps.Subs {
		for a, status := range sub.Rows {
			if status == 1 {
				return true
			}
			if !ps.ImmediateSync && !ps.Articles[a] {
				return true
			}
		}
	}
	return false
}

// The force flags, as finish adds them and apply reads them.
const (
	paramInvalidate = "@force_invalidate_snapshot"
	paramReinit     = "@force_reinit_subscription"
)

// apply moves the state past one operation, after finish has added its
// flags (R10). It reads the operation's identity from Affects: the
// publication is Affects.Publications[0], the operated article
// Affects.Articles[0], the subscription of a subscription operation
// Affects.Subscriptions[0]; and the values the server is told from the
// call: the flags, @article and @sync_type of sp_addsubscription, the
// properties of sp_addpublication.
func (s *State) apply(op *Operation) {
	if op.Kind == "log_reader_agent" && op.Action == "add" {
		s.LogReader = true
		return
	}
	if op.Kind == "publication" && op.Action == "add" {
		s.addPublication(op)
		return
	}
	if op.Kind == "article" && op.Action == "add" && op.entry == nil {
		// An article of a publication this plan creates (no entry: Task 11
		// fix round 1): no subscription exists yet.
		if ps := s.Pubs[first(op.Affects.Publications)]; ps != nil {
			ps.Articles[first(op.Affects.Articles)] = ps.ImmediateSync
		}
		return
	}
	if op.Kind != "generate_and_wait" && (op.entry == nil || scopeOf(op.entry) == scopeNone) {
		return // distributor, profiles, agents outside a publication, jobs
	}
	ps := s.resolve(op)
	if op.Kind == "generate_and_wait" {
		// R10: "generate and wait" sets every row of the publication to 2,
		// and the generation sets every article active.
		for a := range ps.Articles {
			ps.Articles[a] = true
		}
		for _, sub := range ps.Subs {
			for a := range sub.Rows {
				sub.Rows[a] = 2
			}
		}
		return
	}
	e := op.entry
	art := first(op.Affects.Articles)
	if flagSet(op, paramInvalidate) {
		ps.Ready = false // 15-snapshot-scope C.*: in_tran:ready=0
	}
	switch e.Change {
	case cost.OpAddArticle:
		s.addArticle(op, ps, art)
		return
	case cost.OpAddSubscription:
		s.addSubscription(op, ps)
		return
	case cost.OpExtendSubscription:
		s.extendSubscription(op, ps)
		return
	case cost.OpDropArticle:
		delete(ps.Articles, art)
		for _, sub := range ps.Subs {
			delete(sub.Rows, art)
		}
		return
	case cost.OpDropSubscription:
		delete(ps.Subs, subKey(first(op.Affects.Subscriptions)))
		return
	case cost.OpDropSubscriptionArticle:
		if sub := ps.Subs[subKey(first(op.Affects.Subscriptions))]; sub != nil {
			delete(sub.Rows, art)
		}
		return
	case cost.OpDropPublication:
		ps.Exists = false
		ps.Subs = map[string]*SubState{}
		left := false
		for _, other := range s.Pubs {
			left = left || other.Exists
		}
		if !left {
			s.LogReader = false // 13-transient T02
		}
		return
	}
	if e.Wide && e.Class == cost.SnapshotReinit {
		ps.wideMarked = true
	}
	if flagSet(op, paramReinit) {
		// C.*.schema_option, C.native.sync_method: the operated article's
		// rows, or every row for a Wide entry, go to 1. A replication support
		// only subscription keeps its rows at 2: measured on 2022 CU27 by the
		// review of plan 4 Task 4, a reinit-flagged sp_changearticle leaves
		// its status 2 and sp_reinitsubscription refuses it ("subscribed with
		// the 'no sync' option"). Backup and lsn subscriptions are not
		// measured and are marked as before.
		for _, sub := range ps.Subs {
			if !marksOnReinit(sub) {
				continue
			}
			for a := range sub.Rows {
				if e.Wide || a == art {
					sub.Rows[a] = 1
					// The change carries reinitialization and new_snapshot
					// for these rows: counted once (R34).
					ps.count(a)
				}
			}
		}
	}
	switch e.Change {
	case "publications[*].immediate_sync":
		// B.*.1b: false leaves ready 0; B.*.4a: true leaves it 0.
		ps.ImmediateSync = e.Dir == "to_true"
		ps.Ready = false
	case "publications[*].allow_anonymous":
		ps.AllowAnonymous = e.Dir == "to_true"
		if e.Dir == "to_false" {
			ps.Ready = false // B.*.1a
		}
	case "publications[*].sync_method":
		if i := strings.Index(e.Dir, ">"); i >= 0 {
			ps.SyncMethod = e.Dir[i+1:]
		}
	}
}

func (s *State) addPublication(op *Operation) {
	name := first(op.Affects.Publications)
	if name == "" {
		name, _ = paramString(op, "@publication")
	}
	ps := &PubState{Exists: true, Type: "transactional", SyncMethod: "native", Articles: map[string]bool{}, Subs: map[string]*SubState{}}
	// The parameters left out are at their defaults (R15; 11-defaults
	// D.sp_addpublication.*: immediate_sync, allow_anonymous false, native).
	if v, ok := paramString(op, "@repl_freq"); ok && v == "snapshot" {
		ps.Type = "snapshot"
	}
	if v, ok := paramString(op, "@sync_method"); ok {
		ps.SyncMethod = strings.ReplaceAll(v, " ", "_")
	}
	if v, ok := paramString(op, "@immediate_sync"); ok {
		ps.ImmediateSync = v == "true"
	}
	if v, ok := paramString(op, "@allow_anonymous"); ok {
		ps.AllowAnonymous = v == "true"
	}
	s.Pubs[name] = ps
	// sp_addpublication on a database without a log reader creates one
	// (R10, campaign item 19).
	s.LogReader = true
}

// addArticle: on an immediate_sync publication sp_addarticle subscribes
// every subscription by itself, a snapshot-initialized one with a row at 1
// (15-snapshot-scope C.*.addarticle), a replication support only one with a
// row at 2 (the fold review), and sets the active bit at once (R12). A
// backup or lsn subscription there is refused before finish (R34).
func (s *State) addArticle(op *Operation, ps *PubState, art string) {
	ps.Articles[art] = ps.ImmediateSync
	if !ps.ImmediateSync {
		return
	}
	for _, sub := range sortedSubs(ps) {
		switch sub.Init {
		case initSnapshot:
			sub.Rows[art] = 1
			ps.count(art)
		case initRSO:
			sub.Rows[art] = 2
			sub.StartAgent = true
			op.Warnings = append(op.Warnings, rsoWarning(art, sub.Key))
		}
	}
}

func (ps *PubState) count(art string) {
	if ps.counted == nil {
		ps.counted = map[string]bool{}
	}
	ps.counted[art] = true
}

// addSubscription: rows at 2 when the publication has immediate_sync and is
// ready (05-snapshot-flag S7) or the subscription is not snapshot-initialized
// (rowsStartAt2), at 1 otherwise (11-defaults
// D.sp_addsubscription.push.@status).
func (s *State) addSubscription(op *Operation, ps *PubState) {
	key := first(op.Affects.Subscriptions)
	init := syncTypeInit(op)
	sub := ps.Subs[subKey(key)]
	if sub == nil {
		sub = &SubState{Rows: map[string]int{}, Key: key, Init: init}
		ps.Subs[subKey(key)] = sub
	}
	status := 1
	if rowsStartAt2(init) || (ps.ImmediateSync && ps.Ready) {
		status = 2
	}
	added := false
	for _, a := range callArticles(op, ps, sub) {
		sub.Rows[a] = status
		added = true
	}
	if added && status == 2 {
		sub.StartAgent = true
	}
}

// extendSubscription: status 1 rows for a snapshot-initialized subscription
// (D.non_native.extend_rule, 11-defaults
// D.sp_addsubscription.extend.pull.@status), status 2 for a replication
// support only one (D.sp_addsubscription.extend.rso.@status).
func (s *State) extendSubscription(op *Operation, ps *PubState) {
	sub := ps.Subs[subKey(first(op.Affects.Subscriptions))]
	if sub == nil {
		return
	}
	status := 1
	if rowsStartAt2(sub.Init) {
		status = 2 // a backup or lsn extension is refused before finish (R21)
	}
	for _, a := range callArticles(op, ps, sub) {
		sub.Rows[a] = status
		if status == 2 {
			sub.StartAgent = true
			op.Warnings = append(op.Warnings, rsoWarning(a, sub.Key))
		} else {
			ps.count(a)
		}
	}
}

// marksOnReinit tells a subscription whose rows a reinitialization sets to
// 1: every one but a replication support only one (see apply).
func marksOnReinit(sub *SubState) bool { return sub.Init != initRSO }

// The scopes of a cost entry: what the operation must name in Affects.
const (
	scopeNone         = iota // distributor, profiles, log reader, jobs
	scopePublication         // Affects.Publications[0]
	scopeArticle             // and Affects.Articles[0]
	scopeSubscription        // and Affects.Subscriptions[0]
)

func scopeOf(e *cost.Entry) int {
	switch e.Change {
	case cost.OpAddArticle, cost.OpDropArticle, cost.OpArticleFilter, cost.OpArticleView, cost.OpArticleColumn:
		return scopeArticle
	case cost.OpAddSubscription, cost.OpExtendSubscription, cost.OpDropSubscription, cost.OpDropSubscriptionArticle:
		return scopeSubscription
	case cost.OpDropPublication:
		return scopePublication
	}
	switch {
	case strings.HasPrefix(e.Change, "publications[*].articles[*]."):
		return scopeArticle
	case strings.HasPrefix(e.Change, "publications[*]."):
		return scopePublication
	}
	return scopeNone
}

// resolve returns the state of the publication an operation acts on, and
// panics when the operation does not name what its entry's scope needs: a
// programmer error of the strategies (Tasks 10 to 15), never user input.
func (s *State) resolve(op *Operation) *PubState {
	name := first(op.Affects.Publications)
	ps := s.Pubs[name]
	if ps == nil || !ps.Exists {
		panic("plan: " + opName(op) + ": Affects.Publications[0] " + strconvQuote(name) + " names no publication of the predicted state")
	}
	if op.entry == nil {
		return ps
	}
	sc := scopeOf(op.entry)
	if sc == scopeArticle && first(op.Affects.Articles) == "" {
		panic("plan: " + opName(op) + ": no Affects.Articles[0] for an article-scoped entry")
	}
	if sc == scopeSubscription && first(op.Affects.Subscriptions) == "" {
		panic("plan: " + opName(op) + ": no Affects.Subscriptions[0] for a subscription-scoped entry")
	}
	if op.entry.Change == cost.OpDropSubscriptionArticle && first(op.Affects.Articles) == "" {
		panic("plan: " + opName(op) + ": no Affects.Articles[0] for drop_subscription_article")
	}
	return ps
}

func opName(op *Operation) string {
	n := op.Kind + " " + op.Action + " " + op.Path
	if op.entry != nil {
		n += " (" + op.entry.Change + ")"
	}
	return n
}

func strconvQuote(s string) string { return "\"" + s + "\"" }

func rsoWarning(art, sub string) string {
	return "the table of article " + art + " must exist at the subscriber of " + sub + ": a replication support only subscription receives no snapshot of it"
}

// callArticles is what an sp_addsubscription call subscribes: the named
// article, or with N'all' (or no @article) every article of the
// publication the subscription does not have yet.
func callArticles(op *Operation, ps *PubState, sub *SubState) []string {
	if v, ok := paramString(op, "@article"); ok && v != "all" {
		if _, has := sub.Rows[v]; has {
			return nil
		}
		return []string{v}
	}
	var out []string
	for _, a := range sortedKeys(ps.Articles) {
		if _, has := sub.Rows[a]; !has {
			out = append(out, a)
		}
	}
	return out
}

// syncTypeInit reads the initialization from @sync_type (the encSyncType
// words; left out, automatic).
func syncTypeInit(op *Operation) string {
	v, ok := paramString(op, "@sync_type")
	if !ok {
		return initSnapshot
	}
	switch v {
	case "automatic":
		return initSnapshot
	case "replication support only":
		return initRSO
	case "initialize with backup":
		return "backup"
	case "initialize from lsn":
		return "lsn"
	}
	return v
}

// agentStatus is the state of an agent (R13), against the publication's
// last_generation: unknown when the job is nil or does not exist; retrying
// when the last history row has runstatus 5; failed when last_failure is at
// or after since and the last history row has runstatus 6; running when the
// job runs; stopped otherwise. A runstatus 5 row is never a failure.
func agentStatus(a state.AgentFacts, since string) string {
	switch {
	case a.Job == nil || !a.Job.Exists:
		return "unknown"
	case a.LastHistory != nil && a.LastHistory.RunStatus == 5:
		return "retrying"
	case a.LastFailure != nil && a.LastFailure.Time >= since && a.LastHistory != nil && a.LastHistory.RunStatus == 6:
		return "failed"
	case a.Job.Running:
		return "running"
	}
	return "stopped"
}

func first(xs []string) string {
	if len(xs) == 0 {
		return ""
	}
	return xs[0]
}

// paramString returns the unquoted value of a call parameter: N'x' gives x.
func paramString(op *Operation, name string) (string, bool) {
	for _, p := range op.Call.Params {
		if p.Name == name {
			v := p.Value
			if strings.HasPrefix(v, "N'") && strings.HasSuffix(v, "'") && len(v) >= 3 {
				v = strings.ReplaceAll(v[2:len(v)-1], "''", "'")
			}
			return v, true
		}
	}
	return "", false
}

// flagSet tells whether the call passes a flag as 1.
func flagSet(op *Operation, name string) bool {
	v, ok := paramString(op, name)
	return ok && (v == "1" || v == "true")
}
