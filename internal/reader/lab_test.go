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
	if d := cfg.Distributor; d != nil {
		check("distributor.admin_password_secret", d.AdminPasswordSecret)
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

func TestReadLabDistributorAndPublications(t *testing.T) {
	cfg := labRead(t).Config
	d := cfg.Distributor
	if d == nil {
		t.Fatal("no distributor section")
	}
	str := func(what string, got *string, want string) {
		t.Helper()
		if got == nil || *got != want {
			t.Errorf("%s = %v, want %q", what, got, want)
		}
	}
	num := func(what string, got *int, want int) {
		t.Helper()
		if got == nil || *got != want {
			t.Errorf("%s = %v, want %d", what, got, want)
		}
	}
	flag := func(what string, got *bool, want bool) {
		t.Helper()
		if got == nil || *got != want {
			t.Errorf("%s = %v, want %v", what, got, want)
		}
	}
	str("data_folder", d.DataFolder, "/var/opt/mssql//DATA")
	str("data_file", d.DataFile, "distribution.MDF")
	str("log_folder", d.LogFolder, "/var/opt/mssql//DATA")
	str("log_file", d.LogFile, "distribution.LDF")
	num("delete_batch_size_xact", d.DeleteBatchSizeXact, 5000)
	num("delete_batch_size_cmd", d.DeleteBatchSizeCmd, 2000)
	str("admin_link_security", d.AdminLinkSecurity, "sql")
	flag("multi_subnet_failover", d.MultiSubnetFailover, false)
	if d.StorageConnectionStringSecret != nil {
		t.Errorf("storage_connection_string_secret = %q, want nil", *d.StorageConnectionStringSecret)
	}
	str("admin_password_secret", d.AdminPasswordSecret, "SQLREPL_SQL_REPLLAB_DISTRIBUTOR_ADMIN")
	flag("sync_with_backup", cfg.Publisher.SyncWithBackup, false)

	seen := 0
	for _, p := range cfg.Publications {
		if p.Name != "SalesPub" && p.Name != "SalesRef" {
			continue
		}
		seen++
		flag(p.Name+" allow_partition_switch", p.AllowPartitionSwitch, false)
		flag(p.Name+" replicate_partition_switch", p.ReplicatePartitionSwitch, false)
		flag(p.Name+" enabled_for_het_sub", p.EnabledForHetSub, false)
		if p.Snapshot == nil {
			t.Fatalf("%s: no snapshot section", p.Name)
		}
		flag(p.Name+" enabled_for_internet", p.Snapshot.EnabledForInternet, false)
		if len(p.Subscriptions) == 0 {
			t.Errorf("%s: no subscription", p.Name)
		}
		for _, s := range p.Subscriptions {
			str(p.Name+" "+s.Key()+" type", s.Type, "push")
			str(p.Name+" "+s.Key()+" subscriber_type", s.SubscriberType, "sql_server")
		}
	}
	if seen != 2 {
		t.Errorf("%d of SalesPub and SalesRef found, want 2", seen)
	}
}

// TestReadLabSnapshotPublication creates a snapshot publication in Sales, with
// a snapshot agent whose schedule never fires, and removes it.
func TestReadLabSnapshotPublication(t *testing.T) {
	ctx := context.Background()
	sales := labDB(t, "Sales")
	// One connection: the publication procedures and the cleanup run in the
	// same session, and every statement is an ordinary batch.
	conn, err := sales.Conn(ctx)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	exec := func(q string) error {
		_, err := conn.ExecContext(ctx, q)
		return err
	}
	t.Cleanup(func() {
		// Publication first, then the table.
		if err := exec("IF EXISTS (SELECT 1 FROM dbo.syspublications WHERE name = N'm_snap') EXEC sp_droppublication @publication = N'm_snap'"); err != nil {
			t.Errorf("dropping m_snap: %v", err)
		}
		if err := exec("IF OBJECT_ID(N'dbo.m_t1') IS NOT NULL DROP TABLE dbo.m_t1"); err != nil {
			t.Errorf("dropping m_t1: %v", err)
		}
	})
	for _, q := range []string{
		"CREATE TABLE dbo.m_t1 (id int PRIMARY KEY, a int)",
		"EXEC sp_addpublication @publication = N'm_snap', @repl_freq = N'snapshot', @status = N'active'",
		"EXEC sp_addpublication_snapshot @publication = N'm_snap', @frequency_type = 1, @active_start_date = 99991231",
		"EXEC sp_addarticle @publication = N'm_snap', @article = N'm_t1', @source_object = N'm_t1', @source_owner = N'dbo'",
	} {
		if err := exec(q); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}

	cfg := labRead(t).Config
	var snap *model.Publication
	for i := range cfg.Publications {
		if cfg.Publications[i].Name == "m_snap" {
			snap = &cfg.Publications[i]
		}
	}
	if snap == nil {
		t.Fatal("publication m_snap not exported")
	}
	if snap.Type == nil || *snap.Type != "snapshot" {
		t.Errorf("type = %v, want snapshot", snap.Type)
	}
	for _, f := range cfg.Findings {
		if strings.HasPrefix(f.Path, "publications[m_snap]") {
			t.Errorf("unexpected finding %s %s: %s", f.Kind, f.Path, f.Message)
		}
	}
	if len(snap.Articles) != 1 || snap.Articles[0].Commands == nil {
		t.Fatalf("articles = %+v, want one table article with commands", snap.Articles)
	}
	c := snap.Articles[0].Commands
	for what, cmd := range map[string]*model.Command{"insert": c.Insert, "update": c.Update, "delete": c.Delete} {
		if cmd == nil || cmd.Mode != "SQL" {
			t.Errorf("%s command = %+v, want mode SQL", what, cmd)
		}
	}
}

// The lab has no proxy and no Windows job account: job_login is NULL and no
// job step has a proxy. The unreadable branch of run_as is covered by TestRunAs.
// Only the lab's own agents are checked, by name: other sessions' objects in
// Sales must not fail the test.
func TestReadLabAgents(t *testing.T) {
	cfg := labRead(t).Config
	type named struct {
		what     string
		a        *model.Agent
		snapshot bool
	}
	var agents []named
	add := func(what string, a *model.Agent, snapshot bool) {
		if a == nil {
			t.Errorf("%s: not exported", what)
			return
		}
		agents = append(agents, named{what, a, snapshot})
	}
	add("log reader of Sales", cfg.Publisher.LogReaderAgent, false)
	for _, name := range []string{"SalesPub", "SalesRef"} {
		var p *model.Publication
		for i := range cfg.Publications {
			if cfg.Publications[i].Name == name {
				p = &cfg.Publications[i]
			}
		}
		if p == nil {
			t.Errorf("publication %s missing", name)
			continue
		}
		add(name+" snapshot agent", p.SnapshotAgent, true)
		if name != "SalesPub" {
			continue
		}
		var d *model.DistributionAgent
		for _, s := range p.Subscriptions {
			if strings.EqualFold(s.Database, "SalesSub") {
				d = s.DistributionAgent
			}
		}
		if d == nil {
			t.Errorf("SalesPub: no distribution agent for SalesSub")
		} else {
			add("SalesPub distribution agent", &d.Agent, false)
		}
	}
	var shared *model.DistributionAgent
	for i := range cfg.Publisher.SharedDistributionAgents {
		if s := &cfg.Publisher.SharedDistributionAgents[i]; strings.EqualFold(s.Database, "SalesSub") {
			shared = &s.DistributionAgent
		}
	}
	if shared == nil {
		t.Error("no shared distribution agent for SalesSub")
	} else {
		add("shared distribution agent", &shared.Agent, false)
	}
	for _, n := range agents {
		a := n.a
		if a.JobEnabled == nil || !*a.JobEnabled {
			t.Errorf("%s: job_enabled = %v, want true", n.what, a.JobEnabled)
		}
		if a.JobLogin == nil || *a.JobLogin != "" {
			t.Errorf("%s: job_login = %v, want empty", n.what, a.JobLogin)
		}
		if a.JobPasswordSecret != nil {
			t.Errorf("%s: job_password_secret = %v, want nil", n.what, *a.JobPasswordSecret)
		}
		if a.RunAs == nil || *a.RunAs != "" {
			t.Errorf("%s: run_as = %v, want empty", n.what, a.RunAs)
		}
		c := a.DistributorConnection
		if n.snapshot && (c == nil || c.Security == nil || *c.Security != "windows") {
			t.Errorf("%s: distributor_connection = %+v, want windows", n.what, c)
		}
		if !n.snapshot && c != nil {
			t.Errorf("%s: distributor_connection = %+v, want nil", n.what, c)
		}
	}
}

func TestReadLabArticles(t *testing.T) {
	cfg := labRead(t).Config
	for _, f := range cfg.Findings {
		if !strings.HasPrefix(f.Path, "publications[") ||
			strings.HasPrefix(f.Path, "publications[SalesPub]") || strings.HasPrefix(f.Path, "publications[SalesRef]") {
			t.Errorf("unexpected finding %s %s: %s", f.Kind, f.Path, f.Message)
		}
	}
	tables := 0
	var all []model.Article
	for _, p := range cfg.Publications {
		if p.Name == "SalesPub" || p.Name == "SalesRef" {
			all = append(all, p.Articles...)
		}
	}
	for _, a := range all {
		if a.Filter == nil && a.Commands == nil {
			continue // a schema article
		}
		tables++
		if a.Destination.Schema == nil || *a.Destination.Schema != "dbo" {
			t.Errorf("%s: destination.schema = %v, want dbo", a.Name, a.Destination.Schema)
		}
		if a.Name == "Customer" {
			if a.SyncObject == nil || a.SyncObject.Schema != "dbo" || a.SyncObject.Name != "SYNC_Customer" {
				t.Errorf("Customer sync_object = %+v, want dbo.SYNC_Customer", a.SyncObject)
			}
		} else if a.SyncObject != nil {
			t.Errorf("%s: sync_object = %+v, want none (generated view)", a.Name, a.SyncObject)
		}
	}
	if tables < 3 {
		t.Errorf("table articles = %d, want at least 3", tables)
	}
}
