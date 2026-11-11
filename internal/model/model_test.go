package model

import (
	"bytes"
	"reflect"
	"strings"
	"testing"
)

func TestLoadOmittedVsZero(t *testing.T) {
	in := `version: 2
publisher: {server: S, database: D}
publications:
  - name: P
    immediate_sync: false
    retention_hours: 0
    description: ""
    articles:
      - name: A
        schema_options: []
      - name: B
`
	c, err := Load(strings.NewReader(in))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	p := c.Publications[0]
	if p.ImmediateSync == nil || *p.ImmediateSync {
		t.Errorf("immediate_sync: got %v, want a pointer to false", p.ImmediateSync)
	}
	if p.AllowPull != nil {
		t.Errorf("allow_pull: got %v, want nil", *p.AllowPull)
	}
	if p.RetentionHours == nil || *p.RetentionHours != 0 {
		t.Errorf("retention_hours: got %v, want a pointer to 0", p.RetentionHours)
	}
	if p.Description == nil || *p.Description != "" {
		t.Errorf("description: got %v, want a pointer to the empty string", p.Description)
	}
	if p.Status != nil {
		t.Errorf("status: got %q, want nil", *p.Status)
	}
	if so := p.Articles[0].SchemaOptions; so == nil || len(*so) != 0 {
		t.Errorf("article A schema_options: got %v, want a pointer to an empty list", so)
	}
	if so := p.Articles[1].SchemaOptions; so != nil {
		t.Errorf("article B schema_options: got %v, want nil", *so)
	}
}

func TestLoadRejectsUnknownField(t *testing.T) {
	in := "version: 2\npublications: [{name: P, imediate_sync: true}]\n"
	_, err := Load(strings.NewReader(in))
	if err == nil {
		t.Fatal("Load accepted an unknown field")
	}
	if !strings.Contains(err.Error(), "imediate_sync") {
		t.Errorf("error %q does not name imediate_sync", err)
	}
}

func TestLoadRejectsOtherVersion(t *testing.T) {
	_, err := Load(strings.NewReader("version: 1\n"))
	if err == nil {
		t.Fatal("Load accepted version 1")
	}
	if want := "format version 1, this sqlrepl reads 2"; err.Error() != want {
		t.Errorf("error %q, want %q", err, want)
	}
}

// fullConfig builds a configuration with every pointer set, zero values
// included.
func fullConfig() *Config {
	sqlConn := func(secret string) *Connection {
		return &Connection{Security: Ptr("sql"), Login: Ptr("repl"), PasswordSecret: Ptr(secret)}
	}
	agent := func(job string) Agent {
		return Agent{
			JobName:    Ptr(job),
			Profile:    Ptr(""),
			RunAs:      Ptr(""),
			Connection: &Connection{Security: Ptr("windows"), Login: Ptr(""), PasswordSecret: Ptr("")},
			Schedules: Ptr([]Schedule{
				{Name: "s1", Enabled: true, Frequency: "daily", Interval: 1, Subday: "minutes", SubdayInterval: 5},
				{Name: "s2", Frequency: "autostart"},
			}),
			Command: Ptr("-Publisher [S]"),
		}
	}
	proc := &ObjectName{Schema: "dbo", Name: "sp_MSins_dboT"}
	return &Config{
		Version: FormatVersion,
		Publisher: Publisher{
			Server:         "S",
			Database:       "D",
			LogReaderAgent: Ptr(agent("logreader")),
			SharedDistributionAgents: []SharedDistributionAgent{{
				Subscriber: "SUB", Database: "SubDB",
				DistributionAgent: DistributionAgent{Agent: agent("shared"), SubscriptionStreams: Ptr(0), MemoryOptimized: Ptr(false)},
			}},
		},
		Distributor: &Distributor{
			Server:                "S",
			Database:              "distribution",
			MinRetentionHours:     Ptr(0),
			MaxRetentionHours:     Ptr(72),
			HistoryRetentionHours: Ptr(48),
			WorkingDirectory:      Ptr(""),
			PublisherConnection:   sqlConn("publisher/S"),
			Trusted:               Ptr(false),
			Properties:            map[string]string{"k": "v"},
		},
		Publications: []Publication{{
			Name:                      "P",
			Description:               Ptr(""),
			Type:                      Ptr("transactional"),
			Status:                    Ptr("active"),
			SyncMethod:                Ptr("concurrent"),
			RetentionHours:            Ptr(0),
			IndependentAgent:          Ptr(true),
			ImmediateSync:             Ptr(false),
			AllowPush:                 Ptr(true),
			AllowPull:                 Ptr(false),
			AllowAnonymous:            Ptr(false),
			AllowSubscriptionCopy:     Ptr(false),
			AllowInitializeFromBackup: Ptr(false),
			ReplicateDDL:              Ptr(true),
			AllowDrop:                 Ptr(false),
			Snapshot: &Snapshot{
				InDefaultFolder: Ptr(true),
				AltFolder:       Ptr(""),
				Compress:        Ptr(false),
				PreScript:       Ptr(""),
				PostScript:      Ptr(""),
				FTP: &FTP{Address: Ptr(""), Port: Ptr(0), Subdirectory: Ptr(""),
					Login: Ptr("anonymous"), PasswordSecret: Ptr("ftp/P")},
			},
			SnapshotAgent: Ptr(agent("snapshot")),
			Articles: []Article{
				{
					Name:                   "T",
					Type:                   Ptr("logbased"),
					Source:                 ObjectName{Schema: "dbo", Name: "T"},
					Destination:            Destination{Schema: Ptr(""), Name: Ptr("T")},
					Description:            Ptr(""),
					PreCreationCmd:         Ptr("drop"),
					SchemaOptions:          Ptr([]string{}),
					CreationScript:         Ptr(""),
					InsertColumnNames:      Ptr(true),
					Parameterized:          Ptr(false),
					Commands:               &Commands{Insert: &Command{Mode: "CALL", Procedure: proc}, Update: &Command{Mode: "SCALL", Procedure: proc}, Delete: &Command{Mode: "XCALL", Procedure: proc}},
					Filter:                 &Filter{Clause: "a > 0", Procedure: &ObjectName{Schema: "dbo", Name: "f"}},
					SyncObject:             &ObjectName{Schema: "dbo", Name: "v"},
					FireTriggersOnSnapshot: Ptr(false),
					Columns:                []string{"a", "id"},
				},
				{
					Name:                   "V",
					Type:                   Ptr("view_schema_only"),
					Source:                 ObjectName{Schema: "dbo", Name: "V"},
					Destination:            Destination{Schema: Ptr("dbo"), Name: Ptr("V")},
					Description:            Ptr("a view"),
					PreCreationCmd:         Ptr("none"),
					SchemaOptions:          Ptr([]string{"creation_script", "extended_properties"}),
					CreationScript:         Ptr(""),
					InsertColumnNames:      Ptr(false),
					Parameterized:          Ptr(false),
					Commands:               &Commands{Insert: &Command{Mode: "SQL", Procedure: proc}, Update: &Command{Mode: "SQL", Procedure: proc}, Delete: &Command{Mode: "NONE", Procedure: proc}},
					FireTriggersOnSnapshot: Ptr(false),
				},
			},
			Subscriptions: []Subscription{{
				Subscriber:        "SUB",
				Database:          "SubDB",
				Articles:          []string{"T"},
				Initialization:    Ptr("automatic"),
				LoopbackDetection: Ptr(false),
				DistributionAgent: &DistributionAgent{Agent: agent("dist"), SubscriptionStreams: Ptr(4), MemoryOptimized: Ptr(false)},
			}},
		}},
		AgentProfiles: []AgentProfile{{
			Name: "prof", AgentType: "distribution", Description: Ptr(""), Default: Ptr(false),
			Parameters: map[string]string{"-CommitBatchSize": "100"},
		}},
		Findings: []Finding{{Kind: "note", Path: "publications[P].status", Message: "m"}},
	}
}

func TestMarshalLoadRoundTrip(t *testing.T) {
	want := fullConfig()
	out, err := Marshal(want)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	got, err := Load(bytes.NewReader(out))
	if err != nil {
		t.Fatalf("Load: %v\n%s", err, out)
	}
	if !reflect.DeepEqual(got, want) {
		out2, _ := Marshal(got)
		t.Errorf("round trip differs\nwritten:\n%s\nloaded and written again:\n%s", out, out2)
	}
}

func TestNilProperties(t *testing.T) {
	if got := NilProperties(fullConfig()); len(got) != 0 {
		t.Errorf("full configuration: got %q, want none", got)
	}

	c := fullConfig()
	p := &c.Publications[0]
	p.Status = nil
	v := &p.Articles[1]
	v.Commands, v.InsertColumnNames, v.Parameterized, v.FireTriggersOnSnapshot = nil, nil, nil, nil
	conn := c.Publisher.LogReaderAgent.Connection
	conn.Login, conn.PasswordSecret = nil, nil
	got := NilProperties(c)
	if want := []string{"publications[P].status"}; !reflect.DeepEqual(got, want) {
		t.Errorf("got %q, want %q", got, want)
	}

	// A shared agent serves a publication without an independent agent, and
	// a configuration with no publication needs no log reader.
	c = fullConfig()
	c.Publications[0].IndependentAgent = Ptr(false)
	c.Publications[0].Subscriptions[0].DistributionAgent = nil
	c.Publications[0].Articles[0].Filter, c.Publications[0].Articles[0].SyncObject = nil, nil
	c.Publications[0].Articles[0].Commands.Update = &Command{Mode: "SQL"}
	c.Publications[0].Snapshot.FTP = nil
	if got := NilProperties(c); len(got) != 0 {
		t.Errorf("shared agent: got %q, want none", got)
	}
	c.Publications[0].IndependentAgent = Ptr(true)
	if got, want := NilProperties(c), []string{"publications[P].subscriptions[SUB/SubDB].distribution_agent"}; !reflect.DeepEqual(got, want) {
		t.Errorf("independent agent: got %q, want %q", got, want)
	}
	c = fullConfig()
	c.Publisher.LogReaderAgent = nil
	if got, want := NilProperties(c), []string{"publisher.log_reader_agent"}; !reflect.DeepEqual(got, want) {
		t.Errorf("log reader with a publication: got %q, want %q", got, want)
	}
	c.Publications = nil
	if got := NilProperties(c); len(got) != 0 {
		t.Errorf("log reader without publication: got %q, want none", got)
	}
}

func TestPathEscapesKeys(t *testing.T) {
	c := fullConfig()
	c.Publications[0].Articles[0].Name = "a]b"
	c.Publications[0].Articles[0].Description = nil
	want := "publications[P].articles[a]]b]"
	got := NilProperties(c)
	if len(got) != 1 || got[0] != want+".description" {
		t.Fatalf("got %q, want [%q]", got, want+".description")
	}
	if p := Pattern(want); p != "publications[*].articles[*]" {
		t.Errorf("Pattern(%q) = %q, want %q", want, p, "publications[*].articles[*]")
	}
	if p := Pattern("publications[P].articles[a]]].x"); p != "publications[*].articles[*].x" {
		t.Errorf("Pattern of a key ending with ] = %q", p)
	}
}

func TestLoadRejectsNullListElement(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"version: 2\npublisher:\n  server: S\n  database: D\n  log_reader_agent:\n    schedules: [~]\n", "line 6: null list element"},
		{"version: 2\npublications:\n  - name: P\n    articles: [null, {name: A}]\n", "line 4: null list element"},
	} {
		_, err := Load(strings.NewReader(tc.in))
		if err == nil || err.Error() != tc.want {
			t.Errorf("Load(%q): error %v, want %q", tc.in, err, tc.want)
		}
	}
}

func TestLoadRejectsSecondDocument(t *testing.T) {
	_, err := Load(strings.NewReader("version: 2\n---\nversion: 1\n"))
	if err == nil || err.Error() != "more than one YAML document" {
		t.Errorf("error %v, want %q", err, "more than one YAML document")
	}
}

// pointerList has a field shape the walk cannot judge.
type pointerList struct {
	Items []*Publication `yaml:"items"`
}

func TestNilPropertiesPanicsOnPointerSlice(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Error("the walk accepted a list of pointers to structs")
		}
	}()
	v := reflect.ValueOf(&pointerList{}).Elem()
	var out []string
	walkStruct(v, "", nil, v, &out)
}

func TestSecretName(t *testing.T) {
	cases := []struct {
		got, want string
	}{
		{SecretName("SQL", "repllab", "distributor_admin"), "SQLREPL_SQL_REPLLAB_DISTRIBUTOR_ADMIN"},
		{SecretName("SQL", `PUB\INST`, "repl.user"), "SQLREPL_SQL_PUB_INST_REPL_USER"},
		{SecretName("SQL", "caf\u00e9"), "SQLREPL_SQL_CAF_"},
		{SecretName("WIN", `DOMAIN\svc`), "SQLREPL_WIN_DOMAIN_SVC"},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Errorf("got %q, want %q", c.got, c.want)
		}
	}
}
