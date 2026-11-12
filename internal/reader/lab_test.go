package reader

import (
	"context"
	"database/sql"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"
	"unicode"

	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
	"github.com/rudi-bruchez/sqlserver-replication/internal/state"
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

// labFinding tells whether a finding concerns the lab's own objects:
// SalesPub, SalesRef, or anything outside the publications and the shared
// pull agents, which other sessions' objects in Sales can produce.
func labFinding(path string) bool {
	if strings.HasPrefix(path, "publications[SalesPub]") || strings.HasPrefix(path, "publications[SalesRef]") {
		return true
	}
	return !strings.HasPrefix(path, "publications[") && !strings.HasPrefix(path, "publisher.shared_pull_agents[")
}

// labRead reads the Sales publication of the lab, publisher and
// distributor being the same instance.
func labRead(t *testing.T) *Result {
	t.Helper()
	return labReadWith(t, nil)
}

// labReadWith is labRead with connections to subscribers.
func labReadWith(t *testing.T, subscribers map[string]*sql.DB) *Result {
	t.Helper()
	return labReadSource(t, subscribers, false)
}

// labReadFacts is labRead with the runtime facts.
func labReadFacts(t *testing.T) *Result {
	t.Helper()
	return labReadSource(t, nil, true)
}

func labReadSource(t *testing.T, subscribers map[string]*sql.DB, facts bool) *Result {
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
		Subscribers: subscribers,
		Facts:       facts,
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
		if labFinding(f.Path) {
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
		if labFinding(f.Path) {
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

// TestReadLabProfiles checks that a user-defined profile no agent uses is
// exported (lab/setup.sql creates distribution/lab-distrib; the lab agents
// are bound to another profile). Profiles other sessions created are ignored.
func TestReadLabProfiles(t *testing.T) {
	cfg := labRead(t).Config
	for _, p := range cfg.AgentProfiles {
		if p.AgentType != "distribution" || p.Name != "lab-distrib" {
			continue
		}
		if p.Description == nil || *p.Description != "lab profile" {
			t.Errorf("description = %v, want %q", p.Description, "lab profile")
		}
		if p.Default == nil || *p.Default {
			t.Errorf("default = %v, want false", p.Default)
		}
		if p.Parameters["-CommitBatchSize"] != "200" {
			t.Errorf("-CommitBatchSize = %q, want 200", p.Parameters["-CommitBatchSize"])
		}
		return
	}
	t.Error("profile distribution/lab-distrib missing from agent_profiles")
}

// runScript runs a script of testdata on conn, batch by batch, split on the
// lines that hold only GO.
func runScript(ctx context.Context, conn *sql.Conn, name string) error {
	b, err := os.ReadFile("testdata/" + name)
	if err != nil {
		return err
	}
	var batch strings.Builder
	run := func() error {
		q := strings.TrimSpace(batch.String())
		batch.Reset()
		if q == "" {
			return nil
		}
		_, err := conn.ExecContext(ctx, q)
		return err
	}
	for _, line := range strings.Split(string(b), "\n") {
		if strings.EqualFold(strings.TrimFunc(line, unicode.IsSpace), "GO") {
			if err := run(); err != nil {
				return err
			}
			continue
		}
		batch.WriteString(line)
		batch.WriteByte('\n')
	}
	return run()
}

// pullSetup creates the pull subscription of testdata/pull-setup.sql: the
// publication m_pp of Sales, pulled by m_psub of the lab instance itself. It
// returns the lab's @@SERVERNAME.
func pullSetup(t *testing.T) string {
	t.Helper()
	return labScripts(t, "pull")
}

// labScripts runs testdata/<name>-teardown.sql, then <name>-setup.sql and
// the extra scripts, and registers the teardown again in t.Cleanup on a fresh connection: the
// teardown is idempotent, so a run that an earlier failure left behind is
// removed first, and a partial setup is removed too. It returns the lab's
// @@SERVERNAME.
func labScripts(t *testing.T, name string, extra ...string) string {
	t.Helper()
	ctx := context.Background()
	master := labDB(t, "master")
	teardown := func() error {
		conn, err := master.Conn(ctx)
		if err != nil {
			return err
		}
		defer conn.Close()
		return runScript(ctx, conn, name+"-teardown.sql")
	}
	if err := teardown(); err != nil {
		t.Fatalf("teardown before the setup: %v", err)
	}
	t.Cleanup(func() {
		if err := teardown(); err != nil {
			t.Errorf("teardown: %v", err)
		}
	})
	conn, err := master.Conn(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	for _, script := range append([]string{name + "-setup.sql"}, extra...) {
		if err := runScript(ctx, conn, script); err != nil {
			t.Fatalf("%s: %v", script, err)
		}
	}
	var server string
	if err := conn.QueryRowContext(ctx, "SELECT @@SERVERNAME").Scan(&server); err != nil {
		t.Fatal(err)
	}
	return server
}

// pullSubscription returns m_pp's subscription to m_psub.
func pullSubscription(t *testing.T, cfg *model.Config) *model.Subscription {
	t.Helper()
	for i := range cfg.Publications {
		p := &cfg.Publications[i]
		if p.Name != "m_pp" {
			continue
		}
		for j := range p.Subscriptions {
			if strings.EqualFold(p.Subscriptions[j].Database, "m_psub") {
				return &p.Subscriptions[j]
			}
		}
	}
	t.Fatal("subscription of m_pp to m_psub not exported")
	return nil
}

func findingsUnder(cfg *model.Config, prefix string) []model.Finding {
	var out []model.Finding
	for _, f := range cfg.Findings {
		if strings.HasPrefix(f.Path, prefix) {
			out = append(out, f)
		}
	}
	return out
}

// The subscriber is keyed repllab, in lower case, while
// syssubscriptions.srvname is REPLLAB: the lookup ignores case.
func TestReadLabPullSubscription(t *testing.T) {
	server := pullSetup(t)
	cfg := labReadWith(t, map[string]*sql.DB{"repllab": labDB(t, "master")}).Config
	s := pullSubscription(t, cfg)
	if s.Type == nil || *s.Type != "pull" {
		t.Errorf("type = %v, want pull", s.Type)
	}
	if s.DistributionAgent != nil {
		t.Errorf("distribution_agent = %+v, want nil", s.DistributionAgent)
	}
	for _, f := range findingsUnder(cfg, "publications[m_pp]") {
		t.Errorf("unexpected finding %s %s: %s", f.Kind, f.Path, f.Message)
	}
	a := s.PullAgent
	if a == nil {
		t.Fatal("pull_agent not exported")
	}
	if a.JobEnabled == nil || !*a.JobEnabled {
		t.Errorf("job_enabled = %v, want true", a.JobEnabled)
	}
	if c := a.Connection; c == nil || c.Security == nil || *c.Security != "windows" {
		t.Errorf("connection = %+v, want windows", c)
	}
	if c := a.DistributorConnection; c == nil || c.Security == nil || *c.Security != "windows" {
		t.Errorf("distributor_connection = %+v, want windows", c)
	}
	if a.Distributor == nil || !strings.EqualFold(*a.Distributor, server) {
		t.Errorf("distributor = %v, want %s", a.Distributor, server)
	}
	if a.UseFTP == nil || *a.UseFTP {
		t.Errorf("use_ftp = %v, want false", a.UseFTP)
	}
	if a.Schedules == nil || len(*a.Schedules) != 0 {
		t.Errorf("schedules = %v, want empty and non-nil", a.Schedules)
	}
	if a.JobLogin == nil || *a.JobLogin != "" {
		t.Errorf("job_login = %v, want empty", a.JobLogin)
	}
}

func TestReadLabPullSubscriberNotConnected(t *testing.T) {
	pullSetup(t)
	cfg := labRead(t).Config
	s := pullSubscription(t, cfg)
	if s.PullAgent != nil {
		t.Errorf("pull_agent = %+v, want nil", s.PullAgent)
	}
	want := "publications[m_pp].subscriptions[REPLLAB/m_psub].pull_agent"
	fs := findingsUnder(cfg, "publications[m_pp]")
	if len(fs) != 1 || fs[0].Kind != model.FindingUnreadable || fs[0].Path != want {
		t.Errorf("findings = %+v, want one unreadable at %s", fs, want)
	}
}

// A type 2 row at the subscriber is an anonymous subscription: reported out
// of scope, and not taken for a missing pull row. The update is on the
// test's own database, set back before the teardown; no transaction, since
// the reader reads on other connections.
func TestReadLabAnonymousSubscriberRow(t *testing.T) {
	pullSetup(t)
	ctx := context.Background()
	master := labDB(t, "master")
	if _, err := master.ExecContext(ctx, "UPDATE m_psub.dbo.MSreplication_subscriptions SET subscription_type = 2"); err != nil {
		t.Fatalf("update: %v", err)
	}
	t.Cleanup(func() {
		if _, err := master.ExecContext(ctx, "UPDATE m_psub.dbo.MSreplication_subscriptions SET subscription_type = 1"); err != nil {
			t.Errorf("setting subscription_type back: %v", err)
		}
	})
	cfg := labReadWith(t, map[string]*sql.DB{"repllab": labDB(t, "master")}).Config
	pullSubscription(t, cfg)
	var outOfScope, incomplete int
	for _, f := range findingsUnder(cfg, "publications[m_pp].subscriptions[") {
		switch f.Kind {
		case model.FindingOutOfScope:
			outOfScope++
		case model.FindingIncomplete:
			incomplete++
		}
	}
	if outOfScope != 1 || incomplete != 0 {
		t.Errorf("out_of_scope %d, incomplete %d; want 1 and 0: %+v", outOfScope, incomplete, cfg.Findings)
	}
}

// Two publications without an independent agent pulled into one database
// share one pull agent: it is exported once, under
// publisher.shared_pull_agents, and neither subscription has a pull_agent.
func TestReadLabSharedPullAgent(t *testing.T) {
	server := labScripts(t, "pull-shared", "pull-shared-agent1.sql")
	cfg := labReadWith(t, map[string]*sql.DB{"repllab": labDB(t, "master")}).Config
	subs := 0
	for _, p := range cfg.Publications {
		if p.Name != "m_ps1" && p.Name != "m_ps2" {
			continue
		}
		for _, s := range p.Subscriptions {
			if !strings.EqualFold(s.Database, "m_pssub") {
				continue
			}
			subs++
			if s.Type == nil || *s.Type != "pull" {
				t.Errorf("%s: type = %v, want pull", p.Name, s.Type)
			}
			if s.PullAgent != nil || s.DistributionAgent != nil {
				t.Errorf("%s: pull_agent %+v, distribution_agent %+v; want both nil", p.Name, s.PullAgent, s.DistributionAgent)
			}
		}
		for _, f := range findingsUnder(cfg, publicationPath(p.Name)) {
			t.Errorf("unexpected finding %s %s: %s", f.Kind, f.Path, f.Message)
		}
	}
	if subs != 2 {
		t.Errorf("%d subscriptions to m_pssub, want 2", subs)
	}
	var shared []model.SharedPullAgent
	for _, a := range cfg.Publisher.SharedPullAgents {
		if strings.EqualFold(a.Database, "m_pssub") {
			shared = append(shared, a)
		}
	}
	if len(shared) != 1 {
		t.Fatalf("shared_pull_agents for m_pssub = %d, want 1", len(shared))
	}
	a := shared[0]
	for _, f := range findingsUnder(cfg, sharedPullPath) {
		t.Errorf("unexpected finding %s %s: %s", f.Kind, f.Path, f.Message)
	}
	if a.JobEnabled == nil || !*a.JobEnabled {
		t.Errorf("job_enabled = %v, want true", a.JobEnabled)
	}
	if a.Distributor == nil || !strings.EqualFold(*a.Distributor, server) {
		t.Errorf("distributor = %v, want %s", a.Distributor, server)
	}
	if c := a.DistributorConnection; c == nil || c.Security == nil || *c.Security != "windows" {
		t.Errorf("distributor_connection = %+v, want windows", c)
	}
	if a.Profile == nil {
		t.Error("profile = nil, want the profile of the N'ALL' row")
	}
}

// sharedPullPath is the path of the test's shared pull agent; other sessions'
// shared pull agents have other paths.
const sharedPullPath = "publisher.shared_pull_agents[REPLLAB/m_pssub]"

// The measured state where only m_ps2 has called
// sp_addpullsubscription_agent: m_ps1's row has no agent_id. The shared agent
// is exported from m_ps2's row, and m_ps1's subscription has one incomplete
// finding.
func TestReadLabSharedPullAgentMissingRow(t *testing.T) {
	labScripts(t, "pull-shared")
	cfg := labReadWith(t, map[string]*sql.DB{"repllab": labDB(t, "master")}).Config
	var shared *model.SharedPullAgent
	for i := range cfg.Publisher.SharedPullAgents {
		if a := &cfg.Publisher.SharedPullAgents[i]; strings.EqualFold(a.Database, "m_pssub") {
			shared = a
		}
	}
	if shared == nil {
		t.Fatal("no shared pull agent for m_pssub")
	}
	if shared.JobName == nil || !strings.Contains(*shared.JobName, "-m_pssub-") {
		t.Errorf("job_name = %v, want the job of m_pssub", shared.JobName)
	}
	if shared.Command == nil || shared.DistributorConnection == nil {
		t.Errorf("command %v, distributor_connection %v: the job and its properties are not exported", shared.Command, shared.DistributorConnection)
	}
	for _, f := range findingsUnder(cfg, sharedPullPath) {
		t.Errorf("unexpected finding %s %s: %s", f.Kind, f.Path, f.Message)
	}
	want := "publications[m_ps1].subscriptions[REPLLAB/m_pssub]"
	fs := findingsUnder(cfg, "publications[m_ps1]")
	if len(fs) != 1 || fs[0].Kind != model.FindingIncomplete || fs[0].Path != want {
		t.Errorf("m_ps1 findings = %+v, want one incomplete at %s", fs, want)
	}
	for _, f := range findingsUnder(cfg, "publications[m_ps2]") {
		t.Errorf("unexpected finding %s %s: %s", f.Kind, f.Path, f.Message)
	}
}

// TestReadLabFacts checks the facts of the lab's publications in the state
// lab/start.sh waits for: every subscription row delivered (status 2 at both
// ends) and the agents running.
func TestReadLabFacts(t *testing.T) {
	res := labReadFacts(t)
	f := res.Facts
	if f == nil {
		t.Fatal("no facts")
	}
	timeFormat := regexp.MustCompile(`^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}$`)
	if !timeFormat.MatchString(f.ReadAt) {
		t.Errorf("read_at = %q, want 2006-01-02 15:04:05.000", f.ReadAt)
	}

	// Articles per publication, schema-only ones included: SalesRef's
	// vCustomerFR is only in sysschemaarticles and has its subscription row.
	articles := map[string]int{}
	rows, err := labDB(t, "Sales").Query(`
SELECT p.name, COUNT(*) FROM dbo.sysextendedarticlesview AS a
JOIN dbo.syspublications AS p ON p.pubid = a.pubid
WHERE p.name IN (N'SalesPub', N'SalesRef') GROUP BY p.name`)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var name string
		var n int
		if err := rows.Scan(&name, &n); err != nil {
			t.Fatal(err)
		}
		articles[name] = n
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	if articles["SalesPub"] == 0 || articles["SalesRef"] == 0 {
		t.Fatalf("article counts %v", articles)
	}

	pubs := map[string]state.PublicationFacts{}
	for _, p := range f.Publications {
		pubs[p.Name] = p
	}
	if p := pubs["SalesPub"]; !p.ImmediateSyncReady || p.LastGeneration == "" {
		t.Errorf("SalesPub: immediate_sync_ready %t, last_generation %q, want true and a time", p.ImmediateSyncReady, p.LastGeneration)
	}
	if p, ok := pubs["SalesRef"]; !ok || p.ImmediateSyncReady {
		t.Errorf("SalesRef: found %t, immediate_sync_ready %t, want found and false", ok, p.ImmediateSyncReady)
	}
	customer := false
	for _, a := range pubs["SalesPub"].Articles {
		if a.Name == "Customer" {
			customer = a.Active
		}
	}
	if !customer {
		t.Error("SalesPub article Customer is not active")
	}
	// A schema article has the bit too: active is read from it, not assumed.
	var schemaActive int
	if err := labDB(t, "Sales").QueryRow(`
SELECT a.status & 1 FROM dbo.sysschemaarticles AS a
JOIN dbo.syspublications AS p ON p.pubid = a.pubid
WHERE p.name = N'SalesRef' AND a.name = N'vCustomerFR'`).Scan(&schemaActive); err != nil {
		t.Fatal(err)
	}
	found := false
	for _, a := range pubs["SalesRef"].Articles {
		if a.Name == "vCustomerFR" {
			found = true
			if a.Active != (schemaActive != 0) {
				t.Errorf("vCustomerFR active = %t, sysschemaarticles.status & 1 = %d", a.Active, schemaActive)
			}
		}
	}
	if !found {
		t.Error("SalesRef article vCustomerFR not listed")
	}
	if p := pubs["SalesPub"]; !timeFormat.MatchString(p.LastGeneration) {
		t.Errorf("SalesPub last_generation = %q, want 2006-01-02 15:04:05.000", p.LastGeneration)
	}

	seen := 0
	for _, s := range f.Subscriptions {
		if (s.Publication != "SalesPub" && s.Publication != "SalesRef") || s.Database != "SalesSub" {
			continue
		}
		seen++
		if len(s.Rows) != articles[s.Publication] {
			t.Errorf("%s %s.%s: %d rows, want %d", s.Publication, s.Subscriber, s.Database, len(s.Rows), articles[s.Publication])
		}
		for _, r := range s.Rows {
			if r.PublisherStatus != 2 || r.DistributorStatus == nil || *r.DistributorStatus != 2 {
				ds := "null"
				if r.DistributorStatus != nil {
					ds = strconv.Itoa(*r.DistributorStatus)
				}
				t.Errorf("%s %s: publisher_status %d, distributor_status %s, want 2 and 2", s.Publication, r.Article, r.PublisherStatus, ds)
			}
		}
	}
	if seen != 2 {
		t.Errorf("%d subscriptions to SalesSub, want 2", seen)
	}

	running := func(what string, a state.AgentFacts) {
		if a.Job == nil || !a.Job.Exists || !a.Job.Enabled || !a.Job.Running {
			t.Errorf("%s: job %+v, want exists, enabled and running", what, a.Job)
		}
		if h := a.LastHistory; h == nil || !timeFormat.MatchString(h.Time) {
			t.Errorf("%s: last_history %+v, want a row with a 2006-01-02 15:04:05.000 time", what, h)
		}
	}
	var logReader, salesPub, shared int
	for _, a := range f.Agents {
		switch {
		case a.Kind == "log_reader":
			logReader++
			running("log reader", a)
		case a.Kind == "distribution" && a.Publication == "SalesPub" && a.Database == "SalesSub":
			salesPub++
			running("SalesPub distribution agent", a)
		case a.Kind == "distribution" && a.Publication == "ALL" && a.Database == "SalesSub":
			shared++
			running("shared distribution agent", a)
		}
	}
	if logReader != 1 || salesPub != 1 || shared != 1 {
		t.Errorf("agents: %d log reader, %d SalesPub, %d shared distribution, want 1 each", logReader, salesPub, shared)
	}
	// lab-distrib is bound to no agent (Task 9). Only the uses of Sales are
	// the lab's own.
	for _, u := range f.ProfileUses {
		if u.PublisherDB == "Sales" {
			t.Errorf("profile use %+v, want none for Sales", u)
		}
	}
}

// TestReadLabNoFacts checks that a read without Source.Facts returns no facts.
func TestReadLabNoFacts(t *testing.T) {
	if res := labRead(t); res.Facts != nil {
		t.Errorf("Facts = %+v, want nil without Source.Facts", res.Facts)
	}
}

// TestReadLabLastGeneration runs the snapshot agent of its own publication
// twice: the first run generates a snapshot for the new subscription, the
// second finds nothing to initialize and ends with runstatus 2 too.
// last_generation must be the end of the first.
func TestReadLabLastGeneration(t *testing.T) {
	ctx := context.Background()
	labScripts(t, "gen")
	sales := labDB(t, "Sales")
	var agentID int
	var jobID string
	if err := labDB(t, "master").QueryRowContext(ctx, `
SELECT a.id, CONVERT(nvarchar(36), CONVERT(uniqueidentifier, a.job_id))
FROM distribution.dbo.MSsnapshot_agents AS a
WHERE a.publisher_db = N'Sales' AND a.publication = N'm_gen'`).Scan(&agentID, &jobID); err != nil {
		t.Fatal(err)
	}
	// run starts the snapshot agent and waits for its job to stop with n
	// final rows (runstatus 2 or 6) in the history.
	run := func(n int) {
		t.Helper()
		if _, err := sales.ExecContext(ctx, "EXEC sp_startpublication_snapshot @publication = N'm_gen'"); err != nil {
			t.Fatal(err)
		}
		deadline := time.Now().Add(90 * time.Second)
		for {
			var finals, running int
			if err := sales.QueryRowContext(ctx, `
SELECT (SELECT COUNT(*) FROM distribution.dbo.MSsnapshot_history WHERE agent_id = @p1 AND runstatus IN (2, 6)),
       (SELECT COUNT(*) FROM msdb.dbo.sysjobactivity AS ja
        WHERE ja.job_id = CONVERT(uniqueidentifier, @p2)
          AND ja.session_id = (SELECT TOP (1) session_id FROM msdb.dbo.syssessions ORDER BY agent_start_date DESC)
          AND ja.start_execution_date IS NOT NULL AND ja.stop_execution_date IS NULL)`,
				agentID, jobID).Scan(&finals, &running); err != nil {
				t.Fatal(err)
			}
			if finals >= n && running == 0 {
				return
			}
			if time.Now().After(deadline) {
				t.Fatalf("snapshot run %d: %d final rows, job running %d after 90 s", n, finals, running)
			}
			time.Sleep(time.Second)
		}
	}
	run(1)
	run(2)

	// The setup is what the test claims: two final rows, the second a no-op.
	rows, err := sales.QueryContext(ctx, `
SELECT `+timeOpen+`time`+timeClose+`, comments FROM distribution.dbo.MSsnapshot_history
WHERE agent_id = @p1 AND runstatus = 2 ORDER BY time, timestamp`, agentID)
	if err != nil {
		t.Fatal(err)
	}
	var times, comments []string
	for rows.Next() {
		var tm, c string
		if err := rows.Scan(&tm, &c); err != nil {
			t.Fatal(err)
		}
		times, comments = append(times, tm), append(comments, c)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	if len(times) != 2 || strings.Contains(comments[0], "not generated") || !strings.Contains(comments[1], "not generated") {
		t.Fatalf("final rows %v %q, want a generation then a run that generated nothing", times, comments)
	}

	var got string
	for _, p := range labReadFacts(t).Facts.Publications {
		if p.Name == "m_gen" {
			got = p.LastGeneration
		}
	}
	if got != times[0] {
		t.Errorf("last_generation = %q, want %q, the generation (the no-op run ended at %s)", got, times[0], times[1])
	}
}

// uncoveredNils returns the paths of NilProperties(cfg) that concern the
// objects own accepts and that no finding names or contains.
func uncoveredNils(cfg *model.Config, own func(string) bool) []string {
	var out []string
	for _, p := range model.NilProperties(cfg) {
		if !own(p) {
			continue
		}
		covered := false
		for _, f := range cfg.Findings {
			if p == f.Path || strings.HasPrefix(p, f.Path+".") || strings.HasPrefix(p, f.Path+"[") {
				covered = true
				break
			}
		}
		if !covered {
			out = append(out, p)
		}
	}
	return out
}

// The export writes every property of the lab's own objects: a nil property
// that no finding covers is one the reader does not read. The second read
// adds the pull subscription of testdata/pull-setup.sql, read at its
// subscriber.
func TestReadLabExportsEveryProperty(t *testing.T) {
	// Profiles of other sessions are on the same distributor: only the
	// lab's own profile is judged.
	labOwn := func(p string) bool {
		if strings.HasPrefix(p, "agent_profiles[") {
			return strings.HasPrefix(p, "agent_profiles[distribution/lab-distrib]")
		}
		return labFinding(p)
	}
	if got := uncoveredNils(labRead(t).Config, labOwn); len(got) != 0 {
		t.Errorf("Sales: properties not exported: %q", got)
	}

	pullSetup(t)
	cfg := labReadWith(t, map[string]*sql.DB{"repllab": labDB(t, "master")}).Config
	pullSubscription(t, cfg)
	withPull := func(p string) bool {
		return labOwn(p) || strings.HasPrefix(p, "publications[m_pp]")
	}
	if got := uncoveredNils(cfg, withPull); len(got) != 0 {
		t.Errorf("Sales with the pull subscription: properties not exported: %q", got)
	}
}
