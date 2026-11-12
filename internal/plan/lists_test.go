package plan

import (
	"fmt"
	"strings"
	"testing"

	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
	"github.com/rudi-bruchez/sqlserver-replication/internal/state"
)

// Task 15 fix round 1.

// unreachableChecks is labChecks with SUBX not reachable (R29).
func unreachableChecks() *state.Checks {
	c := labChecks()
	c.Servers = append(c.Servers, state.ServerCheck{Name: "SUBX", Error: "dial tcp: refused"})
	c.SubscriberDatabases = append(c.SubscriberDatabases, state.DatabaseCheck{Server: "SUBX", Database: "x"},
		state.DatabaseCheck{Server: "SUBX", Database: "y"})
	return c
}

func onSUBX(db, typ string) model.Subscription {
	s := newSub(db, typ, "snapshot")
	s.Subscriber = "SUBX"
	return s
}

func precondOf(p *Plan, name, object string) *Precondition {
	for i := range p.Preconditions {
		if p.Preconditions[i].Name == name && p.Preconditions[i].Object == object {
			return &p.Preconditions[i]
		}
	}
	return nil
}

func TestListsUnreachableSubscriber(t *testing.T) {
	// The review's input: pull SUBX/x and push SUBX/y.
	p := buildFull(t, unreachableChecks(), nil, func(des, _ *model.Config) {
		addSub(t, des, "SalesPub", onSUBX("x", "pull"))
		addSub(t, des, "SalesPub", onSUBX("y", "push"))
	})
	want := map[string]bool{"sp_addpullsubscription": true, "sp_addpullsubscription_agent": true, "msdb.dbo.sp_start_job": true}
	got := map[string]bool{}
	for _, r := range p.Refusals {
		if !strings.Contains(r.Reason, "runs at subscriber SUBX, which cannot be reached (dial tcp: refused) (R29)") ||
			!strings.HasPrefix(r.Path, "publications[SalesPub].subscriptions[SUBX/x]") {
			t.Errorf("refusal %s: %s", r.Path, r.Reason)
			continue
		}
		got[strings.SplitN(r.Reason, " ", 2)[0]] = true
	}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("refused %v, want %v; refusals %+v", got, want, p.Refusals)
	}
	if pc := precondOf(p, "server version", "SUBX"); pc == nil || pc.Status != "unchecked" || pc.Detail != "not reachable: dial tcp: refused" {
		t.Errorf("SUBX version precondition %+v", pc)
	}

	// Push alone: planned, its preconditions unchecked.
	p = buildFull(t, unreachableChecks(), nil, func(des, _ *model.Config) { addSub(t, des, "SalesPub", onSUBX("y", "push")) })
	ops := withJobs(t, p)
	one(t, ops, "sp_addsubscription")
	start := one(t, ops, "msdb.dbo.sp_start_job")
	if start.Server != "repllab" {
		t.Errorf("a push agent's start at %s", start.Server)
	}
	if pc := precondOf(p, "subscriber database", "y"); pc == nil || pc.Status != "unchecked" {
		t.Errorf("SUBX/y precondition %+v", pc)
	}

	// The drop of a pull subscription there.
	p = buildFull(t, unreachableChecks(), nil, func(des, cur *model.Config) {
		addSub(t, cur, "SalesPub", onSUBX("x", "pull"))
		samePullAgent(t, cur, cur, "SalesPub", "x")
	})
	wantHasRefusal(t, p, "publications[SalesPub].subscriptions[SUBX/x]",
		"sp_droppullsubscription runs at subscriber SUBX, which cannot be reached (dial tcp: refused) (R29)")
	if len(p.Operations) != 0 {
		t.Errorf("a refused plan has operations:\n%s", opsString(p.Operations))
	}
}

func TestListsJobMissingFindings(t *testing.T) {
	for _, path := range []string{"publisher.log_reader_agent", "publications[SalesRef].snapshot_agent"} {
		msg := "agent: job 0x01 recorded by replication no longer exists in msdb"
		p := buildFull(t, nil, nil, func(_, cur *model.Config) {
			cur.Findings = append(cur.Findings, model.Finding{Kind: model.FindingIncomplete, Path: path, Message: msg})
		})
		wantOnlyRefusal(t, p, msg+"; repair of this state is not measured")
	}
}

func TestListsJobMissingPaths(t *testing.T) {
	missing := func(f *state.Facts) { agentOf(f, "snapshot", "SalesRef").Job.Exists = false }
	reason := "the job of publications[SalesRef].snapshot_agent does not exist; sp_update_job would fail with 14262"
	// The disable alone: a job_enabled difference, nothing to start.
	p := buildFull(t, nil, missing, func(des, cur *model.Config) {
		pubOf(t, cur, "SalesRef").SnapshotAgent.JobEnabled = model.Ptr(false)
	})
	wantOnlyRefusal(t, p, reason)
	// The start alone: SalesRef pending before the plan, no operation.
	p = buildFull(t, nil, func(f *state.Facts) {
		missing(f)
		f.Subscriptions[1].Rows[0].PublisherStatus = 1
	}, nil)
	wantOnlyRefusal(t, p, reason)
	// And with the job: the start alone, with the note.
	p = buildFull(t, nil, func(f *state.Facts) { f.Subscriptions[1].Rows[0].PublisherStatus = 1 }, nil)
	ops := withJobs(t, p)
	if len(ops) != 2 || ops[0].Kind != "job_start" || ops[1].Kind != "job_start" || ops[1].Path != "publisher.shared_distribution_agents[REPLLAB/SalesSub].distribution_agent" {
		t.Errorf("operations:\n%s", opsString(ops))
	}
	if !hasWarning(p.Notes, "publication SalesRef already awaits a snapshot before this plan") {
		t.Errorf("notes %q", p.Notes)
	}
}

func TestListsPendingBeforeOnly(t *testing.T) {
	// SalesRef's Product row at 1 before the plan, the plan drops Product:
	// nothing pending after it, the snapshot agent is still listed.
	p := buildFull(t, nil, func(f *state.Facts) { f.Subscriptions[1].Rows[0].PublisherStatus = 1 },
		func(des, _ *model.Config) { removeArticle(t, des, "SalesRef", "Product") })
	withJobs(t, p)
	if len(p.AgentsToStart) == 0 || p.AgentsToStart[0] != (AgentRef{Kind: "snapshot", Publication: "SalesRef", Reason: "pending"}) {
		t.Errorf("agents %+v", p.AgentsToStart)
	}
}

func TestListsCreatedImmediateSyncWarning(t *testing.T) {
	p := buildFull(t, nil, nil, func(des, _ *model.Config) {
		q := testPub("m_p", newTable("m_t"))
		q.ImmediateSync, q.IndependentAgent, q.SyncMethod = model.Ptr(true), model.Ptr(true), str("concurrent")
		des.Publications = append(des.Publications, q)
	})
	withJobs(t, p)
	if !hasWarning(p.Warnings, "publication m_p generates every article at every run of its snapshot agent (daily, every 5 minutes)") {
		t.Errorf("warnings %q", p.Warnings)
	}
	// Disabled in the file: not recurring.
	p = buildFull(t, nil, nil, func(des, _ *model.Config) {
		q := testPub("m_p", newTable("m_t"))
		q.ImmediateSync, q.IndependentAgent, q.SyncMethod = model.Ptr(true), model.Ptr(true), str("concurrent")
		q.SnapshotAgent = &model.Agent{JobEnabled: model.Ptr(false)}
		des.Publications = append(des.Publications, q)
	})
	if hasWarning(p.Warnings, "publication m_p generates") {
		t.Errorf("a disabled job warns: %q", p.Warnings)
	}
}

// The commands measured with SQL Server authentication: no switch beyond
// the Windows ones (Task 15 review).
const (
	sqlPushCommand     = "-Subscriber [repllab] -SubscriberDB [SalesSub] -Publisher [repllab] -Distributor [repllab] -DistributorSecurityMode 1 -Publication [SalesPub] -PublisherDB [Sales]    -Continuous"
	sqlSnapshotCommand = "-Publisher [REPLLAB] -PublisherDB [Sales] -Distributor [REPLLAB] -Publication [SalesPub] -DistributorSecurityMode 1"
	sqlPullCommand     = "-Publisher [repllab] -PublisherDB [Sales] -Publication [SalesRef] -Distributor [repllab] -SubscriptionType 1 -Subscriber [repllab] -SubscriberSecurityMode 1 -SubscriberDB [SalesSub]"
)

func commandWarnings(p *Plan) []string {
	var out []string
	for _, w := range p.Warnings {
		if strings.HasPrefix(w, "the command line of ") {
			out = append(out, w)
		}
	}
	return out
}

func TestListsCommandSwitches(t *testing.T) {
	sqlAuth := func(des, cur *model.Config) {
		pullOnRef(t, des, cur)
		pa := *subOf(t, cur, "SalesRef", "SalesSub").PullAgent
		subOf(t, des, "SalesRef", "SalesSub").PullAgent = &pa
		both(des, cur, func(c *model.Config) {
			salesPubAgent(t, c).Command = str(sqlPushCommand)
			pubOf(t, c, "SalesPub").SnapshotAgent.Command = str(sqlSnapshotCommand)
			subOf(t, c, "SalesRef", "SalesSub").PullAgent.Command = str(sqlPullCommand)
		})
	}
	p := buildFull(t, nil, nil, sqlAuth)
	if w := commandWarnings(p); len(w) != 0 {
		t.Errorf("measured commands warn: %q", w)
	}
	if p := buildFull(t, nil, nil, nil); len(commandWarnings(p)) != 0 {
		t.Errorf("the fixture's commands warn: %q", commandWarnings(p))
	}

	// One switch more on each kind, a bracketed value with a dash ignored.
	p = buildFull(t, nil, nil, func(des, cur *model.Config) {
		sqlAuth(des, cur)
		salesPubAgent(t, cur).Command = str(sqlPushCommand + " -OutputVerboseLevel 2 -Publication [a -B]")
		pubOf(t, des, "SalesPub").SnapshotAgent.Command = str(sqlSnapshotCommand + " -MaxBcpThreads 4")
		subOf(t, des, "SalesRef", "SalesSub").PullAgent.Command = str(sqlPullCommand + " -QueryTimeout 9")
		des.Publisher.LogReaderAgent.Command = str(*des.Publisher.LogReaderAgent.Command + " -ReadBatchSize 5")
	})
	want := []string{
		"the command line of publisher.log_reader_agent holds -ReadBatchSize, which the replication procedures do not write: plan neither compares nor sets it (R32)",
		"the command line of publications[SalesPub].snapshot_agent holds -MaxBcpThreads, which the replication procedures do not write: plan neither compares nor sets it (R32)",
		"the command line of publications[SalesRef].subscriptions[REPLLAB/SalesSub].pull_agent holds -QueryTimeout, which the replication procedures do not write: plan neither compares nor sets it (R32)",
		"the command line of publications[SalesPub].subscriptions[REPLLAB/SalesSub].distribution_agent holds -OutputVerboseLevel, which the replication procedures do not write: plan neither compares nor sets it (R32)",
	}
	if got := commandWarnings(p); strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("command warnings:\n%s\nwant:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
}

func TestListsRestoreDisabled(t *testing.T) {
	ops := withJobs(t, buildFull(t, nil, nil, func(des, _ *model.Config) {
		pubOf(t, des, "SalesRef").SnapshotAgent.JobEnabled = model.Ptr(false)
	}))
	if len(ops) != 2 || ops[0].Kind != "job_disable" || ops[1].Kind != "job_restore" {
		t.Fatalf("operations:\n%s", opsString(ops))
	}
	wantParam(t, ops[1], "@enabled", "0")
	if len(ops[1].Changes) != 1 || ops[1].Changes[0] != (PropertyChange{Path: "publications[SalesRef].snapshot_agent.job_enabled", Before: "true", After: "false"}) {
		t.Errorf("restore changes %+v", ops[1].Changes)
	}
	// A created publication declared disabled: restored disabled.
	ops = withJobs(t, buildFull(t, nil, nil, func(des, _ *model.Config) {
		q := testPub("m_p", newTable("m_t"))
		q.SnapshotAgent = &model.Agent{JobEnabled: model.Ptr(false)}
		des.Publications = append(des.Publications, q)
	}))
	r := ofKind(ops, "job_restore")
	if len(r) != 1 {
		t.Fatalf("operations:\n%s", opsString(ops))
	}
	wantParam(t, r[0], "@enabled", "0")
	if len(r[0].Changes) != 0 {
		t.Errorf("a created job's restore has changes %+v", r[0].Changes)
	}
}

func TestListsPullJobAtSubscriber(t *testing.T) {
	p := buildFull(t, nil, nil, func(des, _ *model.Config) {
		s := newSub("m_pdb", "pull", "snapshot")
		s.Subscriber = "SUBP"
		addSub(t, des, "SalesPub", s)
	})
	ops := withJobs(t, p)
	want := []AgentRef{{Kind: "pull_distribution", Publication: "SalesPub", Subscriber: "SUBP", Database: "m_pdb", Reason: "delivery"}}
	if !equalRefs(p.AgentsToStart, want) {
		t.Errorf("agents %+v", p.AgentsToStart)
	}
	start := one(t, ops, "msdb.dbo.sp_start_job")
	if start.Server != "SUBP" || start.Database != "msdb" || start.Path != "publications[SalesPub].subscriptions[SUBP/m_pdb].pull_agent" ||
		!strings.Contains(start.Call.Prologue, "FROM [m_pdb].dbo.MSreplication_subscriptions AS rs") ||
		!strings.Contains(start.Call.Prologue, "rs.publication = N'SalesPub' AND rs.subscription_type = 1") {
		t.Errorf("pull start at %s.%s %s:\n%s", start.Server, start.Database, start.Path, start.Call.Prologue)
	}
	if pc := precondOf(p, "msdb job permission", jobPermissionObject); pc == nil {
		t.Errorf("preconditions %+v", p.Preconditions)
	}
	var servers []string
	for _, pc := range p.Preconditions {
		if pc.Name == "msdb job permission" && pc.Status == "unchecked" && pc.Detail == "not read" {
			servers = append(servers, pc.Server)
		}
	}
	if strings.Join(servers, ",") != "repllab,SUBP" {
		t.Errorf("msdb permission on %v, want once on repllab (the disable, restore and none of the starts) then SUBP", servers)
	}

	// Reachable in the checks: nothing refused (R29 only for unreachable).
	checks := labChecks()
	checks.Servers = append(checks.Servers, state.ServerCheck{Name: "SUBP", Reachable: true, Major: 16, Version: "16.0.4275.1"})
	withJobs(t, buildFull(t, checks, nil, func(des, _ *model.Config) {
		s := newSub("m_pdb", "pull", "snapshot")
		s.Subscriber = "SUBP"
		addSub(t, des, "SalesPub", s)
	}))

	// A pull agent that exists and whose job does not: refused.
	p = buildFull(t, nil, func(f *state.Facts) {
		f.Agents = append(f.Agents, state.AgentFacts{Kind: "pull_distribution", Publication: "SalesRef", Subscriber: "REPLLAB", Database: "SalesSub",
			Job: &state.JobState{}})
		f.Subscriptions[1].Rows[0].PublisherStatus = 1
	}, func(des, cur *model.Config) { pullOnRef(t, des, cur) })
	wantOnlyRefusal(t, p, "the job of publications[SalesRef].subscriptions[REPLLAB/SalesSub].pull_agent does not exist; sp_update_job would fail with 14262")
}

func TestListsTablePreconditions(t *testing.T) {
	p := buildFull(t, withTable(labChecks(), "m_t", false, false), nil, func(des, _ *model.Config) { addTo(t, des, "SalesRef", newTable("m_t")) })
	wantRefusal(t, p, "publications[SalesRef].articles[m_t]", "table dbo.m_t does not exist in Sales: plan does not create published tables (spec Non-goals)")
	if pc := precondOf(p, "published table", "dbo.m_t"); pc == nil || pc.Status != "failed" || pc.Server != "repllab" {
		t.Errorf("precondition %+v", pc)
	}
	// A view article without a key, or a table of a snapshot publication:
	// no key needed.
	checks := labChecks()
	checks.Tables[len(checks.Tables)-1].HasPrimaryKey = false // vCustomerFR
	p = buildFull(t, withTable(checks, "m_t", true, false), nil, func(des, _ *model.Config) {
		q := testPub("m_s", newTable("m_t"))
		q.Type = str("snapshot")
		des.Publications = append(des.Publications, q)
	})
	withJobs(t, p)
	if pc := precondOf(p, "published table", "dbo.m_t"); pc == nil || pc.Status != "ok" {
		t.Errorf("precondition %+v", pc)
	}
	// A table without a key, refused once whatever the articles on it.
	p = buildFull(t, withTable(labChecks(), "m_t", true, false), nil, func(des, _ *model.Config) {
		addTo(t, des, "SalesRef", newTable("m_t"))
		a := newTable("m_t")
		a.Name = "m_t_again"
		addTo(t, des, "SalesRef", a)
	})
	wantRefusal(t, p, "publications[SalesRef].articles[m_t]", "table dbo.m_t has no primary key: a table article of a transactional publication needs one (error 14088)")
}

func TestListsOtherPreconditions(t *testing.T) {
	// A missing snapshot folder: failed and a warning, never a refusal.
	checks := labChecks()
	checks.Folders[0].Exists = false
	p := buildFull(t, checks, nil, nil)
	if len(p.Refusals) != 0 || !hasWarning(p.Warnings, "snapshot folder /var/opt/mssql/data/ReplData is not visible to the SQL Server service at repllab") {
		t.Errorf("refusals %+v, warnings %q", p.Refusals, p.Warnings)
	}
	if pc := precondOf(p, "snapshot folder", "/var/opt/mssql/data/ReplData"); pc == nil || pc.Status != "failed" {
		t.Errorf("folder precondition %+v", pc)
	}
	checks.Folders[0].Checked = false
	if pc := precondOf(buildFull(t, checks, nil, nil), "snapshot folder", "/var/opt/mssql/data/ReplData"); pc == nil || pc.Status != "unchecked" {
		t.Errorf("unread folder precondition %+v", pc)
	}
	// An alternate folder is checked too.
	p = buildFull(t, labChecks(), nil, func(des, _ *model.Config) {
		pubOf(t, des, "SalesRef").Snapshot.AltFolder = str("/alt")
	})
	if pc := precondOf(p, "snapshot folder", "/alt"); pc == nil || pc.Status != "unchecked" {
		t.Errorf("alternate folder precondition %+v", pc)
	}

	// The edition of a database snapshot publication.
	dbsnap := func(des, _ *model.Config) {
		q := testPub("m_p", newTable("m_t"))
		q.SyncMethod = str("database_snapshot")
		des.Publications = append(des.Publications, q)
	}
	ok := withTable(labChecks(), "m_t", true, true)
	p = buildFull(t, ok, nil, dbsnap)
	withJobs(t, p)
	if pc := precondOf(p, "publisher edition", "m_p"); pc == nil || pc.Status != "ok" {
		t.Errorf("edition precondition %+v", pc)
	}
	std := withTable(labChecks(), "m_t", true, true)
	std.Servers[0].Edition = "Standard Edition (64-bit)"
	wantRefusal(t, buildFull(t, std, nil, dbsnap), "publications[m_p].sync_method",
		"sync_method database_snapshot needs the Enterprise or Developer edition of the publisher; repllab runs Standard Edition (64-bit)")
	if pc := precondOf(buildFull(t, nil, nil, dbsnap), "publisher edition", "m_p"); pc == nil || pc.Status != "unchecked" {
		t.Errorf("edition precondition without checks %+v", pc)
	}

	// A kept subscription's database missing: failed, not refused.
	checks = labChecks()
	checks.SubscriberDatabases[0].Exists = false
	p = buildFull(t, checks, nil, nil)
	if len(p.Refusals) != 0 {
		t.Errorf("refusals %+v", p.Refusals)
	}
	if pc := precondOf(p, "subscriber database", "SalesSub"); pc == nil || pc.Status != "failed" {
		t.Errorf("subscriber database precondition %+v", pc)
	}
	// Two subscriptions to one missing database: both refused.
	checks.SubscriberDatabases = append(checks.SubscriberDatabases, state.DatabaseCheck{Server: "REPLLAB", Database: "m_sdb", Checked: true})
	p = buildFull(t, checks, nil, func(des, _ *model.Config) {
		addSub(t, des, "SalesPub", newSub("m_sdb", "push", "snapshot"))
		addSub(t, des, "SalesRef", newSub("m_sdb", "push", "snapshot"))
	})
	if len(p.Refusals) != 2 {
		t.Errorf("refusals %+v", p.Refusals)
	}
}

func TestListsWarningsAndNotes(t *testing.T) {
	// The cost of a move to concurrent, from the predicted state.
	native := func(des, cur *model.Config) {
		both(des, cur, func(c *model.Config) { pubOf(t, c, "SalesPub").SyncMethod = str("native") })
	}
	p := buildFull(t, nil, nil, native)
	if !hasWarning(p.Warnings, "publication SalesPub uses native, which locks the published tables for most of each generation; moving to concurrent costs a reinitialization of every subscription plus the snapshot flag (its ready snapshot is invalidated); concurrent") {
		t.Errorf("warnings %q", p.Warnings)
	}
	p = buildFull(t, nil, nil, func(des, cur *model.Config) {
		both(des, cur, func(c *model.Config) { pubOf(t, c, "SalesRef").SyncMethod = str("character") })
		pubOf(t, des, "SalesRef").Subscriptions = nil
	})
	if !hasWarning(p.Warnings, "publication SalesRef uses character, which locks the published tables for most of each generation; moving to concurrent costs no flag and no reinitialization (no subscription row is delivered);") {
		t.Errorf("warnings %q", p.Warnings)
	}

	// A failed agent: R13's state after the last generation.
	p = buildFull(t, nil, func(f *state.Facts) {
		a := agentOf(f, "distribution", "ALL")
		a.LastHistory = &state.HistoryRow{Time: "2026-11-12 04:05:10.000", RunStatus: 6}
		a.LastFailure = a.LastHistory
	}, nil)
	if !hasWarning(p.Warnings, "distribution agent of subscription REPLLAB/SalesSub of SalesRef is failed;") {
		t.Errorf("warnings %q", p.Warnings)
	}
	// Running: no agent warning, and no log reader warning without status 3.
	p = buildFull(t, nil, func(f *state.Facts) { agentOf(f, "log_reader", "").Job.Running = false }, nil)
	if hasWarning(p.Warnings, "distribution agent of") || hasWarning(p.Warnings, "log reader agent") {
		t.Errorf("warnings %q", p.Warnings)
	}
	// Status 3 on a native publication: no log reader warning.
	p = buildFull(t, nil, func(f *state.Facts) {
		agentOf(f, "log_reader", "").Job.Running = false
		three := 3
		f.Subscriptions[1].Rows[0].DistributorStatus = &three
	}, nil)
	if hasWarning(p.Warnings, "log reader agent") {
		t.Errorf("warnings %q", p.Warnings)
	}

	// The restore of immediate_sync on a publication with subscriptions.
	p = buildFull(t, nil, nil, func(des, cur *model.Config) {
		pubOf(t, cur, "SalesPub").ImmediateSync = model.Ptr(false)
	})
	if !hasWarning(p.Notes, "restoring immediate_sync on SalesPub: the next run of its snapshot agent generates every article (the remainder of a deferred snapshot, if one was interrupted)") {
		t.Errorf("notes %q", p.Notes)
	}
	p = buildFull(t, nil, nil, func(des, cur *model.Config) {
		both(des, cur, func(c *model.Config) { pubOf(t, c, "SalesPub").Subscriptions = nil })
		pubOf(t, cur, "SalesPub").ImmediateSync = model.Ptr(false)
	})
	if hasWarning(p.Notes, "restoring immediate_sync") {
		t.Errorf("a publication without subscriptions: notes %q", p.Notes)
	}
	// An invalid immediate_sync snapshot the file drops immediate_sync on:
	// no deferred note.
	p = buildFull(t, nil, func(f *state.Facts) { f.Publications[0].ImmediateSyncReady = false }, func(des, _ *model.Config) {
		pubOf(t, des, "SalesPub").ImmediateSync = model.Ptr(false)
	})
	if hasWarning(p.Notes, "full generation deferred") {
		t.Errorf("notes %q", p.Notes)
	}
}

func TestListsSecretsSorted(t *testing.T) {
	des, facts := loadLab(t)
	cur, _ := loadLab(t)
	for _, db := range []string{"m_e", "m_b", "m_d", "m_a"} {
		s := newSub(db, "push", "snapshot")
		s.DistributionAgent = &model.DistributionAgent{Agent: model.Agent{Connection: &model.Connection{Security: str("sql"),
			Login: str("u"), PasswordSecret: str("SQLREPL_SQL_" + strings.ToUpper(db))}}}
		addSub(t, des, "SalesPub", s)
	}
	s := newSub("m_c", "push", "snapshot")
	s.DistributionAgent = &model.DistributionAgent{Agent: model.Agent{Connection: &model.Connection{Security: str("sql"),
		Login: str("u"), PasswordSecret: str("SQLREPL_SQL_M_A")}}}
	addSub(t, des, "SalesPub", s)
	p := Build(Inputs{Desired: des, Current: cur, Facts: facts}, Options{})
	withJobs(t, p)
	var names []string
	for _, s := range p.Secrets {
		names = append(names, s.Name)
	}
	if strings.Join(names, ",") != "SQLREPL_SQL_M_A,SQLREPL_SQL_M_B,SQLREPL_SQL_M_D,SQLREPL_SQL_M_E" ||
		len(p.Secrets[0].Operations) != 2 || p.Secrets[0].Set || p.Secrets[0].Operations[0] >= p.Secrets[0].Operations[1] {
		t.Errorf("secrets %+v", p.Secrets)
	}
}

// Task 17: the checks the planner reviews found missing.

func TestListsKeyColumnExcluded(t *testing.T) {
	dropKey := func(des, _ *model.Config) {
		articleOf(t, des, "SalesPub", "Customer").Columns = []string{"Name", "Country"}
	}
	wantRefusal(t, buildFull(t, labChecks(), nil, dropKey), "publications[SalesPub].articles[Customer].columns",
		"column CustomerID of dbo.Customer is part of its primary key and cannot be excluded (21250, measured)")
	// The key kept, its name in another case: planned.
	p := buildFull(t, labChecks(), nil, func(des, _ *model.Config) {
		articleOf(t, des, "SalesPub", "Customer").Columns = []string{"customerid", "Name"}
	})
	if len(p.Refusals) != 0 {
		t.Errorf("key kept: refusals %+v", p.Refusals)
	}
	// The table's key not read: unchecked.
	checks := labChecks()
	checks.Tables[0].KeyColumns = nil
	if p := buildFull(t, checks, nil, dropKey); hasRefusal(p, "publications[SalesPub].articles[Customer].columns",
		"column CustomerID of dbo.Customer is part of its primary key and cannot be excluded (21250, measured)") {
		t.Errorf("key not read: refusals %+v", p.Refusals)
	}
	if p := buildFull(t, nil, nil, dropKey); hasRefusal(p, "publications[SalesPub].articles[Customer].columns",
		"column CustomerID of dbo.Customer is part of its primary key and cannot be excluded (21250, measured)") {
		t.Errorf("without checks: refusals %+v", p.Refusals)
	}
}

func TestListsProfileNotFound(t *testing.T) {
	named := func(name string) func(des, _ *model.Config) {
		return func(des, _ *model.Config) { des.Publisher.LogReaderAgent.Profile = str(name) }
	}
	wantRefusal(t, buildFull(t, labChecks(), nil, named("m_none")), "publisher.log_reader_agent.profile",
		"profile m_none (logreader) exists neither in the file nor at the distributor")
	// A profile of another agent type does not match.
	wantRefusal(t, buildFull(t, labChecks(), nil, named("lab-distrib")), "publisher.log_reader_agent.profile",
		"profile lab-distrib (logreader) exists neither in the file nor at the distributor")
	// At the distributor, in another case: no refusal of the name.
	p := buildFull(t, labChecks(), nil, func(des, _ *model.Config) {
		des.Publisher.SharedDistributionAgents[0].DistributionAgent.Profile = str("LAB-DISTRIB")
	})
	for _, r := range p.Refusals {
		if strings.Contains(r.Reason, "exists neither") {
			t.Errorf("LAB-DISTRIB: %+v", r)
		}
	}
	// A profile of the file, unknown at the distributor: no refusal.
	p = buildFull(t, labChecks(), nil, func(des, _ *model.Config) {
		des.AgentProfiles = append(des.AgentProfiles, model.AgentProfile{Name: "m_lr", AgentType: "logreader", Parameters: labTemplate(t, "logreader")})
		des.Publisher.LogReaderAgent.Profile = str("M_LR")
	})
	for _, r := range p.Refusals {
		if strings.Contains(r.Reason, "exists neither") {
			t.Errorf("profile of the file: %+v", r)
		}
	}
	// Unchecked without checks, or when the profiles were not read.
	checks := labChecks()
	checks.Profiles = nil
	for _, c := range []*state.Checks{nil, checks} {
		for _, r := range buildFull(t, c, nil, named("m_none")).Refusals {
			if strings.Contains(r.Reason, "exists neither") {
				t.Errorf("unchecked: %+v", r)
			}
		}
	}
}

func TestListsServerNameAnswered(t *testing.T) {
	// A case-only difference passes (the lab answers repllab, the
	// fixture's subscriber is REPLLAB).
	checks := labChecks()
	checks.Servers[0].ServerName = "REPLLAB"
	if p := buildFull(t, checks, nil, nil); len(p.Refusals) != 0 {
		t.Errorf("case only: refusals %+v", p.Refusals)
	}
	// A NULL @@SERVERNAME (sp_dropserver without sp_addserver) reads "":
	// not compared.
	checks.Servers[0].ServerName = ""
	if p := buildFull(t, checks, nil, nil); len(p.Refusals) != 0 {
		t.Errorf("no server name: refusals %+v", p.Refusals)
	}
	checks.Servers[0].ServerName = "OTHERSRV"
	p := buildFull(t, checks, nil, nil)
	wantOnlyRefusal(t, p, "server repllab answers as OTHERSRV: check -server")
	if pc := precondOf(p, "server version", "repllab"); pc == nil || pc.Status != "failed" {
		t.Errorf("precondition %+v", pc)
	}
}

// A pull subscription removed from the file is dropped at a subscriber the
// file no longer names: with checks, that server must have a row, which
// then gets the reachability and @@SERVERNAME checks of the file's servers
// (Task 18 fix round 1, item 1).
func TestListsRemovedPullSubscriberChecked(t *testing.T) {
	removed := func(checks *state.Checks) *Plan {
		return buildFull(t, checks, nil, func(des, cur *model.Config) {
			addSub(t, cur, "SalesPub", onSUBX("x", "pull"))
			samePullAgent(t, cur, cur, "SalesPub", "x")
		})
	}
	path := "publications[SalesPub].subscriptions[SUBX/x]"

	// No row for SUBX: refused.
	p := removed(labChecks())
	wantHasRefusal(t, p, path, "sp_droppullsubscription runs at SUBX, of which the checks hold no row: no check of server SUBX (R29)")
	if len(p.Operations) != 0 {
		t.Errorf("a refused plan has operations:\n%s", opsString(p.Operations))
	}

	// A row naming another server: refused by the name check.
	answers := func(name string) *state.Checks {
		c := labChecks()
		c.Servers = append(c.Servers, state.ServerCheck{Name: "SUBX", ServerName: name, Version: "16.0.4275.1", Reachable: true, Major: 16})
		return c
	}
	p = removed(answers("OTHERSRV"))
	wantHasRefusal(t, p, "SUBX", "server SUBX answers as OTHERSRV: check -server")

	// A reached SUBX, or no checks at all: the drop is planned.
	for name, c := range map[string]*state.Checks{"reached": answers("subx"), "no checks": nil} {
		p := removed(c)
		if len(p.Refusals) != 0 || len(opsCalling(p.Operations, "sp_droppullsubscription")) != 1 {
			t.Errorf("%s: refusals %+v\n%s", name, p.Refusals, opsString(p.Operations))
		}
	}
}

// A push subscription whose job was deleted by hand is dropped when the file
// omits it or its publication: sp_dropsubscription @article = N'all'
// succeeds in that state (minor 8 of the final review, measured). Kept, it
// stays refused.
func TestDropSubscriptionWithoutJob(t *testing.T) {
	const path = "publications[SalesPub].subscriptions[REPLLAB/SalesSub].distribution_agent"
	const msg = "agent: job 0x01 recorded by replication no longer exists in msdb"
	missing := func(f *state.Facts) {
		for i := range f.Agents {
			if a := &f.Agents[i]; a.Kind == "distribution" && a.Publication == "SalesPub" {
				a.Job.Exists = false
			}
		}
	}
	finding := func(cur *model.Config) {
		cur.Findings = append(cur.Findings, model.Finding{Kind: model.FindingIncomplete, Path: path, Message: msg})
	}
	p := buildFull(t, nil, missing, func(des, cur *model.Config) {
		finding(cur)
		pubOf(t, des, "SalesPub").Subscriptions = nil
	})
	drop := one(t, withJobs(t, p), "sp_dropsubscription")
	wantParam(t, drop, "@article", "N'all'")
	wantParam(t, drop, "@publication", "N'SalesPub'")

	p = buildFull(t, nil, missing, func(des, cur *model.Config) {
		finding(cur)
		var keep []model.Publication
		for _, pub := range des.Publications {
			if pub.Name != "SalesPub" {
				keep = append(keep, pub)
			}
		}
		des.Publications = keep
	})
	one(t, withJobs(t, p), "sp_droppublication")

	p = buildFull(t, nil, missing, func(_, cur *model.Config) { finding(cur) })
	wantOnlyRefusal(t, p, msg+"; repair of this state is not measured")
}

// R62: every publication has its snapshot job lookup, the prologue of its
// job operations; an unknown publication has none.
func TestSnapshotJobLookup(t *testing.T) {
	p := buildLab(t, nil, func(des, _ *model.Config) {
		addTo(t, des, "SalesPub", newTable("m_t9"))
		addTo(t, des, "SalesRef", newTable("m_t9"))
	})
	planned(t, p)
	seen := map[string]bool{}
	for _, op := range ofKind(p.Operations, "job_disable") {
		pub := first(op.Affects.Publications)
		got, ok := p.SnapshotJobLookup(pub)
		if !ok || got != op.Call.Prologue {
			t.Errorf("SnapshotJobLookup(%s) = %q, %v; want the job_disable's prologue %q", pub, got, ok, op.Call.Prologue)
		}
		seen[pub] = true
	}
	for _, pub := range []string{"SalesPub", "SalesRef"} {
		if !seen[pub] {
			t.Errorf("no job_disable of %s", pub)
		}
	}
	if got, ok := p.SnapshotJobLookup("nope"); ok {
		t.Errorf("SnapshotJobLookup(nope) = %q, true; want none", got)
	}
}

// R61: a dropped publication's job is restored in step 12 to the value
// found, by a batch that does nothing once the job is gone.
func TestJobRestoreOfDroppedPublication(t *testing.T) {
	for _, enabled := range []bool{true, false} {
		p := buildFull(t, nil, nil, func(des, cur *model.Config) {
			pubOf(t, cur, "SalesRef").SnapshotAgent.JobEnabled = model.Ptr(enabled)
			removePub(des, "SalesRef")
		})
		var restores []Operation
		for _, op := range ofKind(p.Operations, "job_restore") {
			if op.Path == "publications[SalesRef].snapshot_agent" {
				restores = append(restores, op)
			}
		}
		if len(restores) != 1 {
			t.Fatalf("enabled %v: %d job_restore of SalesRef, want 1:\n%s", enabled, len(restores), opsString(p.Operations))
		}
		r := restores[0]
		if r.Step != 12 {
			t.Errorf("enabled %v: the restore is in step %d, want 12", enabled, r.Step)
		}
		if strings.Contains(r.Call.Prologue, "THROW") || !strings.Contains(r.Call.Prologue, "DECLARE @job_id uniqueidentifier;") {
			t.Errorf("enabled %v: prologue %q, want the lookup without THROW", enabled, r.Call.Prologue)
		}
		if r.Call.Guard != "@job_id IS NOT NULL" {
			t.Errorf("enabled %v: guard %q, want @job_id IS NOT NULL", enabled, r.Call.Guard)
		}
		want := "0"
		if enabled {
			want = "1"
		}
		wantParam(t, r, "@enabled", want)
	}
}

// removePub drops the publication named name from c.
func removePub(c *model.Config, name string) {
	var keep []model.Publication
	for _, p := range c.Publications {
		if p.Name != name {
			keep = append(keep, p)
		}
	}
	c.Publications = keep
}

// R55 and R56: the msdb job permission and SQL Server Agent of a server
// that runs job operations, from the checks.
func TestBuildJobPreconditions(t *testing.T) {
	const operatorDetail = "SQLAgentOperatorRole without SELECT on msdb.dbo.sysjobs, sysjobactivity and syssessions: the job prologue and JobIdle fail with 229 (20-apply AP.perm.m_ap_oper.prologue, .activity)"
	cases := []struct {
		name   string
		jp     *state.JobPermissionCheck
		ag     *state.AgentServiceCheck
		status string // of msdb job permission
		detail string
		agent  string // status of sql server agent
	}{
		{"sysadmin", &state.JobPermissionCheck{Checked: true, Sysadmin: true}, &state.AgentServiceCheck{Checked: true, Running: true, Detail: "SQL Server Agent (MSSQLSERVER): Running"},
			"ok", "sysadmin", "ok"},
		{"neither role", &state.JobPermissionCheck{Checked: true, ReadsJobs: true}, nil,
			"failed", "neither sysadmin nor a member of SQLAgentOperatorRole in msdb: the job operations fail with 229 or 14262 (20-apply AP.perm.m_ap_user, m_ap_none)", "unchecked"},
		{"operator without ReadsJobs", &state.JobPermissionCheck{Checked: true, Operator: true}, nil,
			"failed", operatorDetail, "unchecked"},
		{"operator with ReadsJobs", &state.JobPermissionCheck{Checked: true, Operator: true, ReadsJobs: true}, nil,
			"ok", "SQLAgentOperatorRole with SELECT on msdb.dbo.sysjobs, sysjobactivity and syssessions (that grant is not measured)", "unchecked"},
		{"not read", &state.JobPermissionCheck{}, &state.AgentServiceCheck{Detail: "sys.dm_server_services could not be read: x"},
			"unchecked", "not read", "unchecked"},
		{"no check", nil, &state.AgentServiceCheck{Checked: true, Detail: "SQL Server Agent (MSSQLSERVER): Stopped"},
			"unchecked", "not read", "failed"},
	}
	for _, c := range cases {
		checks := labChecks()
		if c.jp != nil {
			jp := *c.jp
			jp.Server = "REPLLAB" // the case does not count (R7)
			checks.JobPermissions = []state.JobPermissionCheck{jp}
		}
		if c.ag != nil {
			ag := *c.ag
			ag.Server = "repllab"
			checks.Agents = []state.AgentServiceCheck{ag}
		}
		p := buildFull(t, checks, nil, func(des, _ *model.Config) { addTo(t, des, "SalesRef", newTable("m_t")) })
		pc := precondOf(p, "msdb job permission", jobPermissionObject)
		if pc == nil || pc.Server != "repllab" || pc.Status != c.status || pc.Detail != c.detail {
			t.Errorf("%s: msdb job permission %+v, want %s: %s", c.name, pc, c.status, c.detail)
		}
		ag := precondOf(p, "sql server agent", agentObject)
		if ag == nil || ag.Server != "repllab" || ag.Status != c.agent {
			t.Errorf("%s: sql server agent %+v, want %s", c.name, ag, c.agent)
		}
		if ag != nil && c.agent == "failed" && ag.Detail != "SQL Server Agent is not running: the jobs apply starts would not run" {
			t.Errorf("%s: sql server agent detail %q", c.name, ag.Detail)
		}
		// A failed precondition does not refuse the plan (R58: apply does).
		if len(p.Refusals) != 0 {
			t.Errorf("%s: refusals %+v", c.name, p.Refusals)
		}
	}
	// Without job operations, neither is listed.
	p := buildFull(t, labChecks(), nil, nil)
	if precondOf(p, "msdb job permission", jobPermissionObject) != nil || precondOf(p, "sql server agent", agentObject) != nil {
		t.Errorf("preconditions without job operations %+v", p.Preconditions)
	}
}

// R59 minor 7: a new article whose destination schema is not dbo, whose
// schema_option lacks create_schemas, and whose schema the checks read
// absent at a subscriber gets a warning.
func TestBuildSchemaMissingWarns(t *testing.T) {
	const want = "schema m_nos does not exist at REPLLAB/SalesSub: the delivery fails"
	noCreate := []string{"object_creation", "custom_procedures", "identity_property", "clustered_index",
		"primary_key", "user_triggers", "nonclustered_indexes"}
	article := func(schema string, options []string) model.Article {
		a := newTable("m_t")
		a.Destination.Schema = model.Ptr(schema)
		if options != nil {
			a.SchemaOptions = &options
		}
		return a
	}
	run := func(a model.Article, schemas []state.SchemaCheck) Operation {
		t.Helper()
		checks := withTable(labChecks(), "m_t", true, true)
		checks.Schemas = schemas
		return one(t, planned(t, buildLab(t, checks, func(des, _ *model.Config) { addTo(t, des, "SalesRef", a) })), "sp_addarticle")
	}
	missing := []state.SchemaCheck{{Server: "REPLLAB", Database: "SalesSub", Schema: "m_nos", Checked: true}}
	wantWarning(t, run(article("m_nos", noCreate), missing), want)
	// Not read: the warning says so.
	wantWarning(t, run(article("m_nos", noCreate), nil), "schema m_nos may not exist at REPLLAB/SalesSub (not checked): the delivery fails if it does not")
	for name, op := range map[string]Operation{
		"exists":         run(article("m_nos", noCreate), []state.SchemaCheck{{Server: "REPLLAB", Database: "SalesSub", Schema: "m_nos", Checked: true, Exists: true}}),
		"create_schemas": run(article("m_nos", append(noCreate, "create_schemas")), missing),
		"dbo":            run(article("dbo", noCreate), nil),
	} {
		for _, w := range op.Warnings {
			if strings.Contains(w, "schema ") {
				t.Errorf("%s: warning %q", name, w)
			}
		}
	}
}
