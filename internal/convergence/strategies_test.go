package convergence

import (
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/rudi-bruchez/sqlserver-replication/internal/apply"
	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
	"github.com/rudi-bruchez/sqlserver-replication/internal/plan"
)

// The convergence tests of the publication-level strategies (plan 3, Task
// 20): immediate_sync, the deferred full snapshot, pull subscriptions and
// their extension, profiles, properties and schedules, and the refusal of
// unmeasured changes.

// refusedFatal fails the test when the plan has a refusal.
func refusedFatal(t *testing.T, p *plan.Plan, file string) {
	t.Helper()
	if len(p.Refusals) > 0 {
		t.Fatalf("%s refused:\n%s", file, p.Summary())
	}
}

// countProc returns the number of operations calling proc.
func countProc(p *plan.Plan, proc string) int {
	n := 0
	for _, op := range p.Operations {
		if procedure(op) == proc {
			n++
		}
	}
	return n
}

// isJob tells R24's job operations.
func isJob(op plan.Operation) bool { return strings.HasPrefix(op.Kind, "job_") }

// jobsAroundAll checks R24's job operations around every other operation
// of the plan: a job_disable before the first, and a job_restore after the
// last unless restore is false (the plan drops the job).
func jobsAroundAll(t *testing.T, p *plan.Plan, restore bool) {
	t.Helper()
	first, last := -1, -1
	for i, op := range p.Operations {
		if !isJob(op) {
			if first < 0 {
				first = i
			}
			last = i
		}
	}
	if first < 0 {
		t.Fatalf("no operation but job operations\n%s", p.Summary())
	}
	disable, restored := false, false
	for i, op := range p.Operations {
		disable = disable || op.Kind == "job_disable" && i < first
		restored = restored || op.Kind == "job_restore" && i > last
	}
	if !disable || restored != restore {
		t.Fatalf("job_disable before the first operation: %v, job_restore after the last: %v (want %v)\n%s",
			disable, restored, restore, p.Summary())
	}
}

// waitFor polls a COUNT query, placeholders replaced, every second, up to
// pollTimeout, until it returns want.
func (e *env) waitFor(t *testing.T, what, q string, want int) {
	t.Helper()
	e.waitForWithin(t, what, q, want, pollTimeout)
}

// waitForWithin is waitFor within timeout: one read when timeout is 0.
func (e *env) waitForWithin(t *testing.T, what, q string, want int, timeout time.Duration) {
	t.Helper()
	q = e.replace(q)
	deadline := time.Now().Add(timeout)
	var n int
	var err error
	for {
		err = e.master.QueryRow(q).Scan(&n)
		if err == nil && n == want {
			return
		}
		if time.Now().After(deadline) {
			break
		}
		time.Sleep(pollEvery)
	}
	t.Fatalf("%s: %d (%v) after %s, want %d\n%s", what, n, err, timeout, want, e.history())
}

// waitReady waits for the immediate_sync snapshot of a publication of {db}
// to be ready.
func (e *env) waitReady(t *testing.T, pub string) {
	t.Helper()
	e.waitFor(t, pub+" immediate_sync_ready",
		"SELECT COUNT(*) FROM {db}.dbo.syspublications WHERE name = N'"+pub+"' AND immediate_sync_ready = 1", 1)
}

// stopPushJob stops the push distribution job of pub's subscription to
// {sub} (an m_ job of the test) and waits until it reads idle.
func (e *env) stopPushJob(t *testing.T, pub string) {
	t.Helper()
	lookup := e.replace(`DECLARE @job_id uniqueidentifier = (SELECT CONVERT(uniqueidentifier, job_id)
FROM ` + quoteName(e.applied.DistributionDB) + `.dbo.MSdistribution_agents
WHERE publisher_db = N'{db}' AND publication = N'` + pub + `' AND subscriber_db = N'{sub}');`)
	if _, err := e.master.Exec(lookup + "\nIF NOT " + plan.JobIdle + " EXEC msdb.dbo.sp_stop_job @job_id = @job_id;"); err != nil {
		t.Errorf("stop the push job of %s: %v", pub, err)
		return
	}
	deadline := time.Now().Add(pollTimeout)
	for time.Now().Before(deadline) {
		var idle int
		if err := e.master.QueryRow(lookup + "\nSELECT CASE WHEN " + plan.JobIdle + " THEN 1 ELSE 0 END;").Scan(&idle); err == nil && idle == 1 {
			return
		}
		time.Sleep(pollEvery)
	}
	t.Errorf("the push job of %s still runs %s after its stop", pub, pollTimeout)
}

// pushRef is the push distribution agent of pub's subscription to {sub}.
func (e *env) pushRef(pub string) plan.AgentRef {
	return plan.AgentRef{Kind: "distribution", Publication: pub, Subscriber: e.server, Database: e.sub}
}

// pullRef is the pull agent of pub's subscription of {sub}.
func (e *env) pullRef(pub string) plan.AgentRef {
	return plan.AgentRef{Kind: "pull_distribution", Publication: pub, Subscriber: e.server, Database: e.sub}
}

func snapshotRef(pub string) plan.AgentRef { return plan.AgentRef{Kind: "snapshot", Publication: pub} }

// createImm plans imm.yaml (edited by edit when not nil) and applies it;
// apply confirms the delivery, the subscriber holds m_t1's 20 rows, the
// snapshot is ready and the next plan is empty.
func createImm(t *testing.T, e *env, edit func(*model.Config)) {
	t.Helper()
	des := e.desired(t, "imm.yaml")
	if edit != nil {
		edit(des)
	}
	p := e.plan(t, des, plan.Options{})
	refusedFatal(t, p, "imm.yaml")
	wantAgents(t, p, []plan.AgentRef{snapshotRef("m_pi"), e.pushRef("m_pi")})
	res := e.apply(t, des, plan.Options{}, apply.OutcomeApplied)
	e.wantDelivered(t, res, "m_pi")
	e.deliveries = []delivery{{"m_t1", 20}}
	e.checkDelivered(t)
	e.waitReady(t, "m_pi")
	e.converged(t, des)
}

func TestLabImmediateSync(t *testing.T) {
	e := labEnv(t, "imm")
	// A nonclustered index on m_t1, which the subscriber receives only once
	// the schema option nonclustered_indexes is set (imm-schema.yaml): it
	// shows that the reinitialization was delivered.
	if _, err := e.master.Exec(e.replace("CREATE INDEX m_ix_a ON {db}.dbo.m_t1 (a)")); err != nil {
		t.Fatal(err)
	}
	createImm(t, e, nil)
	ixAtSub := "SELECT COUNT(*) FROM {sub}.sys.indexes WHERE object_id = OBJECT_ID(N'{sub}.dbo.m_t1') AND name = N'm_ix_a'"
	if n := e.count(t, ixAtSub); n != 0 {
		t.Fatalf("the subscriber's m_t1 has the index m_ix_a without nonclustered_indexes")
	}

	// imm-add.yaml: sp_addarticle invalidates the ready snapshot and
	// subscribes the subscription by itself (R34, C.*.addarticle).
	des := e.desired(t, "imm-add.yaml")
	p := e.plan(t, des, plan.Options{})
	refusedFatal(t, p, "imm-add.yaml")
	add, err := find(p, "sp_addarticle", map[string]string{"@article": "N'm_t2'",
		"@force_invalidate_snapshot": "1", "@force_reinit_subscription": ""})
	if err != nil {
		t.Fatalf("%v\n%s%s", err, p.Summary(), p.SQL())
	}
	wantCosts(t, add, plan.CostNewSnapshot)
	if n := countProc(p, "sp_addsubscription"); n != 0 {
		t.Fatalf("%d sp_addsubscription, want none: sp_addarticle subscribes the subscription itself\n%s", n, p.Summary())
	}
	jobsAround(t, p)
	wantAgents(t, p, []plan.AgentRef{snapshotRef("m_pi"), e.pushRef("m_pi")})
	res := e.apply(t, des, plan.Options{}, apply.OutcomeApplied)
	e.wantDelivered(t, res, "m_pi")
	e.deliveries = []delivery{{"m_t2", 20}}
	e.checkDelivered(t)
	e.converged(t, des)

	// imm-schema.yaml: a schema option of m_t1, both flags (R9).
	des = e.desired(t, "imm-schema.yaml")
	p = e.plan(t, des, plan.Options{})
	refusedFatal(t, p, "imm-schema.yaml")
	chg, err := find(p, "sp_changearticle", map[string]string{"@article": "N'm_t1'", "@property": "N'schema_option'",
		"@force_invalidate_snapshot": "1", "@force_reinit_subscription": "1"})
	if err != nil {
		t.Fatalf("%v\n%s%s", err, p.Summary(), p.SQL())
	}
	wantCosts(t, chg, plan.CostReinitialization, plan.CostNewSnapshot, plan.CostSubscriberDataReplaced)
	jobsAround(t, p)
	wantAgents(t, p, []plan.AgentRef{snapshotRef("m_pi"), e.pushRef("m_pi")})
	res = e.apply(t, des, plan.Options{}, apply.OutcomeApplied)
	e.wantDelivered(t, res, "m_pi")
	e.deliveries = []delivery{{"m_t1", 20}, {"m_t2", 20}}
	e.checkDelivered(t)
	e.waitForWithin(t, "index m_ix_a at the subscriber", ixAtSub, 1, checkTimeout)
	e.converged(t, des)
}

func TestLabDeferFullSnapshot(t *testing.T) {
	e := labEnv(t, "deferfull")
	anonymous := func(c *model.Config) { c.Publications[0].AllowAnonymous = model.Ptr(true) }
	createImm(t, e, anonymous)

	des := e.desired(t, "imm-add.yaml")
	anonymous(des)
	p := e.plan(t, des, plan.Options{DeferFullSnapshot: true, Wait: 10 * time.Minute})
	refusedFatal(t, p, "imm-add.yaml")
	// The seven operations of TestDeferSequence, in this order, R24's job
	// operations around them.
	want := []string{
		"sp_changepublication allow_anonymous=false",
		"sp_changepublication immediate_sync=false",
		"sp_addarticle",
		"sp_addsubscription",
		"sp_startpublication_snapshot",
		"sp_changepublication immediate_sync=true",
		"sp_changepublication allow_anonymous=true",
	}
	var got []string
	for _, op := range p.Operations {
		if isJob(op) {
			continue
		}
		g := procedure(op)
		if g == "sp_changepublication" {
			prop, _ := param(op, "@property")
			val, _ := param(op, "@value")
			g += " " + strings.Trim(strings.TrimPrefix(prop, "N"), "'") + "=" + strings.Trim(strings.TrimPrefix(val, "N"), "'")
		}
		got = append(got, g)
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("operations:\n%s\nwant:\n%s\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"), p.Summary())
	}
	if _, err := find(p, "sp_addsubscription", map[string]string{"@article": "N'm_t2'"}); err != nil {
		t.Fatalf("%v\n%s", err, p.Summary())
	}
	jobsAroundAll(t, p, true)
	// The distribution agent delivers m_t2 between the generate_and_wait
	// and the restore of immediate_sync (final review item 3).
	wantAgents(t, p, []plan.AgentRef{e.pushRef("m_pi")})
	if want := []string{"the full generation is deferred to the next run of the snapshot agent of m_pi"}; !reflect.DeepEqual(p.Notes, want) {
		t.Errorf("notes of the deferral plan %q, want %q", p.Notes, want)
	}

	// apply waits for the delivery of m_t2 before the restore of
	// immediate_sync (R51, spec "-defer-full-snapshot" step 3). On the lab
	// a restore before the delivery does not block it, so the data checks
	// cannot see the order: it is read when the restore is sent. The push
	// agent of m_pi runs continuously and could deliver before apply's own
	// start of step 9; it is stopped when the generate_and_wait is sent, so
	// that the only delivery is the one that start brings.
	hooked := 0
	e.hook = func(op plan.Operation) {
		if op.Kind == "generate_and_wait" {
			e.stopPushJob(t, "m_pi")
			return
		}
		prop, _ := param(op, "@property")
		val, _ := param(op, "@value")
		if procedure(op) != "sp_changepublication" || prop != "N'immediate_sync'" || val != "N'true'" {
			return
		}
		hooked++
		var n int
		err := e.master.QueryRow(e.replace("SELECT COUNT(*) FROM {sub}.dbo.m_t2")).Scan(&n)
		if err != nil || n != 20 {
			t.Errorf("operation %d restores immediate_sync before the delivery of m_t2: %d rows (%v), want 20", op.Seq, n, err)
		}
	}
	res := e.apply(t, des, plan.Options{DeferFullSnapshot: true, Wait: 10 * time.Minute}, apply.OutcomeApplied)
	e.hook = nil
	if hooked != 1 {
		t.Errorf("the restore of immediate_sync was sent %d times through the hook, want 1", hooked)
	}
	e.wantDelivered(t, res, "m_pi")
	e.deliveries = []delivery{{"m_t2", 20}}
	e.checkDelivered(t)
	next := e.plan(t, des, plan.Options{})
	if len(next.Operations) != 0 || len(next.Refusals) != 0 {
		t.Fatalf("the plan after the deferral:\n%s", next.Summary())
	}
	note := "full generation deferred to the next run of the snapshot agent of m_pi"
	found := false
	for _, n := range next.Notes {
		found = found || n == note
	}
	if !found {
		t.Errorf("notes %q, want %q", next.Notes, note)
	}
	e.converged(t, des)
}

func TestLabPullSubscription(t *testing.T) {
	e := labEnv(t, "pullsub")
	des := e.desired(t, "pull.yaml")
	p := e.plan(t, des, plan.Options{})
	refusedFatal(t, p, "pull.yaml")
	inOrder(t, p, []step{
		{"sp_addsubscription", map[string]string{"@subscription_type": "N'pull'"}},
		{"sp_addpullsubscription", map[string]string{"@subscription_type": "N'pull'"}},
		{"sp_addpullsubscription_agent", nil},
	})
	subOps := 0
	for _, op := range p.Operations {
		switch procedure(op) {
		case "sp_addsubscription":
			subOps++
			if !strings.EqualFold(op.Database, e.db) {
				t.Errorf("sp_addsubscription in %s, want the publication database %s", op.Database, e.db)
			}
		case "sp_addpullsubscription", "sp_addpullsubscription_agent":
			subOps++
			if !strings.EqualFold(op.Database, e.sub) {
				t.Errorf("%s in %s, want the subscriber database %s", procedure(op), op.Database, e.sub)
			}
		}
	}
	if subOps != 3 {
		t.Fatalf("%d subscription operations, want 3\n%s", subOps, p.Summary())
	}
	jobsAround(t, p)
	wantAgents(t, p, []plan.AgentRef{snapshotRef("m_pp"), e.pullRef("m_pp")})
	// R51: the pull agent's job_start is sent only once the generation has
	// ended; a pull agent started before exits without delivering. The
	// second start (again) would hide a start in plan order from the data
	// checks, so the order is read when the statement is sent.
	hooked := 0
	e.hook = func(op plan.Operation) {
		if op.Kind != "job_start" || !strings.HasSuffix(op.Path, ".pull_agent") {
			return
		}
		hooked++
		if why := e.generationEnded("m_pp"); why != "" {
			t.Errorf("operation %d %s sent before the generation of m_pp ended: %s", op.Seq, op.Path, why)
		}
	}
	res := e.apply(t, des, plan.Options{}, apply.OutcomeApplied)
	e.hook = nil
	if hooked != 1 {
		t.Errorf("the pull agent's job_start was sent %d times through the hook, want 1", hooked)
	}
	e.wantDelivered(t, res, "m_pp")
	e.deliveries = []delivery{{"m_t1", 20}}
	e.checkDelivered(t)
	e.converged(t, des)

	// The file without the subscription: subscriber first (08-pull P3).
	des.Publications[0].Subscriptions = nil
	p = e.plan(t, des, plan.Options{})
	refusedFatal(t, p, "pull.yaml without its subscription")
	inOrder(t, p, []step{
		{"sp_droppullsubscription", nil},
		{"sp_dropsubscription", nil},
	})
	jobsAround(t, p)
	wantAgents(t, p, nil)
	res = e.apply(t, des, plan.Options{}, apply.OutcomeApplied)
	e.wantDelivered(t, res)
	e.converged(t, des)
}

func TestLabPullExtension(t *testing.T) {
	e := labEnv(t, "pullext")
	des := e.desired(t, "pull.yaml")
	p := e.plan(t, des, plan.Options{})
	refusedFatal(t, p, "pull.yaml")
	wantAgents(t, p, []plan.AgentRef{snapshotRef("m_pp"), e.pullRef("m_pp")})
	res := e.apply(t, des, plan.Options{}, apply.OutcomeApplied)
	e.wantDelivered(t, res, "m_pp")
	e.deliveries = []delivery{{"m_t1", 20}}
	e.checkDelivered(t)
	e.converged(t, des)

	des = e.desired(t, "pull-extend.yaml")
	p = e.plan(t, des, plan.Options{})
	refusedFatal(t, p, "pull-extend.yaml")
	inOrder(t, p, []step{
		{"sp_addarticle", map[string]string{"@article": "N'm_t2'"}},
		{"sp_addsubscription", map[string]string{"@article": "N'm_t2'"}},
	})
	var exts []plan.Operation
	for _, op := range p.Operations {
		if procedure(op) == "sp_addsubscription" {
			exts = append(exts, op)
		}
	}
	if len(exts) != 1 || !matches(exts[0], map[string]string{"@article": "N'm_t2'",
		"@subscription_type": "N'pull'", "@sync_type": "N'automatic'"}) {
		t.Fatalf("want one sp_addsubscription @article = N'm_t2', pull, automatic (R36)\n%s%s", p.Summary(), p.SQL())
	}
	wantCosts(t, exts[0], plan.CostNewSnapshot)
	jobsAround(t, p)
	wantAgents(t, p, []plan.AgentRef{snapshotRef("m_pp"), e.pullRef("m_pp")})
	res = e.apply(t, des, plan.Options{}, apply.OutcomeApplied)
	e.wantDelivered(t, res, "m_pp")
	e.deliveries = []delivery{{"m_t2", 20}}
	e.checkDelivered(t)
	e.converged(t, des)

	for _, f := range e.inputs(t, des).Current.Findings {
		if f.Kind == model.FindingIncomplete {
			t.Errorf("the export of %s has an incomplete finding: %s %s", e.db, f.Path, f.Message)
		}
	}
	if n := e.count(t, `SELECT COUNT(*) FROM distribution.dbo.MSdistribution_agents
WHERE publisher_db = N'{db}' AND publication = N'm_pp' AND subscriber_db = N'{sub}'`); n != 1 {
		t.Errorf("%d MSdistribution_agents rows for the subscription, want 1", n)
	}
}

func TestLabProfileConverges(t *testing.T) {
	e := labEnv(t, "profile")
	des := e.desired(t, "profile.yaml")
	file := e.load(t, "profile.yaml")
	if len(file.AgentProfiles) != 1 {
		t.Fatalf("profile.yaml has %d profiles, want 1", len(file.AgentProfiles))
	}
	// The template's parameters (R6), then the file's.
	prof := file.AgentProfiles[0]
	params := map[string]string{}
	for _, pp := range e.inputs(t, des).Facts.TemplateProfileParameters {
		if pp.AgentType == prof.AgentType {
			params[pp.Name] = pp.Value
		}
	}
	if len(params) == 0 {
		t.Fatalf("no template parameter of the %s agent in the facts", prof.AgentType)
	}
	if params["-CommitBatchSize"] == prof.Parameters["-CommitBatchSize"] {
		t.Fatalf("the template's -CommitBatchSize is already %s: the test changes nothing", params["-CommitBatchSize"])
	}
	for k, v := range prof.Parameters {
		params[k] = v
	}
	prof.Parameters = params
	des.AgentProfiles = append(des.AgentProfiles, prof)

	p := e.plan(t, des, plan.Options{})
	refusedFatal(t, p, "profile.yaml")
	if _, err := find(p, "sp_add_agent_profile", map[string]string{"@profile_name": "N'm_prof_profile'"}); err != nil {
		t.Fatalf("%v\n%s%s", err, p.Summary(), p.SQL())
	}
	if n := countProc(p, "sp_change_agent_parameter"); n != 1 {
		t.Fatalf("%d sp_change_agent_parameter, want 1\n%s%s", n, p.Summary(), p.SQL())
	}
	if _, err := find(p, "sp_change_agent_parameter", map[string]string{
		"@parameter_name": "N'-CommitBatchSize'", "@parameter_value": "N'200'"}); err != nil {
		t.Fatalf("%v\n%s%s", err, p.Summary(), p.SQL())
	}
	if n := countProc(p, "sp_add_agent_parameter"); n != 0 {
		t.Fatalf("%d sp_add_agent_parameter, want none\n%s%s", n, p.Summary(), p.SQL())
	}
	bind, err := find(p, "sp_update_agent_profile", nil)
	if err != nil {
		t.Fatalf("%v\n%s%s", err, p.Summary(), p.SQL())
	}
	if bind.Kind != "agent_binding" || bind.Step != 10 {
		t.Errorf("binding: kind %s step %d, want agent_binding in step 10", bind.Kind, bind.Step)
	}
	jobsAround(t, p)
	wantAgents(t, p, e.snapshotAndPush())
	res := e.apply(t, des, plan.Options{}, apply.OutcomeApplied)
	e.wantDelivered(t, res, "m_p")
	e.deliveries = []delivery{{"m_t1", 10}, {"m_t2", 20}}
	e.checkDelivered(t)
	e.converged(t, des)
}

func TestLabPropertiesAndSchedule(t *testing.T) {
	e := labEnv(t, "props")
	createAndDeliver(t, e)

	des := e.desired(t, "properties.yaml")
	p := e.plan(t, des, plan.Options{})
	refusedFatal(t, p, "properties.yaml")
	var changes []plan.Operation
	for _, op := range p.Operations {
		if !isJob(op) {
			changes = append(changes, op)
		}
	}
	if len(changes) != 3 {
		t.Fatalf("%d operations, want 3\n%s%s", len(changes), p.Summary(), p.SQL())
	}
	for _, op := range changes {
		if pr := procedure(op); pr != "sp_changepublication" && pr != "sp_changepublication_snapshot" {
			t.Errorf("%d %s %s: %s, want sp_changepublication or sp_changepublication_snapshot", op.Seq, op.Kind, op.Path, pr)
		}
		wantCosts(t, op, plan.CostOnline)
	}
	jobsAroundAll(t, p, true)
	wantAgents(t, p, nil)
	res := e.apply(t, des, plan.Options{}, apply.OutcomeApplied)
	e.wantDelivered(t, res)
	e.converged(t, des)

	// drop-publication.yaml: the subscription, then the publication; the
	// lab's profiles, copied into the file, stay out of the plan.
	des = e.desired(t, "drop-publication.yaml")
	p = e.plan(t, des, plan.Options{})
	refusedFatal(t, p, "drop-publication.yaml")
	inOrder(t, p, []step{
		{"sp_dropsubscription", nil},
		{"sp_droppublication", map[string]string{"@publication": "N'm_p'"}},
	})
	for _, op := range p.Operations {
		if strings.HasPrefix(op.Kind, "profile") || procedure(op) == "sp_replicationdboption" {
			t.Errorf("%d %s %s %s: no profile operation and no unpublishing (R27) expected", op.Seq, op.Kind, op.Path, procedure(op))
		}
	}
	// R61: the snapshot job of the dropped publication is restored on a way
	// out of apply before the drop, by a batch guarded on the job existing,
	// which does nothing once the drop has run (Task 4).
	jobsAroundAll(t, p, true)
	for _, op := range p.Operations {
		if op.Kind == "job_restore" && op.Call.Guard != "@job_id IS NOT NULL" {
			t.Errorf("%d job_restore %s: guard %q, want @job_id IS NOT NULL (R61)", op.Seq, op.Path, op.Call.Guard)
		}
	}
	wantAgents(t, p, nil)
	res = e.apply(t, des, plan.Options{}, apply.OutcomeApplied)
	e.wantDelivered(t, res)
	e.converged(t, des)
	if lr := e.inputs(t, des).Current.Publisher.LogReaderAgent; lr != nil {
		t.Errorf("the export still has a log reader agent after the drop of the last publication (R10)")
	}
}

func TestLabUnmeasuredRefused(t *testing.T) {
	e := labEnv(t, "unmeasured")
	createAndDeliver(t, e)

	p := e.plan(t, e.desired(t, "unmeasured.yaml"), plan.Options{})
	if len(p.Refusals) != 2 || len(p.Operations) != 0 {
		t.Fatalf("%d refusals and %d operations, want 2 and none\n%s", len(p.Refusals), len(p.Operations), p.Summary())
	}
	var paths []string
	for _, r := range p.Refusals {
		paths = append(paths, r.Path)
	}
	joined := strings.Join(paths, "\n")
	if !strings.Contains(joined, ".sync_method") || !strings.Contains(joined, ".distribution_agent.schedules") {
		t.Errorf("refusal paths:\n%s\nwant one at sync_method and one at the distribution agent's schedules", joined)
	}
}

// The reviewer's scenario of Task 20 (fix round 2): create.yaml, then the
// same file with sync_method character. sp_changepublication sync_method
// rewrites neither dest_owner nor the commands, so the plan is that call
// alone between R24's job operations, and the next plan is empty.
func TestLabSyncMethodCharacter(t *testing.T) {
	e := labEnv(t, "character")
	createAndDeliver(t, e)

	des := e.desired(t, "create.yaml")
	des.Publications[0].SyncMethod = model.Ptr("character")
	p := e.plan(t, des, plan.Options{})
	refusedFatal(t, p, "create.yaml with sync_method character")
	var got []string
	for _, op := range p.Operations {
		got = append(got, op.Kind+" "+procedure(op))
	}
	want := []string{"job_disable sp_update_job", "publication_property sp_changepublication", "job_restore sp_update_job"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("operations %q, want %q\n%s%s", got, want, p.Summary(), p.SQL())
	}
	chg := p.Operations[1]
	if v, _ := param(chg, "@property"); v != "N'sync_method'" {
		t.Errorf("@property %s, want N'sync_method'", v)
	}
	if v, _ := param(chg, "@value"); v != "N'character'" {
		t.Errorf("@value %s, want N'character'", v)
	}
	wantCosts(t, chg, plan.CostOnline)
	wantAgents(t, p, nil)
	res := e.apply(t, des, plan.Options{}, apply.OutcomeApplied)
	e.wantDelivered(t, res)
	e.converged(t, des)
}

// An omitted destination.schema corrects drift (Task 20 fix round 3, spec
// "Omitted properties"): archive is no sync method's default for m_t2, so
// the plan of create.yaml sets dbo back, with the reinit flag, since the
// subscription is at status 2. The drift is written into sysarticles, as a
// hand change that marks no subscription; the subscriber's m_t2 is emptied
// so that the reinitialization's delivery shows.
func TestLabDriftCorrected(t *testing.T) {
	e := labEnv(t, "drift")
	createAndDeliver(t, e)
	for _, q := range []string{
		"UPDATE {db}.dbo.sysarticles SET dest_owner = N'archive' WHERE name = N'm_t2'",
		"DELETE {sub}.dbo.m_t2",
	} {
		if _, err := e.master.Exec(e.replace(q)); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}

	des := e.desired(t, "create.yaml")
	p := e.plan(t, des, plan.Options{})
	refusedFatal(t, p, "create.yaml")
	chg, err := find(p, "sp_changearticle", map[string]string{"@article": "N'm_t2'",
		"@property": "N'destination_owner'", "@value": "N'dbo'", "@force_reinit_subscription": "1"})
	if err != nil {
		t.Fatalf("%v\n%s%s", err, p.Summary(), p.SQL())
	}
	wantCosts(t, chg, plan.CostReinitialization, plan.CostNewSnapshot, plan.CostSubscriberDataReplaced)
	jobsAround(t, p)
	wantAgents(t, p, e.snapshotAndPush())
	res := e.apply(t, des, plan.Options{}, apply.OutcomeApplied)
	e.wantDelivered(t, res, "m_p")
	e.deliveries = []delivery{{"m_t2", 20}}
	e.checkDelivered(t)
	e.converged(t, des)
}
