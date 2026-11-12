package reader

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"reflect"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
	"github.com/rudi-bruchez/sqlserver-replication/internal/state"

	mssql "github.com/microsoft/go-mssqldb"
	_ "github.com/microsoft/go-mssqldb/namedpipe"
	_ "github.com/microsoft/go-mssqldb/sharedmemory"
)

func TestMaskPasswords(t *testing.T) {
	cases := map[string]string{
		`-Publisher [P] -PublisherPassword secret -Continuous`:    `-Publisher [P] -PublisherPassword ********`,
		`-SubscriberPassword "with space" -DistributorPassword x`: `-SubscriberPassword ********`,
		`-Subscriber [S] -SubscriberDB [db] -Distributor [D]`:     `-Subscriber [S] -SubscriberDB [db] -Distributor [D]`,
	}
	for in, want := range cases {
		if got := maskPasswords(in); got != want {
			t.Errorf("maskPasswords(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestQuoteName(t *testing.T) {
	if got := quoteName("dist]x"); got != "[dist]]x]" {
		t.Fatalf("got %q", got)
	}
}

// TestQueriesParse checks the syntax of every query with SET PARSEONLY, which
// does not resolve object names: any SQL Server instance will do, even one
// with no replication. Set SQLREPL_TEST_DSN to run it, for example
// sqlserver://localhost/SQLEXPRESS, or lpc:localhost\SQLEXPRESS for a local
// instance without TCP.
func TestQueriesParse(t *testing.T) {
	d := os.Getenv("SQLREPL_TEST_DSN")
	if d == "" {
		t.Skip("SQLREPL_TEST_DSN not set")
	}
	db, err := sql.Open("sqlserver", d)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	queries := map[string]string{
		"qServerName": qServerName, "qProbe": qProbe,
		"qPublications": qPublications, "qTableArticles": qTableArticles,
		"qSchemaArticles": qSchemaArticles, "qArticleColumns": qArticleColumns,
		"qSubscriptions": qSubscriptions, "qDistPublisher": qDistPublisher,
		"qDistributionDB": qDistributionDB, "qDistributorProperties": qDistributorProperties,
		"qHasReplServers": qHasReplServers, "qServerID": qServerID,
		"qLogReaderAgent": qLogReaderAgent, "qSnapshotAgents": qSnapshotAgents,
		"qDistributionAgents": qDistributionAgents, "qJob": qJob,
		"qJobSchedules": qJobSchedules, "qAgentProfiles": qAgentProfiles,
		"qAgentParameters": qAgentParameters,
		"qSyncWithBackup":  qSyncWithBackup, "qDistributorLink": qDistributorLink,
		"qDistributionFiles": qDistributionFiles, "qSubscriberType": qSubscriberType,
		"qDatabaseExists": qDatabaseExists, "qPullSubscription": subscriberQuery("SalesSub"),
		"qPublicationFacts": qPublicationFacts, "qArticleFacts": qArticleFacts,
		"qSubscriptionStatus": qSubscriptionStatus, "qReadAt": qReadAt,
		"qDistributorSubscriptionStatus": qDistributorSubscriptionStatus,
		"qLastGeneration":                qLastGeneration, "qLogReaderHistory": qLogReaderHistory,
		"qSnapshotHistory": qSnapshotHistory, "qDistributionHistory": qDistributionHistory,
		"qJobState": qJobState, "qDistributionDBs": qDistributionDBs,
	}
	ctx := context.Background()
	// PARSEONLY only applies to the batches that follow it in the session,
	// so it is set on a dedicated connection, in a batch of its own.
	conn, err := db.Conn(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if _, err := conn.ExecContext(ctx, "SET PARSEONLY ON"); err != nil {
		t.Fatal(err)
	}
	// Both server tables: MSreplservers, and the fallback for distributors
	// that predate it.
	for _, servers := range []string{"[distribution].dbo.MSreplservers", fallbackServers} {
		e := &exporter{dist: "[distribution]", servers: servers}
		for name, q := range queries {
			q = e.distQuery(q)
			if strings.Contains(q, "{") {
				t.Errorf("%s: unreplaced placeholder", name)
			}
			// Parameters are declared so that the batch parses on its own.
			batch := "DECLARE @p1 nvarchar(256), @p2 nvarchar(256), @p3 nvarchar(256);\n" + q
			if _, err := conn.ExecContext(ctx, batch); err != nil {
				t.Errorf("%s with %s: %v", name, servers, err)
			}
		}
	}
	// profileUsesQuery is built at run time from the distribution databases:
	// it is parsed for two names, one that needs quoting, with both server
	// tables.
	for _, fallback := range []bool{false, true} {
		q := profileUsesQuery([]string{"distribution", "m dist]2"}, fallback)
		if strings.Contains(q, "{") {
			t.Errorf("profileUsesQuery: unreplaced placeholder")
		}
		if _, err := conn.ExecContext(ctx, q); err != nil {
			t.Errorf("profileUsesQuery (fallback %t): %v", fallback, err)
		}
	}
	// A syntax error must still be reported, or the test proves nothing.
	if _, err := conn.ExecContext(ctx, "SELECT x FROM WHERE"); err == nil {
		t.Error("PARSEONLY accepted invalid syntax")
	}
}

func TestSecretRegistry(t *testing.T) {
	var s secrets
	a, f := s.name("SQL", "a_b", "c")
	if a != "SQLREPL_SQL_A_B_C" || f != nil {
		t.Fatalf("first: %q, %v", a, f)
	}
	b, f := s.name("SQL", "A_B", "c")
	if b != a || f != nil {
		t.Fatalf("same source: %q, %v", b, f)
	}
	c, f := s.name("SQL", "a", "b_c")
	if c != "SQLREPL_SQL_A_B_C_2" {
		t.Fatalf("collision: %q", c)
	}
	if f == nil || f.Kind != model.FindingNote ||
		!strings.Contains(f.Message, "SQL a_b/c") || !strings.Contains(f.Message, "SQL a/b_c") {
		t.Fatalf("collision finding: %+v", f)
	}
	d, _ := s.name("SQL", "a_b_", "c")
	if d != "SQLREPL_SQL_A_B__C" {
		t.Fatalf("distinct name: %q", d)
	}
	// ASCII-only upper-casing: dotless i and I are two sources.
	var u secrets
	x, f := u.name("SQL", "\u0131")
	y, g := u.name("SQL", "I")
	if x == y || f != nil || g != nil {
		t.Fatalf("dotless i: %q %q %v %v", x, y, f, g)
	}
	// Two different characters that both sanitize to "_" collide.
	z, h := u.name("SQL", "\u00e9")
	if z != x+"_2" || h == nil {
		t.Fatalf("collision of non-ASCII sources: %q, %v", z, h)
	}
}

func TestFindOnce(t *testing.T) {
	e := &exporter{cfg: &model.Config{}, found: map[string]bool{}}
	e.find(model.FindingNote, "publications[P]", "x %d", 1)
	e.find(model.FindingNote, "publications[P]", "x %d", 1)
	if n := len(e.cfg.Findings); n != 1 {
		t.Fatalf("identical calls gave %d findings", n)
	}
	e.find(model.FindingNote, "publications[Q]", "x %d", 1)
	if n := len(e.cfg.Findings); n != 2 {
		t.Fatalf("different paths gave %d findings", n)
	}
}

func TestStartDecision(t *testing.T) {
	cases := []struct {
		name  string
		probe PublisherProbe
		empty bool
		err   string
		kinds []string
	}{
		{"published", PublisherProbe{State: "ONLINE", Distributor: "D", Published: true}, false, "", nil},
		{"offline", PublisherProbe{State: "OFFLINE"}, false, "database is offline", nil},
		{"restoring", PublisherProbe{State: "RESTORING"}, false, "database is restoring", nil},
		{"standby", PublisherProbe{State: "ONLINE", Standby: true, Distributor: "D", Published: true}, false, "database is in standby", nil},
		{"no distributor", PublisherProbe{State: "ONLINE"}, true, "", []string{model.FindingNote}},
		{"unpublished", PublisherProbe{State: "ONLINE", Distributor: "D"}, true, "", []string{model.FindingNote}},
		{"merge only", PublisherProbe{State: "ONLINE", Distributor: "D", MergePublished: true}, true, "",
			[]string{model.FindingNote, model.FindingOutOfScope}},
		{"merge only, no distributor", PublisherProbe{State: "ONLINE", MergePublished: true}, true, "",
			[]string{model.FindingNote, model.FindingOutOfScope}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			empty, findings, err := c.probe.Start()
			if c.err != "" {
				if err == nil || !strings.Contains(err.Error(), c.err) {
					t.Fatalf("err = %v, want %q", err, c.err)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if empty != c.empty {
				t.Errorf("empty = %v, want %v", empty, c.empty)
			}
			var kinds []string
			for _, f := range findings {
				kinds = append(kinds, f.Kind)
			}
			if strings.Join(kinds, ",") != strings.Join(c.kinds, ",") {
				t.Errorf("findings = %v, want %v", kinds, c.kinds)
			}
		})
	}
}

func TestMultiSubnetFailover(t *testing.T) {
	cases := []struct {
		in   sql.NullString
		want bool
	}{
		{sql.NullString{}, false},
		{sql.NullString{String: "addr=tcp:d,1433", Valid: true}, false},
		{sql.NullString{String: "addr=tcp:d,1433;MultiSubnetFailover=Yes;", Valid: true}, true},
		{sql.NullString{String: "multisubnetfailover=yes", Valid: true}, true},
		{sql.NullString{String: "MultiSubnetFailover=No", Valid: true}, false},
	}
	for _, c := range cases {
		if got := multiSubnetFailover(c.in); got != c.want {
			t.Errorf("multiSubnetFailover(%+v) = %v, want %v", c.in, got, c.want)
		}
	}
}

func TestSplitFilePath(t *testing.T) {
	cases := []struct{ in, folder, file string }{
		{`/var/opt/mssql//DATA/distribution.MDF`, `/var/opt/mssql//DATA`, `distribution.MDF`},
		{`C:\Data\distribution.MDF`, `C:\Data`, `distribution.MDF`},
		{`distribution.MDF`, ``, `distribution.MDF`},
	}
	for _, c := range cases {
		folder, file := splitFilePath(c.in)
		if folder != c.folder || file != c.file {
			t.Errorf("splitFilePath(%q) = %q, %q, want %q, %q", c.in, folder, file, c.folder, c.file)
		}
	}
}

func TestCommandSwitch(t *testing.T) {
	lab := `-Publisher [REPLLAB] -PublisherDB [Sales] -Distributor [REPLLAB] -Publication [SalesPub] -DistributorSecurityMode 1`
	cases := []struct {
		cmd, name, want string
		ok              bool
	}{
		{lab, "DistributorSecurityMode", "1", true},
		{lab, "Distributor", "REPLLAB", true},
		{lab, "DistributorLogin", "", false},
		{lab, "PublisherDB", "Sales", true},
		{lab, "Publisher", "REPLLAB", true},
		{`-DistributorSecurityMode 0 -distributorlogin "repl user" -x 1`, "DistributorLogin", "repl user", true},
		{`-Publication [a]]b] -Continuous`, "Publication", "a]b", true},
		{`-Publication [a b] -Continuous`, "Publication", "a b", true},
		{`-PublisherDB [Sales]`, "Publisher", "", false},
		{`-Continuous -Publisher`, "Publisher", "", false},
	}
	for _, c := range cases {
		got, ok := commandSwitch(c.cmd, c.name)
		if got != c.want || ok != c.ok {
			t.Errorf("commandSwitch(%q, %q) = %q, %v; want %q, %v", c.cmd, c.name, got, ok, c.want, c.ok)
		}
	}
}

func TestRunAs(t *testing.T) {
	cases := []struct {
		name  string
		proxy sql.NullInt32
		found bool
		cred  sql.NullString
		want  *string
		ok    bool
	}{
		{"no proxy", sql.NullInt32{}, false, sql.NullString{}, model.Ptr(""), true},
		{"proxy not found", sql.NullInt32{Int32: 3, Valid: true}, false, sql.NullString{}, nil, false},
		{"null credential", sql.NullInt32{Int32: 3, Valid: true}, true, sql.NullString{}, nil, false},
		{"credential", sql.NullInt32{Int32: 3, Valid: true}, true, sql.NullString{String: `DOMAIN\svc`, Valid: true}, model.Ptr(`DOMAIN\svc`), true},
	}
	for _, c := range cases {
		got, ok := runAs(c.proxy, c.found, c.cred)
		if ok != c.ok || (got == nil) != (c.want == nil) || (got != nil && *got != *c.want) {
			t.Errorf("%s: runAs = %v, %v; want %v, %v", c.name, got, ok, c.want, c.ok)
		}
	}
}

// TestAgentSQLSecret feeds a SQL authentication row to agent(), which stops
// before any query because the row has no job.
func TestAgentSQLSecret(t *testing.T) {
	e := &exporter{cfg: &model.Config{}, found: map[string]bool{}, profiles: map[int]profileRow{}}
	a, err := e.agent("publisher.log_reader_agent", "log reader", agentRow{securityMode: 0, login: "repl user", jobLogin: `DOM\svc`}, "PUB-1")
	if err != nil {
		t.Fatal(err)
	}
	re := regexp.MustCompile(`^SQLREPL_[A-Z0-9_]+$`)
	for what, got := range map[string]*string{"connection": a.Connection.PasswordSecret, "job": a.JobPasswordSecret} {
		if got == nil || !re.MatchString(*got) {
			t.Errorf("%s secret = %v", what, got)
		}
	}
	if got := *a.Connection.PasswordSecret; got != "SQLREPL_SQL_PUB_1_REPL_USER" {
		t.Errorf("connection secret = %s", got)
	}
	if got := *a.JobPasswordSecret; got != "SQLREPL_WIN_DOM_SVC" {
		t.Errorf("job secret = %s", got)
	}
}

// The server writes the password raw: nothing may follow the mask.
func TestMaskPasswordsToEndOfLine(t *testing.T) {
	cases := map[string]string{
		`-DistributorSecurityMode 0 -DistributorLogin rv dist -DistributorPassword Thr0w away -Distributor x`: `-DistributorSecurityMode 0 -DistributorLogin rv dist -DistributorPassword ********`,
		`-DistributorPassword [Rv THROW3 tail] -Distributor [x]`:                                              `-DistributorPassword ********`,
		`-DistributorPassword p"w x" -Distributor [x]`:                                                        `-DistributorPassword ********`,
		`-DistributorLogin u-DistributorPassword sec ret`:                                                     `-DistributorLogin u-DistributorPassword ********`,
		`-a /SubscriberPASSWORD s3 cret -b`:                                                                   `-a /SubscriberPASSWORD ********`,
	}
	for in, want := range cases {
		if got := maskPasswords(in); got != want {
			t.Errorf("maskPasswords(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestLoginSwitch(t *testing.T) {
	cases := []struct {
		cmd, want string
		ok        bool
	}{
		{`-Publisher [P] -DistributorSecurityMode 0 -DistributorLogin rv dist -DistributorPassword Thr0w away -Distributor x`, "rv dist", true},
		{`-DistributorSecurityMode 0 -DistributorLogin rv"q]x -DistributorPassword Thr0w away -Distributor [x]`, `rv"q]x`, true},
		{`-DistributorSecurityMode 0 -DistributorLogin rv_u6adbz -DistributorPassword p`, "rv_u6adbz", true},
		{`-DistributorLogin u /DistributorPassword sec ret`, "u", true},
		{`-DistributorLogin a -DistributorLogin b -DistributorPassword p`, "", false}, // second switch inside the span
		{`-DistributorLogin -DistributorPassword p`, "", false},
		{`-DistributorLogin u`, "", false},
		{`-DistributorLogin u -Output /tmp/x -DistributorPassword p`, "", false},
		{`-DistributorLogin a -Publisher b -DistributorPassword p`, "", false},
		{`-DistributorLogin u-DistributorPassword sec ret`, "", false},
		{`-DistributorLogin my password -DistributorPassword p`, "", false},
		{`-Publisher [P]`, "", false},
	}
	for _, c := range cases {
		got, ok := loginSwitch(c.cmd)
		if got != c.want || ok != c.ok {
			t.Errorf("loginSwitch(%q) = %q, %v; want %q, %v", c.cmd, got, ok, c.want, c.ok)
		}
	}
}

func TestDistributorConnection(t *testing.T) {
	const tail = ` -DistributorPassword Thr0w away -Distributor [x]`
	cases := []struct {
		name, cmd     string
		security      string // "" when distributor_connection is nil
		login, secret string
		finding       string // path suffix of the unreadable finding, "" for none
	}{
		{"windows default", `-Publisher [P] -Distributor [D]`, "windows", "", "", ""},
		{"windows with trailing switch", `-Publisher [P] -DistributorSecurityMode 1 -OutputVerboseLevel 2`, "windows", "", "", ""},
		{"sql with trailing switch", `-DistributorSecurityMode 0 -DistributorLogin u -DistributorPassword p -OutputVerboseLevel 2`, "sql", "u", "SQLREPL_SQL_DIST_U", ""},
		{"login with switch", `-DistributorSecurityMode 0 -DistributorLogin u -Output /tmp/x -DistributorPassword p`, "sql", "", "", ".distributor_connection.login"},
		{"login with known switch", `-DistributorSecurityMode 0 -DistributorLogin a -Publisher b -DistributorPassword p`, "sql", "", "", ".distributor_connection.login"},
		{"slash password switch", `-DistributorSecurityMode 0 -DistributorLogin u /DistributorPassword sec ret`, "sql", "u", "SQLREPL_SQL_DIST_U", ""},
		{"glued password switch", `-DistributorSecurityMode 0 -DistributorLogin u-DistributorPassword sec ret`, "sql", "", "", ".distributor_connection.login"},
		{"glued mode switch", `-Publisher [R]-DistributorSecurityMode 0 -DistributorLogin u -DistributorPassword p`, "", "", "", ".distributor_connection"},
		{"glued login switch", `-DistributorSecurityMode 0 [R]-DistributorLogin u -DistributorPassword p`, "", "", "", ".distributor_connection"},
		{"sql with spaces", `-DistributorSecurityMode 0 -DistributorLogin rv dist` + tail, "sql", "rv dist", "SQLREPL_SQL_DIST_RV_DIST", ""},
		{"sql with quote", `-DistributorSecurityMode 0 -DistributorLogin rv"q]x` + tail, "sql", `rv"q]x`, "SQLREPL_SQL_DIST_RV_Q_X", ""},
		{"sql login missing", `-DistributorSecurityMode 0` + tail, "sql", "", "", ".distributor_connection.login"},
		{"sql login empty", `-DistributorSecurityMode 0 -DistributorLogin -DistributorPassword p`, "sql", "", "", ".distributor_connection.login"},
		{"switch without value", `-Publisher [P] -DistributorSecurityMode`, "", "", "", ".distributor_connection"},
		{"non numeric mode", `-DistributorSecurityMode abc -Distributor [D]`, "", "", "", ".distributor_connection"},
		{"unbalanced bracket", `-DistributorSecurityMode 1 -Distributor [D`, "", "", "", ".distributor_connection"},
		{"unbalanced quote", `-DistributorSecurityMode 1 -Distributor "D`, "", "", "", ".distributor_connection"},
	}
	for _, c := range cases {
		e := &exporter{cfg: &model.Config{Distributor: &model.Distributor{Server: "DIST"}}, found: map[string]bool{}}
		var a model.Agent
		e.distributorConnection("a", &a, c.cmd)
		dc := a.DistributorConnection
		if c.security == "" {
			if dc != nil {
				t.Errorf("%s: distributor_connection = %+v, want nil", c.name, dc)
			}
		} else if dc == nil || *dc.Security != c.security {
			t.Errorf("%s: distributor_connection = %+v, want %s", c.name, dc, c.security)
		} else {
			if c.login != "" && (dc.Login == nil || *dc.Login != c.login) {
				t.Errorf("%s: login = %v, want %q", c.name, dc.Login, c.login)
			}
			if c.login == "" && dc.Login != nil {
				t.Errorf("%s: login = %q, want nil", c.name, *dc.Login)
			}
			if (dc.PasswordSecret == nil) != (c.secret == "") || (c.secret != "" && *dc.PasswordSecret != c.secret) {
				t.Errorf("%s: password_secret = %v, want %q", c.name, dc.PasswordSecret, c.secret)
			}
		}
		var got []string
		for _, f := range e.cfg.Findings {
			if f.Kind == model.FindingUnreadable {
				got = append(got, f.Path)
			}
		}
		want := []string(nil)
		if c.finding != "" {
			want = []string{"a" + c.finding}
		}
		if !reflect.DeepEqual(got, want) {
			t.Errorf("%s: unreadable findings %q, want %q", c.name, got, want)
		}
	}
}

const syncCustomer = "create view [dbo].[SYNC_Customer]as select  [CustomerID],[Name],[Country]  from  [dbo].[Customer]  where HAS_PERMS_BY_NAME('[dbo].[Customer]', 'OBJECT', 'SELECT')= 1  and (Country = 'FR')"

const syncOrders = "create view [dbo].[syncobj_0x3939303644423539]as select  [OrderID],[CustomerID],[Amount]  from  [dbo].[Orders]  where HAS_PERMS_BY_NAME('[dbo].[Orders]', 'OBJECT', 'SELECT')= 1 "

func TestCheckSyncView(t *testing.T) {
	cust := []string{"CustomerID", "Name", "Country"}
	withClause := func(c string) string {
		return strings.Replace(syncCustomer, "and (Country = 'FR')", "and ("+c+")", 1)
	}
	tests := []struct {
		name       string
		def, claus string
		cols       []string
		generated  bool
		problems   int
	}{
		{"match", syncCustomer, "Country = 'FR'", cust, true, 0},
		{"other clause", syncCustomer, "Country = 'DE'", cust, true, 1},
		{"fewer columns", syncCustomer, "Country = 'FR'", []string{"CustomerID", "Name"}, true, 1},
		{"column order", syncCustomer, "Country = 'FR'", []string{"Name", "CustomerID", "Country"}, true, 1},
		{"no clause", syncOrders, "", []string{"OrderID", "CustomerID", "Amount"}, true, 0},
		{"clause missing in view", syncOrders, "Amount > 0", []string{"OrderID", "CustomerID", "Amount"}, true, 1},
		{"clause missing in article", syncCustomer, "", cust, true, 1},
		{"not a view", "not a view", "", nil, false, 0},
		{"user view", "create view [dbo].[v] as select a from dbo.t where a > 0", "", []string{"a"}, false, 0},
		{"flag = 1", withClause("flag = 1"), "flag = 1", cust, true, 0},
		{"trailing semicolon", syncCustomer + ";", "Country = 'FR'", cust, true, 0},
		{"id = 10", withClause("Amount = 10"), "Amount = 10", cust, true, 0},
		{"whitespace outside literals", withClause("Country   =\n 'FR'"), "Country = 'FR'", cust, true, 0},
		{"whitespace in literal", withClause("City = 'New  York'"), "City = 'New York'", cust, true, 1},
		{"quote in literal", withClause("City = 'L''Aigle'"), "City = 'L''Aigle'", cust, true, 0},
		{"bracketed names", strings.Replace(syncCustomer, "[CustomerID],[Name],[Country]", "[a from b],[c,d]", 1), "Country = 'FR'", []string{"a from b", "c,d"}, true, 0},
		{"bracket with ]]", strings.Replace(syncCustomer, "[CustomerID],[Name],[Country]", "[a]]b],[c]", 1), "Country = 'FR'", []string{"a]b", "c"}, true, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			generated, problems := checkSyncView(tt.def, tt.claus, tt.cols)
			if generated != tt.generated || len(problems) != tt.problems {
				t.Errorf("generated %v, problems %q; want %v, %d problems", generated, problems, tt.generated, tt.problems)
			}
		})
	}
}

func TestSubsetAllowed(t *testing.T) {
	pub := func(method string, immediate bool) *model.Publication {
		return &model.Publication{SyncMethod: model.Ptr(method), ImmediateSync: model.Ptr(immediate)}
	}
	if subsetAllowed(pub("native", true)) {
		t.Error("immediate_sync: a subset cannot exist")
	}
	for _, m := range []string{"concurrent", "concurrent_c"} {
		if subsetAllowed(pub(m, false)) {
			t.Errorf("%s: a subset cannot exist", m)
		}
	}
	for _, m := range []string{"native", "character", "database_snapshot", "database_snapshot_character"} {
		if !subsetAllowed(pub(m, false)) {
			t.Errorf("%s: a subset can exist", m)
		}
	}
}

func TestSelectProfiles(t *testing.T) {
	profiles := map[int]profileRow{
		1: {name: "Default agent profile", agentType: 3, userDefined: false},
		2: {name: "unused", agentType: 3, userDefined: true, description: "d"},
		3: {name: "merge one", agentType: 9, userDefined: true},
		4: {name: "snap", agentType: 1, userDefined: true, isDefault: true},
	}
	params := map[int]map[string]string{2: {"-CommitBatchSize": "200"}}
	got := selectProfiles(profiles, params)
	if len(got) != 2 || got[0].Name != "snap" || got[1].Name != "unused" {
		t.Fatalf("selectProfiles = %+v, want snap then unused", got)
	}
	if got[0].AgentType != "snapshot" || got[1].AgentType != "distribution" {
		t.Errorf("agent types = %q, %q", got[0].AgentType, got[1].AgentType)
	}
	if got[1].Parameters["-CommitBatchSize"] != "200" {
		t.Errorf("parameters = %v", got[1].Parameters)
	}
	if got[0].Default == nil || !*got[0].Default {
		t.Errorf("default flag lost on %+v", got[0])
	}
}

func TestSubscriberQueryQuotesDatabase(t *testing.T) {
	q := subscriberQuery("m sub]1")
	if !strings.Contains(q, "[m sub]]1].dbo.MSreplication_subscriptions") {
		t.Errorf("query does not quote the database:\n%s", q)
	}
	if strings.Contains(q, "{") {
		t.Errorf("unreplaced placeholder:\n%s", q)
	}
}

// The pull agent's step carries -Subscriber, -SubscriberSecurityMode and
// -SubscriberLogin, read as the distributor switches are.
func TestSubscriberCommandConnection(t *testing.T) {
	cases := []struct {
		name, cmd        string
		security, secret string // security "" when the connection is nil
	}{
		{"lab", `-Publisher [repllab] -PublisherDB [Sales] -Publication [m_pp] -Distributor [repllab] -SubscriptionType 1 -Subscriber [repllab] -SubscriberSecurityMode 1 -SubscriberDB [m_psub]`, "windows", ""},
		{"absent mode", `-Subscriber [S] -SubscriberDB [db]`, "windows", ""},
		{"sql", `-Subscriber [S] -SubscriberSecurityMode 0 -SubscriberLogin u -SubscriberPassword p -SubscriberDB [db]`, "sql", "SQLREPL_SQL_SUB_U"},
		{"unbalanced", `-Subscriber [S -SubscriberSecurityMode 1`, "", ""},
	}
	for _, c := range cases {
		e := &exporter{cfg: &model.Config{}, found: map[string]bool{}}
		got := e.commandConnection("a.connection", c.cmd, "Subscriber", "SUB")
		if c.security == "" {
			if got != nil || len(e.cfg.Findings) != 1 {
				t.Errorf("%s: connection %+v, findings %+v; want nil and one finding", c.name, got, e.cfg.Findings)
			}
			continue
		}
		if got == nil || *got.Security != c.security {
			t.Errorf("%s: connection %+v, want %s", c.name, got, c.security)
			continue
		}
		if (got.PasswordSecret == nil) != (c.secret == "") || (c.secret != "" && *got.PasswordSecret != c.secret) {
			t.Errorf("%s: password_secret = %v, want %q", c.name, got.PasswordSecret, c.secret)
		}
		if len(e.cfg.Findings) != 0 {
			t.Errorf("%s: findings %+v", c.name, e.cfg.Findings)
		}
	}
}

// Error 208 (invalid object name) of the subscriber query is a missing
// table; any other error, 229 (permission denied) included, fails the export.
func TestErrorNumber(t *testing.T) {
	cases := []struct {
		err  error
		want int32
	}{
		{mssql.Error{Number: 208}, 208},
		{fmt.Errorf("subscriber S: %w", mssql.Error{Number: 208}), 208},
		{mssql.Error{Number: 229}, 229},
		{errors.New("connection reset"), 0},
	}
	for _, c := range cases {
		if got := errorNumber(c.err); got != c.want {
			t.Errorf("errorNumber(%v) = %d, want %d", c.err, got, c.want)
		}
	}
}

func TestJobState(t *testing.T) {
	at := sql.NullTime{Time: time.Date(2026, 11, 11, 10, 0, 0, 0, time.UTC), Valid: true}
	null := sql.NullTime{}
	cases := []struct {
		name    string
		exists  bool
		enabled int
		start   sql.NullTime
		stop    sql.NullTime
		want    state.JobState
	}{
		{"no job", false, 1, at, null, state.JobState{}},
		{"running", true, 1, at, null, state.JobState{Exists: true, Enabled: true, Running: true}},
		{"stopped", true, 1, at, at, state.JobState{Exists: true, Enabled: true}},
		{"never started", true, 1, null, null, state.JobState{Exists: true, Enabled: true}},
		{"disabled", true, 0, null, null, state.JobState{Exists: true}},
	}
	for _, c := range cases {
		if got := jobState(c.exists, c.enabled, c.start, c.stop); got != c.want {
			t.Errorf("%s: jobState = %+v, want %+v", c.name, got, c.want)
		}
	}
}
