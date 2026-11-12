package precheck

import (
	"context"
	"database/sql"
	"fmt"
	"net/url"
	"os"
	"slices"
	"strings"
	"testing"
	"time"

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

// TestLabRestoreHistoryLSN checks R57 against real restores on the lab, on
// m_lsn_ databases it creates and drops, reading only: no LSN is passed to
// any procedure and no subscription is created. A COPY_ONLY backup
// restored with its last_lsn is valid; a full backup and a log backup
// restored WITH STOPAT is not (the log backup's last_lsn is past the point
// the database was recovered to); a database dropped and created again
// after its restore is not (restorehistory keeps its rows). Task 5 review,
// Important 1 and 2.
func TestLabRestoreHistoryLSN(t *testing.T) {
	master := labDB(t, "master")
	ctx := context.Background()
	const dir = "/var/opt/mssql/data/"
	dbs := []string{"m_lsn_pub", "m_lsn_pit", "m_lsn_cp"}
	files := []string{"m_lsn_b1.bak", "m_lsn_l1.trn", "m_lsn_b2.bak"}
	exec := func(q string) {
		t.Helper()
		if _, err := master.ExecContext(ctx, q); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	cleanup := func() error {
		for _, d := range dbs {
			q := "IF DB_ID(N'" + d + "') IS NOT NULL BEGIN ALTER DATABASE " + d + " SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE " + d + "; END;" +
				" EXEC msdb.dbo.sp_delete_database_backuphistory @database_name = N'" + d + "';"
			if _, err := master.ExecContext(ctx, q); err != nil {
				return err
			}
		}
		for _, f := range files {
			if _, err := master.ExecContext(ctx, "IF EXISTS (SELECT 1 FROM sys.dm_os_file_exists(N'"+dir+f+"') WHERE file_exists = 1) EXEC master.sys.xp_delete_files N'"+dir+f+"';"); err != nil {
				return err
			}
		}
		return nil
	}
	if err := cleanup(); err != nil {
		t.Fatalf("cleanup before the test: %v", err)
	}
	t.Cleanup(func() {
		if err := cleanup(); err != nil {
			t.Errorf("cleanup: %v", err)
		}
	})
	move := func(to string) string {
		return "MOVE N'm_lsn_pub' TO N'" + dir + to + ".mdf', MOVE N'm_lsn_pub_log' TO N'" + dir + to + "_log.ldf'"
	}
	lastLSN := func(file string) string {
		t.Helper()
		var n string
		if err := master.QueryRowContext(ctx, `SELECT TOP (1) CONVERT(varchar(30), b.last_lsn) FROM msdb.dbo.backupset AS b
JOIN msdb.dbo.backupmediafamily AS f ON f.media_set_id = b.media_set_id
WHERE f.physical_device_name = @p1 ORDER BY b.backup_set_id DESC`, dir+file).Scan(&n); err != nil {
			t.Fatal(err)
		}
		b, err := lsnFromNumeric(n)
		if err != nil {
			t.Fatal(err)
		}
		return fmt.Sprintf("0x%X", b)
	}

	exec("CREATE DATABASE m_lsn_pub; ALTER DATABASE m_lsn_pub SET RECOVERY FULL;")
	exec("EXEC m_lsn_pub.sys.sp_executesql N'CREATE TABLE dbo.m_t (id int PRIMARY KEY); INSERT dbo.m_t VALUES (1), (2);'")
	exec("BACKUP DATABASE m_lsn_pub TO DISK = N'" + dir + "m_lsn_b1.bak' WITH INIT")
	exec("INSERT m_lsn_pub.dbo.m_t VALUES (3); WAITFOR DELAY '00:00:01';")
	var stop string
	if err := master.QueryRowContext(ctx, "SELECT CONVERT(varchar(23), GETDATE(), 121)").Scan(&stop); err != nil {
		t.Fatal(err)
	}
	exec("WAITFOR DELAY '00:00:01'; INSERT m_lsn_pub.dbo.m_t VALUES (4);")
	exec("BACKUP LOG m_lsn_pub TO DISK = N'" + dir + "m_lsn_l1.trn' WITH INIT")
	exec("RESTORE DATABASE m_lsn_pit FROM DISK = N'" + dir + "m_lsn_b1.bak' WITH " + move("m_lsn_pit") + ", NORECOVERY")
	exec("RESTORE LOG m_lsn_pit FROM DISK = N'" + dir + "m_lsn_l1.trn' WITH STOPAT = N'" + stop + "', RECOVERY")
	var rows int
	if err := master.QueryRowContext(ctx, "SELECT COUNT(*) FROM m_lsn_pit.dbo.m_t").Scan(&rows); err != nil || rows != 3 {
		t.Fatalf("m_lsn_pit holds %d rows (%v), want 3: the STOPAT restore is not what the test needs", rows, err)
	}
	exec("BACKUP DATABASE m_lsn_pub TO DISK = N'" + dir + "m_lsn_b2.bak' WITH COPY_ONLY, INIT")
	exec("RESTORE DATABASE m_lsn_cp FROM DISK = N'" + dir + "m_lsn_b2.bak' WITH " + move("m_lsn_cp") + ", RECOVERY")
	pit, cp := lastLSN("m_lsn_l1.trn"), lastLSN("m_lsn_b2.bak")

	check := func() map[string]state.LSNCheck {
		t.Helper()
		desired := &model.Config{Version: model.FormatVersion, Publisher: model.Publisher{Server: "REPLLAB", Database: "m_lsn_pub"},
			Publications: []model.Publication{{Name: "m_p", Subscriptions: []model.Subscription{
				{Subscriber: "REPLLAB", Database: "m_lsn_pit", Initialization: model.Ptr("lsn"), LSN: model.Ptr(pit)},
				{Subscriber: "REPLLAB", Database: "m_lsn_cp", Initialization: model.Ptr("lsn"), LSN: model.Ptr(cp)},
			}}}}
		out := &state.Checks{}
		if err := readLSNs(ctx, Conns{Subscribers: map[string]*sql.DB{"repllab": master}}, map[string]*sql.DB{"repllab": master}, desired, out); err != nil {
			t.Fatal(err)
		}
		got := map[string]state.LSNCheck{}
		for _, lc := range out.LSNs {
			got[lc.Database] = lc
		}
		return got
	}
	got := check()
	if lc := got["m_lsn_cp"]; !lc.Checked || !lc.Valid {
		t.Errorf("COPY_ONLY restore with its last_lsn %s: %+v, want valid", cp, lc)
	}
	if lc := got["m_lsn_pit"]; !lc.Checked || lc.Valid || lc.Reason != r57PointInTime {
		t.Errorf("STOPAT restore with the log backup's last_lsn %s: %+v, want invalid: %s", pit, lc, r57PointInTime)
	}

	// Dropped and created again after its restore: the history stays.
	time.Sleep(1100 * time.Millisecond)
	exec("DROP DATABASE m_lsn_cp; CREATE DATABASE m_lsn_cp;")
	if lc := check()["m_lsn_cp"]; !lc.Checked || lc.Valid || lc.Reason != r57CreatedAfter {
		t.Errorf("m_lsn_cp created again: %+v, want invalid: %s", lc, r57CreatedAfter)
	}
}
