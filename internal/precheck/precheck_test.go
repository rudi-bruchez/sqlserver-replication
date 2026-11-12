package precheck

import (
	"context"
	"database/sql"
	"net/url"
	"os"
	"slices"
	"strings"
	"testing"

	_ "github.com/microsoft/go-mssqldb"

	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
	"github.com/rudi-bruchez/sqlserver-replication/internal/state"
)

// TestPrecheckQueriesParse checks the syntax of every query against a live
// instance, as the reader's TestQueriesParse does.
func TestPrecheckQueriesParse(t *testing.T) {
	d := os.Getenv("SQLREPL_TEST_DSN")
	if d == "" {
		t.Skip("SQLREPL_TEST_DSN not set")
	}
	db, err := sql.Open("sqlserver", d)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
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
	queries := map[string]string{
		"qServer": qServer, "qTable": qTable, "qDatabase": qDatabase,
		"qFolder": qFolder, "qProfiles": qProfiles, "qDatabaseName": qDatabaseName,
		"qJobPermission": qJobPermission, "qAgent": qAgent, "qLogEnd": qLogEnd, "qRestored": qRestored,
		"qSchema": strings.Replace(qSchema, "{db}", quoteName("master"), 1),
	}
	for name, q := range queries {
		batch := "DECLARE @p1 nvarchar(256);\n" + q
		if _, err := conn.ExecContext(ctx, batch); err != nil {
			t.Errorf("%s: %v", name, err)
		}
	}
}

func TestSubscriberLookupIgnoresCase(t *testing.T) {
	db := new(sql.DB)
	c := Conns{Subscribers: map[string]*sql.DB{"repllab": db}, Unreachable: map[string]string{"subx": "refused"}}
	if got := subscriberConn(c.Subscribers, "REPLLAB"); got != db {
		t.Errorf("REPLLAB: %v", got)
	}
	if got := subscriberConn(c.Subscribers, "OTHER"); got != nil {
		t.Errorf("OTHER: %v", got)
	}
	if e, ok := unreachable(c.Unreachable, "SUBX"); !ok || e != "refused" {
		t.Errorf("SUBX unreachable: %q %t", e, ok)
	}
}

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

func TestLabPrecheck(t *testing.T) {
	master := labDB(t, "master")
	des := loadFixture(t)
	var pub *model.Publication
	for i := range des.Publications {
		if des.Publications[i].Name == "SalesPub" {
			pub = &des.Publications[i]
		}
	}
	if pub == nil {
		t.Fatal("SalesPub not in the fixture")
	}
	// The missing database, and a subscriber that cannot be reached (R29).
	pub.Subscriptions = append(pub.Subscriptions,
		model.Subscription{Subscriber: "REPLLAB", Database: "m_nodb", Type: model.Ptr("push")},
		model.Subscription{Subscriber: "m_subx", Database: "x", Type: model.Ptr("pull")})
	checks, err := Run(context.Background(), Conns{
		Publisher:   master,
		Publication: labDB(t, "Sales"),
		Distributor: master,
		Subscribers: map[string]*sql.DB{"repllab": master}, // the file says REPLLAB
		Unreachable: map[string]string{"M_SUBX": "dial tcp: refused"},
	}, des, nil)
	if err != nil {
		t.Fatal(err)
	}

	// The server.
	var server *state.ServerCheck
	for i := range checks.Servers {
		if strings.EqualFold(checks.Servers[i].Name, "repllab") {
			if server != nil {
				t.Errorf("repllab checked twice: %+v", checks.Servers)
			}
			server = &checks.Servers[i]
		}
	}
	if server == nil || !server.Reachable || server.Major != 16 || !strings.Contains(server.Edition, "Developer") ||
		!strings.HasPrefix(server.Version, "16.") || server.ServerName != "repllab" {
		t.Errorf("repllab: %+v", server)
	}
	var subx *state.ServerCheck
	for i := range checks.Servers {
		if checks.Servers[i].Name == "m_subx" {
			subx = &checks.Servers[i]
		}
	}
	if subx == nil || subx.Reachable || subx.Error != "dial tcp: refused" {
		t.Errorf("m_subx: %+v", subx)
	}

	// Every table article's source, with its key and its columns.
	tables := map[string]*state.TableCheck{}
	for i := range checks.Tables {
		tc := &checks.Tables[i]
		tables[tc.Schema+"."+tc.Name] = tc
	}
	for _, n := range []string{"Customer", "Orders", "Product"} {
		tc := tables["dbo."+n]
		if tc == nil || !tc.Exists || !tc.HasPrimaryKey || len(tc.Columns) < 2 || len(tc.KeyColumns) != 1 {
			t.Errorf("dbo.%s: %+v", n, tc)
		}
	}
	if tc := tables["dbo.Customer"]; tc != nil {
		if !slices.Equal(tc.KeyColumns, []string{"CustomerID"}) || tc.Columns[0] != "CustomerID" ||
			!slices.Contains(tc.Columns, "Name") || !slices.Contains(tc.Columns, "Country") {
			t.Errorf("dbo.Customer columns %q, key %q", tc.Columns, tc.KeyColumns)
		}
	}
	if tc := tables["dbo.vCustomerFR"]; tc == nil || !tc.Exists || tc.HasPrimaryKey || len(tc.KeyColumns) != 0 {
		t.Errorf("dbo.vCustomerFR: %+v", tc)
	}

	// The subscriber databases.
	dbs := map[string]state.DatabaseCheck{}
	for _, d := range checks.SubscriberDatabases {
		dbs[d.Server+"/"+d.Database] = d
	}
	if d, ok := dbs["REPLLAB/SalesSub"]; !ok || !d.Checked || !d.Exists {
		t.Errorf("SalesSub: %+v (%t)", d, ok)
	}
	if d, ok := dbs["REPLLAB/m_nodb"]; !ok || !d.Checked || d.Exists {
		t.Errorf("m_nodb: %+v (%t), want checked and missing", d, ok)
	}
	if d, ok := dbs["m_subx/x"]; !ok || d.Checked {
		t.Errorf("m_subx/x: %+v (%t), want unchecked", d, ok)
	}

	// The working directory.
	var folder *state.FolderCheck
	for i := range checks.Folders {
		if checks.Folders[i].Path == "/var/opt/mssql/data/ReplData" {
			folder = &checks.Folders[i]
		}
	}
	if folder == nil || !folder.Checked || !folder.Exists || folder.Server != "repllab" {
		t.Errorf("working directory: %+v", folder)
	}

	// The profiles at the distributor.
	have := map[string]bool{}
	for _, p := range checks.Profiles {
		have[p.AgentType+"/"+p.Name] = true
	}
	for _, k := range []string{"distribution/lab-distrib", "distribution/Default agent profile",
		"snapshot/Default agent profile", "logreader/Default agent profile"} {
		if !have[k] {
			t.Errorf("profile %s missing from %v", k, checks.Profiles)
		}
	}
}

// TestLabPrecheckApply reads the preconditions apply needs on the lab, as
// sa: the job permission and SQL Server Agent of the lab's server (R55,
// R56), the destination schemas at SalesSub (R59 minor 7), and the LSN of
// a subscription whose database has no restore history (R57), which reads
// unchecked. It passes no LSN to the server.
func TestLabPrecheckApply(t *testing.T) {
	master := labDB(t, "master")
	des := loadFixture(t)
	var pub *model.Publication
	for i := range des.Publications {
		if des.Publications[i].Name == "SalesPub" {
			pub = &des.Publications[i]
		}
	}
	if pub == nil {
		t.Fatal("SalesPub not in the fixture")
	}
	a := model.Article{Name: "m_nos_art", Source: model.ObjectName{Schema: "dbo", Name: "Customer"},
		Destination: model.Destination{Schema: model.Ptr("m_nos"), Name: model.Ptr("Customer")}}
	pub.Articles = append(pub.Articles, a)
	pub.Subscriptions = append(pub.Subscriptions, model.Subscription{Subscriber: "REPLLAB", Database: "m_nolsn",
		Type: model.Ptr("push"), Initialization: model.Ptr("lsn"), LSN: model.Ptr("0x00000025000001080001"),
		Articles: []string{"m_nos_art"}})
	ctx := context.Background()
	checks, err := Run(ctx, Conns{
		Publisher:   master,
		Publication: labDB(t, "Sales"),
		Distributor: master,
		Subscribers: map[string]*sql.DB{"repllab": master},
	}, des, nil)
	if err != nil {
		t.Fatal(err)
	}

	if len(checks.JobPermissions) != 1 || !strings.EqualFold(checks.JobPermissions[0].Server, "repllab") ||
		!checks.JobPermissions[0].Checked || !checks.JobPermissions[0].Sysadmin || !checks.JobPermissions[0].ReadsJobs {
		t.Errorf("job permissions %+v, want repllab once, sa a sysadmin reading the jobs", checks.JobPermissions)
	}
	if len(checks.Agents) != 1 || !checks.Agents[0].Checked || !checks.Agents[0].Running ||
		!strings.HasPrefix(checks.Agents[0].Detail, "SQL Server Agent") {
		t.Errorf("agents %+v, want repllab's running", checks.Agents)
	}

	schemas := map[string]state.SchemaCheck{}
	for _, sc := range checks.Schemas {
		schemas[sc.Server+"/"+sc.Database+"/"+sc.Schema] = sc
	}
	if sc, ok := schemas["REPLLAB/SalesSub/dbo"]; !ok || !sc.Checked || !sc.Exists {
		t.Errorf("dbo in SalesSub: %+v (%t)", sc, ok)
	}
	if sc, ok := schemas["REPLLAB/SalesSub/m_nos"]; !ok || !sc.Checked || sc.Exists {
		t.Errorf("m_nos in SalesSub: %+v (%t), want checked and missing", sc, ok)
	}
	if sc, ok := schemas["REPLLAB/m_nolsn/m_nos"]; !ok || sc.Checked {
		t.Errorf("m_nos in the missing m_nolsn: %+v (%t), want unchecked", sc, ok)
	}

	if len(checks.LSNs) != 1 || checks.LSNs[0].Checked || checks.LSNs[0].Valid ||
		checks.LSNs[0].Reason != "REPLLAB/m_nolsn has no restore history" || checks.LSNs[0].LSN != "0x00000025000001080001" {
		t.Errorf("LSNs %+v, want one unchecked for the missing restore history", checks.LSNs)
	}
	// The log end of Sales reads in the form lsnFromLogEnd parses.
	var e string
	if err := master.QueryRowContext(ctx, qLogEnd, "Sales").Scan(&e); err != nil {
		t.Fatal(err)
	}
	if b, err := lsnFromLogEnd(e); err != nil || b == [10]byte{} {
		t.Errorf("log end %q: %x %v", e, b, err)
	}
	// A missing database reads no row, not the current database's log.
	if err := master.QueryRowContext(ctx, qLogEnd, "m_nodb").Scan(&e); err != sql.ErrNoRows {
		t.Errorf("log end of m_nodb: %q %v, want no row", e, err)
	}
}
