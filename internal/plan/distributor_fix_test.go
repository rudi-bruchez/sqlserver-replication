package plan

import (
	"fmt"
	"strings"
	"testing"

	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
	"github.com/rudi-bruchez/sqlserver-replication/internal/state"
)

// hasRefusal tells whether a plan refuses path with reason.
func hasRefusal(p *Plan, path, reason string) bool {
	for _, r := range p.Refusals {
		if r.Path == path && r.Reason == reason {
			return true
		}
	}
	return false
}

func wantHasRefusal(t *testing.T, p *Plan, path, reason string) {
	t.Helper()
	if !hasRefusal(p, path, reason) {
		t.Errorf("no refusal at %s: %s; refusals %+v", path, reason, p.Refusals)
	}
}

func TestDistributorRetentionOrder(t *testing.T) {
	retention := func(min, max int) func(d *model.Distributor) {
		return func(d *model.Distributor) { d.MinRetentionHours, d.MaxRetentionHours = model.Ptr(min), model.Ptr(max) }
	}
	order := func(cur, des func(d *model.Distributor)) string {
		t.Helper()
		ops := planned(t, buildLab(t, nil, func(d, c *model.Config) { cur(c.Distributor); des(d.Distributor) }))
		var props []string
		for _, op := range opsCalling(ops, "sp_changedistributiondb") {
			v, _ := paramOf(op, "@property")
			props = append(props, v)
		}
		return strings.Join(props, ",")
	}
	// Both down (d10 after d9): min first, then max.
	if got := order(retention(2, 96), retention(0, 10)); got != "N'min_distretention',N'max_distretention'" {
		t.Errorf("both down: %s", got)
	}
	// Both up: max first.
	if got := order(retention(0, 72), retention(10, 100)); got != "N'max_distretention',N'min_distretention'" {
		t.Errorf("both up: %s", got)
	}
	// Max down and min up: min first keeps min <= max.
	if got := order(retention(0, 72), retention(10, 50)); got != "N'min_distretention',N'max_distretention'" {
		t.Errorf("max down, min up: %s", got)
	}
	// d19: a desired min above the max.
	p := buildLab(t, nil, func(d, _ *model.Config) { retention(50, 40)(d.Distributor) })
	wantRefusal(t, p, "distributor.min_retention_hours", "min_distretention 50 is above max_distretention 40 (14107, measured)")
}

func TestDistributorRefusalsAndRegistration(t *testing.T) {
	// R4: no distributor on either side.
	cur := normalized(t, noDistributor(testConfig()))
	wantOnlyRefusal(t, Build(Inputs{Desired: noDistributor(testConfig()), Current: cur}, Options{}), r4Declare)

	// The publisher is not registered (lenient read): R4 when the file names
	// no distribution database, R17 at a remote one, sp_adddistpublisher at a
	// local one.
	p := buildLab(t, nil, func(des, cur *model.Config) {
		cur.Distributor = &model.Distributor{Server: "repllab"}
		des.Distributor = nil
	})
	wantRefusal(t, p, "distributor.database", r4Declare)
	p = buildLab(t, nil, func(des, cur *model.Config) {
		cur.Distributor = &model.Distributor{Server: "REMOTE"}
		des.Distributor.Server = "remote"
	})
	wantRefusal(t, p, "distributor.server", r17Remote)
	ops := planned(t, buildLab(t, nil, func(_, cur *model.Config) { cur.Distributor = &model.Distributor{Server: "REPLLAB"} }))
	if len(ops) != 1 || ops[0].Call.Procedure != "sp_adddistpublisher" || ops[0].Step != 1 {
		t.Errorf("registration at a local distributor:\n%s", opsString(ops))
	}

	// A folder of the distribution database: no procedure changes it.
	p = buildLab(t, nil, func(des, _ *model.Config) { des.Distributor.DataFolder = str("/var/opt/mssql/m_data") })
	wantRefusal(t, p, "distributor.data_folder", fmt.Sprintf(noDistChange, "data_folder"))

	// The server named in another case is not a move.
	if ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) { des.Distributor.Server = "REPLLAB" })); len(ops) != 0 {
		t.Errorf("REPLLAB is repllab:\n%s", opsString(ops))
	}
}

func TestOmittedProfileBoundToNewDefault(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		des.AgentProfiles = append(des.AgentProfiles, model.AgentProfile{Name: "m_def", AgentType: "distribution",
			Default: model.Ptr(true), Parameters: labTemplate(t, "distribution")})
		salesPubAgent(t, des).Profile = nil
	}))
	add := one(t, ops, "sp_add_agent_profile")
	bind := one(t, ops, "[distribution].dbo.sp_update_agent_profile")
	if bind.Seq < add.Seq || !strings.Contains(bind.Call.Prologue, "profile_name = N'm_def' AND agent_type = 3") ||
		!strings.Contains(bind.Call.Prologue, "a.publication = N'SalesPub'") {
		t.Errorf("binding to the new default:\n%s\n%s", opsString(ops), bind.Call.Prologue)
	}
}

func TestJobEnabledOnAgents(t *testing.T) {
	// A created push agent declared disabled (d17): sp_update_job after its
	// creation, with the warning.
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		s := newSub("m_sdb", "push", "snapshot")
		s.DistributionAgent = &model.DistributionAgent{Agent: model.Agent{JobEnabled: model.Ptr(false)}}
		addSub(t, des, "SalesPub", s)
	}))
	job := one(t, ops, "msdb.dbo.sp_update_job")
	agent := one(t, ops, "sp_addpushsubscription_agent")
	wantParam(t, job, "@enabled", "0")
	if job.Step != 10 || job.Seq < agent.Seq || job.Database != "msdb" {
		t.Errorf("job step %d seq %d in %s, agent seq %d", job.Step, job.Seq, job.Database, agent.Seq)
	}
	wantWarning(t, job, createdJobWarning)

	// A created log reader.
	cur := normalized(t, testConfig())
	des := testConfig(testPub("m_p", testTable("m_t", "dbo", "m_t")))
	des.Publisher.LogReaderAgent = &model.Agent{JobEnabled: model.Ptr(false)}
	ops = planned(t, Build(Inputs{Desired: des, Current: cur}, Options{}))
	job, lr := one(t, ops, "msdb.dbo.sp_update_job"), one(t, ops, "sp_addlogreader_agent")
	if job.Seq < lr.Seq || !strings.Contains(job.Call.Prologue, "MSlogreader_agents") {
		t.Errorf("log reader job:\n%s", opsString(ops))
	}

	// An existing agent, each way.
	for _, on := range []bool{false, true} {
		ops := planned(t, buildLab(t, nil, func(des, cur *model.Config) {
			salesPubAgent(t, cur).JobEnabled = model.Ptr(!on)
			salesPubAgent(t, des).JobEnabled = model.Ptr(on)
		}))
		job := one(t, ops, "msdb.dbo.sp_update_job")
		want := "0"
		if on {
			want = "1"
		}
		wantParam(t, job, "@enabled", want)
		if len(job.Warnings) != 0 {
			t.Errorf("an existing agent: warnings %v", job.Warnings)
		}
	}

	// A pull agent: at the subscriber.
	ops = planned(t, buildLab(t, nil, func(des, cur *model.Config) {
		pullOnRef(t, des, cur)
		subOf(t, cur, "SalesRef", "SalesSub").PullAgent.JobEnabled = model.Ptr(true)
		a := *subOf(t, cur, "SalesRef", "SalesSub").PullAgent
		a.JobEnabled = model.Ptr(false)
		subOf(t, des, "SalesRef", "SalesSub").PullAgent = &a
	}))
	job = one(t, ops, "msdb.dbo.sp_update_job")
	if job.Server != "REPLLAB" || job.Database != "msdb" || !strings.Contains(job.Call.Prologue, "[SalesSub].dbo.MSreplication_subscriptions") {
		t.Errorf("pull job at %s.%s:\n%s", job.Server, job.Database, job.Call.Prologue)
	}

	// A shared pull agent: not measured.
	p := buildLab(t, nil, func(des, cur *model.Config) {
		both(des, cur, func(c *model.Config) {
			addSub(t, c, "SalesRef", newSub("m_pdb", "pull", "snapshot"))
			pubOf(t, c, "SalesRef").AllowPull = model.Ptr(true)
		})
		for _, x := range []struct {
			c  *model.Config
			on bool
		}{{cur, true}, {des, false}} {
			x.c.Publisher.SharedPullAgents = []model.SharedPullAgent{sharedPull("m_pdb", x.on)}
		}
	})
	wantHasRefusal(t, p, "publisher.shared_pull_agents[REPLLAB/m_pdb].job_enabled",
		"cost of publisher.shared_pull_agents[*].job_enabled change not measured")
}

func TestSharedPlacementRefused(t *testing.T) {
	// A per-subscription push agent on SalesRef, which has no
	// independent_agent.
	p := buildLab(t, nil, func(des, _ *model.Config) {
		a := *salesPubAgent(t, des)
		subOf(t, des, "SalesRef", "SalesSub").DistributionAgent = &a
	})
	wantHasRefusal(t, p, "publications[SalesRef].subscriptions[REPLLAB/SalesSub].distribution_agent", fmt.Sprintf(sharedPushDeclared, "SalesRef"))
	// A per-subscription pull agent there.
	p = buildLab(t, nil, func(des, _ *model.Config) {
		s := subOf(t, des, "SalesRef", "SalesSub")
		s.Type, s.PullAgent = str("pull"), &model.PullAgent{}
		pubOf(t, des, "SalesRef").AllowPull = model.Ptr(true)
	})
	wantHasRefusal(t, p, "publications[SalesRef].subscriptions[REPLLAB/SalesSub].pull_agent", fmt.Sprintf(sharedPullDeclared, "SalesRef"))
	// SalesRef made independent with its shared agent kept in the file.
	p = buildLab(t, nil, func(des, _ *model.Config) { pubOf(t, des, "SalesRef").IndependentAgent = model.Ptr(true) })
	wantHasRefusal(t, p, "publisher.shared_distribution_agents[REPLLAB/SalesSub]", fmt.Sprintf(sharedPushStale, "REPLLAB/SalesSub"))
}

func TestSnapshotAgentRepaired(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(_, cur *model.Config) { pubOf(t, cur, "SalesRef").SnapshotAgent = nil }))
	op := one(t, ops, "sp_addpublication_snapshot")
	if op.Step != 8 || first(op.Affects.Publications) != "SalesRef" {
		t.Errorf("repair in step %d, affects %v", op.Step, op.Affects)
	}
	wantParam(t, op, "@publication", "N'SalesRef'")
}

func TestProfileChanges(t *testing.T) {
	// Description.
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) { des.AgentProfiles[0].Description = str("m_changed") }))
	op := one(t, ops, "sp_change_agent_profile")
	wantParam(t, op, "@property", "N'description'")
	wantParam(t, op, "@value", "N'm_changed'")
	// A parameter named in another case: the held name is changed (M35).
	ops = planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		ps := des.AgentProfiles[0].Parameters
		delete(ps, "-CommitBatchSize")
		ps["-commitbatchsize"] = "300"
	}))
	op = one(t, ops, "sp_change_agent_parameter")
	wantParam(t, op, "@parameter_name", "N'-CommitBatchSize'")
	wantParam(t, op, "@parameter_value", "N'300'")
	if len(ops) != 1 {
		t.Errorf("operations:\n%s", opsString(ops))
	}
}

func TestBindingComparison(t *testing.T) {
	// A current profile not read: not compared (M9).
	if ops := planned(t, buildLab(t, nil, func(des, cur *model.Config) {
		salesPubAgent(t, cur).Profile = nil
		salesPubAgent(t, des).Profile = str("lab-distrib")
	})); len(ops) != 0 {
		t.Errorf("current profile not read:\n%s", opsString(ops))
	}
	// Another case: the same profile (M10).
	if ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		salesPubAgent(t, des).Profile = str("DEFAULT AGENT PROFILE")
	})); len(ops) != 0 {
		t.Errorf("profile in another case:\n%s", opsString(ops))
	}
	// A snapshot agent: its row with local_job = 1, type 1 (M11).
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) { pubOf(t, des, "SalesRef").SnapshotAgent.Profile = str("m_snap") }))
	bind := one(t, ops, "[distribution].dbo.sp_update_agent_profile")
	wantParam(t, bind, "@agent_type", "1")
	for _, s := range []string{"MSsnapshot_agents", "a.publication = N'SalesRef'", "a.local_job = 1"} {
		if !strings.Contains(bind.Call.Prologue, s) {
			t.Errorf("snapshot binding lacks %q:\n%s", s, bind.Call.Prologue)
		}
	}
	// A pull agent: subscription_type 1 (M12).
	ops = planned(t, buildLab(t, nil, func(des, cur *model.Config) {
		pullOnRef(t, des, cur)
		subOf(t, cur, "SalesRef", "SalesSub").PullAgent.Profile = str("Default agent profile")
		a := *subOf(t, cur, "SalesRef", "SalesSub").PullAgent
		a.Profile = str("lab-distrib")
		subOf(t, des, "SalesRef", "SalesSub").PullAgent = &a
	}))
	bind = one(t, ops, "[distribution].dbo.sp_update_agent_profile")
	if !strings.Contains(bind.Call.Prologue, "a.subscription_type = 1") {
		t.Errorf("pull binding:\n%s", bind.Call.Prologue)
	}
	// A shared agent names no publication in Affects (M39).
	ops = planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		des.Publisher.SharedDistributionAgents[0].DistributionAgent.Profile = str("lab-distrib")
	}))
	bind = one(t, ops, "[distribution].dbo.sp_update_agent_profile")
	if len(bind.Affects.Publications) != 0 || !strings.Contains(bind.Call.Prologue, "a.publication = N'ALL'") {
		t.Errorf("shared binding affects %v:\n%s", bind.Affects, bind.Call.Prologue)
	}
	// A log reader the plan creates again starts on the default (M38).
	ops = planned(t, buildLab(t, nil, func(des, cur *model.Config) {
		cur.Publisher.LogReaderAgent.Profile = str("m_lr")
		des.Publisher.LogReaderAgent.Profile = nil
		des.Publications = []model.Publication{testPub("m_p", testTable("m_t", "dbo", "m_t"))}
		des.Publisher.SharedDistributionAgents = nil
	}))
	one(t, ops, "sp_addlogreader_agent")
	if n := len(opsCalling(ops, "[distribution].dbo.sp_update_agent_profile")); n != 0 {
		t.Errorf("a recreated log reader is bound:\n%s", opsString(ops))
	}
}

// profileUse is a use of profile at this publication database.
func profileUse(profile, agentType, pub, subscriber, database string) state.ProfileUse {
	return state.ProfileUse{Profile: profile, AgentType: agentType, DistributionDB: "distribution", Publisher: "repllab",
		PublisherDB: "Sales", Publication: pub, Subscriber: subscriber, Database: database}
}

func TestProfileUsesAfterPlan(t *testing.T) {
	drops := func(uses []state.ProfileUse, profiles []model.AgentProfile, edit func(des, cur *model.Config)) int {
		t.Helper()
		ops := planned(t, buildLabFacts(t, func(f *state.Facts) { f.ProfileUses = uses }, func(des, cur *model.Config) {
			cur.AgentProfiles = append(cur.AgentProfiles, profiles...)
			des.AgentProfiles = nil
			edit(des, cur)
		}))
		return len(opsCalling(ops, "sp_drop_agent_profile")) - 1 // lab-distrib, unused, is dropped too
	}
	none := func(_, _ *model.Config) {}
	lr := model.AgentProfile{Name: "m_lr", AgentType: "logreader", Parameters: map[string]string{}}
	snap := model.AgentProfile{Name: "m_snap", AgentType: "snapshot", Parameters: map[string]string{}}
	dist := model.AgentProfile{Name: "m_dist", AgentType: "distribution", Parameters: map[string]string{}}

	// Named by an agent of the file (M1).
	if n := drops(nil, []model.AgentProfile{dist}, func(des, _ *model.Config) { salesPubAgent(t, des).Profile = str("m_dist") }); n != 0 {
		t.Errorf("a profile an agent of the file names is dropped")
	}
	// The log reader's, when every publication is dropped (M2).
	lrUse := []state.ProfileUse{profileUse("m_lr", "logreader", "", "", "")}
	if n := drops(lrUse, []model.AgentProfile{lr}, none); n != 0 {
		t.Errorf("the log reader's profile is dropped while the log reader stays")
	}
	if n := drops(lrUse, []model.AgentProfile{lr}, func(des, _ *model.Config) {
		des.Publications, des.Publisher.SharedDistributionAgents = nil, nil
	}); n != 1 {
		t.Errorf("every publication dropped: %d drops of m_lr", n)
	}
	// The shared push agent's, when its last push subscription is dropped
	// (M3).
	sharedUse := []state.ProfileUse{profileUse("m_dist", "distribution", "ALL", "REPLLAB", "SalesSub")}
	if n := drops(sharedUse, []model.AgentProfile{dist}, none); n != 0 {
		t.Errorf("the shared agent's profile is dropped while it serves SalesRef")
	}
	if n := drops(sharedUse, []model.AgentProfile{dist}, func(des, _ *model.Config) { pubOf(t, des, "SalesRef").Subscriptions = nil }); n != 1 {
		t.Errorf("last push subscription dropped: %d drops of m_dist", n)
	}
	// A shared pull agent stays after its last subscription (M4).
	pullUse := []state.ProfileUse{profileUse("m_dist", "distribution", "ALL", "REPLLAB", "m_pdb")}
	if n := drops(pullUse, []model.AgentProfile{dist}, func(des, cur *model.Config) {
		pubOf(t, cur, "SalesRef").AllowPull = model.Ptr(true)
		pubOf(t, des, "SalesRef").AllowPull = model.Ptr(true)
		addSub(t, cur, "SalesRef", newSub("m_pdb", "pull", "snapshot"))
	}); n != 0 {
		t.Errorf("a shared pull agent's profile is dropped")
	}
	// The snapshot agent's, when its publication is dropped (M31).
	snapUse := []state.ProfileUse{profileUse("m_snap", "snapshot", "SalesPub", "", "")}
	if n := drops(snapUse, []model.AgentProfile{snap}, func(des, _ *model.Config) {
		des.Publications = des.Publications[1:] // SalesRef
	}); n != 1 {
		t.Errorf("SalesPub dropped: %d drops of m_snap", n)
	}
}

func TestProfileDropAfterRebinding(t *testing.T) {
	// d5: SalesPub's agent is bound back to the default; lab-distrib, which
	// it used, is dropped in the same plan.
	ops := planned(t, buildLabFacts(t, func(f *state.Facts) {
		f.ProfileUses = []state.ProfileUse{useOf("lab-distrib")}
	}, func(des, cur *model.Config) {
		salesPubAgent(t, cur).Profile = str("lab-distrib")
		salesPubAgent(t, des).Profile = nil
		des.AgentProfiles = nil
	}))
	bind := one(t, ops, "[distribution].dbo.sp_update_agent_profile")
	drop := one(t, ops, "sp_drop_agent_profile")
	if drop.Step != 11 || drop.Seq < bind.Seq {
		t.Errorf("binding seq %d, drop step %d seq %d", bind.Seq, drop.Step, drop.Seq)
	}
	// Bound to the same profile in another case: the use stays.
	ops = planned(t, buildLabFacts(t, func(f *state.Facts) {
		f.ProfileUses = []state.ProfileUse{useOf("lab-distrib")}
	}, func(des, cur *model.Config) {
		salesPubAgent(t, cur).Profile = str("Default agent profile")
		salesPubAgent(t, des).Profile = str("LAB-DISTRIB")
		des.AgentProfiles = nil
	}))
	if n := len(opsCalling(ops, "sp_drop_agent_profile")); n != 0 {
		t.Errorf("a profile the plan binds to is dropped:\n%s", opsString(ops))
	}
}

// sharedPull is a shared pull agent as the export writes it.
func sharedPull(db string, enabled bool) model.SharedPullAgent {
	conn := func() *model.Connection { return &model.Connection{Security: str("windows"), Login: str("")} }
	a := model.SharedPullAgent{Subscriber: "REPLLAB", Database: db}
	a.JobEnabled, a.JobLogin, a.Profile = model.Ptr(enabled), str(""), str("Default agent profile")
	a.Connection, a.DistributorConnection = conn(), conn()
	a.SubscriptionStreams, a.MemoryOptimized = model.Ptr(0), model.Ptr(false)
	a.AltSnapshotFolder, a.WorkingDirectory, a.Description = str(""), str(""), str("")
	a.UseFTP, a.EnabledForSyncmgr = model.Ptr(false), model.Ptr(false)
	a.Schedules = &[]model.Schedule{}
	return a
}

// userDefaultSnapshot makes m_def, a user snapshot profile, the current
// default, used by SalesRef's snapshot agent.
func userDefaultSnapshot(f *state.Facts) {
	for i := range f.DefaultProfiles {
		if f.DefaultProfiles[i].AgentType == "snapshot" {
			f.DefaultProfiles[i].Name = "m_def"
		}
	}
	f.ProfileUses = []state.ProfileUse{profileUse("m_def", "snapshot", "SalesRef", "", "")}
}

func mDef() model.AgentProfile {
	return model.AgentProfile{Name: "m_def", AgentType: "snapshot", Description: str(""), Default: model.Ptr(true),
		Parameters: map[string]string{"-BcpBatchSize": "100000"}}
}

func TestOmittedProfileAfterDefaultDrop(t *testing.T) {
	// d23: the file drops m_def and omits SalesRef's snapshot profile: the
	// agent is bound to the template system profile, then m_def is dropped.
	ops := planned(t, buildLabFacts(t, userDefaultSnapshot, func(des, cur *model.Config) {
		cur.AgentProfiles = append(cur.AgentProfiles, mDef())
		pubOf(t, cur, "SalesRef").SnapshotAgent.Profile = str("m_def")
		pubOf(t, des, "SalesRef").SnapshotAgent.Profile = nil
	}))
	bind := one(t, ops, "[distribution].dbo.sp_update_agent_profile")
	drop := one(t, ops, "sp_drop_agent_profile")
	if !strings.Contains(bind.Call.Prologue, "SELECT @profile_id = MIN(profile_id) FROM msdb.dbo.MSagent_profiles WHERE agent_type = 1 AND type = 0;") ||
		bind.Changes[0].After != "the template system profile of snapshot" {
		t.Errorf("binding:\n%s\n%+v", bind.Call.Prologue, bind.Changes)
	}
	if !strings.Contains(drop.Call.Prologue, "N'm_def'") || drop.Seq < bind.Seq {
		t.Errorf("drop seq %d after binding seq %d:\n%s", drop.Seq, bind.Seq, drop.Call.Prologue)
	}
	// SalesPub's snapshot agent is on a system profile: not rebound.
	if n := len(opsCalling(ops, "[distribution].dbo.sp_update_agent_profile")); n != 1 {
		t.Errorf("%d bindings", n)
	}

	// The file keeps m_def as the default: SalesRef stays on it, no drop.
	ops = planned(t, buildLabFacts(t, userDefaultSnapshot, func(des, cur *model.Config) {
		both(des, cur, func(c *model.Config) { c.AgentProfiles = append(c.AgentProfiles, mDef()) })
		pubOf(t, cur, "SalesRef").SnapshotAgent.Profile = str("m_def")
		pubOf(t, des, "SalesRef").SnapshotAgent.Profile = nil
	}))
	if len(ops) != 0 {
		t.Errorf("a kept default:\n%s", opsString(ops))
	}
}

func TestBoundProfileKept(t *testing.T) {
	// A profile absent from the file that an agent of the plan is bound to
	// is not dropped.
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		des.AgentProfiles = nil
		salesPubAgent(t, des).Profile = str("lab-distrib")
	}))
	one(t, ops, "[distribution].dbo.sp_update_agent_profile")
	if n := len(opsCalling(ops, "sp_drop_agent_profile")); n != 0 {
		t.Errorf("a profile the plan binds to is dropped:\n%s", opsString(ops))
	}
}

func TestDefaultProfileChecks(t *testing.T) {
	// Two desired defaults of one type.
	p := buildLab(t, nil, func(des, _ *model.Config) {
		for _, n := range []string{"m_a", "m_b"} {
			des.AgentProfiles = append(des.AgentProfiles, model.AgentProfile{Name: n, AgentType: "snapshot",
				Default: model.Ptr(true), Parameters: labTemplate(t, "snapshot")})
		}
	})
	wantRefusal(t, p, "agent_profiles[snapshot/m_b].default", "profiles m_a and m_b are both the default of snapshot")
	// d24: a new default while the file keeps the current user default
	// without default true.
	p = buildLabFacts(t, userDefaultSnapshot, func(des, cur *model.Config) {
		cur.AgentProfiles = append(cur.AgentProfiles, mDef())
		kept := mDef()
		kept.Default = nil
		des.AgentProfiles = append(des.AgentProfiles, kept, model.AgentProfile{Name: "m_new", AgentType: "snapshot",
			Default: model.Ptr(true), Parameters: labTemplate(t, "snapshot")})
	})
	wantRefusal(t, p, "agent_profiles[snapshot/m_def].default", r6Default)
}

func TestCreatedSnapshotJobEnabledLeft(t *testing.T) {
	// N7: a created snapshot agent declared disabled is Task 15's
	// job_restore, not an sp_update_job of this strategy.
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		p := testPub("m_p", testTable("m_t", "dbo", "m_t"))
		p.SnapshotAgent = &model.Agent{JobEnabled: model.Ptr(false)}
		des.Publications = append(des.Publications, p)
	}))
	one(t, ops, "sp_addpublication_snapshot")
	if n := len(opsCalling(ops, "msdb.dbo.sp_update_job")); n != 0 {
		t.Errorf("%d sp_update_job for a created snapshot agent:\n%s", n, opsString(ops))
	}
}
