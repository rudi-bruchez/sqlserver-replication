package reader

import (
	"context"
	"database/sql"
	"os"
	"strings"
	"testing"

	"github.com/rudi-bruchez/sqlserver-replication/internal/model"

	_ "github.com/microsoft/go-mssqldb"
	_ "github.com/microsoft/go-mssqldb/namedpipe"
	_ "github.com/microsoft/go-mssqldb/sharedmemory"
)

func TestMaskPasswords(t *testing.T) {
	cases := map[string]string{
		`-Publisher [P] -PublisherPassword secret -Continuous`:    `-Publisher [P] -PublisherPassword ******** -Continuous`,
		`-SubscriberPassword "with space" -DistributorPassword x`: `-SubscriberPassword ******** -DistributorPassword ********`,
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
			batch := "DECLARE @p1 nvarchar(256), @p2 nvarchar(256);\n" + q
			if _, err := conn.ExecContext(ctx, batch); err != nil {
				t.Errorf("%s with %s: %v", name, servers, err)
			}
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
