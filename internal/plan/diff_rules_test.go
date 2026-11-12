package plan

import (
	"reflect"
	"strings"
	"testing"

	"github.com/rudi-bruchez/sqlserver-replication/internal/cost"
	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
	"github.com/rudi-bruchez/sqlserver-replication/internal/normalize"
	"github.com/rudi-bruchez/sqlserver-replication/internal/state"
)

// withStrategy registers a test strategy for the length of the test.
func withStrategy(t *testing.T, s strategy) {
	t.Helper()
	saved := strategies
	t.Cleanup(func() { strategies = saved })
	strategies = append(strategies[:len(strategies):len(strategies)], s)
}

func normPair(t *testing.T, des, cur *model.Config) *model.Config {
	t.Helper()
	n, rs := normalize.Normalize(des, cur)
	for _, r := range rs {
		t.Fatalf("unexpected refusal %s: %s", r.Path, r.Reason)
	}
	return n
}

func articleOf(t *testing.T, c *model.Config, pub, name string) *model.Article {
	t.Helper()
	p := pubOf(t, c, pub)
	for i := range p.Articles {
		if p.Articles[i].Name == name {
			return &p.Articles[i]
		}
	}
	t.Fatalf("no article %s in %s", name, pub)
	return nil
}

var never = func(string) bool { return false }

// TestDiffMatchedKeysNotCompared (Review Focus 2): the keys a pair was
// matched on are not compared, so subscriptions, shared agents and a
// profile named in another case are matched and give no change.
func TestDiffMatchedKeysNotCompared(t *testing.T) {
	des, cur := labPair(t)
	for i := range des.Publications {
		for j := range des.Publications[i].Subscriptions {
			s := &des.Publications[i].Subscriptions[j]
			s.Subscriber, s.Database = "repllab", "salessub"
		}
	}
	for i := range des.Publisher.SharedDistributionAgents {
		a := &des.Publisher.SharedDistributionAgents[i]
		a.Subscriber, a.Database = "repllab", "SALESSUB"
	}
	des.AgentProfiles[0].Name = "LAB-Distrib"
	noChanges(t, "raw", diffAll(t, des, cur))
	noChanges(t, "normalized", diffAll(t, normPair(t, des, cur), cur))
}

// TestDiffPathsFromCurrentKey (R26): a matched pair is diffed at the path
// of its current key, the one an unreadable finding names, whatever the
// case of the desired key.
func TestDiffPathsFromCurrentKey(t *testing.T) {
	des, cur := labPair(t)
	for j := range pubOf(t, des, "SalesPub").Subscriptions {
		pubOf(t, des, "SalesPub").Subscriptions[j].Subscriber = "repllab"
	}
	pubOf(t, cur, "SalesPub").Subscriptions[0].DistributionAgent.Profile = nil
	fp := "publications[SalesPub].subscriptions[REPLLAB/SalesSub].distribution_agent.profile"
	cur.Findings = append(cur.Findings, model.Finding{Kind: model.FindingUnreadable, Path: fp, Message: "x"})
	subs, _, _ := matchSubscriptions(pubOf(t, des, "SalesPub").Subscriptions, pubOf(t, cur, "SalesPub").Subscriptions)
	if len(subs) != 1 {
		t.Fatalf("%d subscription pairs, want 1", len(subs))
	}
	sp := subs[0].path("publications[SalesPub].subscriptions")
	if sp != "publications[SalesPub].subscriptions[REPLLAB/SalesSub]" {
		t.Errorf("subscription pair path %s, want the current key", sp)
	}
	noChanges(t, "subscription", diffObject(sp, subs[0].Des, subs[0].Cur, unreadable(cur)))
	if got := diffObject(sp, subs[0].Des, subs[0].Cur, never); len(got) != 1 || got[0].Path != fp {
		t.Errorf("subscription without the skip: got %s, want one change at %s", changesString(got), fp)
	}

	des, cur = labPair(t)
	des.AgentProfiles[0].Name = "LAB-DISTRIB"
	cur.AgentProfiles[0].Description = nil
	fp = "agent_profiles[distribution/lab-distrib].description"
	cur.Findings = append(cur.Findings, model.Finding{Kind: model.FindingUnreadable, Path: fp, Message: "x"})
	profs, _, _ := matchProfiles(des.AgentProfiles, cur.AgentProfiles)
	if len(profs) != 1 {
		t.Fatalf("%d profile pairs, want 1", len(profs))
	}
	pp := profs[0].path("agent_profiles")
	if pp != "agent_profiles[distribution/lab-distrib]" {
		t.Errorf("profile pair path %s, want the current key", pp)
	}
	noChanges(t, "profile", diffObject(pp, profs[0].Des, profs[0].Cur, unreadable(cur)))
	if got := diffObject(pp, profs[0].Des, profs[0].Cur, never); len(got) != 1 || got[0].Path != fp {
		t.Errorf("profile without the skip: got %s, want one change at %s", changesString(got), fp)
	}
}

// TestDiffServersIgnoringCase (CLAUDE.md, R7): server names are compared
// without regard to case.
func TestDiffServersIgnoringCase(t *testing.T) {
	des, cur := labPair(t)
	des.Publisher.Server = "REPLLAB"
	des.Distributor.Server = "REPLLAB"
	noChanges(t, "publisher", diffObject("publisher", &des.Publisher, &cur.Publisher, never))
	noChanges(t, "distributor", diffObject("distributor", des.Distributor, cur.Distributor, never))
	des.Publisher.Server = "OTHER"
	if got := diffObject("publisher", &des.Publisher, &cur.Publisher, never); len(got) != 1 || got[0].Path != "publisher.server" || show(got[0].Before) != `"repllab"` || show(got[0].After) != `"OTHER"` {
		t.Errorf("another server: got %s, want one publisher.server change", changesString(got))
	}

	pull := func(server string) *model.Subscription {
		return &model.Subscription{PullAgent: &model.PullAgent{Distributor: model.Ptr(server)}}
	}
	sp := "publications[P].subscriptions[S/D]"
	noChanges(t, "pull agent distributor", diffObject(sp, pull("REPLLAB"), pull("repllab"), never))
	shared := func(server string) *model.SharedPullAgent {
		return &model.SharedPullAgent{PullAgent: model.PullAgent{Distributor: model.Ptr(server)}}
	}
	noChanges(t, "shared pull agent distributor", diffObject("publisher.shared_pull_agents[S/D]", shared("REPLLAB"), shared("repllab"), never))
	if got := diffObject(sp, pull("OTHER"), pull("repllab"), never); len(got) != 1 || got[0].Path != sp+".pull_agent.distributor" {
		t.Errorf("another distributor: got %s, want one change", changesString(got))
	}
}

// TestBuildRefusesScheduleShapes (R22): an agent with more than one
// schedule, or an empty schedules list, is refused before any comparison,
// and no strategy runs.
func TestBuildRefusesScheduleShapes(t *testing.T) {
	ran := false
	withStrategy(t, func(b *builder) { ran = true })
	des, cur := labPair(t)
	if p := Build(Inputs{Desired: des, Current: cur}, Options{}); len(p.Refusals) != 0 || !ran {
		t.Fatalf("one schedule per agent: refusals %+v, strategies ran %v; want none, true", p.Refusals, ran)
	}

	ran = false
	sa := pubOf(t, des, "SalesPub").SnapshotAgent
	s := (*sa.Schedules)[0]
	sa.Schedules = &[]model.Schedule{s, s}
	des.Publisher.LogReaderAgent.Schedules = &[]model.Schedule{}
	p := Build(Inputs{Desired: des, Current: cur}, Options{})
	want := []Refusal{
		{Path: "publisher.log_reader_agent.schedules", Reason: "an empty schedules list is refused (R22): omit schedules for the procedure's schedule, or declare one"},
		{Path: "publications[SalesPub].snapshot_agent.schedules", Reason: "an agent with more than one schedule is refused (R22): 2 schedules declared"},
	}
	if !reflect.DeepEqual(p.Refusals, want) {
		t.Errorf("refusals = %+v, want %+v", p.Refusals, want)
	}
	if ran || len(p.Operations) != 0 {
		t.Errorf("strategies ran %v, %d operations; want false, 0", ran, len(p.Operations))
	}
	// The comparison gives no change for them: no cost is looked up.
	noChanges(t, "two schedules", diffObject("publications[SalesPub]", pubOf(t, des, "SalesPub"), pubOf(t, cur, "SalesPub"), never))
	noChanges(t, "empty list", diffObject("publisher", &des.Publisher, &cur.Publisher, never))
}

// TestDiffUnreadableUnderParent (R26): an unreadable finding excludes its
// path and everything under it, and only that: a path that merely starts
// with the same characters is compared.
func TestDiffUnreadableUnderParent(t *testing.T) {
	mutated := func() (des, cur *model.Config) {
		des, cur = labPair(t)
		sa := pubOf(t, des, "SalesPub").SnapshotAgent
		(*sa.Schedules)[0].SubdayInterval = 99
		sa.Profile = model.Ptr("x")
		des.Distributor.Properties["heartbeat_interval"] = "99"
		des.AgentProfiles[0].Parameters["-PollingInterval"] = "99"
		des.Publisher.LogReaderAgent.Profile = model.Ptr("x")
		return des, cur
	}
	des, cur := mutated()
	all := diffAll(t, des, cur)
	if len(all) != 5 {
		t.Fatalf("without a finding: %s, want 5 changes", changesString(all))
	}
	for _, x := range []struct {
		finding string
		want    int
	}{
		{"publications[SalesPub]", 3},
		{"publications[SalesPub].snapshot_agent", 3},
		{"publications[SalesPub].snapshot_agent.schedules", 4},
		{"publications[SalesPub].snapshot_agent.schedules[Replication agent schedule.]", 4},
		{"publications[SalesPub].snapshot", 5}, // not a parent of snapshot_agent
		{"distributor", 4},
		{"distributor.properties", 4},
		{"distributor.properties[heartbeat_interval]", 4},
		{"agent_profiles[distribution/lab-distrib].parameters", 4},
		{"agent_profiles[distribution/lab-distrib].parameters[-PollingInterval]", 4},
		{"publisher", 4},
	} {
		des, cur := mutated()
		cur.Findings = append(cur.Findings, model.Finding{Kind: model.FindingUnreadable, Path: x.finding, Message: "x"})
		got := diffAllSkip(t, des, cur, unreadable(cur))
		if len(got) != x.want {
			t.Errorf("finding %s: %s, want %d changes", x.finding, changesString(got), x.want)
		}
		for _, c := range got {
			if strings.HasPrefix(c.Path, x.finding+".") || strings.HasPrefix(c.Path, x.finding+"[") || c.Path == x.finding {
				t.Errorf("finding %s: change under it at %s", x.finding, c.Path)
			}
		}
	}
}

// TestDiffMatchesProfilesIgnoringCase (R6, R7): profiles match by agent
// type exactly and by name without regard to case.
func TestDiffMatchesProfilesIgnoringCase(t *testing.T) {
	des := []model.AgentProfile{{Name: "LAB-Distrib", AgentType: "distribution"}, {Name: "p", AgentType: "snapshot"}}
	cur := []model.AgentProfile{{Name: "lab-distrib", AgentType: "distribution"}, {Name: "p", AgentType: "logreader"}}
	pairs, dOnly, cOnly := matchProfiles(des, cur)
	if len(pairs) != 1 || pairs[0].Des != &des[0] || pairs[0].Cur != &cur[0] {
		t.Errorf("pairs %d, want LAB-Distrib with lab-distrib", len(pairs))
	}
	if len(dOnly) != 1 || dOnly[0] != &des[1] || len(cOnly) != 1 || cOnly[0] != &cur[1] {
		t.Errorf("desired only %d, current only %d; want the two p of different types", len(dOnly), len(cOnly))
	}
}

// TestDiffCommands: a command is one value; with a generated (nil) desired
// procedure only its mode is compared, and a declared procedure name is
// compared without regard to case.
func TestDiffCommands(t *testing.T) {
	proc := &model.ObjectName{Schema: "dbo", Name: "sp_MSins_dboCustomer"}
	cur := &model.Article{Commands: &model.Commands{Insert: &model.Command{Mode: "CALL", Procedure: proc}}}
	art := func(c model.Command) *model.Article { return &model.Article{Commands: &model.Commands{Insert: &c}} }
	for _, x := range []struct {
		name  string
		des   model.Command
		after string // "" for no change
	}{
		{"generated, same mode", model.Command{Mode: "CALL"}, ""},
		{"generated, other mode", model.Command{Mode: "SCALL"}, "SCALL"},
		{"declared, case", model.Command{Mode: "CALL", Procedure: &model.ObjectName{Schema: "DBO", Name: "SP_MSINS_DBOCUSTOMER"}}, ""},
		{"declared, other", model.Command{Mode: "CALL", Procedure: &model.ObjectName{Schema: "dbo", Name: "other"}}, "CALL [dbo].[other]"},
	} {
		got := diffObject("a", art(x.des), cur, never)
		switch {
		case x.after == "":
			noChanges(t, x.name, got)
		case len(got) != 1 || got[0].Path != "a.commands.insert" || show(got[0].Before) != `"CALL [dbo].[sp_MSins_dboCustomer]"` || show(got[0].After) != `"`+x.after+`"`:
			t.Errorf("%s: got %s, want one change to %s", x.name, changesString(got), x.after)
		}
	}
}

// identityCase is the lab with the current Customer article manual and its
// identity_property option, which a desired file without the option
// matches (R14).
func identityCase(t *testing.T) (des, cur *model.Config) {
	des, cur = labPair(t)
	ca := articleOf(t, cur, "SalesPub", "Customer")
	ca.IdentityRangeManagement = model.Ptr("manual")
	da := articleOf(t, des, "SalesPub", "Customer")
	da.IdentityRangeManagement = model.Ptr("manual")
	opts := []string{}
	for _, o := range *ca.SchemaOptions {
		if o != "identity_property" {
			opts = append(opts, o)
		}
	}
	if len(opts) == len(*ca.SchemaOptions) {
		t.Fatal("the fixture's Customer article has no identity_property")
	}
	da.SchemaOptions = &opts
	return des, cur
}

// columnsCase is the lab with the current Orders article listing every
// column of its table and the desired one an empty list (R30).
func columnsCase(t *testing.T) (des, cur *model.Config, checks *state.Checks) {
	des, cur = labPair(t)
	cols := []string{"OrderID", "CustomerID", "Amount"}
	src := articleOf(t, cur, "SalesPub", "Orders").Source
	checks = &state.Checks{Tables: []state.TableCheck{{Schema: src.Schema, Name: src.Name, Exists: true, Columns: cols}}}
	articleOf(t, cur, "SalesPub", "Orders").Columns = cols
	articleOf(t, des, "SalesPub", "Orders").Columns = []string{}
	return des, cur, checks
}

// articleDiff is a strategy diffing one article pair of SalesPub, the
// normalized sides kept.
func articleDiff(t *testing.T, name string, got *[]Change, des **model.Article) strategy {
	return func(b *builder) {
		d, c := articleOf(t, b.des, "SalesPub", name), articleOf(t, b.cur, "SalesPub", name)
		*got = b.diff(pubPathOf("SalesPub")+".articles"+model.Element(name), d, c)
		*des = d
	}
}

// TestBuildIdentityBit (R14): Build removes identity_property from a
// current article that is manual, current or desired.
func TestBuildIdentityBit(t *testing.T) {
	var got []Change
	var da *model.Article
	withStrategy(t, articleDiff(t, "Customer", &got, &da))
	des, cur := identityCase(t)
	if p := Build(Inputs{Desired: des, Current: cur}, Options{}); len(p.Refusals) != 0 {
		t.Fatalf("refusals %+v", p.Refusals)
	}
	noChanges(t, "current manual", got)

	// Manual in the desired file only: the change of
	// identity_range_management is planned, not one of the option.
	des, cur = identityCase(t)
	articleOf(t, cur, "SalesPub", "Customer").IdentityRangeManagement = model.Ptr("none")
	Build(Inputs{Desired: des, Current: cur}, Options{})
	for _, c := range got {
		if strings.HasSuffix(c.Path, ".schema_options") {
			t.Errorf("desired manual: unexpected change at %s", c.Path)
		}
	}
}

// TestBuildFoldsColumns (R30): Build folds the full column list of the
// table and an empty list to nil on both sides.
func TestBuildFoldsColumns(t *testing.T) {
	var got []Change
	var da *model.Article
	withStrategy(t, articleDiff(t, "Orders", &got, &da))
	des, cur, checks := columnsCase(t)
	Build(Inputs{Desired: des, Current: cur, Checks: checks}, Options{})
	noChanges(t, "full and empty", got)
	if da.Columns != nil {
		t.Errorf("desired columns %#v after Build, want nil", da.Columns)
	}
	// Without the table's columns the lists are compared as given.
	des, cur, _ = columnsCase(t)
	Build(Inputs{Desired: des, Current: cur}, Options{})
	if len(got) != 1 || !strings.HasSuffix(got[0].Path, ".columns") {
		t.Errorf("without the checks: got %s, want one columns change", changesString(got))
	}
}

// TestBuildKeepsInputs: Build changes neither the desired nor the current
// configuration it is given, although it folds columns and the identity
// bit.
func TestBuildKeepsInputs(t *testing.T) {
	setup := func() (des, cur *model.Config, checks *state.Checks) {
		des, cur = identityCase(t)
		d2, c2, checks := columnsCase(t)
		articleOf(t, des, "SalesPub", "Orders").Columns = articleOf(t, d2, "SalesPub", "Orders").Columns
		articleOf(t, cur, "SalesPub", "Orders").Columns = articleOf(t, c2, "SalesPub", "Orders").Columns
		return des, cur, checks
	}
	des, cur, checks := setup()
	Build(Inputs{Desired: des, Current: cur, Checks: checks}, Options{})
	wantDes, wantCur, _ := setup()
	if !reflect.DeepEqual(des, wantDes) {
		t.Error("Build changed its desired configuration")
	}
	if !reflect.DeepEqual(cur, wantCur) {
		t.Error("Build changed its current configuration")
	}
}

// TestDiffScheduleDefaultByPublicationType (R22): the default of an omitted
// schedule is read for the type of the publication the path is under.
func TestDiffScheduleDefaultByPublicationType(t *testing.T) {
	const pattern = "publications[*].subscriptions[*].distribution_agent.schedules"
	if s, ok := defaultSchedule(pattern, "transactional"); !ok || s.Frequency != "agent_start" {
		t.Errorf("transactional push agent: %+v %v, want agent_start", s, ok)
	}
	if _, ok := defaultSchedule(pattern, "snapshot"); ok {
		t.Errorf("snapshot push agent: a default, want none measured")
	}
	des, cur := labPair(t)
	ds := &pubOf(t, des, "SalesPub").Subscriptions[0]
	ds.DistributionAgent.Schedules = nil
	cs := &pubOf(t, cur, "SalesPub").Subscriptions[0]
	(*cs.DistributionAgent.Schedules)[0].Frequency = "daily"
	(*cs.DistributionAgent.Schedules)[0].Interval = 1
	sp := pubPathOf("SalesPub") + ".subscriptions" + model.Element(cs.Key())
	b := &builder{des: des}
	if got := b.diff(sp, ds, cs); len(got) != 2 {
		t.Errorf("transactional: got %s, want frequency and interval changes", changesString(got))
	}
	pubOf(t, des, "SalesPub").Type = model.Ptr("snapshot")
	noChanges(t, "snapshot", b.diff(sp, ds, cs))
}

// TestDiffPairsSorted: pairs, desired-only and current-only objects are
// sorted by key, a folded key without regard to case.
func TestDiffPairsSorted(t *testing.T) {
	des := []model.Publication{{Name: "b"}, {Name: "c"}, {Name: "a"}, {Name: "z"}}
	cur := []model.Publication{{Name: "y"}, {Name: "a"}, {Name: "c"}, {Name: "b"}, {Name: "x"}}
	pairs, dOnly, cOnly := matchPublications(des, cur)
	var keys []string
	for _, p := range pairs {
		keys = append(keys, p.Des.Name+"="+p.Cur.Name)
	}
	for _, p := range dOnly {
		keys = append(keys, "+"+p.Name)
	}
	for _, p := range cOnly {
		keys = append(keys, "-"+p.Name)
	}
	if got := strings.Join(keys, " "); got != "a=a b=b c=c +z -x -y" {
		t.Errorf("publications: %s", got)
	}
	ds := []model.Subscription{{Subscriber: "S2", Database: "d"}, {Subscriber: "s1", Database: "D"}}
	cs := []model.Subscription{{Subscriber: "s2", Database: "D"}, {Subscriber: "S1", Database: "d"}}
	sp, _, _ := matchSubscriptions(ds, cs)
	if len(sp) != 2 || sp[0].Cur.Subscriber != "S1" || sp[1].Cur.Subscriber != "s2" {
		t.Errorf("subscriptions not sorted by key without regard to case")
	}
}

// TestDiffOnlyUnreadableSkips (R26): only an unreadable finding excludes a
// path and gives a note; an incomplete, note or out_of_scope one does not.
func TestDiffOnlyUnreadableSkips(t *testing.T) {
	cur := &model.Config{Findings: []model.Finding{
		{Kind: model.FindingIncomplete, Path: "i"},
		{Kind: model.FindingNote, Path: "n"},
		{Kind: model.FindingOutOfScope, Path: "o"},
		{Kind: model.FindingUnreadable, Path: "u"},
	}}
	skip := unreadable(cur)
	for p, want := range map[string]bool{"i": false, "n": false, "o": false, "u": true, "u.v": true, "u[k]": true, "uv": false} {
		if skip(p) != want {
			t.Errorf("skip(%s) = %v, want %v", p, !want, want)
		}
	}
	des, lab := labPair(t)
	lab.Findings = append(lab.Findings,
		model.Finding{Kind: model.FindingIncomplete, Path: "publications[SalesPub].snapshot_agent", Message: "x"},
		model.Finding{Kind: model.FindingNote, Path: "publications[SalesRef]", Message: "y"})
	if p := Build(Inputs{Desired: des, Current: lab}, Options{}); len(p.Notes) != 0 {
		t.Errorf("notes %q, want none", p.Notes)
	}
}

// TestDiffIdentifiersIgnoringCase: column names, a subscription's articles
// and the article source are SQL identifiers, compared without regard to
// case, and so are a profile's parameter names, the path naming the
// current key.
func TestDiffIdentifiersIgnoringCase(t *testing.T) {
	des, cur := labPair(t)
	ap := pubPathOf("SalesPub") + ".articles[Customer]"
	da, ca := articleOf(t, des, "SalesPub", "Customer"), articleOf(t, cur, "SalesPub", "Customer")
	da.Columns, ca.Columns = []string{"customerid", "Name", "Country"}, []string{"CustomerID", "Name", "Country"}
	da.Source.Name = strings.ToLower(ca.Source.Name)
	noChanges(t, "columns and source", diffObject(ap, da, ca, never))
	da.Columns = []string{"Name", "CustomerID"}
	da.Source.Name = "Other"
	if got := diffObject(ap, da, ca, never); len(got) != 2 {
		t.Errorf("other columns and source: got %s, want 2 changes", changesString(got))
	}

	ds, cs := &pubOf(t, des, "SalesPub").Subscriptions[0], &pubOf(t, cur, "SalesPub").Subscriptions[0]
	ds.Articles, cs.Articles = []string{"customer"}, []string{"Customer"}
	noChanges(t, "subscription articles", diffObject(pubPathOf("SalesPub")+".subscriptions"+model.Element(cs.Key()), ds, cs, never))

	pp := "agent_profiles[distribution/lab-distrib]"
	dp, cp := &des.AgentProfiles[0], &cur.AgentProfiles[0]
	v := dp.Parameters["-PollingInterval"]
	delete(dp.Parameters, "-PollingInterval")
	dp.Parameters["-pollinginterval"] = v
	noChanges(t, "parameter name case", diffObject(pp, dp, cp, never))
	dp.Parameters["-pollinginterval"] = "99"
	dp.Parameters["-NewParam"] = "1"
	got := diffObject(pp, dp, cp, never)
	want := pp + ".parameters[-NewParam] (agent_profiles[*].parameters): <absent> -> \"1\"; " +
		pp + ".parameters[-PollingInterval] (agent_profiles[*].parameters): \"" + v + "\" -> \"99\""
	if changesString(got) != "["+want+"]" {
		t.Errorf("got %s, want [%s]", changesString(got), want)
	}
}

// TestDiffRefusesLogins (R16): every login change needs its password and is
// refused with the R16 reason where the cost table has no entry; the
// job_login entries the table refuses with 14529 keep theirs.
func TestDiffRefusesLogins(t *testing.T) {
	for _, p := range []string{
		"distributor.publisher_connection.login",
		"publisher.log_reader_agent.connection.login",
		"publications[*].snapshot_agent.distributor_connection.login",
		"publications[*].subscriptions[*].distribution_agent.connection.login",
		"publications[*].subscriptions[*].pull_agent.connection.login",
		"publications[*].subscriptions[*].pull_agent.distributor_connection.login",
		"publications[*].snapshot.ftp.login",
		"publisher.shared_distribution_agents[*].distribution_agent.job_login",
		"publisher.shared_pull_agents[*].job_login",
	} {
		if notCompared(p) {
			t.Errorf("%s is not compared", p)
		}
		if _, ok := cost.Lookup(p, "set", "transactional"); ok {
			t.Errorf("%s has a cost entry", p)
		}
		b := &builder{}
		b.unmeasured(Change{Path: p, Pattern: p})
		if len(b.refusals) != 1 || b.refusals[0].Reason != loginReason {
			t.Errorf("%s: refusals %+v, want the R16 reason", p, b.refusals)
		}
	}
	for _, p := range []string{
		"publisher.log_reader_agent.job_login",
		"publications[*].snapshot_agent.job_login",
		"publications[*].subscriptions[*].distribution_agent.job_login",
		"publications[*].subscriptions[*].pull_agent.job_login",
	} {
		if e, ok := cost.Lookup(p, "set", "transactional"); !ok || e.Class != cost.Refused || e.Error != 14529 {
			t.Errorf("%s: entry %+v %v, want refused with 14529", p, e, ok)
		}
	}
	// The logins are compared: one change each.
	des, cur := labPair(t)
	des.Distributor.PublisherConnection.Login = model.Ptr("l")
	des.Publications[0].SnapshotAgent.DistributorConnection.Login = model.Ptr("l")
	des.Publications[0].Snapshot.FTP = &model.FTP{Login: model.Ptr("l")}
	cur.Publications[0].Snapshot.FTP = &model.FTP{Login: model.Ptr("o")}
	var pats []string
	for _, c := range diffAll(t, des, cur) {
		pats = append(pats, c.Pattern)
	}
	if got := strings.Join(pats, " "); got != "distributor.publisher_connection.login publications[*].snapshot.ftp.login publications[*].snapshot_agent.distributor_connection.login" {
		t.Errorf("login changes %s", got)
	}
}
