// Package convergence holds the convergence tests of the planner on the
// lab (plan 3, Task 19): plan a desired file, run the plan's T-SQL, plan
// again and expect nothing. The tests run only through lab/gotest.sh.
package convergence

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"
	"unicode"

	mssql "github.com/microsoft/go-mssqldb"

	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
	"github.com/rudi-bruchez/sqlserver-replication/internal/plan"
	"github.com/rudi-bruchez/sqlserver-replication/internal/precheck"
	"github.com/rudi-bruchez/sqlserver-replication/internal/reader"
)

// env is one test's view of the lab: its publication database {db} and
// subscriber database {sub}, the lab instance playing the publisher, the
// distributor and the subscriber.
type env struct {
	name, server, db, sub string
	dsn                   *url.URL
	master                *sql.DB
	dbs                   map[string]*sql.DB // by database name
	// deliveries is what startAndWait and a generate_and_wait operation
	// wait for, set by the test before it calls them.
	deliveries []delivery
}

// delivery is a subscriber table and the row count it must reach.
type delivery struct {
	table string
	want  int
}

const (
	pollEvery   = time.Second
	pollTimeout = 120 * time.Second
)

// newEnv opens the lab instance. The test is skipped unless
// SQLREPL_TEST_LAB is set; once it is set, a missing SQLREPL_TEST_DSN is a
// failure, not a skip.
func newEnv(t *testing.T) *env {
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
	e := &env{dsn: u, dbs: map[string]*sql.DB{}}
	t.Cleanup(func() {
		for _, db := range e.dbs {
			db.Close()
		}
	})
	e.master = e.open(t, "master")
	if err := e.master.QueryRow("SELECT @@SERVERNAME").Scan(&e.server); err != nil {
		t.Fatal(err)
	}
	return e
}

// open returns a pool connected to a database of the lab, one per
// database.
func (e *env) open(t *testing.T, database string) *sql.DB {
	t.Helper()
	if db, ok := e.dbs[database]; ok {
		return db
	}
	u := *e.dsn
	q := u.Query()
	q.Set("database", database)
	u.RawQuery = q.Encode()
	db, err := sql.Open("sqlserver", u.String())
	if err != nil {
		t.Fatal(err)
	}
	e.dbs[database] = db
	return db
}

// labEnv runs setup.sql for the test name, its databases being m_pdb_<name>
// and m_sdb_<name>, after a teardown that removes what an earlier run left;
// the teardown runs again at the end of the test, followed by the residue
// check.
func labEnv(t *testing.T, name string) *env {
	t.Helper()
	e := newEnv(t)
	e.name, e.db, e.sub = name, "m_pdb_"+name, "m_sdb_"+name
	if err := e.teardown(t); err != nil {
		t.Fatalf("teardown before the setup: %v", err)
	}
	t.Cleanup(func() {
		if err := e.teardown(t); err != nil {
			t.Errorf("teardown: %v", err)
		}
	})
	conn, err := e.master.Conn(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if err := e.script(conn, "setup.sql"); err != nil {
		t.Fatalf("setup.sql: %v", err)
	}
	return e
}

// replace substitutes the placeholders of a test file.
func (e *env) replace(s string) string {
	return strings.NewReplacer("{server}", e.server, "{db}", e.db, "{sub}", e.sub,
		"{prof}", "m_prof_"+e.name).Replace(s)
}

// script runs a script of testdata on conn, batch by batch, split on the
// lines that hold only GO, its placeholders replaced.
func (e *env) script(conn *sql.Conn, name string) error {
	b, err := os.ReadFile("testdata/" + name)
	if err != nil {
		return err
	}
	ctx := context.Background()
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
	for _, line := range strings.Split(e.replace(string(b)), "\n") {
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

// teardown runs teardown.sql, then the residue check. A drop can fail
// while an agent still holds the database (18752, carried decision 5): the
// script is idempotent and runs again, up to three times, after a short
// wait. The script's errors are logged; only the residue left after the
// last run is an error.
func (e *env) teardown(t *testing.T) error {
	t.Helper()
	ctx := context.Background()
	var residue []string
	for attempt := 1; attempt <= 3; attempt++ {
		conn, err := e.master.Conn(ctx)
		if err != nil {
			return err
		}
		err = e.script(conn, "teardown.sql")
		conn.Close()
		if err != nil {
			t.Logf("teardown.sql, run %d: %v", attempt, err)
		}
		residue, err = e.residue()
		if err != nil {
			return err
		}
		if len(residue) == 0 {
			return nil
		}
		time.Sleep(2 * time.Second)
	}
	return fmt.Errorf("left on the lab: %s", strings.Join(residue, "; "))
}

// residueQuery lists what a test leaves: its two databases, a publication
// of its database at the distributor, a job named with either database, a
// profile named m_prof_<name>. The names are matched exactly, never by a
// wildcard on m_ (carried decision 9: M_FRESHSUB is not ours).
const residueQuery = `
SELECT N'database ' + name FROM sys.databases WHERE name IN (@db, @sub)
UNION ALL SELECT N'publication ' + publication FROM distribution.dbo.MSpublications WHERE publisher_db = @db
UNION ALL SELECT N'subscription to ' + subscriber_db FROM distribution.dbo.MSsubscriptions WHERE subscriber_db = @sub OR publisher_db = @db
UNION ALL SELECT N'job ' + name FROM msdb.dbo.sysjobs WHERE CHARINDEX(@db, name) > 0 OR CHARINDEX(@sub, name) > 0
UNION ALL SELECT N'profile ' + profile_name FROM msdb.dbo.MSagent_profiles WHERE profile_name = @prof`

func (e *env) residue() ([]string, error) {
	rows, err := e.master.Query(residueQuery, sql.Named("db", e.db), sql.Named("sub", e.sub),
		sql.Named("prof", "m_prof_"+e.name))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var s string
		if err := rows.Scan(&s); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// desired loads a test file, placeholders replaced, and copies the lab's
// current agent_profiles into it (R6, R33): the file is the whole truth,
// and lab-distrib must not be dropped.
func (e *env) desired(t *testing.T, file string) *model.Config {
	t.Helper()
	b, err := os.ReadFile("testdata/" + file)
	if err != nil {
		t.Fatal(err)
	}
	des, err := model.Load(strings.NewReader(e.replace(string(b))))
	if err != nil {
		t.Fatalf("%s: %v", file, err)
	}
	des.AgentProfiles = e.labProfiles(t)
	return des
}

// labProfiles reads the lab's agent profiles, through the read of Sales,
// which only reads.
func (e *env) labProfiles(t *testing.T) []model.AgentProfile {
	t.Helper()
	ctx := context.Background()
	probe, err := reader.Probe(ctx, e.master, "Sales")
	if err != nil {
		t.Fatal(err)
	}
	res, err := reader.Read(ctx, reader.Source{Publisher: e.open(t, "Sales"), Distributor: e.master,
		Database: "Sales", Probe: probe})
	if err != nil {
		t.Fatal(err)
	}
	return res.Config.AgentProfiles
}

// plan reads the database the file names, with the facts, runs the
// prechecks and builds the plan, wired as cmd/sqlrepl's runPlan wires them:
// every server of the file, the pull subscribers and the lab's
// @@SERVERNAME are the one lab instance (carried decision 1).
func (e *env) plan(t *testing.T, des *model.Config, opt plan.Options) *plan.Plan {
	t.Helper()
	ctx := context.Background()
	probe, err := reader.Probe(ctx, e.master, des.Publisher.Database)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := probe.Start(); err != nil {
		t.Fatal(err)
	}
	pub := e.open(t, probe.Name)
	distName := probe.Distributor
	if d := des.Distributor; d != nil && d.Server != "" {
		distName = d.Server
	}
	subs := map[string]*sql.DB{e.server: e.master}
	add := func(name string) {
		for k := range subs {
			if strings.EqualFold(k, name) {
				return
			}
		}
		subs[name] = e.master
	}
	for _, p := range des.Publications {
		for _, s := range p.Subscriptions {
			add(s.Subscriber)
		}
	}
	pulls, err := reader.PullSubscribers(ctx, pub)
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range pulls {
		add(s)
	}
	res, err := reader.Read(ctx, reader.Source{Publisher: pub, Distributor: e.master, Database: probe.Name,
		Probe: probe, Subscribers: subs, Facts: true})
	if err != nil {
		t.Fatal(err)
	}
	checks, err := precheck.Run(ctx, precheck.Conns{Publisher: e.master, Publication: pub, Distributor: e.master,
		Subscribers: subs, DistributorServer: distName}, des)
	if err != nil {
		t.Fatal(err)
	}
	return plan.Build(plan.Inputs{Desired: des, Current: res.Config, Facts: res.Facts, Checks: checks,
		SecretSet: func(name string) bool {
			_, ok := os.LookupEnv(name)
			return ok
		}}, opt)
}

func quoteName(s string) string { return "[" + strings.ReplaceAll(s, "]", "]]") + "]" }

// run executes the plan's statements but the job_start ones (R24:
// startAndWait stands in for them), each on the pinned connection of its
// server after a USE of its database, its secrets bound from the
// environment. A failed statement fails the test with the operation and
// the server's message, after a rollback of the transaction it may leave
// open (carried decision 4).
func (e *env) run(t *testing.T, p *plan.Plan) {
	t.Helper()
	if len(p.Refusals) > 0 {
		t.Fatalf("run of a refused plan:\n%s", p.Summary())
	}
	ctx := context.Background()
	conns := map[string]*sql.Conn{}
	defer func() {
		for _, c := range conns {
			c.Close()
		}
	}()
	for i, st := range p.Statements() {
		op := p.Operations[i]
		if op.Kind == "job_start" {
			continue
		}
		key := strings.ToLower(st.Server)
		conn, ok := conns[key]
		if !ok {
			var err error
			if conn, err = e.master.Conn(ctx); err != nil {
				t.Fatal(err)
			}
			conns[key] = conn
		}
		if _, err := conn.ExecContext(ctx, "USE "+quoteName(st.Database)); err != nil {
			t.Fatalf("operation %d %s %s %s: USE %s: %v", op.Seq, op.Action, op.Kind, op.Path, st.Database, err)
		}
		var args []any
		for _, s := range st.Secrets {
			args = append(args, sql.Named(strings.TrimPrefix(s.Var, "@"), os.Getenv(s.Name)))
		}
		if _, err := conn.ExecContext(ctx, st.Text, args...); err != nil {
			var tc int
			terr := conn.QueryRowContext(ctx, "SELECT @@TRANCOUNT").Scan(&tc)
			if terr == nil && tc > 0 {
				if _, rerr := conn.ExecContext(ctx, "IF @@TRANCOUNT > 0 ROLLBACK"); rerr != nil {
					t.Logf("rollback: %v", rerr)
				}
			}
			t.Fatalf("operation %d %s %s %s at %s (@@TRANCOUNT %d): %v\n%s", op.Seq, op.Action, op.Kind, op.Path,
				st.Server, tc, err, st.Text)
		}
		if op.Kind == "generate_and_wait" {
			e.waitAll(t)
		}
	}
}

// startAndWait starts the snapshot agent of each publication of
// AgentsToStart (sp_startpublication_snapshot, never sp_start_job: carried
// decision 6), then waits for the deliveries the test expects.
func (e *env) startAndWait(t *testing.T, p *plan.Plan) {
	t.Helper()
	started := map[string]bool{}
	for _, a := range p.AgentsToStart {
		if started[a.Publication] || a.Publication == "ALL" {
			continue
		}
		started[a.Publication] = true
		e.startSnapshot(t, p.Database, a.Publication)
	}
	e.waitAll(t)
}

// startSnapshot runs sp_startpublication_snapshot, again every second while
// the job is running or has a pending request: the server then refuses the
// start with 22022, class 16, an error for go-mssqldb (measured by this
// task, against carried decision 6, which read it as informational). The
// run in progress can be the end of an earlier generation, which does not
// see the plan's changes, so the harness waits for it to end and starts its
// own.
func (e *env) startSnapshot(t *testing.T, database, publication string) {
	t.Helper()
	deadline := time.Now().Add(pollTimeout)
	for {
		_, err := e.open(t, database).Exec("EXEC sp_startpublication_snapshot @publication = @p",
			sql.Named("p", publication))
		if err == nil {
			return
		}
		var me mssql.Error
		if !errors.As(err, &me) || me.Number != 22022 || time.Now().After(deadline) {
			t.Fatalf("sp_startpublication_snapshot %s: %v", publication, err)
		}
		time.Sleep(pollEvery)
	}
}

func (e *env) waitAll(t *testing.T) {
	t.Helper()
	for _, d := range e.deliveries {
		e.waitDelivered(t, d.table, d.want)
	}
}

// waitDelivered polls the row count of a table of the subscriber database
// every second, up to 120 s, until it is want. A table not created yet
// counts as not delivered.
func (e *env) waitDelivered(t *testing.T, table string, want int) {
	t.Helper()
	q := fmt.Sprintf("SELECT COUNT(*) FROM %s.dbo.%s", quoteName(e.sub), quoteName(table))
	deadline := time.Now().Add(pollTimeout)
	var n int
	var err error
	for {
		err = e.master.QueryRow(q).Scan(&n)
		if err == nil && n == want {
			return
		}
		if time.Now().After(deadline) {
			break
		}
		time.Sleep(pollEvery)
	}
	t.Fatalf("%s.dbo.%s: %d rows (%v) after %s, want %d\n%s", e.sub, table, n, err, pollTimeout, want, e.history())
}

// history is the last agent messages of the test's database, to tell why a
// delivery did not come.
func (e *env) history() string {
	rows, err := e.master.Query(`
SELECT TOP (10) N'snapshot ' + CONVERT(nvarchar(30), h.time, 126) + N' ' + ISNULL(h.comments, N'')
FROM distribution.dbo.MSsnapshot_history AS h JOIN distribution.dbo.MSsnapshot_agents AS a ON a.id = h.agent_id
WHERE a.publisher_db = @db
UNION ALL
SELECT TOP (10) N'distribution ' + CONVERT(nvarchar(30), h.time, 126) + N' ' + ISNULL(h.comments, N'')
FROM distribution.dbo.MSdistribution_history AS h JOIN distribution.dbo.MSdistribution_agents AS a ON a.id = h.agent_id
WHERE a.publisher_db = @db`, sql.Named("db", e.db))
	if err != nil {
		return "history: " + err.Error()
	}
	defer rows.Close()
	var b strings.Builder
	for rows.Next() {
		var s string
		if rows.Scan(&s) == nil {
			b.WriteString(s + "\n")
		}
	}
	return b.String()
}

// converged fails the test unless a new plan of des is empty: no operation,
// no refusal, no agent to start.
func (e *env) converged(t *testing.T, des *model.Config) {
	t.Helper()
	if p := e.plan(t, des, plan.Options{}); !p.Empty() {
		t.Fatalf("not converged, the plan after the run:\n%s", p.Summary())
	}
}

// count returns the result of a COUNT query on the lab.
func (e *env) count(t *testing.T, q string) int {
	t.Helper()
	var n int
	if err := e.master.QueryRow(e.replace(q)).Scan(&n); err != nil {
		t.Fatalf("%s: %v", q, err)
	}
	return n
}

var errNoOperation = errors.New("no such operation")

// procedure is the last part of a call's procedure name.
func procedure(op plan.Operation) string {
	p := op.Call.Procedure
	if i := strings.LastIndex(p, "."); i >= 0 {
		p = p[i+1:]
	}
	return p
}

// param returns the value of a call's parameter.
func param(op plan.Operation, name string) (string, bool) {
	for _, p := range op.Call.Params {
		if p.Name == name {
			return p.Value, true
		}
	}
	return "", false
}

// find returns the first operation calling proc whose parameters hold
// every name and value of want, a value "" meaning absent.
func find(p *plan.Plan, proc string, want map[string]string) (plan.Operation, error) {
	for _, op := range p.Operations {
		if procedure(op) == proc && matches(op, want) {
			return op, nil
		}
	}
	return plan.Operation{}, fmt.Errorf("%w: %s %v", errNoOperation, proc, want)
}

func matches(op plan.Operation, want map[string]string) bool {
	for k, v := range want {
		got, ok := param(op, k)
		if v == "" && ok || v != "" && got != v {
			return false
		}
	}
	return true
}

// hasCost tells whether an operation is listed with a cost.
func hasCost(op plan.Operation, c plan.Cost) bool {
	for _, x := range op.Costs {
		if x == c {
			return true
		}
	}
	return false
}
