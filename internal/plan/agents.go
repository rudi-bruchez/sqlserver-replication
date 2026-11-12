package plan

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/rudi-bruchez/sqlserver-replication/internal/cost"
	"github.com/rudi-bruchez/sqlserver-replication/internal/decode"
	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
	"github.com/rudi-bruchez/sqlserver-replication/internal/normalize"
)

// agentsStrategy is listed in lateStrategies (build.go), before
// distributorStrategy.

// The refusals of the shared agents (carried decision of the Task 12 and 13
// reviews): an agent declared in the place it will not be after this plan.
const (
	sharedPushDeclared = "publication %s uses a shared distribution agent after this plan: declare the agent under publisher.shared_distribution_agents"
	sharedPullDeclared = "publication %s uses a shared pull agent after this plan: declare the agent under publisher.shared_pull_agents"
	sharedPushStale    = "the publications the shared distribution agent of %s serves become independent in this plan: remove it from publisher.shared_distribution_agents"
	createdJobWarning  = "the job starts at its creation, before this call disables it (measured by the Task 14 review: sp_addlogreader_agent and the implicit shared distribution job start at once)"
	sharedPullStale    = "the publications the shared pull agent of %s serves become independent in this plan: remove it from publisher.shared_pull_agents"
)

// The Order keys of the agents' operations: step 3 "dboption" for
// sp_replicationdboption, before Task 11's "logreader"; step 8
// "<pub>\x00" 2 for the repair of a snapshot agent, as addPublication's;
// step 10 "<agent path>\x00" then 1 for the profile binding, 2 for the
// schedule, 3 for job_enabled.

// agentsStrategy plans the publication database (step 3) and the agents
// (step 10): the profile bindings (R41), the snapshot agent's schedule
// (R22), job_enabled (R23), the repair of a missing snapshot agent (step 8)
// and of a missing log reader (step 3), and refuses every other agent change
// no cost entry covers. A subscription agent's other properties are Task
// 12's (subscriptionProperty).
func agentsStrategy(b *builder) {
	b.publicationDatabase()
	b.sharedPlacement()
	for _, s := range b.agentSlots() {
		b.planAgent(s)
	}
}

// publicationDatabase is step 3: sp_replicationdboption publish when the
// database has no publication and the file has one (the call is
// idempotent, spec "Order" step 3), and the log reader when the file needs
// one, none exists, and Task 11 adds none (the repair of the incomplete
// finding at publisher.log_reader_agent).
func (b *builder) publicationDatabase() {
	if len(b.cur.Publications) == 0 && len(b.des.Publications) > 0 {
		op := b.newOp(3, "dboption", "publication_db", "change", "publisher", Call{Procedure: "sp_replicationdboption", Params: []Param{
			{Name: "@dbname", Value: literal(b.des.Publisher.Database)},
			{Name: "@optname", Value: literal("publish")},
			{Name: "@value", Value: literal("true")},
		}})
		op.Database = "master"
		op.Reason = "the database has no publication: it is enabled for publishing before its log reader and publications"
		op.Sources = append(op.Sources, "spec Order step 3")
		b.add(op)
	}
	if !b.des.NeedsLogReader() || b.st.LogReader || b.plansLogReader() || b.des.Publisher.LogReaderAgent == nil {
		return
	}
	const path = "publisher.log_reader_agent"
	call, err := creationCall("sp_addlogreader_agent", b.des.Publisher.LogReaderAgent, normalize.Context{Object: "log_reader_agent"}, nil)
	if err != nil {
		b.refuse(path, "%v", err)
		return
	}
	op := b.newOp(3, "logreader", "log_reader_agent", "add", path, call)
	op.Reason = "the database's publications need a log reader agent and none exists (the export's incomplete finding)"
	op.Sources = append(op.Sources, "spec Order step 3")
	b.add(op)
}

// plansLogReader tells whether an operation of the plan creates the log
// reader.
func (b *builder) plansLogReader() bool {
	for _, op := range b.ops {
		if op.Kind == "log_reader_agent" && op.Action == "add" {
			return true
		}
	}
	return false
}

// sharedPlacement refuses an agent declared where it will not be after
// this plan (carried decision of the Task 12 and 13 reviews): a
// per-subscription agent on a publication without independent_agent, and a
// current shared agent the file keeps declared while the publications it
// serves become independent. A shared agent left after the drop of its last
// subscription, or declared and created by nothing, is not compared (R5).
func (b *builder) sharedPlacement() {
	for i := range b.des.Publications {
		p := &b.des.Publications[i]
		if boolOf(p.IndependentAgent) {
			continue
		}
		for j := range p.Subscriptions {
			s := &p.Subscriptions[j]
			switch {
			case s.DistributionAgent != nil:
				b.refuse(subPath(p.Name, s)+".distribution_agent", sharedPushDeclared, p.Name)
			case s.PullAgent != nil:
				b.refuse(subPath(p.Name, s)+".pull_agent", sharedPullDeclared, p.Name)
			}
		}
	}
	served := func(c *model.Config, typ, subscriber, database string) bool {
		for _, p := range c.Publications {
			if boolOf(p.IndependentAgent) {
				continue
			}
			for _, s := range p.Subscriptions {
				if stringOr(s.Type, "push") == typ && strings.EqualFold(s.Subscriber, subscriber) && strings.EqualFold(s.Database, database) {
					return true
				}
			}
		}
		return false
	}
	// madeIndependent tells a subscriber database that a current publication
	// without independent_agent serves, which the file makes independent.
	madeIndependent := func(typ, subscriber, database string) bool {
		for _, pc := range b.cur.Publications {
			if boolOf(pc.IndependentAgent) {
				continue
			}
			for _, pd := range b.des.Publications {
				if pd.Name != pc.Name || !boolOf(pd.IndependentAgent) {
					continue
				}
				for _, s := range pc.Subscriptions {
					if stringOr(s.Type, "push") == typ && strings.EqualFold(s.Subscriber, subscriber) && strings.EqualFold(s.Database, database) {
						return true
					}
				}
			}
		}
		return false
	}
	stale := func(path, format, subscriber, database, typ string) {
		if !served(b.des, typ, subscriber, database) && madeIndependent(typ, subscriber, database) {
			b.refuse(path, format, subscriber+"/"+database)
		}
	}
	pairs, _, _ := matchFold(b.des.Publisher.SharedDistributionAgents, b.cur.Publisher.SharedDistributionAgents,
		func(a *model.SharedDistributionAgent) (string, string) { return a.Subscriber, a.Database })
	for _, sp := range pairs {
		stale(sp.path("publisher.shared_distribution_agents"), sharedPushStale, sp.Des.Subscriber, sp.Des.Database, "push")
	}
	ppairs, _, _ := matchFold(b.des.Publisher.SharedPullAgents, b.cur.Publisher.SharedPullAgents,
		func(a *model.SharedPullAgent) (string, string) { return a.Subscriber, a.Database })
	for _, sp := range ppairs {
		stale(sp.path("publisher.shared_pull_agents"), sharedPullStale, sp.Des.Subscriber, sp.Des.Database, "pull")
	}
}

// Agent kinds of a slot.
const (
	agentLogReader  = "log_reader"
	agentSnapshot   = "snapshot"
	agentPush       = "push"
	agentPull       = "pull"
	agentSharedPush = "shared_push"
	agentSharedPull = "shared_pull"
)

// agentSlot is one agent of the file, with its current self: cur is nil for
// an agent this plan creates.
type agentSlot struct {
	path, kind, agentType string
	pub, pubType          string // pub is "ALL" for a shared agent, "" for the log reader
	subscriber, database  string
	sub                   *model.Subscription // the desired subscription, push and pull
	des, cur              *model.Agent
	desObj, curObj        any // what is diffed: the agent with its extension
}

// agentSlots is every agent of the file this plan keeps or creates.
func (b *builder) agentSlots() []agentSlot {
	var out []agentSlot
	if d := b.des.Publisher.LogReaderAgent; d != nil {
		c := b.cur.Publisher.LogReaderAgent
		if b.plansLogReader() {
			c = nil // created (again) by this plan
		}
		if c != nil || b.plansLogReader() {
			out = append(out, agentSlot{path: "publisher.log_reader_agent", kind: agentLogReader, agentType: "logreader",
				pubType: "transactional", des: d, cur: c, desObj: d, curObj: c})
		}
	}
	pairs, desOnly, _ := matchPublications(b.des.Publications, b.cur.Publications)
	for _, pp := range pairs {
		out = append(out, b.publicationSlots(pp.Des, pp.Cur, pp.path("publications"))...)
	}
	for _, p := range desOnly {
		out = append(out, b.publicationSlots(p, nil, pubPath(p.Name))...)
	}

	spairs, sdes, _ := matchFold(b.des.Publisher.SharedDistributionAgents, b.cur.Publisher.SharedDistributionAgents,
		func(a *model.SharedDistributionAgent) (string, string) { return a.Subscriber, a.Database })
	shared := func(d, c *model.SharedDistributionAgent, path string) {
		s := agentSlot{path: path + ".distribution_agent", kind: agentSharedPush, agentType: "distribution", pub: "ALL",
			pubType: "transactional", subscriber: d.Subscriber, database: d.Database, des: &d.DistributionAgent.Agent, desObj: &d.DistributionAgent}
		if c != nil && !b.sharedPush[subKey(d.Key())] {
			s.cur, s.curObj = &c.DistributionAgent.Agent, &c.DistributionAgent
		} else if !b.sharedPush[subKey(d.Key())] {
			return // nothing creates it: refused by sharedPlacement, or orphan
		}
		out = append(out, s)
	}
	for _, sp := range spairs {
		shared(sp.Des, sp.Cur, sp.path("publisher.shared_distribution_agents"))
	}
	for _, a := range sdes {
		shared(a, nil, "publisher.shared_distribution_agents"+model.Element(a.Key()))
	}
	ppairs, _, _ := matchFold(b.des.Publisher.SharedPullAgents, b.cur.Publisher.SharedPullAgents,
		func(a *model.SharedPullAgent) (string, string) { return a.Subscriber, a.Database })
	for _, sp := range ppairs {
		// The plan never creates a shared pull agent (R21).
		out = append(out, agentSlot{path: sp.path("publisher.shared_pull_agents"), kind: agentSharedPull, agentType: "distribution",
			pub: "ALL", pubType: "transactional", subscriber: sp.Des.Subscriber, database: sp.Des.Database,
			des: &sp.Des.PullAgent.Agent, cur: &sp.Cur.PullAgent.Agent, desObj: sp.Des, curObj: sp.Cur})
	}
	return out
}

// publicationSlots is the snapshot agent and the subscription agents of a
// publication of the file; pc is nil for a publication the plan adds.
func (b *builder) publicationSlots(pd, pc *model.Publication, ppath string) []agentSlot {
	var out []agentSlot
	pubType := stringOr(pd.Type, "transactional")
	if d := pd.SnapshotAgent; d != nil {
		s := agentSlot{path: ppath + ".snapshot_agent", kind: agentSnapshot, agentType: "snapshot", pub: pd.Name, pubType: pubType,
			des: d, desObj: d}
		if pc != nil && pc.SnapshotAgent != nil {
			s.cur, s.curObj = pc.SnapshotAgent, pc.SnapshotAgent
		} else if pc != nil {
			b.repairSnapshotAgent(pd)
		}
		out = append(out, s)
	}
	var curSubs []model.Subscription
	if pc != nil {
		curSubs = pc.Subscriptions
	}
	spairs, adds, _ := matchSubscriptions(pd.Subscriptions, curSubs)
	slot := func(d, c *model.Subscription, path string) {
		if stringOr(d.Type, "push") != stringOr(subType(c, d), "push") {
			return // a type change is refused (R21)
		}
		s := agentSlot{pub: pd.Name, pubType: pubType, subscriber: d.Subscriber, database: d.Database, sub: d, agentType: "distribution"}
		switch stringOr(d.Type, "push") {
		case "push":
			if d.DistributionAgent == nil {
				return // a shared agent
			}
			s.path, s.kind, s.des, s.desObj = path+".distribution_agent", agentPush, &d.DistributionAgent.Agent, d.DistributionAgent
			if c != nil && c.DistributionAgent != nil {
				s.cur, s.curObj = &c.DistributionAgent.Agent, c.DistributionAgent
			}
		case "pull":
			if d.PullAgent == nil {
				return
			}
			s.path, s.kind, s.des, s.desObj = path+".pull_agent", agentPull, &d.PullAgent.Agent, d.PullAgent
			if c != nil && c.PullAgent != nil {
				s.cur, s.curObj = &c.PullAgent.Agent, c.PullAgent
			}
		default:
			return
		}
		if c != nil && s.cur == nil {
			return // no current agent to compare with, and none created
		}
		out = append(out, s)
	}
	for _, sp := range spairs {
		if b.readd[pd.Name+sep+subKey(sp.Des.Key())] {
			slot(sp.Des, nil, sp.path(ppath+".subscriptions")) // dropped and added back: a new agent
			continue
		}
		slot(sp.Des, sp.Cur, sp.path(ppath+".subscriptions"))
	}
	for _, s := range adds {
		slot(s, nil, subPath(pd.Name, s))
	}
	return out
}

// subType is the current subscription's type, or the desired one for a
// subscription the plan adds.
func subType(c, d *model.Subscription) *string {
	if c != nil {
		return c.Type
	}
	return d.Type
}

// repairSnapshotAgent creates the snapshot agent of an existing publication
// that has none (step 8, as addPublication; the repair of the export's
// incomplete finding at publications[*].snapshot_agent).
func (b *builder) repairSnapshotAgent(pd *model.Publication) {
	path := pubPath(pd.Name) + ".snapshot_agent"
	call, err := creationCall("sp_addpublication_snapshot", pd.SnapshotAgent,
		normalize.Context{Object: "snapshot_agent", PubType: stringOr(pd.Type, "transactional")},
		[]Param{{Name: "@publication", Value: literal(pd.Name)}})
	if err != nil {
		b.refuse(path, "%v", err)
		return
	}
	op := b.newOp(8, pd.Name+sep+"2", "snapshot_agent", "add", path, call)
	op.Affects.Publications = []string{pd.Name}
	op.Reason = "the publication has no snapshot agent: it is created (the repair of the export's incomplete finding)"
	op.Sources = append(op.Sources, "spec Order step 8")
	b.add(op)
}

// agentProfile is a profile an agent of the file names.
type agentProfile struct{ agentType, profile string }

// agentProfiles is every profile an agent of c names.
func agentProfiles(c *model.Config) []agentProfile {
	var out []agentProfile
	add := func(t string, a *model.Agent) {
		if a != nil && a.Profile != nil && *a.Profile != "" {
			out = append(out, agentProfile{t, *a.Profile})
		}
	}
	add("logreader", c.Publisher.LogReaderAgent)
	for i := range c.Publisher.SharedDistributionAgents {
		add("distribution", &c.Publisher.SharedDistributionAgents[i].DistributionAgent.Agent)
	}
	for i := range c.Publisher.SharedPullAgents {
		add("distribution", &c.Publisher.SharedPullAgents[i].PullAgent.Agent)
	}
	for i := range c.Publications {
		p := &c.Publications[i]
		add("snapshot", p.SnapshotAgent)
		for j := range p.Subscriptions {
			s := &p.Subscriptions[j]
			if s.DistributionAgent != nil {
				add("distribution", &s.DistributionAgent.Agent)
			}
			if s.PullAgent != nil {
				add("distribution", &s.PullAgent.Agent)
			}
		}
	}
	return out
}

// templateProfile stands for the template system profile of a type, the
// system profile MIN(profile_id) (stored-procedures/sp_add_agent_profile.sql:82),
// whose name the facts do not give.
const templateProfile = "\x00template"

// defaultProfile is the default profile of an agent type this plan leaves in
// place (R41; fix rounds 1 and 3 of Task 14), in this order: a profile of the
// file of that type with default true (a new one takes the flag from
// sp_add_agent_profile @default = 1 in step 2; normalization refuses two, and
// a default change of a kept profile is refused, R6); else the current
// default (state.Facts.DefaultProfiles) when the plan keeps it, a system
// profile or a user profile the file declares; else, the plan dropping the
// current default user profile, templateProfile (measured by the Task 14
// review: dropping an unused default user profile makes the template the
// default again). "" when unknown. Measured by the review too:
// sp_add_agent_profile @default = 1 rebinds no existing agent, so an agent
// whose profile the file omits is bound by this plan, and an agent created
// after it starts on the new default.
func (b *builder) defaultProfile(agentType string) string {
	for _, p := range b.des.AgentProfiles {
		if p.AgentType == agentType && boolOf(p.Default) {
			return p.Name
		}
	}
	if b.in.Facts == nil {
		return ""
	}
	for _, d := range b.in.Facts.DefaultProfiles {
		if d.AgentType != agentType {
			continue
		}
		if b.userProfile(b.cur, agentType, d.Name) && !b.userProfile(b.des, agentType, d.Name) {
			return templateProfile // the plan drops it
		}
		return d.Name
	}
	return ""
}

// userProfile tells a user profile of c, matched without regard to case
// (R7).
func (b *builder) userProfile(c *model.Config, agentType, name string) bool {
	for _, p := range c.AgentProfiles {
		if p.AgentType == agentType && strings.EqualFold(p.Name, name) {
			return true
		}
	}
	return false
}

// planAgent plans one agent: its profile binding, then, for an existing
// agent, its schedule, its job_enabled and its other properties.
func (b *builder) planAgent(s agentSlot) {
	if b.skip(s.path) {
		return
	}
	b.binding(s)
	if s.cur == nil {
		if j := s.des.JobEnabled; j != nil && !*j && s.kind != agentSnapshot {
			// R23 on an agent the plan creates: disabled after its creation
			// (the snapshot agent's is Task 15's job_restore).
			b.jobEnabled(s, Change{Path: s.path + ".job_enabled", Pattern: model.Pattern(s.path + ".job_enabled"), After: model.Ptr("false")})
		}
		return
	}
	var schedules []Change
	for _, ch := range b.diff(s.path, s.desObj, s.curObj) {
		rel := strings.TrimPrefix(ch.Path, s.path+".")
		switch {
		case rel == "profile":
			continue // binding (R41)
		case rel == "schedules" || strings.HasPrefix(rel, "schedules[") || strings.HasPrefix(rel, "schedules."):
			schedules = append(schedules, ch)
		case rel == "job_enabled":
			if s.kind == agentSnapshot {
				continue // R23: the snapshot job's job_restore sets it (R24, Task 15)
			}
			b.jobEnabled(s, ch)
		case s.kind == agentPush || s.kind == agentPull:
			continue // Task 12 (subscriptionProperty)
		default:
			b.agentChange(s, ch)
		}
	}
	if len(schedules) > 0 {
		b.schedule(s, schedules)
	}
}

// agentChange is a change of a log reader, snapshot or shared agent
// property other than the profile, the schedule and job_enabled: refused
// by the server, or not measured (spec "Costs and unmeasured changes").
func (b *builder) agentChange(s agentSlot, ch Change) {
	var e cost.Entry
	found := false
	for _, dir := range directions(ch) {
		if e, found = cost.Lookup(ch.Path, dir, s.pubType); found {
			break
		}
	}
	switch {
	case !found:
		b.unmeasured(ch)
	case e.Class == cost.Refused:
		b.refuse(ch.Path, "%s change refused by the server (%d)", ch.Pattern, e.Error)
	default:
		b.refuse(ch.Path, "no measured call for %s", ch.Pattern)
	}
}

// binding binds an agent to the file's profile, or to the default profile
// of its type when the file omits it (R41): a current binding to another
// profile is a change; a created agent starts on the default profile (spec
// "Agents and profiles"). Names compare without regard to case (R7).
func (b *builder) binding(s agentSlot) {
	def := b.defaultProfile(s.agentType)
	want := def
	if s.des.Profile != nil && *s.des.Profile != "" {
		want = *s.des.Profile
	}
	if want == "" {
		return // the default is not known: not compared
	}
	have := def
	if s.cur != nil {
		if s.cur.Profile == nil {
			return // not read (a pull agent without its row): not compared
		}
		if *s.cur.Profile != "" {
			have = *s.cur.Profile // "": no profile id, the default
		}
	}
	switch {
	case want == templateProfile && have != templateProfile:
		if !b.userProfile(b.cur, s.agentType, have) {
			// A system profile: taken as the template, whose name the facts
			// do not give (another system profile is not told apart).
			return
		}
	case have != "" && strings.EqualFold(have, want):
		return
	}
	if b.rebound == nil {
		b.rebound = map[string]string{}
	}
	b.rebound[agentKey(s.agentType, s.pub, s.subscriber, s.database)] = want
	e, ok := cost.Lookup(cost.OpProfileBinding, "", "transactional")
	if !ok {
		b.refuse(s.path+".profile", "cost of %s not measured", cost.OpProfileBinding)
		return
	}
	code, err := decode.AgentTypeCode(s.agentType)
	if err != nil {
		b.refuse(s.path+".profile", "%v", err)
		return
	}
	dist := quoteName(b.distributionDB())
	from, where := b.agentRow(s, dist)
	pro := "DECLARE @agent_id int, @profile_id int;\n" +
		"SELECT @agent_id = a.id " + from + " WHERE " + where + ";\n" +
		profileLookup(want, code) +
		"IF @agent_id IS NULL OR @profile_id IS NULL THROW 50000, " +
		literal(fmt.Sprintf("the agent %s or the profile %s (%s) does not exist", s.path, profileLabel(want, s.agentType), s.agentType)) + ", 1;"
	op := b.distOp(10, s.path+sep+"1", "agent_binding", "change", s.path, Call{Procedure: "sp_update_agent_profile", Prologue: pro, Params: []Param{
		{Name: "@agent_type", Value: strconv.Itoa(code)},
		{Name: "@agent_id", Value: "@agent_id"},
		{Name: "@profile_id", Value: "@profile_id"},
	}})
	op.Call.Procedure = procedureName("sp_update_agent_profile", b.distributionDB())
	withCites(&op, e)
	op.Changes = []PropertyChange{{Path: s.path + ".profile", Before: profileLabel(have, s.agentType), After: profileLabel(want, s.agentType)}}
	op.Affects = s.affects()
	op.Reason = "the agent is bound to its profile after its creation and the profile's (spec Agents and profiles)"
	if s.des.Profile == nil {
		op.Reason = "the file omits the agent's profile: it is bound to the default profile of its type (R41)"
	}
	op.Sources = append(op.Sources, "spec Agents and profiles", "spec Order step 10")
	b.add(op)
}

// profileLookup sets @profile_id to the profile named want of the type
// code, or to the type's template system profile.
func profileLookup(want string, code int) string {
	if want == templateProfile {
		return "SELECT @profile_id = MIN(profile_id) FROM msdb.dbo.MSagent_profiles WHERE agent_type = " + strconv.Itoa(code) + " AND type = 0;\n"
	}
	return "SELECT @profile_id = profile_id FROM msdb.dbo.MSagent_profiles WHERE profile_name = " + literal(want) +
		" AND agent_type = " + strconv.Itoa(code) + ";\n"
}

// profileLabel writes a profile name, templateProfile as words.
func profileLabel(name, agentType string) string {
	if name == templateProfile {
		return "the template system profile of " + agentType
	}
	return name
}

// agentKey names an agent of this publication database as a
// state.ProfileUse does: its type, its publication ("" for the log reader,
// ALL for a shared agent), its subscriber and subscription database.
func agentKey(agentType, pub, subscriber, database string) string {
	return agentType + sep + pub + sep + strings.ToLower(subscriber) + sep + strings.ToLower(database)
}

func (s agentSlot) affects() Affects {
	var a Affects
	if s.pub != "" && s.pub != "ALL" {
		a.Publications = []string{s.pub}
	}
	if s.sub != nil {
		a.Subscriptions = []string{s.sub.Key()}
	}
	return a
}

// agentRow is the FROM and WHERE of an agent's row at the distributor,
// aliased a, as the reader finds it (internal/reader/queries.go): by the
// publisher's id in the distribution database's servers table, the
// publication database and, as the agent has them, the publication, the
// subscriber and its database, and the subscription type.
func (b *builder) agentRow(s agentSlot, dist string) (from, where string) {
	servers := dist + ".dbo.MSreplservers"
	cond := []string{
		"UPPER(ps.srvname) = UPPER(" + literal(b.des.Publisher.Server) + ")",
		"a.publisher_db = " + literal(b.des.Publisher.Database),
	}
	switch s.kind {
	case agentLogReader:
		from = "FROM " + dist + ".dbo.MSlogreader_agents AS a JOIN " + servers + " AS ps ON ps.srvid = a.publisher_id"
	case agentSnapshot:
		from = "FROM " + dist + ".dbo.MSsnapshot_agents AS a JOIN " + servers + " AS ps ON ps.srvid = a.publisher_id"
		// sp_addpublication registers a row with local_job = 0 before
		// sp_addpublication_snapshot (lab/README.md).
		cond = append(cond, "a.publication = "+literal(s.pub), "a.local_job = 1")
	default:
		from = "FROM " + dist + ".dbo.MSdistribution_agents AS a JOIN " + servers + " AS ps ON ps.srvid = a.publisher_id JOIN " +
			servers + " AS rs ON rs.srvid = a.subscriber_id"
		typ := "0"
		if s.kind == agentPull || s.kind == agentSharedPull {
			typ = "1"
		}
		cond = append(cond, "a.publication = "+literal(s.pub), "UPPER(rs.srvname) = UPPER("+literal(s.subscriber)+")",
			"a.subscriber_db = "+literal(s.database), "a.subscription_type = "+typ)
	}
	return from, strings.Join(cond, " AND ")
}

// jobEnabled is R23 for an agent other than the snapshot agent:
// msdb.dbo.sp_update_job @job_id, @enabled at the job's server, the job
// found in the batch as R24 finds it; online, note O20.
func (b *builder) jobEnabled(s agentSlot, ch Change) {
	if s.kind == agentSharedPull {
		b.unmeasured(ch) // the shared pull job's lookup at the subscriber is not measured
		return
	}
	e, ok := cost.Lookup(cost.OpJobEnabled, "", "transactional")
	if !ok {
		b.unmeasured(ch)
		return
	}
	on := orEmpty(ch.After) == "true"
	enabled := "0"
	if on {
		enabled = "1"
	}
	var pro string
	missing := literal(fmt.Sprintf("the job of %s does not exist", s.path))
	if s.kind == agentPull {
		// The pull agent's job is at the subscriber, named by the
		// subscription's row there (internal/reader/agents.go).
		pro = "DECLARE @job_id uniqueidentifier;\n" +
			"SELECT @job_id = sj.job_id FROM " + quoteName(s.database) + ".dbo.MSreplication_subscriptions AS rs" +
			" JOIN msdb.dbo.sysjobs AS sj ON sj.job_id = CONVERT(uniqueidentifier, rs.agent_id)" +
			" WHERE UPPER(rs.publisher) = UPPER(" + literal(b.des.Publisher.Server) + ") AND rs.publisher_db = " +
			literal(b.des.Publisher.Database) + " AND rs.publication = " + literal(s.pub) + " AND rs.subscription_type = 1;\n" +
			"IF @job_id IS NULL THROW 50000, " + missing + ", 1;"
	} else {
		from, where := b.agentRow(s, quoteName(b.distributionDB()))
		pro = "DECLARE @job_id uniqueidentifier;\n" +
			"SELECT @job_id = sj.job_id " + from + " JOIN msdb.dbo.sysjobs AS sj ON sj.job_id = CONVERT(uniqueidentifier, a.job_id) WHERE " + where + ";\n" +
			"IF @job_id IS NULL THROW 50000, " + missing + ", 1;"
	}
	op := b.distOp(10, s.path+sep+"3", "job_enabled", "change", s.path, Call{Procedure: "msdb.dbo.sp_update_job", Prologue: pro, Params: []Param{
		{Name: "@job_id", Value: "@job_id"},
		{Name: "@enabled", Value: enabled},
	}})
	if s.kind == agentPull {
		op.Server = s.subscriber
	}
	if s.cur == nil {
		op.Warnings = append(op.Warnings, createdJobWarning)
	}
	withCites(&op, e)
	for _, n := range e.Notes {
		op.Sources = append(op.Sources, "note "+n)
	}
	op.Changes = []PropertyChange{{Path: ch.Path, Before: orEmpty(ch.Before), After: orEmpty(ch.After)}}
	op.Affects = s.affects()
	op.Reason = "the agent's job_enabled changes (R23)"
	op.Sources = append(op.Sources, "R23")
	b.add(op)
}

// schedule plans the changes of an agent's schedule, its fields grouped
// into one call (R22): sp_changepublication_snapshot for the snapshot agent,
// passing every @frequency_* and @active_* parameter of the file's
// schedule, @active_start_date and @active_start_time_of_day only when not
// zero (R37); for any other agent, one refusal (not measured).
func (b *builder) schedule(s agentSlot, changes []Change) {
	whole := Change{Path: s.path + ".schedules", Pattern: model.Pattern(s.path + ".schedules")}
	e, ok := cost.Lookup(whole.Path, "", s.pubType)
	if !ok || s.kind != agentSnapshot {
		b.unmeasured(whole)
		return
	}
	var sc model.Schedule
	if s.des.Schedules != nil {
		sc = (*s.des.Schedules)[0] // one schedule per agent (scheduleRefusals, R22)
	} else {
		def, ok := defaultSchedule(whole.Pattern, s.pubType)
		if !ok {
			b.unmeasured(whole)
			return
		}
		sc = def
	}
	freq, err := encFreq(sc.Frequency)
	if err != nil {
		b.refuse(whole.Path, "%v", err)
		return
	}
	subday, err := encSubday(sc.Subday)
	if err != nil {
		b.refuse(whole.Path, "%v", err)
		return
	}
	n := func(name string, v int) Param { return Param{Name: name, Value: strconv.Itoa(v)} }
	params := []Param{{Name: "@publication", Value: literal(s.pub)}, {Name: "@frequency_type", Value: freq},
		n("@frequency_interval", sc.Interval), {Name: "@frequency_subday", Value: subday},
		n("@frequency_subday_interval", sc.SubdayInterval)}
	if s.des.Schedules != nil {
		params = append(params, n("@frequency_relative_interval", sc.RelativeInterval),
			n("@frequency_recurrence_factor", sc.RecurrenceFactor))
		if sc.StartDate != 0 {
			params = append(params, n("@active_start_date", sc.StartDate))
		}
		params = append(params, n("@active_end_date", sc.EndDate))
		if sc.StartTime != 0 {
			params = append(params, n("@active_start_time_of_day", sc.StartTime))
		}
		params = append(params, n("@active_end_time_of_day", sc.EndTime))
	}
	op := b.newOp(10, s.path+sep+"2", "agent_schedule", "change", s.path, Call{Procedure: e.Procedure, Params: params})
	withCites(&op, e)
	for _, ch := range changes {
		op.Changes = append(op.Changes, PropertyChange{Path: ch.Path, Before: orEmpty(ch.Before), After: orEmpty(ch.After)})
	}
	op.Affects = s.affects()
	op.Reason = "the snapshot agent's schedule changes: one call with every frequency and active parameter (R22)"
	op.Sources = append(op.Sources, "R22", "spec Order step 10")
	b.add(op)
}
