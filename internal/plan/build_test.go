package plan

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
	"github.com/rudi-bruchez/sqlserver-replication/internal/state"
)

// labChecks is what the precondition checks read on the lab: every table of
// the fixture found with its key and columns, its subscriber database and
// snapshot folder, the server at major 16 (Task 15).
func labChecks() *state.Checks {
	c := customerChecks("Customer")
	for _, n := range []string{"Orders", "Product", "vCustomerFR"} {
		c.Tables = append(c.Tables, state.TableCheck{Schema: "dbo", Name: n, Exists: true, HasPrimaryKey: n != "vCustomerFR",
			Columns: []string{"ID"}})
	}
	c.Servers = []state.ServerCheck{{Name: "repllab", Version: "16.0.4275.1", Edition: "Developer Edition (64-bit)", Reachable: true, Major: 16}}
	c.SubscriberDatabases = []state.DatabaseCheck{{Server: "REPLLAB", Database: "SalesSub", Checked: true, Exists: true}}
	c.Folders = []state.FolderCheck{{Server: "repllab", Path: "/var/opt/mssql/data/ReplData", Checked: true, Exists: true}}
	// The lab's profiles, as TestLabPrecheck reads them (in part).
	for _, t := range []string{"snapshot", "logreader", "distribution"} {
		c.Profiles = append(c.Profiles, state.ProfileCheck{Name: "Default agent profile", AgentType: t})
	}
	c.Profiles = append(c.Profiles, state.ProfileCheck{Name: "Verbose history agent profile.", AgentType: "distribution"},
		state.ProfileCheck{Name: "lab-distrib", AgentType: "distribution"})
	return c
}

// withTable adds a table to checks.
func withTable(c *state.Checks, name string, exists, key bool) *state.Checks {
	c.Tables = append(c.Tables, state.TableCheck{Schema: "dbo", Name: name, Exists: exists, HasPrimaryKey: key, Columns: []string{"id", "a"}})
	return c
}

// buildFull builds the lab fixture with checks, facts changed by fedit and
// the configurations by edit.
func buildFull(t *testing.T, checks *state.Checks, fedit func(f *state.Facts), edit func(des, cur *model.Config)) *Plan {
	t.Helper()
	des, facts := loadLab(t)
	cur, _ := loadLab(t)
	if fedit != nil {
		fedit(facts)
	}
	if edit != nil {
		edit(des, cur)
	}
	return Build(Inputs{Desired: des, Current: cur, Facts: facts, Checks: checks}, Options{})
}

func agentOf(f *state.Facts, kind, pub string) *state.AgentFacts {
	for i := range f.Agents {
		if f.Agents[i].Kind == kind && f.Agents[i].Publication == pub {
			return &f.Agents[i]
		}
	}
	return nil
}

func ofKind(ops []Operation, kind string) []Operation {
	var out []Operation
	for _, op := range ops {
		if op.Kind == kind {
			out = append(out, op)
		}
	}
	return out
}

func hasWarning(xs []string, sub string) bool {
	for _, x := range xs {
		if strings.Contains(x, sub) {
			return true
		}
	}
	return false
}

func TestBuildExportIsEmpty(t *testing.T) {
	p := buildFull(t, labChecks(), nil, nil)
	if !p.Empty() || len(p.Operations) != 0 || len(p.Refusals) != 0 || len(p.AgentsToStart) != 0 {
		t.Fatalf("the export against itself: refusals %+v, agents %+v, operations:\n%s", p.Refusals, p.AgentsToStart, opsString(p.Operations))
	}
	for _, pc := range p.Preconditions {
		if pc.Status != "ok" {
			t.Errorf("precondition %+v not ok", pc)
		}
	}
	if len(p.Preconditions) == 0 {
		t.Error("no precondition listed")
	}
}

func TestBuildOrderSteps(t *testing.T) {
	ops := withJobs(t, buildFull(t, nil, nil, orderStepsEdit(t)))
	for i := 1; i < len(ops); i++ {
		if ops[i].Step < ops[i-1].Step || ops[i].Seq != i+1 {
			t.Fatalf("operation %d step %d seq %d after step %d:\n%s", i+1, ops[i].Step, ops[i].Seq, ops[i-1].Step, opsString(ops))
		}
	}
	seq := func(proc string, match func(Operation) bool) []int {
		var out []int
		for _, op := range ops {
			if op.Call.Procedure == proc && (match == nil || match(op)) {
				out = append(out, op.Seq)
			}
		}
		if len(out) == 0 {
			t.Fatalf("no %s:\n%s", proc, opsString(ops))
		}
		return out
	}
	last := func(xs []int) int { return xs[len(xs)-1] }
	if d4, d5 := inStep(ops, 4), inStep(ops, 5); len(d4) == 0 || len(d5) == 0 || d4[len(d4)-1].Seq > d5[0].Seq {
		t.Errorf("the drops of step 4 come after step 5's:\n%s", opsString(ops))
	}
	if last(seq("sp_add_agent_profile", nil)) > seq("[distribution].dbo.sp_update_agent_profile", nil)[0] {
		t.Errorf("binding before the profile:\n%s", opsString(ops))
	}
	ofP := func(op Operation) bool { return first(op.Affects.Publications) == "m_p" }
	if seq("sp_addpublication", ofP)[0] > seq("sp_addarticle", ofP)[0] {
		t.Errorf("article before its publication:\n%s", opsString(ops))
	}
	if arts := seq("sp_addarticle", ofP); len(arts) != 2 || last(arts) > seq("sp_addsubscription", ofP)[0] {
		t.Errorf("sp_addarticle %v after the subscription:\n%s", arts, opsString(ops))
	}
	seq("sp_articlefilter", ofP)
}

// orderStepsEdit creates a profile, a publication with two articles, a
// filter and a push subscription bound to the profile, and drops SalesRef
// with its subscription and the shared agent only it uses.
func orderStepsEdit(t *testing.T) func(des, cur *model.Config) {
	return func(des, _ *model.Config) {
		des.AgentProfiles = append(des.AgentProfiles, model.AgentProfile{Name: "m_prof", AgentType: "distribution",
			Description: str(""), Default: model.Ptr(false), Parameters: labTemplate(t, "distribution")})
		p := testPub("m_p", filteredTable("m_t1"), newTable("m_t2"))
		p.IndependentAgent = model.Ptr(true)
		s := newSub("m_sdb", "push", "snapshot")
		s.DistributionAgent = &model.DistributionAgent{Agent: model.Agent{Profile: str("m_prof")}}
		p.Subscriptions = []model.Subscription{s}
		var keep []model.Publication
		for _, q := range des.Publications {
			if q.Name != "SalesRef" {
				keep = append(keep, q)
			}
		}
		des.Publications = append(keep, p)
		des.Publisher.SharedDistributionAgents = nil
	}
}

func TestBuildRepairsIncomplete(t *testing.T) {
	ops := withJobs(t, buildFull(t, nil, nil, func(_, cur *model.Config) {
		pubOf(t, cur, "SalesRef").SnapshotAgent = nil
		cur.Findings = append(cur.Findings, model.Finding{Kind: model.FindingIncomplete, Path: "publications[SalesRef].snapshot_agent",
			Message: "publication SalesRef: no snapshot agent found at the distributor"})
	}))
	snap := one(t, ops, "sp_addpublication_snapshot")
	wantParam(t, snap, "@publication", "N'SalesRef'")

	p := buildFull(t, nil, nil, func(_, cur *model.Config) {
		cur.Findings = append(cur.Findings, model.Finding{Kind: model.FindingIncomplete, Path: "publications[SalesRef].subscriptions[REPLLAB/SalesSub]",
			Message: "articles disagree on subscription_type, sync_type, update_mode or loopback_detection; the first article's values are exported"})
	})
	if len(p.Refusals) != 1 || !strings.HasSuffix(p.Refusals[0].Reason, "repair of this state is not measured") ||
		!strings.Contains(p.Refusals[0].Reason, "articles disagree on subscription_type") || len(p.Operations) != 0 {
		t.Errorf("refusals %+v, operations:\n%s", p.Refusals, opsString(p.Operations))
	}
}

func TestBuildRefusalsListedAll(t *testing.T) {
	checks := withTable(labChecks(), "m_t", true, false)
	checks.Servers[0].Major, checks.Servers[0].Version = 15, "15.0.4430.1"
	checks.SubscriberDatabases = append(checks.SubscriberDatabases, state.DatabaseCheck{Server: "REPLLAB", Database: "m_sdb", Checked: true})
	p := buildFull(t, checks, nil, func(des, _ *model.Config) {
		addTo(t, des, "SalesRef", newTable("m_t"))
		addSub(t, des, "SalesPub", newSub("m_sdb", "push", "snapshot"))
	})
	if len(p.Refusals) != 3 || len(p.Operations) != 0 {
		t.Errorf("%d refusals %+v, want 3; operations:\n%s", len(p.Refusals), p.Refusals, opsString(p.Operations))
	}
}

func TestBuildWarnings(t *testing.T) {
	p := buildFull(t, nil, func(f *state.Facts) {
		agentOf(f, "distribution", "SalesPub").Job.Running = false
		agentOf(f, "log_reader", "").Job.Running = false
		three := 3
		f.Subscriptions[0].Rows[0].DistributorStatus = &three // SalesPub, concurrent
	}, nil)
	if len(p.Refusals) != 0 {
		t.Fatalf("refusals %+v", p.Refusals)
	}
	if !hasWarning(p.Warnings, "publication SalesRef uses native, which locks the published tables for most of each generation; moving to concurrent costs a reinitialization") {
		t.Errorf("no lock warning on SalesRef: %q", p.Warnings)
	}
	if !hasWarning(p.Warnings, "distribution agent of subscription REPLLAB/SalesSub of SalesPub is stopped; plan cannot see a snapshot generated and not delivered (campaign item 14)") {
		t.Errorf("no warning on the stopped agent: %q", p.Warnings)
	}
	if !hasWarning(p.Warnings, "log reader agent of repllab.Sales is stopped") {
		t.Errorf("no warning naming the log reader: %q", p.Warnings)
	}
	if !hasWarning(p.Warnings, "publication SalesPub generates every article at every run of its snapshot agent (daily, every 5 minutes)") {
		t.Errorf("no full generation warning on SalesPub: %q", p.Warnings)
	}
}

func TestBuildAgentsToStart(t *testing.T) {
	p := buildFull(t, nil, nil, func(des, _ *model.Config) { addTo(t, des, "SalesRef", newTable("m_t")) })
	withJobs(t, p)
	want := []AgentRef{
		{Kind: "snapshot", Publication: "SalesRef", Reason: "pending"},
		{Kind: "distribution", Publication: "ALL", Subscriber: "REPLLAB", Database: "SalesSub", Reason: "delivery"},
	}
	if !equalRefs(p.AgentsToStart, want) {
		t.Errorf("agents to start %+v, want %+v", p.AgentsToStart, want)
	}

	p = buildFull(t, nil, nil, func(des, _ *model.Config) { addSub(t, des, "SalesPub", newSub("m_sdb", "push", "snapshot")) })
	withJobs(t, p)
	want = []AgentRef{{Kind: "distribution", Publication: "SalesPub", Subscriber: "REPLLAB", Database: "m_sdb", Reason: "delivery"}}
	if !equalRefs(p.AgentsToStart, want) {
		t.Errorf("S7: agents to start %+v, want %+v", p.AgentsToStart, want)
	}
}

func equalRefs(a, b []AgentRef) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestBuildDeferredGenerationNote(t *testing.T) {
	p := buildFull(t, nil, func(f *state.Facts) { f.Publications[0].ImmediateSyncReady = false }, nil)
	if len(p.Operations) != 0 || len(p.Refusals) != 0 || len(p.AgentsToStart) != 0 {
		t.Fatalf("refusals %+v, agents %+v, operations:\n%s", p.Refusals, p.AgentsToStart, opsString(p.Operations))
	}
	if !hasWarning(p.Notes, "full generation deferred to the next run of the snapshot agent of SalesPub") {
		t.Errorf("notes %q", p.Notes)
	}
}

func TestBuildDeterministic(t *testing.T) {
	render := func() string {
		checks := withTable(withTable(labChecks(), "m_t1", true, true), "m_t2", true, true)
		b, err := json.Marshal(buildFull(t, checks, nil, orderStepsEdit(t)))
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	if a, b := render(), render(); a != b {
		t.Errorf("two builds differ:\n%s\n%s", a, b)
	}
}

func TestBuildPreconditions(t *testing.T) {
	p := buildFull(t, withTable(labChecks(), "m_t", true, false), nil, func(des, _ *model.Config) { addTo(t, des, "SalesRef", newTable("m_t")) })
	if len(p.Refusals) != 1 || !strings.Contains(p.Refusals[0].Reason, "14088") {
		t.Errorf("a table without a key: refusals %+v", p.Refusals)
	}

	checks := labChecks()
	checks.SubscriberDatabases = append(checks.SubscriberDatabases, state.DatabaseCheck{Server: "REPLLAB", Database: "m_sdb", Checked: true})
	p = buildFull(t, checks, nil, func(des, _ *model.Config) { addSub(t, des, "SalesPub", newSub("m_sdb", "push", "snapshot")) })
	if len(p.Refusals) != 1 || !strings.Contains(p.Refusals[0].Reason, "m_sdb") {
		t.Errorf("a missing subscriber database: refusals %+v", p.Refusals)
	}

	p = buildFull(t, nil, nil, func(des, _ *model.Config) {
		addTo(t, des, "SalesRef", newTable("m_t"))
		addSub(t, des, "SalesPub", newSub("m_sdb", "push", "snapshot"))
	})
	withJobs(t, p)
	if len(p.Preconditions) == 0 {
		t.Error("no precondition without checks")
	}
	for _, pc := range p.Preconditions {
		if pc.Status != "unchecked" {
			t.Errorf("without checks: %+v", pc)
		}
	}

	checks = labChecks()
	checks.Servers[0].Major, checks.Servers[0].Version = 15, "15.0.4430.1"
	p = buildFull(t, checks, nil, nil)
	wantOnlyRefusal(t, p, "the cost table holds measurements of SQL Server 2022 (16.x) only; repllab runs 15.0.4430.1")
}

func TestBuildSecrets(t *testing.T) {
	edit := func(des, _ *model.Config) {
		s := newSub("m_sdb", "push", "snapshot")
		s.DistributionAgent = &model.DistributionAgent{Agent: model.Agent{Connection: &model.Connection{Security: str("sql"),
			Login: str("u"), PasswordSecret: str("SQLREPL_SQL_S_U")}}}
		addSub(t, des, "SalesPub", s)
	}
	for _, set := range []bool{false, true} {
		des, facts := loadLab(t)
		cur, _ := loadLab(t)
		edit(des, cur)
		p := Build(Inputs{Desired: des, Current: cur, Facts: facts, SecretSet: func(name string) bool { return set && name == "SQLREPL_SQL_S_U" }}, Options{})
		withJobs(t, p)
		if len(p.Secrets) != 1 || p.Secrets[0].Name != "SQLREPL_SQL_S_U" || p.Secrets[0].Set != set || len(p.Secrets[0].Operations) != 1 {
			t.Fatalf("secrets %+v, want SQLREPL_SQL_S_U once, set %v", p.Secrets, set)
		}
		agent := one(t, p.Operations, "sp_addpushsubscription_agent")
		if p.Secrets[0].Operations[0] != agent.Seq {
			t.Errorf("secret used by %v, the agent is %d", p.Secrets[0].Operations, agent.Seq)
		}
	}
}

func TestBuildJobOperations(t *testing.T) {
	// An article added to SalesRef.
	ops := withJobs(t, buildFull(t, nil, nil, func(des, _ *model.Config) { addTo(t, des, "SalesRef", newTable("m_t")) }))
	dis := ops[0]
	if dis.Kind != "job_disable" || dis.Step != 0 || dis.Seq != 1 || first(dis.Affects.Publications) != "SalesRef" ||
		!strings.Contains(dis.Call.Prologue, "[distribution].dbo.MSsnapshot_agents") || !strings.Contains(dis.Call.Prologue, "msdb.dbo.sysjobs") {
		t.Fatalf("first operation:\n%s\n%s", opsString(ops), dis.Call.Prologue)
	}
	wantParam(t, dis, "@enabled", "0")
	lastWork := 0
	for _, op := range ops {
		if op.Step >= 1 && op.Step <= 11 {
			lastWork = op.Seq
		}
		if op.Kind == "job_disable" || op.Kind == "job_restore" || op.Kind == "job_start" {
			wantOpCosts(t, op, CostOnline)
		}
	}
	tail := ops[lastWork:]
	if len(tail) != 3 || tail[0].Kind != "job_restore" || tail[1].Kind != "job_start" || tail[2].Kind != "job_start" {
		t.Fatalf("after the last operation:\n%s", opsString(tail))
	}
	wantParam(t, tail[0], "@enabled", "1")
	if tail[1].Call.Procedure != "msdb.dbo.sp_start_job" || !strings.Contains(tail[1].Call.Prologue, "MSsnapshot_agents") ||
		!strings.Contains(tail[2].Call.Prologue, "MSdistribution_agents") || !strings.Contains(tail[2].Call.Prologue, "a.publication = N'ALL'") {
		t.Errorf("starts:\n%s\n%s", tail[1].Call.Prologue, tail[2].Call.Prologue)
	}

	// A created publication: its disable right after its snapshot agent.
	ops = withJobs(t, buildFull(t, nil, nil, func(des, _ *model.Config) {
		des.Publications = append(des.Publications, testPub("m_p", newTable("m_t")))
	}))
	snap := one(t, ops, "sp_addpublication_snapshot")
	if next := ops[snap.Seq]; next.Kind != "job_disable" || next.Step != 8 || first(next.Affects.Publications) != "m_p" {
		t.Errorf("after the created snapshot agent:\n%s", opsString(ops))
	}
	for _, op := range inStep(ops, 0) {
		if first(op.Affects.Publications) == "m_p" {
			t.Errorf("a step 0 disable for the created publication:\n%s", opsString(ops))
		}
	}
	if r := ofKind(ops, "job_restore"); len(r) != 1 || first(r[0].Affects.Publications) != "m_p" {
		t.Errorf("restores:\n%s", opsString(r))
	}

	// A dropped publication: disabled, not restored.
	ops = withJobs(t, buildFull(t, nil, nil, func(des, _ *model.Config) {
		des.Publications = des.Publications[:1]
		des.Publisher.SharedDistributionAgents = nil
	}))
	if d := ofKind(ops, "job_disable"); len(d) != 1 || first(d[0].Affects.Publications) != "SalesRef" || d[0].Step != 0 {
		t.Errorf("disables:\n%s", opsString(ops))
	}
	if r := ofKind(ops, "job_restore"); len(r) != 0 {
		t.Errorf("a dropped publication restored:\n%s", opsString(ops))
	}

	// The repair of SalesRef's missing snapshot agent.
	ops = withJobs(t, buildFull(t, nil, nil, func(_, cur *model.Config) {
		pubOf(t, cur, "SalesRef").SnapshotAgent = nil
		cur.Findings = append(cur.Findings, model.Finding{Kind: model.FindingIncomplete, Path: "publications[SalesRef].snapshot_agent", Message: "no snapshot agent"})
	}))
	if len(inStep(ops, 0)) != 0 {
		t.Errorf("a step 0 disable for a repaired agent:\n%s", opsString(ops))
	}
	snap = one(t, ops, "sp_addpublication_snapshot")
	if next := ops[snap.Seq]; next.Kind != "job_disable" || next.Step != 8 {
		t.Errorf("after the repaired snapshot agent:\n%s", opsString(ops))
	}

	// A current agent whose job does not exist.
	p := buildFull(t, nil, func(f *state.Facts) { agentOf(f, "snapshot", "SalesRef").Job.Exists = false },
		func(des, _ *model.Config) { addTo(t, des, "SalesRef", newTable("m_t")) })
	wantHasRefusal(t, p, "publications[SalesRef].snapshot_agent",
		"the job of publications[SalesRef].snapshot_agent does not exist; sp_update_job would fail with 14262")
	if len(p.Operations) != 0 {
		t.Errorf("a refused plan has operations:\n%s", opsString(p.Operations))
	}

	// The export against itself.
	if p := buildFull(t, labChecks(), nil, nil); len(p.Operations) != 0 {
		t.Errorf("job operations on an empty plan:\n%s", opsString(p.Operations))
	}
}

func TestBuildJobEnabledReenable(t *testing.T) {
	ops := withJobs(t, buildFull(t, nil, nil, func(des, cur *model.Config) {
		pubOf(t, cur, "SalesRef").SnapshotAgent.JobEnabled = model.Ptr(false)
		pubOf(t, des, "SalesRef").SnapshotAgent.JobEnabled = nil
	}))
	if len(ops) != 2 || ops[0].Kind != "job_disable" || ops[0].Step != 0 || ops[1].Kind != "job_restore" {
		t.Fatalf("operations:\n%s", opsString(ops))
	}
	wantParam(t, ops[1], "@enabled", "1")
	if n := len(opsCalling(ops, "msdb.dbo.sp_update_job")); n != 2 {
		t.Errorf("%d sp_update_job, want 2", n)
	}
	for _, op := range ops {
		wantOpCosts(t, op, CostOnline)
	}
}

// withJobs is planned with R24's job operations, which planned leaves out
// for the tests of the strategies.
func withJobs(t *testing.T, p *Plan) []Operation {
	t.Helper()
	for _, r := range p.Refusals {
		t.Errorf("unexpected refusal %s: %s", r.Path, r.Reason)
	}
	if t.Failed() {
		t.FailNow()
	}
	return p.Operations
}
