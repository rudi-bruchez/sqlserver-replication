package precheck

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"fmt"
	"io"
	"strings"
	"testing"

	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
	"github.com/rudi-bruchez/sqlserver-replication/internal/state"
)

// fakeDriver is a database/sql driver whose servers answer the precheck
// queries with fixed rows: the DSN is the @@SERVERNAME it answers, "null"
// for a NULL one. It stands in for a second instance, which the lab does
// not have.
type fakeDriver struct{}

func init() { sql.Register("precheckfake", fakeDriver{}) }

func (fakeDriver) Open(name string) (driver.Conn, error) { return fakeConn{name}, nil }

type fakeConn struct{ server string }

func (c fakeConn) Prepare(q string) (driver.Stmt, error) { return fakeStmt{c.server, q}, nil }
func (fakeConn) Close() error                            { return nil }
func (fakeConn) Begin() (driver.Tx, error)               { return nil, fmt.Errorf("no transactions") }

type fakeStmt struct{ server, q string }

func (fakeStmt) Close() error  { return nil }
func (fakeStmt) NumInput() int { return -1 }
func (fakeStmt) Exec([]driver.Value) (driver.Result, error) {
	return nil, fmt.Errorf("no exec")
}

func (s fakeStmt) Query([]driver.Value) (driver.Rows, error) {
	var name driver.Value = s.server
	if s.server == "null" {
		name = nil
	}
	switch strings.TrimSpace(s.q) {
	case strings.TrimSpace(qServer):
		return &fakeRows{rows: [][]driver.Value{{name, "16.0.4305.5", "16", "Developer Edition (64-bit)"}}}, nil
	case strings.TrimSpace(qDatabaseName):
		return &fakeRows{rows: [][]driver.Value{{"Sales"}}}, nil
	case strings.TrimSpace(qDatabase):
		return &fakeRows{rows: [][]driver.Value{{int64(7), int64(1)}}}, nil
	case strings.TrimSpace(qProfiles):
		return &fakeRows{}, nil
	}
	return nil, fmt.Errorf("fake: unexpected query %q", s.q)
}

type fakeRows struct{ rows [][]driver.Value }

func (r *fakeRows) Columns() []string {
	if len(r.rows) == 0 {
		return []string{"a", "b"}
	}
	return make([]string, len(r.rows[0]))
}
func (*fakeRows) Close() error { return nil }
func (r *fakeRows) Next(dest []driver.Value) error {
	if len(r.rows) == 0 {
		return io.EOF
	}
	copy(dest, r.rows[0])
	r.rows = r.rows[1:]
	return nil
}

func fakeDB(t *testing.T, server string) *sql.DB {
	t.Helper()
	db, err := sql.Open("precheckfake", server)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	return db
}

// fakeDesired is repllab/Sales with one subscription at REPLLAB, no article.
func fakeDesired() *model.Config {
	return &model.Config{Version: model.FormatVersion, Publisher: model.Publisher{Server: "repllab", Database: "Sales"},
		Publications: []model.Publication{{Name: "p", Subscriptions: []model.Subscription{
			{Subscriber: "REPLLAB", Database: "SalesSub", Type: model.Ptr("push")}}}}}
}

func TestFakeNullServerName(t *testing.T) {
	db := fakeDB(t, "null")
	c, err := Run(context.Background(), Conns{Publisher: db, Publication: db, Distributor: db}, fakeDesired())
	if err != nil {
		t.Fatal(err)
	}
	if len(c.Servers) != 1 || !c.Servers[0].Reachable || c.Servers[0].ServerName != "" || c.Servers[0].Major != 16 {
		t.Errorf("servers %+v", c.Servers)
	}
}

func TestFakeSubscriberOwnServerName(t *testing.T) {
	pub := fakeDB(t, "repllab")
	run := func(sub *sql.DB) string {
		t.Helper()
		c, err := Run(context.Background(), Conns{Publisher: pub, Publication: pub, Distributor: pub,
			Subscribers: map[string]*sql.DB{"repllab": sub}}, fakeDesired())
		if err != nil {
			t.Fatal(err)
		}
		if len(c.Servers) != 1 || len(c.SubscriberDatabases) != 1 || !c.SubscriberDatabases[0].Exists {
			t.Fatalf("checks %+v", c)
		}
		return c.Servers[0].ServerName
	}
	// The subscriber's own connection answers another server: kept, for
	// Build to refuse.
	if got := run(fakeDB(t, "OTHERSRV")); got != "OTHERSRV" {
		t.Errorf("own connection answering OTHERSRV: ServerName %q", got)
	}
	// A case-only difference, or the same connection: the first answer.
	if got := run(fakeDB(t, "REPLLAB")); got != "repllab" {
		t.Errorf("own connection answering REPLLAB: ServerName %q", got)
	}
	if got := run(pub); got != "repllab" {
		t.Errorf("same connection: ServerName %q", got)
	}
}

func checkOf(c *state.Checks, name string) *state.ServerCheck {
	for i := range c.Servers {
		if strings.EqualFold(c.Servers[i].Name, name) {
			return &c.Servers[i]
		}
	}
	return nil
}

// Every server of Conns gets a ServerCheck, not only the file's: a
// subscriber of a pull subscription removed from the file, reached or not
// (Task 18 fix round 1, item 1a).
func TestRunChecksEveryConnServer(t *testing.T) {
	desired := &model.Config{Publisher: model.Publisher{Server: "PUB", Database: "D"}}
	c, err := Run(context.Background(), Conns{
		Publisher:   fakeDB(t, "PUB"),
		Distributor: fakeDB(t, "PUB"),
		Subscribers: map[string]*sql.DB{"OLDPULL": fakeDB(t, "OTHERSRV")},
		Unreachable: map[string]string{"GONE": "dial tcp: refused"},
	}, desired)
	if err != nil {
		t.Fatal(err)
	}
	if sc := checkOf(c, "OLDPULL"); sc == nil || !sc.Reachable || sc.ServerName != "OTHERSRV" || sc.Major != 16 {
		t.Errorf("OLDPULL: %+v", sc)
	}
	if sc := checkOf(c, "GONE"); sc == nil || sc.Reachable || sc.Error != "dial tcp: refused" {
		t.Errorf("GONE: %+v", sc)
	}
}

// With no distributor section, the distributor the caller resolved is the
// one checked, not the publisher (item 6).
func TestRunDistributorServer(t *testing.T) {
	desired := &model.Config{Publisher: model.Publisher{Server: "PUB", Database: "D"}}
	c, err := Run(context.Background(), Conns{
		Publisher:         fakeDB(t, "PUB"),
		Distributor:       fakeDB(t, "DIST"),
		DistributorServer: "DIST",
	}, desired)
	if err != nil {
		t.Fatal(err)
	}
	if sc := checkOf(c, "DIST"); sc == nil || !sc.Reachable || sc.ServerName != "DIST" {
		t.Errorf("DIST: %+v", sc)
	}
	if sc := checkOf(c, "PUB"); sc == nil || sc.ServerName != "PUB" {
		t.Errorf("PUB: %+v, want it to answer as itself", sc)
	}
}
