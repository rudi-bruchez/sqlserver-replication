package normalize

import (
	"fmt"
	"os"
	"reflect"
	"strings"
	"testing"

	"github.com/rudi-bruchez/sqlserver-replication/internal/decode"
	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
	"gopkg.in/yaml.v3"
)

var str = model.Ptr[string]

// testPub is a transactional native active publication named name.
func testPub(name string, arts ...model.Article) model.Publication {
	return model.Publication{Name: name, Type: str("transactional"), Status: str("active"), SyncMethod: str("native"), Articles: arts}
}

func testTable(name, schema, table string) model.Article {
	return model.Article{Name: name, Source: model.ObjectName{Schema: schema, Name: table}}
}

func testConfig(pubs ...model.Publication) *model.Config {
	return &model.Config{Version: model.FormatVersion, Publisher: model.Publisher{Server: "S", Database: "D"}, Publications: pubs}
}

func loadFixture(t *testing.T) *model.Config {
	t.Helper()
	f, err := os.Open("../testdata/lab/sales.yaml")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	c, err := model.Load(f)
	if err != nil {
		t.Fatal(err)
	}
	return c
}

// refused tells whether rs holds a refusal at path whose reason contains
// every part.
func refused(rs []Refusal, path string, parts ...string) bool {
	for _, r := range rs {
		if r.Path != path {
			continue
		}
		ok := true
		for _, s := range parts {
			ok = ok && strings.Contains(r.Reason, s)
		}
		if ok {
			return true
		}
	}
	return false
}

func noRefusal(t *testing.T, label string, rs []Refusal) {
	t.Helper()
	for _, r := range rs {
		t.Errorf("%s: unexpected refusal %s: %s", label, r.Path, r.Reason)
	}
}

// show renders a value with its pointers followed, for failure messages.
func show(v any) string {
	b, err := yaml.Marshal(v)
	if err != nil {
		return fmt.Sprint(v)
	}
	return strings.TrimSpace(string(b))
}

func cmd(mode, schema, name string) *model.Command {
	c := &model.Command{Mode: mode}
	if name != "" {
		c.Procedure = &model.ObjectName{Schema: schema, Name: name}
	}
	return c
}

// leftNil are the keys a normalized configuration may leave nil: kept
// current or not passed (R4, R14, R22, R41) and secret names.
var leftNil = map[string]bool{
	"job_name": true, "job_enabled": true, "run_as": true, "command": true, "profile": true,
	"schedules": true, "identity_range_management": true, "job_password_secret": true,
	"distributor": true, "sync_with_backup": true, "procedure": true,
}

func TestNormalizeFillsDefaults(t *testing.T) {
	out, rs := Normalize(testConfig(testPub("P", testTable("A", "dbo", "T"))), nil)
	noRefusal(t, "dbo.T native", rs)
	for _, path := range model.NilProperties(out) {
		k := path[strings.LastIndex(path, ".")+1:]
		if !leftNil[k] {
			t.Errorf("dbo.T native: %s left nil", path)
		}
	}
	pub := out.Publications[0]
	a := pub.Articles[0]
	if want := decode.SchemaOptionNames(0x30073); a.SchemaOptions == nil || !reflect.DeepEqual(*a.SchemaOptions, want) {
		t.Errorf("schema_options %s, want %v", show(a.SchemaOptions), want)
	}
	if a.Commands == nil {
		t.Fatal("commands nil")
	}
	for _, c := range []struct {
		got, want *model.Command
	}{
		// The generated procedures (CALL [dbo].[sp_MSins_dboT]) stay nil:
		// compared on their mode only, since the template is wrong past 109
		// characters of owner and table (Fill).
		{a.Commands.Insert, cmd("CALL", "", "")},
		{a.Commands.Update, cmd("SCALL", "", "")},
		{a.Commands.Delete, cmd("CALL", "", "")},
	} {
		if !reflect.DeepEqual(c.got, c.want) {
			t.Errorf("command %s, want %s", show(c.got), show(c.want))
		}
	}
	checks := []struct {
		name string
		got  any
		want any
	}{
		{"type", a.Type, str("logbased")},
		{"destination.schema", a.Destination.Schema, str("dbo")},
		{"destination.name", a.Destination.Name, str("T")},
		{"parameterized", a.Parameterized, model.Ptr(true)},
		{"insert_column_names", a.InsertColumnNames, model.Ptr(false)},
		{"pre_creation_cmd", a.PreCreationCmd, str("drop")},
		{"retention_hours", pub.RetentionHours, model.Ptr(336)},
		{"independent_agent", pub.IndependentAgent, model.Ptr(false)},
		{"immediate_sync", pub.ImmediateSync, model.Ptr(false)},
		{"allow_push", pub.AllowPush, model.Ptr(true)},
		{"allow_pull", pub.AllowPull, model.Ptr(false)},
		{"replicate_ddl", pub.ReplicateDDL, model.Ptr(true)},
		{"status", pub.Status, str("active")},
	}
	for _, c := range checks {
		if !reflect.DeepEqual(c.got, c.want) {
			t.Errorf("%s: got %v, want %v", c.name, reflect.Indirect(reflect.ValueOf(c.got)), reflect.Indirect(reflect.ValueOf(c.want)))
		}
	}

	chr := testPub("P", testTable("A", "m_s", "T"))
	chr.SyncMethod = str("character")
	out, rs = Normalize(testConfig(chr), nil)
	noRefusal(t, "m_s.T character", rs)
	a = out.Publications[0].Articles[0]
	if !reflect.DeepEqual(a.Destination.Schema, str("")) {
		t.Errorf("character destination.schema %s, want \"\"", show(a.Destination.Schema))
	}
	if a.Commands == nil || !reflect.DeepEqual(a.Commands.Insert, cmd("SQL", "", "")) {
		t.Errorf("character commands %s, want SQL", show(a.Commands))
	}

	// A shared push agent gets the push rows' values (m_ps measured a
	// shared agent).
	sh := testConfig(testPub("P", testTable("A", "dbo", "T")))
	sh.Publisher.SharedDistributionAgents = []model.SharedDistributionAgent{{Subscriber: "S", Database: "D"}}
	out, rs = Normalize(sh, nil)
	noRefusal(t, "shared push agent", rs)
	ag := out.Publisher.SharedDistributionAgents[0].DistributionAgent
	if ag.Connection == nil || !reflect.DeepEqual(ag.Connection.Security, str("windows")) || !reflect.DeepEqual(ag.JobLogin, str("")) ||
		!reflect.DeepEqual(ag.SubscriptionStreams, model.Ptr(0)) || !reflect.DeepEqual(ag.MemoryOptimized, model.Ptr(false)) {
		t.Errorf("shared push agent: %s", show(ag))
	}

	// Subscription defaults are measured on transactional publications only.
	snap := testPub("P", testTable("A", "dbo", "T"))
	snap.Type = str("snapshot")
	snap.Subscriptions = []model.Subscription{{Subscriber: "S", Database: "D", Initialization: str("snapshot")}}
	_, rs = Normalize(testConfig(snap), nil)
	if !refused(rs, "publications[P].subscriptions[S/D].type", "not measured on snapshot publications") {
		t.Errorf("snapshot publication subscription: refusals %v", rs)
	}
}

func TestNormalizeRequired(t *testing.T) {
	a := testTable("A", "dbo", "T")
	a.Filter = &model.Filter{Clause: "x = 1"}
	pub := testPub("P", a)
	pub.Status = nil
	pub.Subscriptions = []model.Subscription{{Subscriber: "S", Database: "D"}}
	_, rs := Normalize(testConfig(pub), nil)
	want := []string{
		"publications[P].status",
		"publications[P].subscriptions[S/D].initialization",
		"publications[P].articles[A].filter.procedure",
	}
	for _, w := range want {
		if !refused(rs, w, "has no default and must be written") {
			t.Errorf("no refusal at %s", w)
		}
	}
	if len(rs) != len(want) {
		t.Errorf("%d refusals, want %d: %v", len(rs), len(want), rs)
	}
}

func TestNormalizePrerequisites(t *testing.T) {
	imm := testPub("P")
	imm.ImmediateSync = model.Ptr(true)
	out, rs := Normalize(testConfig(imm), nil)
	noRefusal(t, "immediate_sync", rs)
	if got := out.Publications[0].IndependentAgent; got == nil || !*got {
		t.Errorf("immediate_sync: independent_agent %s, want true", show(got))
	}

	anon := testPub("P")
	anon.AllowAnonymous = model.Ptr(true)
	out, rs = Normalize(testConfig(anon), nil)
	noRefusal(t, "allow_anonymous", rs)
	if q := out.Publications[0]; q.ImmediateSync == nil || !*q.ImmediateSync || q.IndependentAgent == nil || !*q.IndependentAgent {
		t.Errorf("allow_anonymous: immediate_sync %s, independent_agent %s, want true, true", show(q.ImmediateSync), show(q.IndependentAgent))
	}

	pull := testPub("P")
	pull.Subscriptions = []model.Subscription{{Subscriber: "S", Database: "D", Type: str("pull"), Initialization: str("snapshot")}}
	out, rs = Normalize(testConfig(pull), nil)
	noRefusal(t, "pull", rs)
	if got := out.Publications[0].AllowPull; got == nil || !*got {
		t.Errorf("pull subscription: allow_pull %s, want true", show(got))
	}

	sw := testPub("P")
	sw.AllowPartitionSwitch = model.Ptr(true)
	out, rs = Normalize(testConfig(sw), nil)
	noRefusal(t, "allow_partition_switch", rs)
	if got := out.Publications[0].ReplicatePartitionSwitch; got == nil || !*got {
		t.Errorf("allow_partition_switch: replicate_partition_switch %s, want true", show(got))
	}
}

func TestNormalizeConflicts(t *testing.T) {
	sub := func(typ string, arts ...string) []model.Subscription {
		return []model.Subscription{{Subscriber: "S", Database: "D", Type: str(typ), Initialization: str("snapshot"), Articles: arts}}
	}
	cases := []struct {
		name   string
		edit   func(*model.Publication)
		path   string
		reason string
	}{
		{"immediate_sync without independent_agent", func(q *model.Publication) {
			q.ImmediateSync, q.IndependentAgent = model.Ptr(true), model.Ptr(false)
		}, "publications[P].immediate_sync", "21022"},
		{"allow_anonymous without immediate_sync", func(q *model.Publication) {
			q.AllowAnonymous, q.ImmediateSync = model.Ptr(true), model.Ptr(false)
		}, "publications[P].allow_anonymous", "20011"},
		{"allow_subscription_copy without immediate_sync", func(q *model.Publication) {
			q.AllowSubscriptionCopy = model.Ptr(true)
		}, "publications[P].allow_subscription_copy", "21210"},
		{"replicate_partition_switch without allow_partition_switch", func(q *model.Publication) {
			q.ReplicatePartitionSwitch, q.AllowPartitionSwitch = model.Ptr(true), model.Ptr(false)
		}, "publications[P].replicate_partition_switch", "21866"},
		{"compress without alt_folder", func(q *model.Publication) {
			q.Snapshot = &model.Snapshot{Compress: model.Ptr(true)}
		}, "publications[P].snapshot.compress", "21157"},
		{"enabled_for_internet without ftp.address", func(q *model.Publication) {
			q.Snapshot = &model.Snapshot{EnabledForInternet: model.Ptr(true)}
		}, "publications[P].snapshot.enabled_for_internet", "21158"},
		{"subscription on an inactive publication", func(q *model.Publication) {
			q.Status, q.Subscriptions = str("inactive"), sub("push")
		}, "publications[P].subscriptions[S/D]", "21000"},
		{"pull subscription without allow_pull", func(q *model.Publication) {
			q.AllowPull, q.Subscriptions = model.Ptr(false), sub("pull")
		}, "publications[P].subscriptions[S/D].type", "20012"},
		{"push subscription without allow_push", func(q *model.Publication) {
			q.AllowPush, q.Subscriptions = model.Ptr(false), sub("push")
		}, "publications[P].subscriptions[S/D].type", "20012"},
		{"concurrent on a snapshot publication", func(q *model.Publication) {
			q.Type, q.SyncMethod = str("snapshot"), str("concurrent")
		}, "publications[P].sync_method", "22547"},
		{"concurrent_c on a snapshot publication", func(q *model.Publication) {
			q.Type, q.SyncMethod = str("snapshot"), str("concurrent_c")
		}, "publications[P].sync_method", "22547"},
		{"subset under concurrent", func(q *model.Publication) {
			q.SyncMethod, q.Subscriptions = str("concurrent"), sub("push", "A")
		}, "publications[P].subscriptions[S/D].articles", "14100"},
		{"subset under concurrent_c with immediate_sync", func(q *model.Publication) {
			q.SyncMethod, q.ImmediateSync, q.Subscriptions = str("concurrent_c"), model.Ptr(true), sub("push", "A")
		}, "publications[P].subscriptions[S/D].articles", "14100"},
		{"subset under immediate_sync", func(q *model.Publication) {
			q.ImmediateSync, q.Subscriptions = model.Ptr(true), sub("push", "A")
		}, "publications[P].subscriptions[S/D].articles", "14122"},
		{"enabled_for_het_sub", func(q *model.Publication) {
			q.EnabledForHetSub = model.Ptr(true)
		}, "publications[P].enabled_for_het_sub", "out of scope"},
		{"identity_range_management auto", func(q *model.Publication) {
			q.Articles[0].IdentityRangeManagement = str("auto")
		}, "publications[P].articles[A].identity_range_management", "out of scope"},
		{"schedule disabled on a created agent", func(q *model.Publication) {
			q.SnapshotAgent = &model.Agent{Schedules: &[]model.Schedule{{Name: "s", Enabled: model.Ptr(false), Frequency: "agent_start"}}}
		}, "publications[P].snapshot_agent.schedules[s].enabled", "a schedule's enabled cannot be set by a replication procedure"},
		{"daily schedule with interval 0", func(q *model.Publication) {
			q.SnapshotAgent = &model.Agent{Schedules: &[]model.Schedule{{Name: "s", Frequency: "daily"}}}
		}, "publications[P].snapshot_agent.schedules[s].interval", "interval of a daily schedule must be written"},
	}
	for _, c := range cases {
		q := testPub("P", testTable("A", "dbo", "T"))
		c.edit(&q)
		_, rs := Normalize(testConfig(q), nil)
		if !refused(rs, c.path, c.reason) {
			t.Errorf("%s: no refusal at %s with %q; refusals %v", c.name, c.path, c.reason, rs)
		}
	}
	// A subscription that omits articles subscribes every article: no
	// subset refusal, and articles stays nil.
	for _, m := range []string{"concurrent", "native"} {
		q := testPub("P", testTable("A", "dbo", "T"))
		q.SyncMethod, q.ImmediateSync, q.Subscriptions = str(m), model.Ptr(m == "native"), sub("push")
		out, rs := Normalize(testConfig(q), nil)
		noRefusal(t, "omitted articles under "+m, rs)
		if got := out.Publications[0].Subscriptions[0].Articles; got != nil {
			t.Errorf("omitted articles under %s: %v, want nil", m, got)
		}
	}
	// Without the conflicting half, none of them is refused.
	_, rs := Normalize(testConfig(testPub("P", testTable("A", "dbo", "T"))), nil)
	noRefusal(t, "plain", rs)
}

func TestNormalizeEnumerations(t *testing.T) {
	q := testPub("P", testTable("A", "dbo", "T"))
	q.SyncMethod = str("concurent")
	c := testConfig(q)
	c.Findings = []model.Finding{{Kind: model.FindingNote, Path: "publications[P]", Message: "m"}}
	out, rs := Normalize(c, nil)
	if !refused(rs, "publications[P].sync_method", `unknown value "concurent"`) {
		t.Errorf("sync_method concurent: refusals %v", rs)
	}
	if out.Findings != nil {
		t.Errorf("findings kept: %v", out.Findings)
	}

	q = testPub("P", testTable("A", "dbo", "T"))
	q.Articles[0].Type = str("unknown(9)")
	_, rs = Normalize(testConfig(q), nil)
	if !refused(rs, "publications[P].articles[A].type", `unknown value "unknown(9)"`) {
		t.Errorf("type unknown(9): refusals %v", rs)
	}
}

func TestNormalizeQualifiesNames(t *testing.T) {
	a := testTable("A", "", "m_x")
	a.Commands = &model.Commands{Insert: cmd("CALL", "", "m_ins"), Update: cmd("SCALL", "s", "p"), Delete: cmd("CALL", "", "m_del")}
	a.Filter = &model.Filter{Clause: "x = 1", Procedure: &model.ObjectName{Name: "m_x"}}
	a.SyncObject = &model.ObjectName{Name: "m_x"}
	b := testTable("B", "s", "m_x")
	b.Filter = &model.Filter{Clause: "x = 1", Procedure: &model.ObjectName{Schema: "s", Name: "m_x"}}
	b.SyncObject = &model.ObjectName{Schema: "s", Name: "m_x"}
	out, rs := Normalize(testConfig(testPub("P", a, b)), nil)
	noRefusal(t, "names", rs)
	na, nb := out.Publications[0].Articles[0], out.Publications[0].Articles[1]
	if !reflect.DeepEqual(na.Commands.Insert, cmd("CALL", "dbo", "m_ins")) {
		t.Errorf("CALL m_ins: %s", show(na.Commands.Insert))
	}
	if !reflect.DeepEqual(na.Commands.Update, cmd("SCALL", "s", "p")) {
		t.Errorf("SCALL [s].[p]: %s", show(na.Commands.Update))
	}
	for _, c := range []struct {
		name string
		got  model.ObjectName
		want string
	}{
		{"A filter.procedure", *na.Filter.Procedure, "dbo"},
		{"A sync_object", *na.SyncObject, "dbo"},
		{"A source", na.Source, "dbo"},
		{"B filter.procedure", *nb.Filter.Procedure, "s"},
		{"B sync_object", *nb.SyncObject, "s"},
		{"B source", nb.Source, "s"},
	} {
		if c.got.Schema != c.want || c.got.Name != "m_x" {
			t.Errorf("%s: %+v, want schema %s", c.name, c.got, c.want)
		}
	}
}

func TestNormalizeInapplicableSkipped(t *testing.T) {
	fx := loadFixture(t)
	out, rs := Normalize(fx, fx)
	noRefusal(t, "fixture", rs)
	if out.Publications[0].Name != "SalesPub" || out.Publications[0].Snapshot.FTP != nil {
		t.Errorf("SalesPub snapshot.ftp %s, want nil", show(out.Publications[0].Snapshot.FTP))
	}

	d := loadFixture(t)
	d.Publications[0].Snapshot.EnabledForInternet = model.Ptr(true)
	d.Publications[0].Snapshot.FTP = &model.FTP{Address: str("ftp.example")}
	out, rs = Normalize(d, fx)
	noRefusal(t, "enabled_for_internet", rs)
	ftp := out.Publications[0].Snapshot.FTP
	if ftp == nil || !reflect.DeepEqual(ftp.Port, model.Ptr(21)) || !reflect.DeepEqual(ftp.Login, str("anonymous")) {
		t.Errorf("enabled_for_internet: ftp %s, want port 21, login anonymous", show(ftp))
	}

	out, rs = Normalize(testConfig(testPub("H", testTable("A", "dbo", "T"))), nil)
	noRefusal(t, "hand-written", rs)
	s := out.Publications[0].Snapshot
	if s == nil || !reflect.DeepEqual(s.EnabledForInternet, model.Ptr(false)) || s.FTP != nil {
		t.Errorf("hand-written publication: snapshot %s, want enabled_for_internet false and no ftp", show(s))
	}
}

func TestNormalizeSchedules(t *testing.T) {
	withSchedule := func(s model.Schedule) *model.Config {
		q := testPub("P", testTable("A", "dbo", "T"))
		q.SnapshotAgent = &model.Agent{Schedules: &[]model.Schedule{s}}
		return testConfig(q)
	}
	sched := func(c *model.Config) model.Schedule { return (*c.Publications[0].SnapshotAgent.Schedules)[0] }
	const path = "publications[P].snapshot_agent.schedules[s]"

	out, rs := Normalize(withSchedule(model.Schedule{Name: "s", Enabled: model.Ptr(true), Frequency: "once", StartDate: 99991231}), nil)
	noRefusal(t, "once", rs)
	if s := sched(out); s.EndDate != 99991231 || s.EndTime != 235959 || s.StartTime != 0 || s.StartDate != 99991231 {
		t.Errorf("once: %s, want end_date 99991231, end_time 235959, start_time 0", show(s))
	}

	disabled := withSchedule(model.Schedule{Name: "s", Enabled: model.Ptr(false), Frequency: "once"})
	_, rs = Normalize(disabled, nil)
	if !refused(rs, path+".enabled", "a schedule's enabled cannot be set by a replication procedure") {
		t.Errorf("enabled false on a created agent: refusals %v", rs)
	}
	current, _ := Normalize(disabled, nil)
	_, rs = Normalize(disabled, current)
	noRefusal(t, "enabled false against a current false", rs)
	trueCur := withSchedule(model.Schedule{Name: "s", Enabled: model.Ptr(true), Frequency: "once"})
	_, rs = Normalize(disabled, trueCur)
	if !refused(rs, path+".enabled", "cannot be set") {
		t.Errorf("enabled false against a current true: refusals %v", rs)
	}

	out, rs = Normalize(withSchedule(model.Schedule{Name: "s", Frequency: "once"}), nil)
	noRefusal(t, "nil enabled", rs)
	if s := sched(out); s.Enabled != nil {
		t.Errorf("nil enabled became %v", *s.Enabled)
	}

	_, rs = Normalize(withSchedule(model.Schedule{Name: "s", Frequency: "daily"}), nil)
	if !refused(rs, path+".interval", "interval of a daily schedule must be written") {
		t.Errorf("daily interval 0: refusals %v", rs)
	}
	_, rs = Normalize(withSchedule(model.Schedule{Name: "s"}), nil)
	if !refused(rs, path+".frequency", "has no default and must be written") {
		t.Errorf("no frequency: refusals %v", rs)
	}
}

func TestNormalizePublicationNameCollision(t *testing.T) {
	_, rs := Normalize(testConfig(testPub("P"), testPub("p")), nil)
	if len(rs) != 1 || !strings.Contains(rs[0].Reason, `"P"`) || !strings.Contains(rs[0].Reason, `"p"`) {
		t.Errorf("refusals %v, want one naming P and p", rs)
	}
}

func TestNormalizeIdentityBit(t *testing.T) {
	art := func(irm *string) model.Article {
		a := testTable("A", "dbo", "T")
		a.IdentityRangeManagement = irm
		a.SchemaOptions = &[]string{"object_creation", "identity_property"}
		return a
	}
	out, rs := Normalize(testConfig(testPub("P", art(str("manual")))), nil)
	noRefusal(t, "manual", rs)
	if got := *out.Publications[0].Articles[0].SchemaOptions; !reflect.DeepEqual(got, []string{"object_creation"}) {
		t.Errorf("manual: schema_options %v", got)
	}
	// The current manual value counts too.
	cur := testConfig(testPub("P", art(str("manual"))))
	out, rs = Normalize(testConfig(testPub("P", art(nil))), cur)
	noRefusal(t, "current manual", rs)
	if got := *out.Publications[0].Articles[0].SchemaOptions; !reflect.DeepEqual(got, []string{"object_creation"}) {
		t.Errorf("current manual: schema_options %v", got)
	}
	out, _ = Normalize(testConfig(testPub("P", art(str("none")))), nil)
	if got := *out.Publications[0].Articles[0].SchemaOptions; len(got) != 2 {
		t.Errorf("none: schema_options %v, want identity_property kept", got)
	}
}

func TestNormalizeKeepsCurrent(t *testing.T) {
	fx := loadFixture(t)
	if *fx.Distributor.MaxRetentionHours != 72 {
		t.Fatalf("fixture max retention %d", *fx.Distributor.MaxRetentionHours)
	}
	d := loadFixture(t)
	d.Distributor = nil
	out, rs := Normalize(d, fx)
	noRefusal(t, "no distributor", rs)
	if out.Distributor == nil || *out.Distributor.MaxRetentionHours != 72 || !reflect.DeepEqual(out.Distributor, fx.Distributor) {
		t.Errorf("no distributor: %s, want the current one", show(out.Distributor))
	}

	d = loadFixture(t)
	d.Distributor.DataFolder = nil
	out, _ = Normalize(d, fx)
	if !reflect.DeepEqual(out.Distributor.DataFolder, fx.Distributor.DataFolder) {
		t.Errorf("data_folder %s, want the current %s", show(out.Distributor.DataFolder), *fx.Distributor.DataFolder)
	}

	d = loadFixture(t)
	ag := d.Publications[0].Subscriptions[0].DistributionAgent
	ag.JobName, ag.RunAs, ag.Command, ag.JobEnabled = nil, nil, nil, nil
	out, rs = Normalize(d, fx)
	noRefusal(t, "push agent", rs)
	if got, want := out.Publications[0].Subscriptions[0].DistributionAgent, fx.Publications[0].Subscriptions[0].DistributionAgent; !reflect.DeepEqual(got, want) {
		t.Errorf("push agent %s, want %s", show(got), show(want))
	}

	d = loadFixture(t)
	d.Publisher.SyncWithBackup = nil
	out, _ = Normalize(d, fx)
	if !reflect.DeepEqual(out.Publisher.SyncWithBackup, model.Ptr(false)) {
		t.Errorf("sync_with_backup %s, want the current false", show(out.Publisher.SyncWithBackup))
	}
	d = loadFixture(t)
	d.Publisher.SyncWithBackup = model.Ptr(true)
	_, rs = Normalize(d, fx)
	if !refused(rs, "publisher.sync_with_backup", "not measured") {
		t.Errorf("sync_with_backup true against false: refusals %v", rs)
	}
}

// TestNormalizeInstanceDependent: the distributor's folders and files and a
// pull agent's distributor are neither filled nor refused when omitted on a
// new object, and keep the current value on an existing one.
func TestNormalizeInstanceDependent(t *testing.T) {
	pull := testPub("P")
	pull.IndependentAgent, pull.AllowPull = model.Ptr(true), model.Ptr(true)
	pull.Subscriptions = []model.Subscription{{Subscriber: "S", Database: "D", Type: str("pull"), Initialization: str("snapshot")}}
	c := testConfig(pull)
	c.Distributor = &model.Distributor{Server: "S", Database: "distribution"}
	out, rs := Normalize(c, nil)
	noRefusal(t, "new", rs)
	ds := out.Distributor
	for name, v := range map[string]*string{
		"data_folder": ds.DataFolder, "data_file": ds.DataFile, "log_folder": ds.LogFolder,
		"log_file": ds.LogFile, "working_directory": ds.WorkingDirectory,
	} {
		if v != nil {
			t.Errorf("new distributor: %s = %q, want nil", name, *v)
		}
	}
	if !reflect.DeepEqual(ds.MaxRetentionHours, model.Ptr(72)) {
		t.Errorf("new distributor: max_retention_hours %s, want the default 72", show(ds.MaxRetentionHours))
	}
	pa := out.Publications[0].Subscriptions[0].PullAgent
	if pa == nil || pa.Distributor != nil {
		t.Errorf("new pull agent %s, want one with a nil distributor", show(pa))
	}

	cur := testConfig(pull)
	cur.Distributor = &model.Distributor{Server: "S", Database: "distribution", DataFolder: str("/d"), DataFile: str("distribution.MDF"),
		LogFolder: str("/l"), LogFile: str("distribution.LDF"), WorkingDirectory: str("/w")}
	cur.Publications[0].Subscriptions[0].PullAgent = &model.PullAgent{Distributor: str("DIST")}
	out, rs = Normalize(c, cur)
	noRefusal(t, "existing", rs)
	ds = out.Distributor
	for name, v := range map[string][2]*string{
		"data_folder": {ds.DataFolder, str("/d")}, "data_file": {ds.DataFile, str("distribution.MDF")},
		"log_folder": {ds.LogFolder, str("/l")}, "log_file": {ds.LogFile, str("distribution.LDF")},
		"working_directory": {ds.WorkingDirectory, str("/w")},
	} {
		if !reflect.DeepEqual(v[0], v[1]) {
			t.Errorf("existing distributor: %s %s, want %s", name, show(v[0]), *v[1])
		}
	}
	if got := out.Publications[0].Subscriptions[0].PullAgent.Distributor; !reflect.DeepEqual(got, str("DIST")) {
		t.Errorf("existing pull agent: distributor %s, want DIST", show(got))
	}
}

func TestNormalizeIdempotent(t *testing.T) {
	fx := loadFixture(t)
	short := func() []*model.Config {
		imm := testPub("P", testTable("A", "dbo", "T"))
		imm.AllowAnonymous = model.Ptr(true)
		chr := testPub("P", testTable("A", "m_s", "T"))
		chr.SyncMethod = str("character")
		names := testTable("A", "", "m_x")
		names.Commands = &model.Commands{Insert: cmd("CALL", "", "m_ins")}
		names.IdentityRangeManagement = str("manual")
		names.SchemaOptions = &[]string{"object_creation", "identity_property", "timestamp_as_timestamp"}
		pull := testPub("P")
		pull.IndependentAgent = model.Ptr(true)
		pull.Subscriptions = []model.Subscription{{Subscriber: "S", Database: "D", Type: str("pull"), Initialization: str("snapshot")}}
		sched := testPub("P")
		sched.SnapshotAgent = &model.Agent{Schedules: &[]model.Schedule{{Name: "s", Frequency: "once"}}}
		return []*model.Config{
			testConfig(testPub("P", testTable("A", "dbo", "T"))), testConfig(imm), testConfig(chr),
			testConfig(testPub("P", names)), testConfig(pull), testConfig(sched),
		}
	}
	type pair struct{ desired, current *model.Config }
	pairs := []pair{{fx, fx}}
	for _, c := range short() {
		pairs = append(pairs, pair{c, nil})
	}
	for i, pr := range pairs {
		once, _ := Normalize(pr.desired, pr.current)
		twice, _ := Normalize(once, pr.current)
		if !reflect.DeepEqual(once, twice) {
			a, _ := model.Marshal(once)
			b, _ := model.Marshal(twice)
			t.Errorf("case %d: not idempotent\nonce:\n%s\ntwice:\n%s", i, a, b)
		}
	}
}

func TestNormalizeExportUnchanged(t *testing.T) {
	fx := loadFixture(t)
	out, rs := Normalize(fx, fx)
	noRefusal(t, "fixture", rs)
	want := loadFixture(t)
	want.Findings = nil
	if !reflect.DeepEqual(out, want) {
		a, _ := model.Marshal(out)
		b, _ := model.Marshal(want)
		t.Errorf("fixture changed\ngot:\n%s\nwant:\n%s", a, b)
	}
	if fx.Publications[0].Snapshot.FTP != nil {
		t.Error("Normalize changed its input")
	}
}
