package plan

import (
	"reflect"
	"strings"
	"testing"

	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
	"github.com/rudi-bruchez/sqlserver-replication/internal/normalize"
	"github.com/rudi-bruchez/sqlserver-replication/internal/state"
)

// labPair loads the lab fixture twice: a desired and a current that share
// nothing.
func labPair(t *testing.T) (des, cur *model.Config) {
	t.Helper()
	des, _ = loadLab(t)
	cur, _ = loadLab(t)
	return des, cur
}

func pubOf(t *testing.T, c *model.Config, name string) *model.Publication {
	t.Helper()
	for i := range c.Publications {
		if c.Publications[i].Name == name {
			return &c.Publications[i]
		}
	}
	t.Fatalf("no publication %s", name)
	return nil
}

func pubPathOf(name string) string { return "publications" + model.Element(name) }

// diffAll compares every object of the two configurations the comparison
// looks at: the publisher, the distributor, the shared agents, the
// publications, their articles and subscriptions, the profiles.
func diffAll(t *testing.T, des, cur *model.Config) []Change {
	t.Helper()
	never := func(string) bool { return false }
	out := diffObject("publisher", &des.Publisher, &cur.Publisher, never)
	out = append(out, diffObject("distributor", des.Distributor, cur.Distributor, never)...)
	sd, dOnly, cOnly := matchFold(des.Publisher.SharedDistributionAgents, cur.Publisher.SharedDistributionAgents,
		func(a *model.SharedDistributionAgent) (string, string) { return a.Subscriber, a.Database })
	if len(dOnly)+len(cOnly) > 0 {
		t.Fatalf("shared agents unmatched: %d desired, %d current", len(dOnly), len(cOnly))
	}
	for _, p := range sd {
		out = append(out, diffObject("publisher.shared_distribution_agents"+model.Element(p.Des.Key()), p.Des, p.Cur, never)...)
	}
	pubs, dp, cp := matchPublications(des.Publications, cur.Publications)
	if len(dp)+len(cp) > 0 {
		t.Fatalf("publications unmatched: %d desired, %d current", len(dp), len(cp))
	}
	for _, p := range pubs {
		pp := pubPathOf(p.Des.Name)
		out = append(out, diffObject(pp, p.Des, p.Cur, never)...)
		arts, da, ca := matchArticles(p.Des.Articles, p.Cur.Articles)
		if len(da)+len(ca) > 0 {
			t.Fatalf("articles of %s unmatched", pp)
		}
		for _, a := range arts {
			out = append(out, diffObject(pp+".articles"+model.Element(a.Des.Name), a.Des, a.Cur, never)...)
		}
		subs, ds, cs := matchSubscriptions(p.Des.Subscriptions, p.Cur.Subscriptions)
		if len(ds)+len(cs) > 0 {
			t.Fatalf("subscriptions of %s unmatched", pp)
		}
		for _, s := range subs {
			out = append(out, diffObject(pp+".subscriptions"+model.Element(s.Des.Key()), s.Des, s.Cur, never)...)
		}
	}
	profs, dpr, cpr := matchProfiles(des.AgentProfiles, cur.AgentProfiles)
	if len(dpr)+len(cpr) > 0 {
		t.Fatalf("profiles unmatched")
	}
	for _, p := range profs {
		out = append(out, diffObject("agent_profiles"+model.Element(p.Des.Key()), p.Des, p.Cur, never)...)
	}
	return out
}

func noChanges(t *testing.T, what string, cs []Change) {
	t.Helper()
	for _, c := range cs {
		t.Errorf("%s: unexpected change at %s: %s -> %s", what, c.Path, show(c.Before), show(c.After))
	}
}

func changesString(cs []Change) string {
	var b strings.Builder
	b.WriteString("[")
	for i, c := range cs {
		if i > 0 {
			b.WriteString("; ")
		}
		b.WriteString(c.Path + " (" + c.Pattern + "): " + show(c.Before) + " -> " + show(c.After))
	}
	return b.String() + "]"
}

func show(s *string) string {
	if s == nil {
		return "<absent>"
	}
	return "\"" + *s + "\""
}

// TestDiffScalars: one property that differs gives one change, with its
// pattern and both values; equal objects give none.
func TestDiffScalars(t *testing.T) {
	des, cur := labPair(t)
	never := func(string) bool { return false }
	pp := pubPathOf("SalesRef")
	noChanges(t, "equal", diffObject(pp, pubOf(t, des, "SalesRef"), pubOf(t, cur, "SalesRef"), never))

	pubOf(t, des, "SalesRef").RetentionHours = model.Ptr(336)
	pubOf(t, cur, "SalesRef").RetentionHours = model.Ptr(100)
	got := diffObject(pp, pubOf(t, des, "SalesRef"), pubOf(t, cur, "SalesRef"), never)
	if len(got) != 1 {
		t.Fatalf("got %d changes, want 1: %s", len(got), changesString(got))
	}
	c := got[0]
	if c.Path != pp+".retention_hours" || c.Pattern != "publications[*].retention_hours" || show(c.Before) != `"100"` || show(c.After) != `"336"` {
		t.Errorf("got %s (%s) %s -> %s", c.Path, c.Pattern, show(c.Before), show(c.After))
	}
}

// TestDiffSkipsUnreadable (Review Focus 4): a current value the login could
// not read is not a change, and the plan notes the path.
func TestDiffSkipsUnreadable(t *testing.T) {
	des, cur := labPair(t)
	path := pubPathOf("SalesPub") + ".snapshot_agent.run_as"
	pubOf(t, cur, "SalesPub").SnapshotAgent.RunAs = nil
	pubOf(t, des, "SalesPub").SnapshotAgent.RunAs = model.Ptr("")
	// profile is compared, unlike run_as: the skip must hide it too.
	ppath := pubPathOf("SalesPub") + ".snapshot_agent.profile"
	pubOf(t, cur, "SalesPub").SnapshotAgent.Profile = nil
	cur.Findings = append(cur.Findings,
		model.Finding{Kind: model.FindingUnreadable, Path: path, Message: "no permission"},
		model.Finding{Kind: model.FindingUnreadable, Path: ppath, Message: "no permission"})

	skip := unreadable(cur)
	noChanges(t, "unreadable", diffObject(pubPathOf("SalesPub"), pubOf(t, des, "SalesPub"), pubOf(t, cur, "SalesPub"), skip))
	if got := diffObject(pubPathOf("SalesPub"), pubOf(t, des, "SalesPub"), pubOf(t, cur, "SalesPub"), func(string) bool { return false }); len(got) != 1 || got[0].Path != ppath {
		t.Errorf("without the skip: got %s, want one change at %s", changesString(got), ppath)
	}

	cur.Findings = cur.Findings[:1]
	pubOf(t, cur, "SalesPub").SnapshotAgent.Profile = model.Ptr("Default agent profile")
	p := Build(Inputs{Desired: des, Current: cur}, Options{})
	for _, r := range p.Refusals {
		t.Errorf("unexpected refusal %s: %s", r.Path, r.Reason)
	}
	if len(p.Notes) != 1 || !strings.Contains(p.Notes[0], path) {
		t.Errorf("notes = %q, want one naming %s", p.Notes, path)
	}
}

// TestDiffNotCompared: the generated names, the job step, the command line,
// a schedule's name, an existing subscription's initialization and the
// secrets are never compared.
func TestDiffNotCompared(t *testing.T) {
	des, cur := labPair(t)
	dp := pubOf(t, des, "SalesPub")
	dp.SnapshotAgent.JobName = model.Ptr("other job")
	dp.SnapshotAgent.RunAs = model.Ptr("proxy")
	dp.SnapshotAgent.Command = model.Ptr("-Publisher [X] -Other")
	(*dp.SnapshotAgent.Schedules)[0].Name = "my schedule"
	ds := &dp.Subscriptions[0]
	ds.Initialization = model.Ptr("replication_support_only")
	ds.DistributionAgent.Connection.PasswordSecret = model.Ptr("SQLREPL_SQL_X")

	never := func(string) bool { return false }
	pp := pubPathOf("SalesPub")
	cp := pubOf(t, cur, "SalesPub")
	noChanges(t, "publication", diffObject(pp, dp, cp, never))
	noChanges(t, "subscription", diffObject(pp+".subscriptions"+model.Element(ds.Key()), ds, &cp.Subscriptions[0], never))

	for _, p := range []string{
		"publications[*].snapshot_agent.job_name",
		"publications[*].snapshot_agent.run_as",
		"publications[*].snapshot_agent.command",
		"publications[*].snapshot_agent.schedules[*].name",
		"publications[*].snapshot_agent.schedules[*].enabled",
		"publications[*].subscriptions[*].initialization",
		"publications[*].subscriptions[*].distribution_agent.connection.password_secret",
		"publications[*].subscriptions[*].backup.device_name",
		"publications[*].subscriptions[*].lsn",
		"distributor.data_file_size_mb",
		"findings",
	} {
		if !notCompared(p) {
			t.Errorf("notCompared(%s) = false", p)
		}
	}
	for _, p := range []string{
		"publications[*].retention_hours",
		"publications[*].articles[*].commands.insert",
		"publications[*].snapshot_agent.schedules[*].frequency",
		"publications[*].subscriptions[*].distribution_agent.connection.login",
	} {
		if notCompared(p) {
			t.Errorf("notCompared(%s) = true", p)
		}
	}
}

// TestDiffRefusesLoginChange: a login change of an agent's connection is
// compared, and refused with the R16 reason rather than as unmeasured.
func TestDiffRefusesLoginChange(t *testing.T) {
	des, cur := labPair(t)
	ds := &pubOf(t, des, "SalesPub").Subscriptions[0]
	ds.DistributionAgent.Connection.Security = model.Ptr("sql")
	ds.DistributionAgent.Connection.Login = model.Ptr("repl")
	cs := &pubOf(t, cur, "SalesPub").Subscriptions[0]
	cs.DistributionAgent.Connection.Security = model.Ptr("sql")
	cs.DistributionAgent.Connection.Login = model.Ptr("other")
	sp := pubPathOf("SalesPub") + ".subscriptions" + model.Element(ds.Key())
	got := diffObject(sp, ds, cs, func(string) bool { return false })
	if len(got) != 1 || got[0].Pattern != "publications[*].subscriptions[*].distribution_agent.connection.login" {
		t.Fatalf("got %s, want one login change", changesString(got))
	}
	b := &builder{}
	b.unmeasured(got[0])
	b.unmeasured(Change{Path: "publications[P].x", Pattern: "publications[*].x"})
	want := []Refusal{
		{Path: sp + ".distribution_agent.connection.login", Reason: "a login change needs its password, which plan does not compare (R16); plan 4"},
		{Path: "publications[P].x", Reason: "cost of publications[*].x change not measured"},
	}
	if !reflect.DeepEqual(b.refusals, want) {
		t.Errorf("refusals = %+v, want %+v", b.refusals, want)
	}
}

// TestDiffMatchesSubscriptionsIgnoringCase (Review Focus 2): subscriber and
// database names match without regard to case.
func TestDiffMatchesSubscriptionsIgnoringCase(t *testing.T) {
	des := []model.Subscription{{Subscriber: "repllab", Database: "salessub"}}
	cur := []model.Subscription{{Subscriber: "REPLLAB", Database: "SalesSub"}}
	pairs, dOnly, cOnly := matchSubscriptions(des, cur)
	if len(pairs) != 1 || len(dOnly) != 0 || len(cOnly) != 0 {
		t.Fatalf("pairs %d, desired only %d, current only %d; want 1, 0, 0", len(pairs), len(dOnly), len(cOnly))
	}
	if pairs[0].Des != &des[0] || pairs[0].Cur != &cur[0] {
		t.Errorf("the pair does not hold the two subscriptions")
	}
}

// TestDiffNilAndEmptyLists (R30): columns omitted, empty and the table's
// full column list are one value.
func TestDiffNilAndEmptyLists(t *testing.T) {
	checks := &state.Checks{Tables: []state.TableCheck{{Schema: "dbo", Name: "Orders", Exists: true, Columns: []string{"OrderID", "CustomerID", "Amount"}}}}
	variants := [][]string{nil, {}, {"OrderID", "CustomerID", "Amount"}}
	never := func(string) bool { return false }
	config := func(cols []string) *model.Config {
		c, _ := loadLab(t)
		pubOf(t, c, "SalesPub").Articles[1].Columns = cols
		foldColumns(c, checks)
		return c
	}
	for _, a := range variants {
		for _, b := range variants {
			d, c := config(a), config(b)
			ap := pubPathOf("SalesPub") + ".articles[Orders]"
			noChanges(t, "columns", diffObject(ap, &pubOf(t, d, "SalesPub").Articles[1], &pubOf(t, c, "SalesPub").Articles[1], never))
		}
	}
	d, c := config([]string{"OrderID", "Amount"}), config(nil)
	got := diffObject("a", &pubOf(t, d, "SalesPub").Articles[1], &pubOf(t, c, "SalesPub").Articles[1], never)
	if len(got) != 1 || got[0].Path != "a.columns" {
		t.Errorf("a partial list against every column: got %s, want one change at a.columns", changesString(got))
	}
}

// TestDiffSchedulesFrequencyOnly (R22): an omitted schedule is the
// procedure's, compared on its frequency fields; a declared one in full.
func TestDiffSchedulesFrequencyOnly(t *testing.T) {
	des, cur := labPair(t)
	never := func(string) bool { return false }
	pp := pubPathOf("SalesPub")
	cs := &(*pubOf(t, cur, "SalesPub").SnapshotAgent.Schedules)[0]
	cs.StartDate, cs.StartTime = 20250101, 10000
	pubOf(t, des, "SalesPub").SnapshotAgent.Schedules = nil
	noChanges(t, "omitted schedule", diffObject(pp, pubOf(t, des, "SalesPub"), pubOf(t, cur, "SalesPub"), never))

	declared := *cs
	declared.StartDate = 20261201
	pubOf(t, des, "SalesPub").SnapshotAgent.Schedules = &[]model.Schedule{declared}
	got := diffObject(pp, pubOf(t, des, "SalesPub"), pubOf(t, cur, "SalesPub"), never)
	if len(got) != 1 || !strings.HasSuffix(got[0].Path, ".start_date") {
		t.Errorf("declared schedule: got %s, want one start_date change", changesString(got))
	}

	// The omitted schedule against a current one of another frequency.
	pubOf(t, des, "SalesPub").SnapshotAgent.Schedules = nil
	cs.SubdayInterval = 10
	if got := diffObject(pp, pubOf(t, des, "SalesPub"), pubOf(t, cur, "SalesPub"), never); len(got) != 1 || !strings.HasSuffix(got[0].Path, ".subday_interval") {
		t.Errorf("omitted schedule, current every 10 minutes: got %s, want one subday_interval change", changesString(got))
	}
}

// TestDiffScheduleDatesOmitted (R37, Review Focus 6): the fixture's
// schedules have no start date or time, and an omitted one keeps the
// current one.
func TestDiffScheduleDatesOmitted(t *testing.T) {
	des, cur := labPair(t)
	dated := 0
	for _, r := range agentSchedules(cur) {
		for i := range *r {
			(*r)[i].StartDate, (*r)[i].StartTime = 20261112, 10000
			dated++
		}
	}
	if dated == 0 {
		t.Fatal("the fixture has no schedule")
	}
	norm := func() *model.Config {
		n, rs := normalize.Normalize(des, cur)
		for _, r := range rs {
			t.Fatalf("unexpected refusal %s: %s", r.Path, r.Reason)
		}
		return n
	}
	noChanges(t, "dates omitted", diffAll(t, norm(), cur))

	(*pubOf(t, des, "SalesPub").SnapshotAgent.Schedules)[0].StartDate = 20261201
	got := diffAll(t, norm(), cur)
	want := pubPathOf("SalesPub") + ".snapshot_agent.schedules[Replication agent schedule.].start_date"
	if len(got) != 1 || got[0].Path != want || show(got[0].Before) != `"20261112"` || show(got[0].After) != `"20261201"` {
		for _, c := range got {
			t.Errorf("got a change at %s: %s -> %s", c.Path, show(c.Before), show(c.After))
		}
		t.Errorf("want one change at %s, 20261112 -> 20261201", want)
	}
}

// agentSchedules lists the schedule lists of every agent of c.
func agentSchedules(c *model.Config) []*[]model.Schedule {
	var out []*[]model.Schedule
	add := func(a *model.Agent) {
		if a != nil && a.Schedules != nil {
			out = append(out, a.Schedules)
		}
	}
	add(c.Publisher.LogReaderAgent)
	for i := range c.Publisher.SharedDistributionAgents {
		add(&c.Publisher.SharedDistributionAgents[i].DistributionAgent.Agent)
	}
	for i := range c.Publications {
		p := &c.Publications[i]
		add(p.SnapshotAgent)
		for j := range p.Subscriptions {
			if d := p.Subscriptions[j].DistributionAgent; d != nil {
				add(&d.Agent)
			}
		}
	}
	return out
}

// TestBuildRefusesOutOfScope (R26): each out_of_scope finding of the
// current configuration is a refusal, and a refused plan has no operation.
func TestBuildRefusesOutOfScope(t *testing.T) {
	saved := strategies
	t.Cleanup(func() { strategies = saved })
	strategies = append(strategies[:len(strategies):len(strategies)], func(b *builder) {
		b.ops = append(b.ops, Operation{Step: 1, Kind: "distributor", Action: "change", Path: "distributor"})
	})

	des, cur := labPair(t)
	if p := Build(Inputs{Desired: des, Current: cur}, Options{}); len(p.Refusals) != 0 || len(p.Operations) != 1 {
		t.Fatalf("without findings: %d refusals, %d operations; want 0, 1 (the test strategy)", len(p.Refusals), len(p.Operations))
	}
	cur.Findings = append(cur.Findings,
		model.Finding{Kind: model.FindingOutOfScope, Path: "publications[SalesPub]", Message: "merge publication"},
		model.Finding{Kind: model.FindingOutOfScope, Path: "publications[SalesRef].subscriptions[X/Y]", Message: "updatable subscription"},
		model.Finding{Kind: model.FindingNote, Path: "publications[SalesRef]", Message: "a note"})
	p := Build(Inputs{Desired: des, Current: cur}, Options{})
	want := []Refusal{
		{Path: "publications[SalesPub]", Reason: "merge publication"},
		{Path: "publications[SalesRef].subscriptions[X/Y]", Reason: "updatable subscription"},
	}
	if !reflect.DeepEqual(p.Refusals, want) {
		t.Errorf("refusals = %+v, want %+v", p.Refusals, want)
	}
	if len(p.Operations) != 0 {
		t.Errorf("%d operations, want none", len(p.Operations))
	}
}
