package plan

import (
	"strings"
	"testing"

	"github.com/rudi-bruchez/sqlserver-replication/internal/cost"
	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
	"github.com/rudi-bruchez/sqlserver-replication/internal/state"
)

// buildLabFacts is buildLab with the facts changed by fedit too.
func buildLabFacts(t *testing.T, fedit func(f *state.Facts), edit func(des, cur *model.Config)) *Plan {
	t.Helper()
	des, facts := loadLab(t)
	cur, _ := loadLab(t)
	if fedit != nil {
		fedit(facts)
	}
	if edit != nil {
		edit(des, cur)
	}
	return Build(Inputs{Desired: des, Current: cur, Facts: facts}, Options{})
}

// wantOnlyRefusal checks that a plan has exactly one refusal, with reason.
func wantOnlyRefusal(t *testing.T, p *Plan, reason string) {
	t.Helper()
	if len(p.Refusals) != 1 || p.Refusals[0].Reason != reason {
		t.Errorf("refusals %+v, want one: %s", p.Refusals, reason)
	}
	if len(p.Operations) != 0 {
		t.Errorf("a refused plan has operations:\n%s", opsString(p.Operations))
	}
}

// labTemplate is the lab's template parameters of an agent type.
func labTemplate(t *testing.T, agentType string) map[string]string {
	t.Helper()
	_, f := loadLab(t)
	m := map[string]string{}
	for _, p := range f.TemplateProfileParameters {
		if p.AgentType == agentType {
			m[p.Name] = p.Value
		}
	}
	if len(m) == 0 {
		t.Fatalf("no template parameters for %s", agentType)
	}
	return m
}

func inStep(ops []Operation, step int) []Operation {
	var out []Operation
	for _, op := range ops {
		if op.Step == step {
			out = append(out, op)
		}
	}
	return out
}

func noDistributor(c *model.Config) *model.Config {
	c.Distributor = nil
	return c
}

func newDistributor(server string) *model.Distributor {
	return &model.Distributor{Server: server, Database: "distribution", AdminPasswordSecret: str("SQLREPL_SQL_S_DISTRIBUTOR_ADMIN")}
}

func TestDistributorCreateLocal(t *testing.T) {
	cur := normalized(t, noDistributor(testConfig()))
	des := testConfig()
	des.Distributor = newDistributor("s") // the publisher S, in another case
	ops := planned(t, Build(Inputs{Desired: des, Current: cur, Facts: &state.Facts{}}, Options{}))
	step1 := inStep(ops, 1)
	if len(step1) != 3 || len(ops) != 3 {
		t.Fatalf("%d operations in step 1 of %d, want 3:\n%s", len(step1), len(ops), opsString(ops))
	}
	for i, proc := range []string{"sp_adddistributor", "sp_adddistributiondb", "sp_adddistpublisher"} {
		if step1[i].Call.Procedure != proc {
			t.Errorf("operation %d calls %s, want %s", i+1, step1[i].Call.Procedure, proc)
		}
		if len(step1[i].Shared) != 0 {
			t.Errorf("%s shared with %v", proc, step1[i].Shared)
		}
	}
	if step1[0].Database != "master" || step1[0].Server != "s" {
		t.Errorf("sp_adddistributor at %s.%s, want s.master", step1[0].Server, step1[0].Database)
	}
	wantParam(t, step1[0], "@distributor", "N's'")
	wantParam(t, step1[1], "@database", "N'distribution'")
	wantParam(t, step1[2], "@publisher", "N'S'")
	wantParam(t, step1[2], "@distribution_db", "N'distribution'")
}

func TestDistributorRemoteRefused(t *testing.T) {
	cur := normalized(t, noDistributor(testConfig()))
	des := testConfig()
	des.Distributor = newDistributor("REMOTE")
	wantOnlyRefusal(t, Build(Inputs{Desired: des, Current: cur, Facts: &state.Facts{}}, Options{}), r17Remote)
}

func TestDistributorMoveRefused(t *testing.T) {
	wantOnlyRefusal(t, buildLab(t, nil, func(des, _ *model.Config) { des.Distributor.Server = "OTHER" }), distributorMove)
}

func TestDistributorChangeShared(t *testing.T) {
	ops := planned(t, buildLabFacts(t, func(f *state.Facts) {
		f.PublisherDatabases = []state.PublisherDatabase{
			{DistributionDB: "distribution", Publisher: "repllab", Database: "Sales"},
			{DistributionDB: "distribution", Publisher: "repllab", Database: "Other"},
		}
	}, func(des, _ *model.Config) { des.Distributor.MaxRetentionHours = model.Ptr(96) }))
	if len(ops) != 1 {
		t.Fatalf("%d operations, want 1:\n%s", len(ops), opsString(ops))
	}
	op := one(t, ops, "sp_changedistributiondb")
	if op.Step != 1 || op.Database != "master" {
		t.Errorf("step %d in %s", op.Step, op.Database)
	}
	wantParam(t, op, "@database", "N'distribution'")
	wantParam(t, op, "@property", "N'max_distretention'")
	wantParam(t, op, "@value", "N'96'")
	wantOpCosts(t, op, CostOnline, CostSharedObjectChanged)
	if strings.Join(op.Shared, ",") != "repllab.Other" {
		t.Errorf("shared %v, want [repllab.Other]", op.Shared)
	}
}

func TestProfileCreateBeforeBinding(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		des.AgentProfiles = append(des.AgentProfiles, model.AgentProfile{Name: "m_prof", AgentType: "distribution",
			Parameters: labTemplate(t, "distribution")})
		s := newSub("m_sdb", "push", "snapshot")
		s.DistributionAgent = &model.DistributionAgent{Agent: model.Agent{Profile: str("m_prof")}}
		addSub(t, des, "SalesPub", s)
	}))
	add := one(t, ops, "sp_add_agent_profile")
	bind := one(t, ops, "[distribution].dbo.sp_update_agent_profile")
	if add.Step != 2 || bind.Step != 10 || add.Seq > bind.Seq {
		t.Errorf("profile step %d seq %d, binding step %d seq %d:\n%s", add.Step, add.Seq, bind.Step, bind.Seq, opsString(ops))
	}
	wantParam(t, add, "@profile_name", "N'm_prof'")
	wantParam(t, add, "@agent_type", "3")
	if !strings.Contains(bind.Call.Prologue, "profile_name = N'm_prof' AND agent_type = 3") ||
		!strings.Contains(bind.Call.Prologue, "a.subscriber_db = N'm_sdb'") {
		t.Errorf("binding prologue:\n%s", bind.Call.Prologue)
	}
	// The template's parameters exactly: no parameter call.
	for _, proc := range []string{"sp_add_agent_parameter", "sp_change_agent_parameter", "sp_drop_agent_parameter"} {
		if n := len(opsCalling(ops, proc)); n != 0 {
			t.Errorf("%d %s", n, proc)
		}
	}
}

// useOf is a profile use of the lab's SalesPub subscription agent.
func useOf(profile string) state.ProfileUse {
	return state.ProfileUse{Profile: profile, AgentType: "distribution", DistributionDB: "distribution", Publisher: "repllab",
		PublisherDB: "Sales", Publication: "SalesPub", Subscriber: "REPLLAB", Database: "SalesSub"}
}

func TestProfileDropOnlyUnused(t *testing.T) {
	noProfiles := func(des, _ *model.Config) { des.AgentProfiles = nil }
	virtual := state.ProfileUse{Profile: "lab-distrib", AgentType: "distribution", DistributionDB: "distribution",
		Publisher: "repllab", PublisherDB: "Sales", Publication: "SalesPub", Virtual: true}
	for name, uses := range map[string][]state.ProfileUse{
		"other case": {useOf("LAB-DISTRIB")},
		"virtual":    {virtual},
	} {
		ops := planned(t, buildLabFacts(t, func(f *state.Facts) { f.ProfileUses = uses }, noProfiles))
		if len(ops) != 0 {
			t.Errorf("%s: a used profile is dropped:\n%s", name, opsString(ops))
		}
	}

	ops := planned(t, buildLab(t, nil, noProfiles))
	drop := one(t, ops, "sp_drop_agent_profile")
	if drop.Step != 11 || len(ops) != 1 {
		t.Errorf("drop in step %d:\n%s", drop.Step, opsString(ops))
	}
	if !strings.Contains(drop.Call.Prologue, "profile_name = N'lab-distrib' AND agent_type = 3") {
		t.Errorf("prologue:\n%s", drop.Call.Prologue)
	}

	ops = planned(t, buildLab(t, nil, func(des, _ *model.Config) { des.AgentProfiles[0].Name = "Lab-Distrib" }))
	if len(ops) != 0 {
		t.Errorf("Lab-Distrib matches lab-distrib (R7):\n%s", opsString(ops))
	}
}

// userDefault makes the lab's default distribution profile a user profile
// whose values differ from the template's (19-profiles
// PF.copy_after_user_default).
func userDefault(t *testing.T) (func(f *state.Facts), func(des, cur *model.Config)) {
	tpl := labTemplate(t, "distribution")
	user := map[string]string{}
	for k, v := range tpl {
		user[k] = v
	}
	user["-CommitBatchSize"] = "300"
	fedit := func(f *state.Facts) {
		for i := range f.DefaultProfiles {
			if f.DefaultProfiles[i].AgentType == "distribution" {
				f.DefaultProfiles[i].Name = "m_userdef"
			}
		}
	}
	edit := func(des, cur *model.Config) {
		both(des, cur, func(c *model.Config) {
			c.AgentProfiles = append(c.AgentProfiles, model.AgentProfile{Name: "m_userdef", AgentType: "distribution",
				Description: str(""), Default: model.Ptr(true), Parameters: user})
		})
		params := map[string]string{}
		for k, v := range tpl {
			params[k] = v
		}
		params["-CommitBatchSize"] = "200"
		params["-PacketSize"] = "8192"
		delete(params, "-QueryTimeout")
		des.AgentProfiles = append(des.AgentProfiles, model.AgentProfile{Name: "m_new", AgentType: "distribution", Parameters: params})
	}
	return fedit, edit
}

func TestProfileCreateCopiesParameters(t *testing.T) {
	fedit, edit := userDefault(t)
	check := func(drops int) {
		t.Helper()
		ops := planned(t, buildLabFacts(t, fedit, edit))
		one(t, ops, "sp_add_agent_profile")
		chg := one(t, ops, "sp_change_agent_parameter")
		wantParam(t, chg, "@parameter_name", "N'-CommitBatchSize'")
		wantParam(t, chg, "@parameter_value", "N'200'")
		add := one(t, ops, "sp_add_agent_parameter")
		wantParam(t, add, "@parameter_name", "N'-PacketSize'")
		wantParam(t, add, "@parameter_value", "N'8192'")
		got := opsCalling(ops, "sp_drop_agent_parameter")
		if len(got) != drops {
			t.Fatalf("%d sp_drop_agent_parameter, want %d:\n%s", len(got), drops, opsString(ops))
		}
		if drops == 1 {
			wantParam(t, got[0], "@parameter_name", "N'-QueryTimeout'")
		}
		for _, op := range append(append(opsCalling(ops, "sp_change_agent_parameter"), opsCalling(ops, "sp_add_agent_parameter")...), got...) {
			if op.Step != 2 || !strings.Contains(op.Call.Prologue, "profile_name = N'm_new'") {
				t.Errorf("%s in step %d, prologue %s", op.Call.Procedure, op.Step, op.Call.Prologue)
			}
		}
	}
	check(1)

	// Without PF.drop_parameter in the cost table, an omitted copied name
	// is kept and not compared (R6).
	saved := cost.Table
	t.Cleanup(func() { cost.Table = saved })
	table := make([]cost.Entry, len(saved))
	copy(table, saved)
	for i := range table {
		if table[i].Change != "agent_profiles[*].parameters" {
			continue
		}
		var cites []cost.Cite
		for _, c := range table[i].Cites {
			if !strings.HasSuffix(c.Row, "PF.drop_parameter") {
				cites = append(cites, c)
			}
		}
		table[i].Cites = cites
	}
	cost.Table = table
	check(0)
}

func TestProfileDefaultChangeRefused(t *testing.T) {
	wantOnlyRefusal(t, buildLab(t, nil, func(des, _ *model.Config) { des.AgentProfiles[0].Default = model.Ptr(true) }), r6Default)

	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) {
		des.AgentProfiles = append(des.AgentProfiles, model.AgentProfile{Name: "m_def", AgentType: "distribution",
			Default: model.Ptr(true), Parameters: labTemplate(t, "distribution")})
	}))
	wantParam(t, one(t, ops, "sp_add_agent_profile"), "@default", "1")
}

func TestProfileDropAfterLastUse(t *testing.T) {
	ops := planned(t, buildLabFacts(t, func(f *state.Facts) {
		f.ProfileUses = []state.ProfileUse{useOf("lab-distrib")}
	}, func(des, cur *model.Config) {
		subOf(t, cur, "SalesPub", "SalesSub").DistributionAgent.Profile = str("lab-distrib")
		pubOf(t, des, "SalesPub").Subscriptions = nil
		des.AgentProfiles = nil
	}))
	sub := one(t, ops, "sp_dropsubscription")
	drop := one(t, ops, "sp_drop_agent_profile")
	if sub.Step != 4 || drop.Step != 11 || sub.Seq > drop.Seq {
		t.Errorf("subscription drop step %d, profile drop step %d:\n%s", sub.Step, drop.Step, opsString(ops))
	}
}

// salesPubAgent is the desired and current push agent of SalesPub's
// subscription.
func salesPubAgent(t *testing.T, c *model.Config) *model.DistributionAgent {
	return subOf(t, c, "SalesPub", "SalesSub").DistributionAgent
}

func TestOmittedProfileIsDefault(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, cur *model.Config) {
		salesPubAgent(t, cur).Profile = str("lab-distrib")
		salesPubAgent(t, des).Profile = nil
	}))
	if len(ops) != 1 {
		t.Fatalf("%d operations, want 1:\n%s", len(ops), opsString(ops))
	}
	bind := ops[0]
	if bind.Kind != "agent_binding" || bind.Step != 10 {
		t.Errorf("%s in step %d", bind.Kind, bind.Step)
	}
	if !strings.Contains(bind.Call.Prologue, "profile_name = N'Default agent profile' AND agent_type = 3") {
		t.Errorf("binding prologue:\n%s", bind.Call.Prologue)
	}
	wantParam(t, bind, "@agent_type", "3")

	ops = planned(t, buildLab(t, nil, func(des, _ *model.Config) { salesPubAgent(t, des).Profile = nil }))
	if len(ops) != 0 {
		t.Errorf("bound to the default already:\n%s", opsString(ops))
	}
}

func TestAgentBindingCall(t *testing.T) {
	ops := planned(t, buildLab(t, nil, func(des, _ *model.Config) { salesPubAgent(t, des).Profile = str("lab-distrib") }))
	bind := one(t, ops, "[distribution].dbo.sp_update_agent_profile")
	if bind.Server != "repllab" || bind.Database != "distribution" {
		t.Errorf("binding at %s.%s", bind.Server, bind.Database)
	}
	wantParam(t, bind, "@agent_id", "@agent_id")
	wantParam(t, bind, "@profile_id", "@profile_id")
	for _, s := range []string{
		"DECLARE @agent_id int, @profile_id int;",
		"FROM [distribution].dbo.MSdistribution_agents AS a",
		"a.publication = N'SalesPub'", "UPPER(rs.srvname) = UPPER(N'REPLLAB')", "a.subscription_type = 0",
		"profile_name = N'lab-distrib' AND agent_type = 3",
		"IF @agent_id IS NULL OR @profile_id IS NULL THROW 50000",
	} {
		if !strings.Contains(bind.Call.Prologue, s) {
			t.Errorf("prologue lacks %q:\n%s", s, bind.Call.Prologue)
		}
	}
	wantOpCosts(t, bind, CostOnline)
}

func TestSnapshotScheduleChange(t *testing.T) {
	declare := func(start int) []Operation {
		return planned(t, buildLab(t, nil, func(des, _ *model.Config) {
			pubOf(t, des, "SalesPub").SnapshotAgent.Schedules = &[]model.Schedule{{Name: "m_s", Frequency: "daily", Interval: 1,
				Subday: "minutes", SubdayInterval: 10, StartDate: start}}
		}))
	}
	ops := declare(0)
	if len(ops) != 1 {
		t.Fatalf("%d operations, want 1:\n%s", len(ops), opsString(ops))
	}
	op := one(t, ops, "sp_changepublication_snapshot")
	if op.Step != 10 || op.Database != "Sales" {
		t.Errorf("step %d in %s", op.Step, op.Database)
	}
	for name, v := range map[string]string{
		"@publication": "N'SalesPub'", "@frequency_type": "4", "@frequency_interval": "1", "@frequency_subday": "4",
		"@frequency_subday_interval": "10", "@active_end_date": "99991231", "@active_end_time_of_day": "235959",
	} {
		wantParam(t, op, name, v)
	}
	noParam(t, op, "@active_start_date")
	noParam(t, op, "@active_start_time_of_day")
	wantOpCosts(t, op, CostOnline)

	wantParam(t, one(t, declare(20261201), "sp_changepublication_snapshot"), "@active_start_date", "20261201")
}

func TestUnmeasuredAgentChangesRefused(t *testing.T) {
	p := buildLab(t, nil, func(des, _ *model.Config) {
		salesPubAgent(t, des).Schedules = &[]model.Schedule{{Name: "m_s", Frequency: "daily", Interval: 1, Subday: "minutes", SubdayInterval: 10}}
		des.Publisher.LogReaderAgent.JobLogin = str(`REPLLAB\m_job`)
		pubOf(t, des, "SalesRef").SnapshotAgent.Connection.Login = str("m_login")
	})
	want := map[string]string{
		"publications[SalesPub].subscriptions[REPLLAB/SalesSub].distribution_agent.schedules": "cost of publications[*].subscriptions[*].distribution_agent.schedules change not measured",
		"publisher.log_reader_agent.job_login":                                                "publisher.log_reader_agent.job_login change refused by the server (14529)",
		"publications[SalesRef].snapshot_agent.connection.login":                              loginReason,
	}
	if len(p.Refusals) != len(want) {
		t.Errorf("%d refusals, want %d: %+v", len(p.Refusals), len(want), p.Refusals)
	}
	for _, r := range p.Refusals {
		if want[r.Path] != r.Reason {
			t.Errorf("refusal %s: %s, want %q", r.Path, r.Reason, want[r.Path])
		}
	}
}

func TestLogReaderCreatedForNewDatabase(t *testing.T) {
	cur := normalized(t, testConfig())
	des := testConfig(testPub("m_p", testTable("m_t", "dbo", "m_t")))
	ops := planned(t, Build(Inputs{Desired: des, Current: cur}, Options{}))
	opt := one(t, ops, "sp_replicationdboption")
	lr := one(t, ops, "sp_addlogreader_agent")
	pub := one(t, ops, "sp_addpublication")
	if opt.Step != 3 || lr.Step != 3 || !(opt.Seq < lr.Seq && lr.Seq < pub.Seq) {
		t.Errorf("dboption step %d seq %d, log reader step %d seq %d, publication seq %d", opt.Step, opt.Seq, lr.Step, lr.Seq, pub.Seq)
	}
	if opt.Database != "master" {
		t.Errorf("sp_replicationdboption in %s", opt.Database)
	}
	wantParam(t, opt, "@dbname", "N'D'")
	wantParam(t, opt, "@optname", "N'publish'")
	wantParam(t, opt, "@value", "N'true'")
}

// TestProfileCreatedParametersOnline: the parameter calls of a profile the
// plan creates cost online only, nothing using it yet; those of an existing
// profile change a shared object (Task 16 review).
func TestProfileCreatedParametersOnline(t *testing.T) {
	ops := planned(t, buildLabFacts(t, func(f *state.Facts) {
		f.PublisherDatabases = []state.PublisherDatabase{
			{DistributionDB: "distribution", Publisher: "repllab", Database: "Sales"},
			{DistributionDB: "distribution", Publisher: "repllab", Database: "Other"},
		}
	}, func(des, _ *model.Config) {
		params := labTemplate(t, "distribution")
		params["-PollingInterval"] = "7"
		des.AgentProfiles = append(des.AgentProfiles, model.AgentProfile{Name: "m_prof", AgentType: "distribution",
			Parameters: params})
		des.AgentProfiles[0].Parameters["-PollingInterval"] = "9"
	}))
	var created, existing int
	for _, op := range ops {
		if op.Kind != "profile_property" {
			continue
		}
		switch op.Path {
		case "agent_profiles[distribution/m_prof]":
			created++
			wantOpCosts(t, op, CostOnline)
		default:
			existing++
			wantOpCosts(t, op, CostOnline, CostSharedObjectChanged)
		}
	}
	if created != 1 || existing != 1 {
		t.Errorf("%d parameter calls of the created profile and %d of the existing one, want 1 and 1:\n%s", created, existing, opsString(ops))
	}
}
