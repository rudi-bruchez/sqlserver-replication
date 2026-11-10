package reader

import (
	"context"
	"database/sql"
	"os"
	"strings"
	"testing"

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
// with no replication. Set REPLCFG_TEST_DSN to run it, for example
// sqlserver://localhost/SQLEXPRESS, or lpc:localhost\SQLEXPRESS for a local
// instance without TCP.
func TestQueriesParse(t *testing.T) {
	d := os.Getenv("REPLCFG_TEST_DSN")
	if d == "" {
		t.Skip("REPLCFG_TEST_DSN not set")
	}
	db, err := sql.Open("sqlserver", d)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	queries := map[string]string{
		"qServerName": qServerName, "qDistributorName": qDistributorName,
		"qPublications": qPublications, "qTableArticles": qTableArticles,
		"qSchemaArticles": qSchemaArticles, "qArticleColumns": qArticleColumns,
		"qSubscriptions": qSubscriptions, "qDistPublisher": qDistPublisher,
		"qDistributionDB": qDistributionDB, "qDistributorProperties": qDistributorProperties,
		"qHasReplServers": qHasReplServers, "qServerID": qServerID,
		"qLogReaderAgent": qLogReaderAgent, "qSnapshotAgents": qSnapshotAgents,
		"qDistributionAgents": qDistributionAgents, "qJob": qJob,
		"qJobSchedules": qJobSchedules, "qAgentProfiles": qAgentProfiles,
		"qAgentParameters": qAgentParameters,
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
