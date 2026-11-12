package precheck

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"net/url"
	"os"
	"slices"
	"strings"
	"testing"

	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
	"github.com/rudi-bruchez/sqlserver-replication/internal/state"
)

// Task 17 fix round 1: the permission branches, on throwaway objects and
// logins named rv_t17fix_, removed in t.Cleanup.

// labLogin is a copy of the reader's test helper (internal/reader
// lab_test.go): it creates the SQL Server login name with a random
// password and, in each database of dbs, a user of it in db_datareader,
// then runs each grant, {database, batch}, as sa. A login left by an
// earlier run is removed first, and everything again in t.Cleanup. It
// returns a function that opens a database of the lab as the login; the
// handles it opens are closed before the login is dropped.
func labLogin(t *testing.T, name string, dbs []string, grants ...[2]string) func(database string) *sql.DB {
	t.Helper()
	ctx := context.Background()
	master := labDB(t, "master")
	// in runs a batch in database db: USE inside EXEC () ends with it, and
	// leaves the pooled connection in master.
	in := func(db, batch string) error {
		_, err := master.ExecContext(ctx, "EXEC (@p1)", "USE "+quoteName(db)+";\n"+batch)
		return err
	}
	drop := func() error {
		for _, db := range dbs {
			if err := in(db, "IF USER_ID(N'"+name+"') IS NOT NULL DROP USER "+quoteName(name)); err != nil {
				return err
			}
		}
		_, err := master.ExecContext(ctx, `
DECLARE @k nvarchar(max) = N'';
SELECT @k += N'KILL ' + CAST(session_id AS nvarchar(10)) + N';' FROM sys.dm_exec_sessions WHERE login_name = @p1;
EXEC (@k);
IF SUSER_ID(@p1) IS NOT NULL EXEC (N'DROP LOGIN ' + @p2);`, name, quoteName(name))
		return err
	}
	if err := drop(); err != nil {
		t.Fatalf("removing login %s before the test: %v", name, err)
	}
	t.Cleanup(func() {
		if err := drop(); err != nil {
			t.Errorf("removing login %s: %v", name, err)
		}
	})
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		t.Fatal(err)
	}
	password := "Aa1!" + hex.EncodeToString(b)
	if _, err := master.ExecContext(ctx, `
EXEC (N'CREATE LOGIN ' + @p1 + N' WITH PASSWORD = ' + @p2 + N', CHECK_POLICY = OFF')`,
		quoteName(name), "N'"+password+"'"); err != nil {
		t.Fatalf("creating login %s: %v", name, err)
	}
	for _, db := range dbs {
		if err := in(db, "CREATE USER "+quoteName(name)+"; ALTER ROLE db_datareader ADD MEMBER "+quoteName(name)); err != nil {
			t.Fatalf("user %s in %s: %v", name, db, err)
		}
	}
	for _, g := range grants {
		if err := in(g[0], g[1]); err != nil {
			t.Fatalf("%s in %s: %v", g[1], g[0], err)
		}
	}
	return func(database string) *sql.DB {
		t.Helper()
		u, err := url.Parse(os.Getenv("SQLREPL_TEST_DSN"))
		if err != nil {
			t.Fatal("SQLREPL_TEST_DSN is not a URL")
		}
		u.User = url.UserPassword(name, password)
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
}

// fixObjects creates the throwaway schema and tables in Sales, as sa, and
// removes them in t.Cleanup (also those an earlier run left).
func fixObjects(t *testing.T) {
	t.Helper()
	ctx := context.Background()
	sales := labDB(t, "Sales")
	drop := func() error {
		_, err := sales.ExecContext(ctx, `
DROP TABLE IF EXISTS dbo.rv_t17fix_pk, dbo.rv_t17fix_uq, dbo.rv_t17fix_comp, rv_t17fix_s2.rv_t17fix_t;
IF SCHEMA_ID(N'rv_t17fix_s2') IS NOT NULL DROP SCHEMA rv_t17fix_s2;`)
		return err
	}
	if err := drop(); err != nil {
		t.Fatalf("removing objects before the test: %v", err)
	}
	t.Cleanup(func() {
		if err := drop(); err != nil {
			t.Errorf("removing objects: %v", err)
		}
	})
	for _, batch := range []string{
		"CREATE SCHEMA rv_t17fix_s2",
		"CREATE TABLE rv_t17fix_s2.rv_t17fix_t (id int PRIMARY KEY)",
		"CREATE TABLE dbo.rv_t17fix_comp (id int PRIMARY KEY)",
		"CREATE TABLE dbo.rv_t17fix_pk (k1 int NOT NULL, k2 int NOT NULL, v int, PRIMARY KEY (k2, k1))",
		"CREATE TABLE dbo.rv_t17fix_uq (id int NOT NULL UNIQUE, v int)",
	} {
		if _, err := sales.ExecContext(ctx, batch); err != nil {
			t.Fatalf("%s: %v", batch, err)
		}
	}
}

// fixDesired is a desired file of the lab's Sales with one publication
// whose articles are the tables named schema.name.
func fixDesired(tables ...string) *model.Config {
	p := model.Publication{Name: "rv_t17fix_p"}
	for _, n := range tables {
		s, name, _ := strings.Cut(n, ".")
		p.Articles = append(p.Articles, model.Article{Name: name, Source: model.ObjectName{Schema: s, Name: name}})
	}
	return &model.Config{Version: model.FormatVersion, Publisher: model.Publisher{Server: "repllab", Database: "Sales"},
		Publications: []model.Publication{p}}
}

// runAs runs the checks with the publication database read through pub,
// the rest as sa.
func runAs(t *testing.T, pub *sql.DB, des *model.Config) (*state.Checks, error) {
	t.Helper()
	master := labDB(t, "master")
	return Run(context.Background(), Conns{Publisher: master, Publication: pub, Distributor: master}, des, nil)
}

func TestLabPrecheckKeys(t *testing.T) {
	fixObjects(t)
	c, err := runAs(t, labDB(t, "Sales"), fixDesired("dbo.rv_t17fix_pk", "dbo.rv_t17fix_uq"))
	if err != nil {
		t.Fatal(err)
	}
	if len(c.Tables) != 2 {
		t.Fatalf("tables %+v", c.Tables)
	}
	if pk := c.Tables[0]; !pk.Exists || !pk.HasPrimaryKey || !slices.Equal(pk.KeyColumns, []string{"k2", "k1"}) ||
		!slices.Equal(pk.Columns, []string{"k1", "k2", "v"}) {
		t.Errorf("PRIMARY KEY (k2, k1): %+v", pk)
	}
	if uq := c.Tables[1]; !uq.Exists || uq.HasPrimaryKey || len(uq.KeyColumns) != 0 {
		t.Errorf("UNIQUE, no primary key: %+v", uq)
	}
}

func TestLabPrecheckPublicationDatabase(t *testing.T) {
	_, err := runAs(t, labDB(t, "master"), fixDesired("dbo.Customer"))
	if err == nil || !strings.Contains(err.Error(), "the publication connection is in database master, not Sales") {
		t.Errorf("connected to master: %v", err)
	}
	// The name compares without regard to case.
	des := fixDesired("dbo.Customer")
	des.Publisher.Database = "SALES"
	if c, err := runAs(t, labDB(t, "Sales"), des); err != nil || len(c.Tables) != 1 || !c.Tables[0].Exists {
		t.Errorf("SALES: %v %+v", err, c)
	}
}

func TestLabPrecheckFolders(t *testing.T) {
	des := fixDesired("dbo.Customer")
	des.Distributor = &model.Distributor{Server: "repllab", Database: "distribution", WorkingDirectory: model.Ptr("/var/opt/mssql/data/rv_t17fix_missing")}
	des.Publications[0].Snapshot = &model.Snapshot{AltFolder: model.Ptr("/var/opt/mssql/data/rv_t17fix_alt")}
	q := model.Publication{Name: "rv_t17fix_q", Snapshot: &model.Snapshot{AltFolder: model.Ptr("/var/opt/mssql/data/ReplData")}}
	des.Publications = append(des.Publications, q)
	c, err := runAs(t, labDB(t, "Sales"), des)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]state.FolderCheck{}
	for _, f := range c.Folders {
		got[f.Path] = f
	}
	want := map[string]bool{
		"/var/opt/mssql/data/rv_t17fix_missing": false,
		"/var/opt/mssql/data/rv_t17fix_alt":     false,
		"/var/opt/mssql/data/ReplData":          true,
	}
	for p, exists := range want {
		f, ok := got[p]
		if !ok || !f.Checked || f.Exists != exists || f.Server != "repllab" {
			t.Errorf("folder %s: %+v (%t), want checked, exists %t", p, f, ok, exists)
		}
	}
	if len(c.Folders) != len(want) {
		t.Errorf("folders %+v", c.Folders)
	}
}

func TestLabPrecheckRestrictedTables(t *testing.T) {
	fixObjects(t)
	// No permission on any table (not in db_datareader).
	none := labLogin(t, "rv_t17fix_none", []string{"Sales"},
		[2]string{"Sales", "ALTER ROLE db_datareader DROP MEMBER [rv_t17fix_none]"})
	// VIEW DEFINITION on the database, denied on a schema and on a table.
	deny := labLogin(t, "rv_t17fix_deny", []string{"Sales"},
		[2]string{"Sales", "ALTER ROLE db_datareader DROP MEMBER [rv_t17fix_deny];" +
			" GRANT VIEW DEFINITION TO [rv_t17fix_deny];" +
			" DENY VIEW DEFINITION ON SCHEMA::[rv_t17fix_s2] TO [rv_t17fix_deny];" +
			" DENY VIEW DEFINITION ON OBJECT::[dbo].[rv_t17fix_comp] TO [rv_t17fix_deny]"})
	// SELECT granted, VIEW DEFINITION denied: OBJECT_ID is NULL and the
	// probe succeeds (Task 17 fix round 2, A).
	dvd := labLogin(t, "rv_t17fix_dvd", []string{"Sales"},
		[2]string{"Sales", "ALTER ROLE db_datareader DROP MEMBER [rv_t17fix_dvd];" +
			" GRANT SELECT ON OBJECT::[dbo].[rv_t17fix_comp] TO [rv_t17fix_dvd];" +
			" DENY VIEW DEFINITION ON OBJECT::[dbo].[rv_t17fix_comp] TO [rv_t17fix_dvd]"})
	for _, tc := range []struct {
		login string
		open  func(string) *sql.DB
		table string
	}{
		{"dvd", dvd, "dbo.rv_t17fix_comp"},
		{"none", none, "dbo.rv_t17fix_comp"},
		{"deny", deny, "rv_t17fix_s2.rv_t17fix_t"},
		{"deny", deny, "dbo.rv_t17fix_comp"},
	} {
		_, err := runAs(t, tc.open("Sales"), fixDesired(tc.table))
		t.Logf("%s, %s: %v", tc.login, tc.table, err)
		if err == nil || !strings.Contains(err.Error(), "table "+tc.table+": cannot be read") {
			t.Errorf("%s, %s: %v, want cannot be read", tc.login, tc.table, err)
		}
	}
	// A missing table under the same logins: missing, no error.
	for _, tc := range []struct {
		login string
		open  func(string) *sql.DB
		table string
	}{
		{"none", none, "dbo.rv_t17fix_missing"},
		{"deny", deny, "rv_t17fix_s2.rv_t17fix_missing"},
		{"deny", deny, "rv_t17fix_nosuch.rv_t17fix_missing"},
	} {
		c, err := runAs(t, tc.open("Sales"), fixDesired(tc.table))
		if err != nil || len(c.Tables) != 1 || c.Tables[0].Exists {
			t.Errorf("%s, %s: %v %+v, want missing", tc.login, tc.table, err, c)
		}
	}
}

func TestLabPrecheckSubscriberLogin(t *testing.T) {
	// A login with no user in SalesSub, given as REPLLAB's subscriber
	// connection while REPLLAB is also the publisher: its own connection
	// is used, and the database is unchecked, not missing.
	sub := labLogin(t, "rv_t17fix_sub", nil)
	des := fixDesired("dbo.Customer")
	des.Publications[0].Subscriptions = []model.Subscription{{Subscriber: "REPLLAB", Database: "SalesSub", Type: model.Ptr("push")}}
	master := labDB(t, "master")
	c, err := Run(context.Background(), Conns{Publisher: master, Publication: labDB(t, "Sales"), Distributor: master,
		Subscribers: map[string]*sql.DB{"repllab": sub("master")}}, des, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(c.SubscriberDatabases) != 1 || c.SubscriberDatabases[0].Checked || c.SubscriberDatabases[0].Exists {
		t.Errorf("SalesSub as rv_t17fix_sub: %+v, want unchecked", c.SubscriberDatabases)
	}
}
