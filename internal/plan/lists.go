package plan

import (
	"fmt"
	"sort"
	"strings"

	"github.com/rudi-bruchez/sqlserver-replication/internal/cost"
	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
	"github.com/rudi-bruchez/sqlserver-replication/internal/state"
)

// The plan-level lists of spec "What a plan is" (Task 15): the refusals of
// R18, R26 and the preconditions, the preconditions, R24's job operations,
// the secrets, the agents apply starts, the warnings and the notes.

// The texts of the plan-level lists.
const (
	r18Version       = "the cost table holds measurements of SQL Server 2022 (16.x) only; %s runs %s"
	r24NoJob         = "the job of %s does not exist; sp_update_job would fail with 14262"
	r24SharedPull    = "the shared pull agent of %s is not started by apply: its job lookup at the subscriber is not measured; the delivery waits for its next run"
	r26NotMeasured   = "%s; repair of this state is not measured"
	r29Unreachable   = "%s runs at subscriber %s, which cannot be reached (%s) (R29)"
	r29NoCheck       = "%s runs at %s, of which the checks hold no row: no check of server %s (R29)"
	tableMissing     = "table %s does not exist in %s: plan does not create published tables (spec Non-goals)"
	tableNoKey       = "table %s has no primary key: a table article of a transactional publication needs one (error 14088)"
	subDBMissing     = "subscriber database %s does not exist at %s: plan does not create subscriber databases (spec Non-goals)"
	keyColumnOut     = "column %s of %s is part of its primary key and cannot be excluded (21250, measured)"
	profileMissing   = "profile %s (%s) exists neither in the file nor at the distributor"
	editionNeeded    = "sync_method %s needs the Enterprise or Developer edition of the publisher; %s runs %s"
	folderWarning    = "snapshot folder %s is not visible to the SQL Server service at %s: the snapshot agent cannot write there unless it exists and the agent's account can reach it (plan does not create it, spec Non-goals)"
	serverNameWrong  = "server %s answers as %s: check -server"
	lockWarning      = "publication %s uses %s, which locks the published tables for most of each generation; moving to concurrent costs %s; concurrent and concurrent_c still lock the tables briefly near the start and the end of each run; the cost of a move to database snapshot is not measured"
	fullGenWarning   = "publication %s generates every article at every run of its snapshot agent (%s)"
	agentWarning     = "distribution agent of %s is %s; plan cannot see a snapshot generated and not delivered (campaign item 14)"
	logReaderWarning = "log reader agent of %s is %s; subscription %s of %s has rows at status 3 in MSsubscriptions, which wait for its SYNCDONE token (O18)"
	commandWarning   = "the command line of %s holds %s, which the replication procedures do not write: plan neither compares nor sets it (R32)"
	deferredNote     = "full generation deferred to the next run of the snapshot agent of %s"
	pendingNote      = "publication %s already awaits a snapshot before this plan"
	restoreImmNote   = "restoring immediate_sync on %s: the next run of its snapshot agent generates every article (the remainder of a deferred snapshot, if one was interrupted)"
)

// precondSubscriberDB is the name of a subscriber database's precondition;
// the summary writes its object with its server (Task 18 fix round 1).
const precondSubscriberDB = "subscriber database"

// Precondition statuses.
const (
	precondOK        = "ok"
	precondFailed    = "failed"
	precondUnchecked = "unchecked"
)

// repairSuffixes are the paths of the incomplete findings the plan repairs
// (R26): the snapshot agent (repairSnapshotAgent) and the log reader
// (publicationDatabase), the filter clause without procedure and the filter
// procedure without clause (the article's filter is planned again), the
// synchronization view out of step (its view is planned again). Any other
// incomplete finding is refused.
var repairSuffixes = []string{".snapshot_agent", ".log_reader_agent", ".filter", ".sync_object"}

// incomplete refuses an incomplete finding of the current configuration that
// no rule repairs (R26). A subscription missing articles is R35's
// (changeSubscription), refused or planned there.
func (b *builder) incomplete(f model.Finding) {
	if strings.HasPrefix(f.Path, "publications[") && strings.Contains(f.Path, ".subscriptions[") && strings.HasSuffix(f.Path, ".articles") {
		return
	}
	for _, s := range repairSuffixes {
		if strings.HasSuffix(f.Path, s) && !b.agentKept(f.Path) {
			return
		}
	}
	if b.droppedWithoutJob(f.Path) {
		return
	}
	b.refuse(f.Path, r26NotMeasured, f.Message)
}

// droppedWithoutJob tells the agent of a push subscription whose job was
// deleted by hand, when the file omits the subscription or its publication:
// the plan drops it whole, with sp_dropsubscription @article = N'all', which
// succeeds in that state and leaves no transaction open (measured by the
// final review, minor 8). Any other operation on such a subscription stays
// refused, a drop of a pull subscription (sp_droppullsubscription first)
// too: not measured.
func (b *builder) droppedWithoutJob(path string) bool {
	for i := range b.cur.Publications {
		pc := &b.cur.Publications[i]
		for j := range pc.Subscriptions {
			s := &pc.Subscriptions[j]
			if path != subPath(pc.Name, s)+".distribution_agent" || stringOr(s.Type, "push") != "push" ||
				!b.jobMissing("distribution", pc.Name, s.Subscriber, s.Database) {
				continue
			}
			pd := pubNamed(b.des, pc.Name)
			if pd == nil {
				return true
			}
			_, _, drops := matchSubscriptions(pd.Subscriptions, []model.Subscription{*s})
			return len(drops) == 1
		}
	}
	return false
}

// agentKept tells an incomplete finding at an agent the current
// configuration has (its job missing, unrecorded or without its replication
// step): the plan creates only a missing agent, so it repairs none of these
// (controller's ruling of the Task 15 review; sp_addpublication_snapshot is
// the only repair that creates a job).
func (b *builder) agentKept(path string) bool {
	if path == "publisher.log_reader_agent" {
		return b.cur.Publisher.LogReaderAgent != nil
	}
	if pub, ok := strings.CutSuffix(path, ".snapshot_agent"); ok {
		for i := range b.cur.Publications {
			if pubPath(b.cur.Publications[i].Name) == pub {
				return b.cur.Publications[i].SnapshotAgent != nil
			}
		}
	}
	return false
}

// lists fills the plan-level lists of p, once the strategies and finish have
// run; before is the state observed before the plan. A refusal of any list
// empties the operations (R3).
func (b *builder) lists(p *Plan, before *State) {
	after := b.st
	if after == nil {
		after = before
	}
	if len(b.refusals) == 0 {
		p.AgentsToStart = b.agentsToStart(before)
		p.Operations = b.addJobOps(p.Operations, p.AgentsToStart)
	}
	p.Preconditions = b.preconditions(p.Operations)
	b.unreachable(append(append([]Operation{}, b.ops...), p.Operations...))
	b.planWarnings(after)
	b.planNotes(before)
	if len(b.refusals) > 0 {
		p.Operations, p.AgentsToStart = nil, nil
	}
	p.Secrets = b.secrets(p.Operations)
}

// agentsToStart is R24's list: the snapshot agent of each publication
// pending after the last operation or before the plan, then the
// distribution agent of each subscription owed a delivery: rows the
// generation sets (at 1, or of an inactive article without immediate_sync),
// or rows at 2 that no generation precedes (SubState.StartAgent). A shared
// pull agent is not listed, with a warning: its job lookup is not measured.
//
// A publication the plan defers (defer.go) lists the distribution agent of
// every subscription: its generate_and_wait sets the rows of the added
// articles to 2 before the end, so owes no longer sees them, and the agent
// must deliver them before immediate_sync is restored (final review item
// 3). Their job_start goes between the two (b.deferStarts, addJobOps).
func (b *builder) agentsToStart(before *State) []AgentRef {
	var refs []AgentRef
	seen := map[AgentRef]bool{}
	add := func(r AgentRef) {
		if !seen[r] {
			seen[r] = true
			refs = append(refs, r)
		}
	}
	names := make([]string, 0, len(b.st.Pubs))
	for name := range b.st.Pubs {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		if b.st.Pubs[name].Exists && (b.st.Pending(name) || before.Pending(name)) {
			add(AgentRef{Kind: "snapshot", Publication: name, Reason: "pending"})
		}
	}
	for _, name := range names {
		ps := b.st.Pubs[name]
		if !ps.Exists {
			continue
		}
		deferred := b.deferred(name)
		for _, sub := range sortedSubs(ps) {
			if !sub.StartAgent && !owes(ps, sub) && !deferred {
				continue
			}
			r := b.deliveryAgent(name, sub)
			if r.Kind == "pull_distribution" && r.Publication == "ALL" {
				// As Task 14's job_enabled of a shared pull agent: not measured.
				w := fmt.Sprintf(r24SharedPull, r.Subscriber+"/"+r.Database)
				if !hasString(b.warnings, w) {
					b.warnings = append(b.warnings, w)
				}
				continue
			}
			if deferred {
				if b.deferStarts == nil {
					b.deferStarts = map[AgentRef]string{}
				}
				b.deferStarts[r] = name
			}
			add(r)
		}
	}
	return refs
}

// owes tells a subscription whose rows await a generation.
func owes(ps *PubState, sub *SubState) bool {
	for a, s := range sub.Rows {
		if s == 1 || (!ps.ImmediateSync && !ps.Articles[a]) {
			return true
		}
	}
	return false
}

// deliveryAgent is the distribution agent of a subscription: its own, or
// the shared agent of its subscriber database (publication ALL) on a
// publication without independent_agent; a pull agent is
// pull_distribution.
func (b *builder) deliveryAgent(pub string, sub *SubState) AgentRef {
	var p *model.Publication
	var s *model.Subscription
	for _, c := range []*model.Config{b.des, b.cur} {
		for i := range c.Publications {
			if c.Publications[i].Name != pub {
				continue
			}
			for j := range c.Publications[i].Subscriptions {
				if subKey(c.Publications[i].Subscriptions[j].Key()) == subKey(sub.Key) {
					p, s = &c.Publications[i], &c.Publications[i].Subscriptions[j]
				}
			}
		}
		if s != nil {
			break
		}
	}
	r := AgentRef{Kind: "distribution", Publication: pub, Reason: "delivery"}
	if s == nil {
		k := strings.SplitN(sub.Key, "/", 2)
		r.Subscriber, r.Database = k[0], k[len(k)-1]
		return r
	}
	r.Subscriber, r.Database = s.Subscriber, s.Database
	if c := pubNamed(b.cur, pub); c != nil {
		for i := range c.Subscriptions {
			if cs := &c.Subscriptions[i]; subKey(cs.Key()) == subKey(sub.Key) {
				// The names as stored, for the job lookup (minor 10).
				r.Subscriber, r.Database = cs.Subscriber, cs.Database
			}
		}
	}
	if stringOr(s.Type, "push") == "pull" {
		r.Kind = "pull_distribution"
	}
	if !boolOf(p.IndependentAgent) {
		r.Publication = "ALL"
	}
	return r
}

// facts is the observed agent of kind and publication ("" for the log
// reader, ALL for a shared agent), subscriber and database; nil when not
// observed.
func (b *builder) agentFacts(kind, pub, subscriber, database string) *state.AgentFacts {
	if b.in.Facts == nil {
		return nil
	}
	for i := range b.in.Facts.Agents {
		a := &b.in.Facts.Agents[i]
		if a.Kind == kind && a.Publication == pub && strings.EqualFold(a.Subscriber, subscriber) && strings.EqualFold(a.Database, database) {
			return a
		}
	}
	return nil
}

func hasString(xs []string, s string) bool {
	for _, x := range xs {
		if x == s {
			return true
		}
	}
	return false
}

// jobMissing tells an observed agent whose job does not exist (R24): an
// agent not observed, or whose job's server is not connected, is not.
func (b *builder) jobMissing(kind, pub, subscriber, database string) bool {
	a := b.agentFacts(kind, pub, subscriber, database)
	return a != nil && a.Job != nil && !a.Job.Exists
}

// snapshotEnabled is a publication's snapshot job_enabled (R23: omitted,
// true).
func snapshotEnabled(p *model.Publication) bool {
	return p == nil || p.SnapshotAgent == nil || p.SnapshotAgent.JobEnabled == nil || *p.SnapshotAgent.JobEnabled
}

func pubNamed(c *model.Config, name string) *model.Publication {
	for i := range c.Publications {
		if c.Publications[i].Name == name {
			return &c.Publications[i]
		}
	}
	return nil
}

// addJobOps adds R24's job operations to the finished operations and
// renumbers Seq: a job_disable of the snapshot job of each publication the
// plan operates on (a snapshot job_enabled difference included), in step 0,
// or right after its sp_addpublication_snapshot in step 8 when the plan
// creates the agent (before that call MSsnapshot_agents has a row with
// local_job 0 and a job_id of no job, 14262); a job_restore in step 12 for
// each job disabled, with the file's job_enabled (R23), or for a dropped
// publication the value found, guarded so that it does nothing once the
// drop has deleted the job (R61); then
// a job_start per agent to start, in step 12, or for an agent of a deferral
// between its generate_and_wait and the restore of immediate_sync.
func (b *builder) addJobOps(ops []Operation, refs []AgentRef) []Operation {
	operated := map[string]bool{}
	created := map[string]string{} // the Order of its sp_addpublication_snapshot
	dropped := map[string]bool{}
	createdAgent := map[string]bool{} // "<pub>\x00<lower-cased subscription key>" of a created distribution agent
	for _, op := range ops {
		pub := first(op.Affects.Publications)
		if pub == "" {
			continue
		}
		operated[pub] = true
		switch {
		case op.Kind == "snapshot_agent" && op.Action == "add":
			created[pub] = op.Order
		case op.Kind == "publication" && op.Action == "drop":
			dropped[pub] = true
		case (op.Kind == "push_agent" || op.Kind == "pull_agent") && op.Action == "add":
			createdAgent[pub+sep+subKey(first(op.Affects.Subscriptions))] = true
			createdAgent["ALL"+sep+subKey(first(op.Affects.Subscriptions))] = true
		}
	}
	pairs, _, _ := matchPublications(b.des.Publications, b.cur.Publications)
	for _, pp := range pairs {
		path := pp.path("publications") + ".snapshot_agent"
		if pp.Cur.SnapshotAgent != nil && !b.skip(path+".job_enabled") && snapshotEnabled(pp.Des) != snapshotEnabled(pp.Cur) {
			operated[pp.Des.Name] = true // R23: carried by the restore
		}
	}

	var jobs []Operation
	for _, pub := range sortedKeys(operated) {
		slot := agentSlot{path: pubPath(pub) + ".snapshot_agent", kind: agentSnapshot, pub: pub}
		cur := pubNamed(b.cur, pub)
		order, isNew := created[pub]
		switch {
		case isNew:
			jobs = append(jobs, b.jobOp(8, order+sep+"job", "job_disable", cost.OpJobDisable, slot, "0"))
		case cur == nil || cur.SnapshotAgent == nil:
			continue // no snapshot job
		case b.jobMissing("snapshot", pub, "", ""):
			b.refuse(slot.path, r24NoJob, slot.path)
			continue
		default:
			jobs = append(jobs, b.jobOp(0, pub, "job_disable", cost.OpJobDisable, slot, "0"))
		}
		if dropped[pub] {
			// sp_droppublication deletes the job, but a way out of apply
			// before the drop must not leave it disabled: restored to the
			// value found, by a batch that does nothing once the job is gone
			// (R61).
			op := b.jobOp(12, "1"+sep+pub, "job_restore", cost.OpJobRestore, slot, enabledLiteral(snapshotEnabled(cur)))
			op.Call.Prologue, op.Call.Guard = b.jobFind(slot), "@job_id IS NOT NULL"
			op.Reason = "the snapshot job of the dropped publication is restored to the value found on a way out of apply before the drop; after the drop the job is gone and the call does not run (R61)"
			op.Sources = append(op.Sources, "R61")
			jobs = append(jobs, op)
			continue
		}
		on := snapshotEnabled(pubNamed(b.des, pub))
		if pubNamed(b.des, pub) == nil {
			on = snapshotEnabled(cur)
		}
		op := b.jobOp(12, "1"+sep+pub, "job_restore", cost.OpJobRestore, slot, enabledLiteral(on))
		if !isNew && snapshotEnabled(cur) != on {
			op.Changes = []PropertyChange{{Path: slot.path + ".job_enabled", Before: fmt.Sprint(snapshotEnabled(cur)), After: fmt.Sprint(on)}}
			op.Reason = "the snapshot job is set to the file's job_enabled at the end of the plan (R23, R24)"
		}
		jobs = append(jobs, op)
	}

	for i, r := range refs {
		order := fmt.Sprintf("2%s%04d", sep, i)
		var slot agentSlot
		var factKind string
		isNew := false
		switch r.Kind {
		case "snapshot":
			slot = agentSlot{path: pubPath(r.Publication) + ".snapshot_agent", kind: agentSnapshot, pub: r.Publication}
			factKind, isNew = "snapshot", created[r.Publication] != ""
		default:
			s := &model.Subscription{Subscriber: r.Subscriber, Database: r.Database}
			slot = agentSlot{kind: agentPush, pub: r.Publication, subscriber: r.Subscriber, database: r.Database}
			factKind, isNew = r.Kind, createdAgent[r.Publication+sep+subKey(s.Key())]
			switch {
			case r.Kind == "pull_distribution":
				slot.kind, slot.path = agentPull, subPath(r.Publication, s)+".pull_agent"
			case r.Publication == "ALL":
				slot.kind, slot.path = agentSharedPush, "publisher.shared_distribution_agents"+model.Element(s.Key())+".distribution_agent"
			default:
				slot.path = subPath(r.Publication, s) + ".distribution_agent"
			}
			if r.Publication != "ALL" {
				slot.sub = s
			}
		}
		if !isNew && b.jobMissing(factKind, r.Publication, r.Subscriber, r.Database) {
			b.refuse(slot.path, r24NoJob, slot.path)
			continue
		}
		if pub, ok := b.deferStarts[r]; ok {
			op := b.jobOp(9, endOfStep+pub+sep+"1"+sep+"job"+order, "job_start", cost.OpJobStart, slot, "")
			op.Reason = "-defer-full-snapshot: the agent delivers the added articles that generate_and_wait generated, before immediate_sync is restored"
			jobs = append(jobs, op)
			continue
		}
		jobs = append(jobs, b.jobOp(12, order, "job_start", cost.OpJobStart, slot, ""))
	}

	ops = append(ops, jobs...)
	sort.SliceStable(ops, func(i, j int) bool {
		if ops[i].Step != ops[j].Step {
			return ops[i].Step < ops[j].Step
		}
		return ops[i].Order < ops[j].Order
	})
	for i := range ops {
		ops[i].Seq = i + 1
	}
	return ops
}

// JobIdle is the guard of a job_start: the job has no run requested or
// running in the current session of SQL Server Agent. sp_start_job refuses
// to start a job that has one: the push distribution job that
// sp_addpushsubscription_agent has just created and started, a continuous
// agent that runs. go-mssqldb returns that refusal as an mssql.Error of
// number 22022, class 16 (the 0x5606 line is sqlcmd's print of it), and on
// any 22022 the job_start batch returns no started row (lab/README.md,
// "SQL Server Agent stopped"). The printed batch is the executed one (spec
// anti-goal 2), so the guard is in it; a run that starts between the check
// and the start still fails with 22022, which apply reads as running.
// Measured on the lab by TestLabJobStartGuard (final review item 4).
const JobIdle = "NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobactivity AS ja" +
	" WHERE ja.job_id = @job_id AND ja.session_id = (SELECT MAX(ss.session_id) FROM msdb.dbo.syssessions AS ss)" +
	" AND (ja.run_requested_date IS NOT NULL OR ja.start_execution_date IS NOT NULL) AND ja.stop_execution_date IS NULL)"

// enabledLiteral is the @enabled value of sp_update_job.
func enabledLiteral(on bool) string {
	if on {
		return "1"
	}
	return "0"
}

// jobOp is one of R24's operations on the job of s: msdb.dbo.sp_update_job
// @job_id, @enabled (enabled not empty), or msdb.dbo.sp_start_job @job_id
// under the JobIdle guard, the job found in the batch (jobLookup), at the
// distributor, or at the
// subscriber for a pull agent; online.
func (b *builder) jobOp(step int, order, kind, change string, s agentSlot, enabled string) Operation {
	proc, action := "msdb.dbo.sp_update_job", "disable"
	params := []Param{{Name: "@job_id", Value: "@job_id"}}
	switch kind {
	case "job_restore":
		action = "restore"
	case "job_start":
		proc, action = "msdb.dbo.sp_start_job", "start"
	}
	if enabled != "" {
		params = append(params, Param{Name: "@enabled", Value: enabled})
	}
	call := Call{Procedure: proc, Prologue: b.jobLookup(s), Params: params}
	if kind == "job_start" {
		call.Guard = JobIdle
	}
	op := b.distOp(step, order, kind, action, s.path, call)
	if s.kind == agentPull {
		op.Server = s.subscriber
	}
	if e, ok := cost.Lookup(change, "", "transactional"); ok {
		withCites(&op, e)
	}
	op.Costs = []Cost{CostOnline}
	op.Affects = s.affects()
	switch kind {
	case "job_disable":
		op.Reason = "no scheduled run of the snapshot agent starts inside the plan (spec apply step 3)"
	case "job_restore":
		op.Reason = "the snapshot job is restored as the file declares it, on every way out of apply (spec apply step 3)"
	default:
		op.Reason = "apply starts the agent once the plan has run (spec apply step 5)"
	}
	op.Sources = append(op.Sources, "lab/README.md O20", "R24")
	return op
}

// preconditions lists the checks the plan depends on and refuses the plan
// on those that refuse it: the servers' versions (R18), the published
// tables and their keys (14088), the primary key columns a column subset
// keeps (21250), the profiles the agents name, the subscriber databases of
// the subscriptions the plan creates, the snapshot folders (a warning), the
// edition a database snapshot sync_method needs, and, at each server that
// runs job operations, the msdb job permission (R55) and SQL Server Agent
// (R56).
func (b *builder) preconditions(ops []Operation) []Precondition {
	checks := b.in.Checks
	var out []Precondition
	publisher := b.des.Publisher.Server

	var servers []string
	seenServer := map[string]bool{}
	addServer := func(name string) {
		if name != "" && !seenServer[strings.ToLower(name)] {
			seenServer[strings.ToLower(name)] = true
			servers = append(servers, name)
		}
	}
	addServer(publisher)
	addServer(b.distributorServer())
	for _, p := range b.des.Publications {
		for _, s := range p.Subscriptions {
			addServer(s.Subscriber)
		}
	}
	// The servers the operations run at, beside the file's: a pull
	// subscription removed from the file is dropped at its subscriber,
	// whose name and version are checked like the file's (Task 18 fix
	// round 1).
	for _, op := range ops {
		addServer(op.Server)
	}
	for _, name := range servers {
		pc := Precondition{Name: "server version", Server: name, Object: name, Status: precondUnchecked}
		sc := serverCheck(checks, name)
		switch {
		case sc == nil:
		case !sc.Reachable:
			pc.Detail = "not reachable: " + sc.Error
		case sc.ServerName != "" && !strings.EqualFold(sc.ServerName, name):
			// The address reached another server (R7: case does not count;
			// the lab answers repllab, the fixture's subscriber is REPLLAB).
			pc.Status, pc.Detail = precondFailed, fmt.Sprintf(serverNameWrong, name, sc.ServerName)
			b.refuse(name, serverNameWrong, name, sc.ServerName)
		case sc.Major != 16:
			pc.Status, pc.Detail = precondFailed, fmt.Sprintf(r18Version, name, sc.Version)
			b.refuse(name, r18Version, name, sc.Version)
		default:
			pc.Status, pc.Detail = precondOK, sc.Version
		}
		out = append(out, pc)
	}

	type table struct {
		object, path string
		needsKey     bool
	}
	var tables []*table
	byName := map[string]*table{}
	for _, p := range b.des.Publications {
		for _, a := range p.Articles {
			k := strings.ToLower(a.Source.Schema + "." + a.Source.Name)
			t := byName[k]
			if t == nil {
				t = &table{object: a.Source.Schema + "." + a.Source.Name, path: pubPath(p.Name) + ".articles" + model.Element(a.Name)}
				byName[k] = t
				tables = append(tables, t)
			}
			t.needsKey = t.needsKey || (typeFamily(a.Type) == "table" && stringOr(p.Type, "transactional") == "transactional")
		}
	}
	for _, t := range tables {
		pc := Precondition{Name: "published table", Server: publisher, Object: t.object, Status: precondUnchecked}
		if tc := tableCheck(checks, t.object); tc != nil {
			switch {
			case !tc.Exists:
				pc.Status, pc.Detail = precondFailed, "does not exist"
				b.refuse(t.path, tableMissing, t.object, b.des.Publisher.Database)
			case t.needsKey && !tc.HasPrimaryKey:
				pc.Status, pc.Detail = precondFailed, "no primary key (error 14088)"
				b.refuse(t.path, tableNoKey, t.object)
			default:
				pc.Status = precondOK
			}
		}
		out = append(out, pc)
	}
	b.keyColumns(checks)
	b.namedProfiles(checks)

	creates := b.createdSubscriptions()
	seenDB := map[string]bool{}
	for _, p := range b.des.Publications {
		for i := range p.Subscriptions {
			s := &p.Subscriptions[i]
			k := subKey(s.Key())
			if seenDB[k] {
				if creates[p.Name+sep+k] {
					b.refuseMissingDB(checks, s, subPath(p.Name, s))
				}
				continue
			}
			seenDB[k] = true
			pc := Precondition{Name: precondSubscriberDB, Server: s.Subscriber, Object: s.Database, Status: precondUnchecked}
			if dc := databaseCheck(checks, s.Subscriber, s.Database); dc != nil {
				switch {
				case !dc.Checked:
					pc.Detail = "the subscriber could not be read"
				case !dc.Exists:
					pc.Status, pc.Detail = precondFailed, "does not exist"
				default:
					pc.Status = precondOK
				}
			}
			if creates[p.Name+sep+k] {
				b.refuseMissingDB(checks, s, subPath(p.Name, s))
			}
			out = append(out, pc)
		}
	}

	var folders []string
	if d := b.des.Distributor; d != nil && d.WorkingDirectory != nil && *d.WorkingDirectory != "" {
		folders = append(folders, *d.WorkingDirectory)
	} else if d := b.cur.Distributor; d != nil && d.WorkingDirectory != nil && *d.WorkingDirectory != "" {
		folders = append(folders, *d.WorkingDirectory)
	}
	for _, p := range b.des.Publications {
		if p.Snapshot != nil && p.Snapshot.AltFolder != nil && *p.Snapshot.AltFolder != "" {
			folders = append(folders, *p.Snapshot.AltFolder)
		}
	}
	seenFolder := map[string]bool{}
	dist := b.distributorServer()
	for _, f := range folders {
		if seenFolder[f] {
			continue
		}
		seenFolder[f] = true
		pc := Precondition{Name: "snapshot folder", Server: dist, Object: f, Status: precondUnchecked}
		if fc := folderCheck(checks, dist, f); fc != nil {
			switch {
			case !fc.Checked:
				pc.Detail = "could not be read"
			case !fc.Exists:
				pc.Status, pc.Detail = precondFailed, "not visible to the SQL Server service"
				b.warnings = append(b.warnings, fmt.Sprintf(folderWarning, f, dist))
			default:
				pc.Status = precondOK
			}
		}
		out = append(out, pc)
	}

	for _, p := range b.des.Publications {
		m := stringOr(p.SyncMethod, "native")
		if m != "database_snapshot" && m != "database_snapshot_character" {
			continue
		}
		pc := Precondition{Name: "publisher edition", Server: publisher, Object: p.Name, Status: precondUnchecked,
			Detail: "sync_method " + m + " needs the Enterprise or Developer edition"}
		if sc := serverCheck(checks, publisher); sc != nil && sc.Reachable {
			e := strings.ToLower(sc.Edition)
			if strings.Contains(e, "enterprise") || strings.Contains(e, "developer") {
				pc.Status, pc.Detail = precondOK, sc.Edition
			} else {
				pc.Status, pc.Detail = precondFailed, sc.Edition
				b.refuse(pubPath(p.Name)+".sync_method", editionNeeded, m, publisher, sc.Edition)
			}
		}
		out = append(out, pc)
	}

	seenJob := map[string]bool{}
	for _, op := range ops {
		if op.Kind != "job_disable" && op.Kind != "job_restore" && op.Kind != "job_start" {
			continue
		}
		if seenJob[strings.ToLower(op.Server)] {
			continue
		}
		seenJob[strings.ToLower(op.Server)] = true
		out = append(out, jobPermission(checks, op.Server), agentService(checks, op.Server))
	}
	return out
}

// The objects and texts of R55's and R56's preconditions.
const (
	jobPermissionObject = "sysadmin, or SQLAgentOperatorRole with SELECT on msdb.dbo.sysjobs, sysjobactivity and syssessions"
	agentObject         = "SQL Server Agent service"
	notRead             = "not read"
	jobSysadmin         = "sysadmin"
	jobOperatorReads    = "SQLAgentOperatorRole with SELECT on msdb.dbo.sysjobs, sysjobactivity and syssessions (that grant is not measured)"
	jobOperatorRefused  = "SQLAgentOperatorRole without SELECT on msdb.dbo.sysjobs, sysjobactivity and syssessions: the job prologue and JobIdle fail with 229 (20-apply AP.perm.m_ap_oper.prologue, .activity)"
	jobNoRole           = "neither sysadmin nor a member of SQLAgentOperatorRole in msdb: the job operations fail with 229 or 14262 (20-apply AP.perm.m_ap_user, m_ap_none)"
	agentStoppedDetail  = "SQL Server Agent is not running: the jobs apply starts would not run"
)

// jobPermission is R55's precondition at a server that runs job
// operations. Every job operation begins with the prologue, which reads
// msdb.dbo.sysjobs, and a job_start's JobIdle reads sysjobactivity and
// syssessions: SQLAgentOperatorRole alone runs sp_update_job and
// sp_start_job but fails with 229 on both reads (20-apply
// AP.perm.m_ap_oper.*). So it is ok for a sysadmin, or for an operator
// granted SELECT on the three tables, a case no row measured; failed
// otherwise; unchecked when it was not read.
func jobPermission(c *state.Checks, server string) Precondition {
	pc := Precondition{Name: "msdb job permission", Server: server, Object: jobPermissionObject, Status: precondUnchecked, Detail: notRead}
	var jp *state.JobPermissionCheck
	if c != nil {
		for i := range c.JobPermissions {
			if strings.EqualFold(c.JobPermissions[i].Server, server) {
				jp = &c.JobPermissions[i]
			}
		}
	}
	switch {
	case jp == nil || !jp.Checked:
	case jp.Sysadmin:
		pc.Status, pc.Detail = precondOK, jobSysadmin
	case jp.Operator && jp.ReadsJobs:
		pc.Status, pc.Detail = precondOK, jobOperatorReads
	case jp.Operator:
		pc.Status, pc.Detail = precondFailed, jobOperatorRefused
	default:
		pc.Status, pc.Detail = precondFailed, jobNoRole
	}
	return pc
}

// agentService is R56's precondition at a server that runs job operations:
// the SQL Server Agent row of sys.dm_server_services reads Running
// (agent-stopped AS.detect.dm_server_services.*).
func agentService(c *state.Checks, server string) Precondition {
	pc := Precondition{Name: "sql server agent", Server: server, Object: agentObject, Status: precondUnchecked, Detail: notRead}
	var ag *state.AgentServiceCheck
	if c != nil {
		for i := range c.Agents {
			if strings.EqualFold(c.Agents[i].Server, server) {
				ag = &c.Agents[i]
			}
		}
	}
	switch {
	case ag == nil:
	case !ag.Checked:
		if ag.Detail != "" {
			pc.Detail = ag.Detail
		}
	case ag.Running:
		pc.Status, pc.Detail = precondOK, ag.Detail
	default:
		pc.Status, pc.Detail = precondFailed, agentStoppedDetail
	}
	return pc
}

// The warnings of R59 minor 7 on a new article's destination schema.
const (
	schemaMissing   = "schema %s does not exist at %s/%s: the delivery fails"
	schemaUnchecked = "schema %s may not exist at %s/%s (not checked): the delivery fails if it does not"
)

// schemaWarnings are the warnings of an article the plan adds whose
// destination schema is not dbo and whose schema_option lacks
// create_schemas (0x8000000): at each subscription of the file that
// receives it, the schema must exist in the subscriber database, which
// the checks read absent or did not read.
func (b *builder) schemaWarnings(pd *model.Publication, a *model.Article) []string {
	schema := stringOr(a.Destination.Schema, "")
	if schema == "" || strings.EqualFold(schema, "dbo") {
		return nil
	}
	if a.SchemaOptions != nil && hasFold(*a.SchemaOptions, "create_schemas") {
		return nil
	}
	var out []string
	for i := range pd.Subscriptions {
		s := &pd.Subscriptions[i]
		if !covers(s, a.Name) {
			continue
		}
		var sc *state.SchemaCheck
		if c := b.in.Checks; c != nil {
			for j := range c.Schemas {
				x := &c.Schemas[j]
				if strings.EqualFold(x.Server, s.Subscriber) && strings.EqualFold(x.Database, s.Database) && strings.EqualFold(x.Schema, schema) {
					sc = x
				}
			}
		}
		switch {
		case sc == nil || !sc.Checked:
			out = append(out, fmt.Sprintf(schemaUnchecked, schema, s.Subscriber, s.Database))
		case !sc.Exists:
			out = append(out, fmt.Sprintf(schemaMissing, schema, s.Subscriber, s.Database))
		}
	}
	return out
}

// unreachable refuses every operation that runs at a subscriber whose
// ServerCheck says it cannot be reached (R29): the pull procedures and the
// job operations there. The push operations run at the publisher and the
// distributor and stay planned, with the subscriber's preconditions
// unchecked. With checks, an operation at a server they hold no row for
// (neither the publisher nor the distributor) is refused too: nothing says
// the server was reached (Task 18 fix round 1).
func (b *builder) unreachable(ops []Operation) {
	if b.in.Checks == nil {
		return
	}
	seen := map[string]bool{}
	for _, op := range ops {
		if strings.EqualFold(op.Server, b.des.Publisher.Server) || strings.EqualFold(op.Server, b.distributorServer()) {
			continue
		}
		sc := serverCheck(b.in.Checks, op.Server)
		if sc != nil && sc.Reachable {
			continue
		}
		k := op.Path + sep + op.Call.Procedure
		if seen[k] {
			continue
		}
		seen[k] = true
		if sc == nil {
			b.refuse(op.Path, r29NoCheck, op.Call.Procedure, op.Server, op.Server)
			continue
		}
		b.refuse(op.Path, r29Unreachable, op.Call.Procedure, op.Server, sc.Error)
	}
}

// keyColumns refuses an article whose column subset leaves out a column of
// its table's primary key: sp_articlecolumn refuses the drop with 21250,
// after the operations before it ran (measured, Task 11 review). A table
// the checks did not read is not checked. Empty columns are every column.
func (b *builder) keyColumns(checks *state.Checks) {
	for _, p := range b.des.Publications {
		for _, a := range p.Articles {
			if len(a.Columns) == 0 {
				continue
			}
			object := a.Source.Schema + "." + a.Source.Name
			tc := tableCheck(checks, object)
			if tc == nil || !tc.Exists {
				continue
			}
			for _, k := range tc.KeyColumns {
				if !hasFold(a.Columns, k) {
					b.refuse(pubPath(p.Name)+".articles"+model.Element(a.Name)+".columns", keyColumnOut, k, object)
				}
			}
		}
	}
}

// namedProfiles refuses an agent of the file whose profile is neither a
// profile of the file nor one at the distributor, of the agent's type and
// without regard to case (R7): otherwise only the THROW of the binding's
// prologue stops it, mid-plan (Task 14 review). Unchecked without checks,
// or when the profiles were not read (a distributor always has its system
// profiles).
func (b *builder) namedProfiles(checks *state.Checks) {
	if checks == nil || len(checks.Profiles) == 0 {
		return
	}
	for _, ap := range agentProfiles(b.des) {
		if b.userProfile(b.des, ap.agentType, ap.profile) {
			continue
		}
		found := false
		for _, pc := range checks.Profiles {
			if pc.AgentType == ap.agentType && strings.EqualFold(pc.Name, ap.profile) {
				found = true
				break
			}
		}
		if !found {
			b.refuse(ap.path+".profile", profileMissing, ap.profile, ap.agentType)
		}
	}
}

func (b *builder) refuseMissingDB(checks *state.Checks, s *model.Subscription, path string) {
	if dc := databaseCheck(checks, s.Subscriber, s.Database); dc != nil && dc.Checked && !dc.Exists {
		b.refuse(path, subDBMissing, s.Database, s.Subscriber)
	}
}

// createdSubscriptions is the subscriptions of the file the plan creates,
// by "<pub>\x00<lower-cased key>": those of a publication it creates, those
// it adds to an existing one, and those it drops and adds back.
func (b *builder) createdSubscriptions() map[string]bool {
	out := map[string]bool{}
	pairs, desOnly, _ := matchPublications(b.des.Publications, b.cur.Publications)
	for _, p := range desOnly {
		for _, s := range p.Subscriptions {
			out[p.Name+sep+subKey(s.Key())] = true
		}
	}
	for _, pp := range pairs {
		_, adds, _ := matchSubscriptions(pp.Des.Subscriptions, pp.Cur.Subscriptions)
		for _, s := range adds {
			out[pp.Des.Name+sep+subKey(s.Key())] = true
		}
	}
	for k := range b.readd {
		out[k] = true
	}
	return out
}

func serverCheck(c *state.Checks, name string) *state.ServerCheck {
	if c == nil {
		return nil
	}
	for i := range c.Servers {
		if strings.EqualFold(c.Servers[i].Name, name) {
			return &c.Servers[i]
		}
	}
	return nil
}

func tableCheck(c *state.Checks, object string) *state.TableCheck {
	if c == nil {
		return nil
	}
	for i := range c.Tables {
		if strings.EqualFold(c.Tables[i].Schema+"."+c.Tables[i].Name, object) {
			return &c.Tables[i]
		}
	}
	return nil
}

func databaseCheck(c *state.Checks, server, database string) *state.DatabaseCheck {
	if c == nil {
		return nil
	}
	for i := range c.SubscriberDatabases {
		d := &c.SubscriberDatabases[i]
		if strings.EqualFold(d.Server, server) && strings.EqualFold(d.Database, database) {
			return d
		}
	}
	return nil
}

func folderCheck(c *state.Checks, server, path string) *state.FolderCheck {
	if c == nil {
		return nil
	}
	for i := range c.Folders {
		if strings.EqualFold(c.Folders[i].Server, server) && c.Folders[i].Path == path {
			return &c.Folders[i]
		}
	}
	return nil
}

// secrets is every secret the operations pass, sorted, with whether it is
// set and the Seq of each use (R16).
func (b *builder) secrets(ops []Operation) []SecretUse {
	uses := map[string][]int{}
	for _, op := range ops {
		for _, p := range op.Call.Params {
			if p.Secret != "" {
				uses[p.Secret] = append(uses[p.Secret], op.Seq)
			}
		}
	}
	names := make([]string, 0, len(uses))
	for n := range uses {
		names = append(names, n)
	}
	sort.Strings(names)
	var out []SecretUse
	for _, n := range names {
		out = append(out, SecretUse{Name: n, Set: b.in.SecretSet != nil && b.in.SecretSet(n), Operations: uses[n]})
	}
	return out
}

// planWarnings are the plan-level warnings (operation-scoped ones are on
// the operations): the blocking of native and character, the full
// generation of immediate_sync at every scheduled run (spec "Blocking"),
// the agents a delivery depends on (R13, spec "Inputs") and the command
// lines (R32). after is the state predicted after the plan.
func (b *builder) planWarnings(after *State) {
	for i := range b.des.Publications {
		p := &b.des.Publications[i]
		if m := stringOr(p.SyncMethod, "native"); m == "native" || m == "character" {
			b.warnings = append(b.warnings, fmt.Sprintf(lockWarning, p.Name, m, concurrentMoveCost(after.Pubs[p.Name])))
		}
		if !boolOf(p.ImmediateSync) {
			continue
		}
		agent := p.SnapshotAgent
		if agent == nil || agent.Schedules == nil {
			if c := pubNamed(b.cur, p.Name); c != nil && c.SnapshotAgent != nil {
				agent = c.SnapshotAgent
			} else if def, ok := defaultSchedule(model.Pattern(pubPath(p.Name)+".snapshot_agent.schedules"), stringOr(p.Type, "transactional")); ok {
				// A snapshot agent the plan creates without a schedule: the
				// one sp_addpublication_snapshot stores (the defaults table).
				a := model.Agent{Schedules: &[]model.Schedule{def}}
				if p.SnapshotAgent != nil {
					a.JobEnabled = p.SnapshotAgent.JobEnabled
				}
				agent = &a
			}
		}
		if recurring(agent) {
			b.warnings = append(b.warnings, fmt.Sprintf(fullGenWarning, p.Name, recurrence(agent)))
		}
	}
	b.agentWarnings()
	b.commandWarnings()
}

// concurrentMoveCost is the measured cost of a sync_method change to
// concurrent from the predicted state (spec "Blocking"; 15-snapshot-scope
// C.native.sync_method, 02-matrix P22): a reinitialization of every
// subscription when a row is at 2, plus the snapshot flag when the
// publication has immediate_sync and a ready snapshot.
func concurrentMoveCost(ps *PubState) string {
	var parts []string
	if ps != nil && rowsAt(ps, "", true, 2) {
		parts = append(parts, "a reinitialization of every subscription")
	}
	if ps != nil && ps.ImmediateSync && ps.Ready {
		parts = append(parts, "the snapshot flag (its ready snapshot is invalidated)")
	}
	if len(parts) == 0 {
		return "no flag and no reinitialization (no subscription row is delivered)"
	}
	return strings.Join(parts, " plus ")
}

// recurrence writes how often a recurring schedule of an agent runs.
func recurrence(a *model.Agent) string {
	for _, s := range *a.Schedules {
		if s.Enabled != nil && !*s.Enabled {
			continue
		}
		switch s.Frequency {
		case "once", "agent_start", "":
			continue
		}
		if s.Subday != "" && s.Subday != "once" && s.SubdayInterval > 0 {
			return fmt.Sprintf("%s, every %d %s", s.Frequency, s.SubdayInterval, s.Subday)
		}
		return s.Frequency
	}
	return ""
}

// agentWarnings warns, for each subscription the plan keeps, when its
// distribution agent is not running (R13; plan cannot see a generated,
// undelivered snapshot, spec "Inputs"), and, for a concurrent or
// concurrent_c subscription with a row at status 3 in MSsubscriptions,
// when the log reader is not running (O18).
func (b *builder) agentWarnings() {
	f := b.in.Facts
	if f == nil {
		return
	}
	since := map[string]string{}
	for _, p := range f.Publications {
		since[p.Name] = p.LastGeneration
	}
	rows := map[string][]state.SubscriptionRow{}
	for _, s := range f.Subscriptions {
		rows[s.Publication+sep+subKey(s.Subscriber+"/"+s.Database)] = s.Rows
	}
	pairs, _, _ := matchPublications(b.des.Publications, b.cur.Publications)
	for _, pp := range pairs {
		pc := pp.Cur
		kept, _, _ := matchSubscriptions(pp.Des.Subscriptions, pc.Subscriptions)
		for _, sp := range kept {
			s := sp.Cur
			label := "subscription " + s.Key() + " of " + pc.Name
			kind, pub := "distribution", pc.Name
			if stringOr(s.Type, "push") == "pull" {
				kind = "pull_distribution"
			}
			if !boolOf(pc.IndependentAgent) {
				pub = "ALL"
			}
			if a := b.agentFacts(kind, pub, s.Subscriber, s.Database); a != nil {
				if st := agentStatus(*a, since[pc.Name]); st != "running" {
					b.warnings = append(b.warnings, fmt.Sprintf(agentWarning, label, st))
				}
			}
			if m := stringOr(pc.SyncMethod, "native"); m != "concurrent" && m != "concurrent_c" {
				continue
			}
			at3 := false
			for _, r := range rows[pc.Name+sep+subKey(s.Key())] {
				at3 = at3 || (r.DistributorStatus != nil && *r.DistributorStatus == 3)
			}
			if !at3 {
				continue
			}
			if lr := b.agentFacts("log_reader", "", "", ""); lr != nil {
				if st := agentStatus(*lr, since[pc.Name]); st != "running" {
					db := b.des.Publisher.Server + "." + b.des.Publisher.Database
					b.warnings = append(b.warnings, fmt.Sprintf(logReaderWarning, db, st, s.Key(), pc.Name))
				}
			}
		}
	}
}

// commandSwitches are the switches the replication procedures write in an
// agent's command line, per agent kind (R32): those of the lab fixture's
// commands (internal/testdata/lab/sales.yaml) for the log reader, snapshot
// and distribution agents, and of 08-pull P1.named for a pull agent, which
// the fixture has none of. Compared without regard to case.
var commandSwitches = map[string][]string{
	agentLogReader: {"Publisher", "PublisherDB", "Distributor", "DistributorSecurityMode", "Continuous"},
	agentSnapshot:  {"Publisher", "PublisherDB", "Distributor", "Publication", "DistributorSecurityMode"},
	agentPush:      {"Subscriber", "SubscriberDB", "Publisher", "Distributor", "DistributorSecurityMode", "Publication", "PublisherDB", "Continuous"},
	agentPull:      {"Publisher", "PublisherDB", "Publication", "Distributor", "SubscriptionType", "Subscriber", "SubscriberSecurityMode", "SubscriberDB", "Continuous"},
}

// commandWarnings warns on each switch of an agent's command line, in the
// file or on the server, outside commandSwitches (R32).
func (b *builder) commandWarnings() {
	seen := map[string]bool{}
	check := func(path, kind string, a *model.Agent) {
		if a == nil || a.Command == nil {
			return
		}
		known := map[string]bool{}
		for _, s := range commandSwitches[kind] {
			known[strings.ToLower(s)] = true
		}
		for _, sw := range switches(*a.Command) {
			k := path + sep + strings.ToLower(sw)
			if !known[strings.ToLower(sw)] && !seen[k] {
				seen[k] = true
				b.warnings = append(b.warnings, fmt.Sprintf(commandWarning, path, "-"+sw))
			}
		}
	}
	for _, c := range []*model.Config{b.des, b.cur} {
		check("publisher.log_reader_agent", agentLogReader, c.Publisher.LogReaderAgent)
		for i := range c.Publisher.SharedDistributionAgents {
			a := &c.Publisher.SharedDistributionAgents[i]
			check("publisher.shared_distribution_agents"+model.Element(a.Key())+".distribution_agent", agentPush, &a.DistributionAgent.Agent)
		}
		for i := range c.Publisher.SharedPullAgents {
			a := &c.Publisher.SharedPullAgents[i]
			check("publisher.shared_pull_agents"+model.Element(a.Key())+".pull_agent", agentPull, &a.PullAgent.Agent)
		}
		for i := range c.Publications {
			p := &c.Publications[i]
			check(pubPath(p.Name)+".snapshot_agent", agentSnapshot, p.SnapshotAgent)
			for j := range p.Subscriptions {
				s := &p.Subscriptions[j]
				if s.DistributionAgent != nil {
					check(subPath(p.Name, s)+".distribution_agent", agentPush, &s.DistributionAgent.Agent)
				}
				if s.PullAgent != nil {
					check(subPath(p.Name, s)+".pull_agent", agentPull, &s.PullAgent.Agent)
				}
			}
		}
	}
}

// switches is the switch names of a command line, in order: the words that
// start with "-" and a letter, outside a bracketed or quoted value.
func switches(cmd string) []string {
	var out []string
	depth, quoted := 0, false
	for _, w := range strings.Fields(cmd) {
		if depth == 0 && !quoted && len(w) > 1 && w[0] == '-' && (w[1] >= 'A' && w[1] <= 'Z' || w[1] >= 'a' && w[1] <= 'z') {
			out = append(out, w[1:])
			continue
		}
		depth += strings.Count(w, "[") - strings.Count(w, "]")
		if depth < 0 {
			depth = 0
		}
		if strings.Count(w, "\"")%2 == 1 {
			quoted = !quoted
		}
	}
	return out
}

// planNotes are the plan-level notes: an immediate_sync snapshot that is
// invalid while nothing awaits it (spec "Inputs"), a publication pending
// before the plan (owedAtEnd hides its cost: Task 9 ruling), and the
// restore of immediate_sync on a publication with subscriptions (the
// remainder of an interrupted -defer-full-snapshot, Task 13 review).
func (b *builder) planNotes(before *State) {
	for i := range b.des.Publications {
		p := &b.des.Publications[i]
		ps := before.Pubs[p.Name]
		if ps == nil || !ps.Exists {
			continue
		}
		switch {
		case before.Pending(p.Name):
			b.notes = append(b.notes, fmt.Sprintf(pendingNote, p.Name))
		case ps.ImmediateSync && !ps.Ready && boolOf(p.ImmediateSync) && !b.deferred(p.Name):
			b.notes = append(b.notes, fmt.Sprintf(deferredNote, p.Name))
		}
		if c := pubNamed(b.cur, p.Name); c != nil && boolOf(p.ImmediateSync) && !boolOf(c.ImmediateSync) && len(c.Subscriptions) > 0 {
			b.notes = append(b.notes, fmt.Sprintf(restoreImmNote, p.Name))
		}
	}
}
