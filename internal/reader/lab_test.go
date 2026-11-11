package reader

import (
	"context"
	"database/sql"
	"net/url"
	"os"
	"regexp"
	"strings"
	"testing"

	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
)

// labDB opens a database of the lab instance (lab/gotest.sh sets the
// variables). The test is skipped unless SQLREPL_TEST_LAB is set; once it is
// set, a missing SQLREPL_TEST_DSN is a failure, not a skip.
func labDB(t *testing.T, database string) *sql.DB {
	t.Helper()
	if os.Getenv("SQLREPL_TEST_LAB") == "" {
		t.Skip("SQLREPL_TEST_LAB not set (run lab/gotest.sh)")
	}
	d := os.Getenv("SQLREPL_TEST_DSN")
	if d == "" {
		t.Fatal("SQLREPL_TEST_LAB is set but SQLREPL_TEST_DSN is not")
	}
	u, err := url.Parse(d)
	if err != nil {
		t.Fatal("SQLREPL_TEST_DSN is not a URL")
	}
	q := u.Query()
	q.Set("database", database)
	u.RawQuery = q.Encode()
	db, err := sql.Open("sqlserver", u.String())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	return db
}

// labRead reads the Sales publication of the lab, publisher and
// distributor being the same instance.
func labRead(t *testing.T) *Result {
	t.Helper()
	probe, err := Probe(context.Background(), labDB(t, "master"), "Sales")
	if err != nil {
		t.Fatal(err)
	}
	res, err := Read(context.Background(), Source{
		Publisher:   labDB(t, "Sales"),
		Distributor: labDB(t, "master"),
		Database:    "Sales",
		Probe:       probe,
	})
	if err != nil {
		t.Fatal(err)
	}
	return res
}

func TestReadLabSales(t *testing.T) {
	cfg := labRead(t).Config
	if cfg.Version != 2 {
		t.Errorf("version = %d, want 2", cfg.Version)
	}
	have := map[string]bool{}
	for _, p := range cfg.Publications {
		have[p.Name] = true
	}
	for _, n := range []string{"SalesPub", "SalesRef"} {
		if !have[n] {
			t.Errorf("publication %s missing", n)
		}
	}
	for _, f := range cfg.Findings {
		if !strings.HasPrefix(f.Path, "publications[") ||
			strings.HasPrefix(f.Path, "publications[SalesPub]") || strings.HasPrefix(f.Path, "publications[SalesRef]") {
			t.Errorf("unexpected finding %s %s: %s", f.Kind, f.Path, f.Message)
		}
	}
	re := regexp.MustCompile(`^SQLREPL_[A-Z0-9_]+$`)
	check := func(where string, s *string) {
		if s != nil && !re.MatchString(*s) {
			t.Errorf("%s: secret name %q", where, *s)
		}
	}
	agent := func(where string, a *model.Agent) {
		if a != nil && a.Connection != nil {
			check(where, a.Connection.PasswordSecret)
		}
	}
	if d := cfg.Distributor; d != nil && d.PublisherConnection != nil {
		check("distributor.publisher_connection", d.PublisherConnection.PasswordSecret)
	}
	agent("log reader", cfg.Publisher.LogReaderAgent)
	for _, s := range cfg.Publisher.SharedDistributionAgents {
		agent("shared "+s.Key(), &s.DistributionAgent.Agent)
	}
	for _, p := range cfg.Publications {
		agent(p.Name+" snapshot agent", p.SnapshotAgent)
		if p.Snapshot != nil && p.Snapshot.FTP != nil {
			check(p.Name+" ftp", p.Snapshot.FTP.PasswordSecret)
		}
		for _, s := range p.Subscriptions {
			if s.DistributionAgent != nil {
				agent(p.Name+" "+s.Key(), &s.DistributionAgent.Agent)
			}
		}
	}
}

func TestReadLabUnpublishedDatabase(t *testing.T) {
	ctx := context.Background()
	master := labDB(t, "master")
	if _, err := master.ExecContext(ctx, "CREATE DATABASE m_empty"); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		master.ExecContext(ctx, "ALTER DATABASE m_empty SET SINGLE_USER WITH ROLLBACK IMMEDIATE")
		if _, err := master.ExecContext(ctx, "DROP DATABASE m_empty"); err != nil {
			t.Errorf("dropping m_empty: %v", err)
		}
	})
	probe, err := Probe(ctx, master, "m_empty")
	if err != nil {
		t.Fatal(err)
	}
	res, err := Read(ctx, Source{
		Publisher:   labDB(t, "m_empty"),
		Distributor: labDB(t, "master"),
		Database:    "m_empty",
		Probe:       probe,
	})
	if err != nil {
		t.Fatal(err)
	}
	cfg := res.Config
	if len(cfg.Publications) != 0 {
		t.Errorf("%d publications, want none", len(cfg.Publications))
	}
	var server string
	if err := master.QueryRowContext(ctx, "SELECT @@SERVERNAME").Scan(&server); err != nil {
		t.Fatal(err)
	}
	d := cfg.Distributor
	if d == nil {
		t.Fatal("no distributor section")
	}
	if !strings.EqualFold(d.Server, server) || d.Database != "distribution" {
		t.Errorf("distributor = %s / %s, want %s / distribution", d.Server, d.Database, server)
	}
	if len(cfg.Findings) != 1 || cfg.Findings[0].Kind != model.FindingNote || cfg.Findings[0].Path != "publications" {
		t.Errorf("findings = %+v, want one note at publications", cfg.Findings)
	}
}
