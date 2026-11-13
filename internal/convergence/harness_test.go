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

	"github.com/rudi-bruchez/sqlserver-replication/internal/apply"
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
	// hook, when set, is called by e.apply before apply sends each
	// statement (Options.BeforeStatement), with the operation; it fails the
	// test itself (t.Errorf) and never stops the run.
	hook func(op plan.Operation)
	// stop, when set, is called after hook; its error stops the run before
	// that statement, as Options.BeforeStatement's does.
	stop func(op plan.Operation) error
	// vars are placeholders of the test's own, replaced in its files after
	// those of every test.
	vars map[string]string
	// applied is the plan apply built under its locks, and applyT the
	// server's GETDATE() when it was read: what a hook compares with.
	applied *plan.Plan
	applyT  time.Time
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
	db, err := e.pool(database)
	if err != nil {
		t.Fatal(err)
	}
	return db
}

// pool is open without a test, for the plan function apply calls.
func (e *env) pool(database string) (*sql.DB, error) {
	if db, ok := e.dbs[database]; ok {
		return db, nil
	}
	u := *e.dsn
	q := u.Query()
	q.Set("database", database)
	u.RawQuery = q.Encode()
	db, err := sql.Open("sqlserver", u.String())
	if err != nil {
		return nil, err
	}
	e.dbs[database] = db
	return db, nil
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
	s = strings.NewReplacer("{server}", e.server, "{db}", e.db, "{sub}", e.sub,
		"{prof}", "m_prof_"+e.name, "{login}", e.login(), "{bak}", e.backupFile()).Replace(s)
	for k, v := range e.vars {
		s = strings.ReplaceAll(s, k, v)
	}
	return s
}

// login is the SQL login a test may create, m_login_<name> (Task 12):
// teardown.sql drops it.
func (e *env) login() string { return "m_login_" + e.name }

// backupFile is the backup a test may write of {db} (Task 12):
// teardown.sql deletes it and the backup and restore history of {db} and
// {sub}.
func (e *env) backupFile() string { return "/var/opt/mssql/data/" + e.db + ".bak" }

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
// wildcard on m_ (carried decision 9: M_FRESHSUB is not ours). A job name
// holds the database as a token between hyphens, as replication names its
// jobs (REPLLAB-m_pdb_create-49, REPLLAB-m_pdb_create-m_p-2356,
// repllab-m_pdb_create-m_p-repllab-2321, read on the lab), so the match
// is on "-<db>-": a bare substring would also take the jobs of a test whose
// name extends this one's (create and createx). Task 12 adds the login
// m_login_<name>, the backup file of {db} and the backup and restore
// history of the two databases.
const residueQuery = `
SELECT N'database ' + name FROM sys.databases WHERE name IN (@db, @sub)
UNION ALL SELECT N'publication ' + publication FROM distribution.dbo.MSpublications WHERE publisher_db = @db
UNION ALL SELECT N'subscription to ' + subscriber_db FROM distribution.dbo.MSsubscriptions WHERE subscriber_db = @sub OR publisher_db = @db
UNION ALL SELECT N'job ' + name FROM msdb.dbo.sysjobs WHERE CHARINDEX(N'-' + @db + N'-', name) > 0 OR CHARINDEX(N'-' + @sub + N'-', name) > 0
UNION ALL SELECT N'profile ' + profile_name FROM msdb.dbo.MSagent_profiles WHERE profile_name = @prof
UNION ALL SELECT N'login ' + name FROM sys.server_principals WHERE name = @login
UNION ALL SELECT N'backup history of ' + database_name FROM msdb.dbo.backupset WHERE database_name IN (@db, @sub)
UNION ALL SELECT N'restore history of ' + destination_database_name FROM msdb.dbo.restorehistory WHERE destination_database_name IN (@db, @sub)
UNION ALL SELECT N'backup file ' + @bak FROM sys.dm_os_file_exists(@bak) WHERE file_exists = 1`

func (e *env) residue() ([]string, error) {
	rows, err := e.master.Query(residueQuery, sql.Named("db", e.db), sql.Named("sub", e.sub),
		sql.Named("prof", "m_prof_"+e.name), sql.Named("login", e.login()), sql.Named("bak", e.backupFile()))
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
	des := e.load(t, file)
	des.AgentProfiles = e.labProfiles(t)
	return des
}

// load loads a test file as written, placeholders replaced.
func (e *env) load(t *testing.T, file string) *model.Config {
	t.Helper()
	b, err := os.ReadFile("testdata/" + file)
	if err != nil {
		t.Fatal(err)
	}
	des, err := model.Load(strings.NewReader(e.replace(string(b))))
	if err != nil {
		t.Fatalf("%s: %v", file, err)
	}
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
// prechecks and builds the plan (inputs).
func (e *env) plan(t *testing.T, des *model.Config, opt plan.Options) *plan.Plan {
	t.Helper()
	return plan.Build(e.inputs(t, des), opt)
}

// inputs reads the database the file names, with the facts, and runs the
// prechecks, wired as cmd/sqlrepl's runPlan wires them: every server of
// the file, the pull subscribers and the lab's @@SERVERNAME are the one lab
// instance (carried decision 1). Its Current is the export of the database.
func (e *env) inputs(t *testing.T, des *model.Config) plan.Inputs {
	t.Helper()
	in, err := e.read(context.Background(), des)
	if err != nil {
		t.Fatal(err)
	}
	return in
}

// read is inputs without a test: apply calls it under its locks (e.target),
// where a t.Fatal would skip the restores and the unlock.
func (e *env) read(ctx context.Context, des *model.Config) (plan.Inputs, error) {
	probe, err := reader.Probe(ctx, e.master, des.Publisher.Database)
	if err != nil {
		return plan.Inputs{}, err
	}
	if _, _, err := probe.Start(); err != nil {
		return plan.Inputs{}, err
	}
	pub, err := e.pool(probe.Name)
	if err != nil {
		return plan.Inputs{}, err
	}
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
		return plan.Inputs{}, err
	}
	for _, s := range pulls {
		add(s)
	}
	res, err := reader.Read(ctx, reader.Source{Publisher: pub, Distributor: e.master, Database: probe.Name,
		Probe: probe, Subscribers: subs, Facts: true})
	if err != nil {
		return plan.Inputs{}, err
	}
	checks, err := precheck.Run(ctx, precheck.Conns{Publisher: e.master, Publication: pub, Distributor: e.master,
		Subscribers: subs, DistributorServer: distName}, des, res.Config)
	if err != nil {
		return plan.Inputs{}, err
	}
	return plan.Inputs{Desired: des, Current: res.Config, Facts: res.Facts, Checks: checks,
		SecretSet: func(name string) bool {
			_, ok := secretEnv(name)
			return ok
		}}, nil
}

// secretEnv is Options.Secret and Inputs.SecretSet: R54, an empty variable
// is not set.
func secretEnv(name string) (string, bool) {
	v, ok := os.LookupEnv(name)
	return v, ok && v != ""
}

// target is what e.apply hands apply.Run (R60): the lab instance under
// every server name of the file, the plan read and built under the locks
// as plan.Build(e.inputs), and the distributor lock taken by R45's rule,
// as cmd/sqlrepl takes it, when the file declares distributor or
// agent_profiles.
func (e *env) target(des *model.Config, opt plan.Options) apply.Target {
	servers := apply.Servers{e.server: e.master, des.Publisher.Server: e.master}
	if d := des.Distributor; d != nil && d.Server != "" {
		servers[d.Server] = e.master
	}
	for _, p := range des.Publications {
		for _, s := range p.Subscriptions {
			servers[s.Subscriber] = e.master
		}
	}
	t := apply.Target{Server: des.Publisher.Server, Database: des.Publisher.Database, Servers: servers,
		Distributor: e.server}
	var distErr error
	if des.Distributor != nil || des.AgentProfiles != nil {
		if d := des.Distributor; d != nil && d.Database != "" {
			t.DistributionDB = d.Database
		} else {
			t.DistributionDB, distErr = reader.DistributionDB(context.Background(), e.master, des.Publisher.Server)
		}
	}
	t.Plan = func(ctx context.Context) (*plan.Plan, error) {
		if distErr != nil {
			return nil, fmt.Errorf("distribution database: %w", distErr)
		}
		if err := e.master.QueryRowContext(ctx, "SELECT GETDATE()").Scan(&e.applyT); err != nil {
			return nil, err
		}
		in, err := e.read(ctx, des)
		if err != nil {
			return nil, err
		}
		e.applied = plan.Build(in, opt)
		return e.applied, nil
	}
	return t
}

// applyWait is R60's -wait.
const applyWait = 5 * time.Minute

// applyRun runs des through apply.Run (R60): auto-approved, -wait 5
// minutes, unless edit changes the options, every line it prints to t.Log
// and returned. It never fails the test, and may run in a goroutine.
func (e *env) applyRun(t *testing.T, des *model.Config, opt plan.Options, edit func(*apply.Options)) (*apply.Result, []string, error) {
	out := &lineLog{t: t}
	o := apply.Options{Wait: applyWait, AutoApprove: true, Secret: secretEnv, Out: out}
	if e.hook != nil || e.stop != nil {
		o.BeforeStatement = func(seq int) error {
			for _, op := range e.applied.Operations {
				if op.Seq != seq {
					continue
				}
				if e.hook != nil {
					e.hook(op)
				}
				if e.stop != nil {
					return e.stop(op)
				}
			}
			return nil
		}
	}
	if edit != nil {
		edit(&o)
	}
	res, err := apply.Run(context.Background(), e.target(des, opt), o)
	out.flush()
	return res, out.lines, err
}

// apply is applyRun with the default options. It fails the test unless
// the run ends with want and, for applied, with every delivery owed
// confirmed.
func (e *env) apply(t *testing.T, des *model.Config, opt plan.Options, want apply.Outcome) *apply.Result {
	t.Helper()
	res, _, err := e.applyRun(t, des, opt, nil)
	e.wantRun(t, res, err, want)
	return res
}

// wantRun is the check of e.apply on a run of applyRun.
func (e *env) wantRun(t *testing.T, res *apply.Result, err error, want apply.Outcome) {
	t.Helper()
	if err != nil {
		t.Fatalf("apply: %v", err)
	}
	if res.Outcome != want {
		t.Fatalf("apply ended %s, want %s (exit %d, failure %+v)", res.Outcome, want, res.ExitCode(), res.Failure)
	}
	if want == apply.OutcomeApplied {
		for _, d := range res.Deliveries {
			if d.Status != "confirmed" {
				t.Fatalf("delivery %s to %s: %s (%s)", d.Publication, d.Subscription, d.Status, d.Detail)
			}
			// A confirmation always names the run that delivered (R50).
			if d.Run == "" {
				t.Fatalf("delivery %s to %s confirmed without a run", d.Publication, d.Subscription)
			}
		}
		if len(res.JobsLeftDisabled) > 0 || res.LockLost || len(res.LockReleaseFailures) > 0 {
			t.Fatalf("applied with jobs left disabled %q, lock lost %v, lock release failures %q",
				res.JobsLeftDisabled, res.LockLost, res.LockReleaseFailures)
		}
	}
}

// wantDelivered checks that res holds exactly one confirmed delivery per
// publication of pubs to {server}/{sub}, and no other delivery.
func (e *env) wantDelivered(t *testing.T, res *apply.Result, pubs ...string) {
	t.Helper()
	sub := e.server + "/" + e.sub
	ok := len(res.Deliveries) == len(pubs)
	for i := 0; ok && i < len(pubs); i++ {
		d := res.Deliveries[i]
		ok = d.Publication == pubs[i] && strings.EqualFold(d.Subscription, sub) && d.Status == "confirmed"
	}
	if !ok {
		t.Fatalf("deliveries %+v, want one confirmed per publication of %q to %s", res.Deliveries, pubs, sub)
	}
}

// checkTimeout bounds the data checks after apply, which has already
// confirmed the delivery (R60). Short on purpose: a longer wait lets the
// agent deliver after apply returned, which hides a confirmation apply did
// not earn (Task 11 review, Important 1). 0 is one read: measured once on
// the lab (fix round 2), the rows of all 16 apply scenarios were there at
// the first read after apply confirmed their delivery.
const checkTimeout = 0

// checkDelivered checks the row counts the test expects (e.deliveries),
// waiting at most checkTimeout.
func (e *env) checkDelivered(t *testing.T) {
	t.Helper()
	for _, d := range e.deliveries {
		e.waitRows(t, d.table, d.want, checkTimeout)
	}
}

// generationEnded tells whether the generation of pub that apply's run
// started has ended at this moment (R51): its snapshot job reads idle
// (plan.JobIdle through the plan's lookup) and MSsnapshot_history has a
// completed row (runstatus 2, "[100%] A snapshot of <n> article(s) was
// generated.") of a run started after the plan was read. It returns why
// not, "" when it has.
func (e *env) generationEnded(pub string) string {
	lookup, ok := e.applied.SnapshotJobLookup(pub)
	if !ok {
		return "no snapshot job lookup for " + pub
	}
	var idle int
	if err := e.master.QueryRow(lookup + "\nSELECT CASE WHEN " + plan.JobIdle + " THEN 1 ELSE 0 END;").Scan(&idle); err != nil {
		return "job idle read: " + err.Error()
	}
	var done int
	dist := quoteName(e.applied.DistributionDB)
	err := e.master.QueryRow(`SELECT COUNT(*) FROM `+dist+`.dbo.MSsnapshot_history AS h
JOIN `+dist+`.dbo.MSsnapshot_agents AS a ON a.id = h.agent_id
WHERE a.publisher_db = @db AND a.publication = @pub AND h.runstatus = 2 AND h.start_time >= @t`,
		sql.Named("db", e.db), sql.Named("pub", pub), sql.Named("t", e.applyT)).Scan(&done)
	if err != nil {
		return "snapshot history read: " + err.Error()
	}
	if idle != 1 || done == 0 {
		return fmt.Sprintf("snapshot job idle %d, completed runs since %s: %d",
			idle, e.applyT.Format("15:04:05.000"), done)
	}
	return ""
}

// lineLog is Options.Out: each line apply prints goes to t.Log, and is
// kept in lines.
type lineLog struct {
	t     *testing.T
	buf   []byte
	lines []string
}

func (w *lineLog) Write(b []byte) (int, error) {
	w.buf = append(w.buf, b...)
	for {
		i := strings.IndexByte(string(w.buf), '\n')
		if i < 0 {
			return len(b), nil
		}
		w.t.Log(string(w.buf[:i]))
		w.lines = append(w.lines, string(w.buf[:i]))
		w.buf = w.buf[i+1:]
	}
}

func (w *lineLog) flush() {
	if len(w.buf) > 0 {
		w.t.Log(string(w.buf))
		w.lines = append(w.lines, string(w.buf))
		w.buf = nil
	}
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
			trancount := ""
			terr := conn.QueryRowContext(ctx, "SELECT @@TRANCOUNT").Scan(&tc)
			if terr != nil {
				trancount = fmt.Sprintf("@@TRANCOUNT not read: %v", terr)
			} else {
				trancount = fmt.Sprintf("@@TRANCOUNT %d", tc)
			}
			if terr == nil && tc == 0 && dropWith18752(op, err) {
				t.Logf("operation %d %s %s %s: tolerated: %v", op.Seq, op.Action, op.Kind, op.Path, err)
				continue
			}
			if terr == nil && tc > 0 {
				if _, rerr := conn.ExecContext(ctx, "IF @@TRANCOUNT > 0 ROLLBACK"); rerr != nil {
					t.Logf("rollback: %v", rerr)
				}
			}
			t.Fatalf("operation %d %s %s %s at %s (%s): %v\n%s", op.Seq, op.Action, op.Kind, op.Path,
				st.Server, trancount, err, st.Text)
		}
		if op.Kind == "generate_and_wait" {
			e.waitAll(t)
		}
	}
}

// dropWith18752 tells the error the harness tolerates (controller's
// ruling, Task 20 fix round 1): 18752 from sp_droppublication, or from
// sp_replicationdboption with publish false, with @@TRANCOUNT 0 afterward
// (checked by the caller). Measured by Task 20: sp_droppublication of the
// database's last publication, its log reader running, returns 18752 to
// go-mssqldb as an error, yet the publication, its distributor rows, its
// log reader and its jobs are gone and the next plan is "no changes". The
// convergence check that follows the run is what proves the drop. Plan 4's
// apply treats it as success only when a re-read shows the object gone.
func dropWith18752(op plan.Operation, err error) bool {
	var me mssql.Error
	if !errors.As(err, &me) || me.Number != 18752 {
		return false
	}
	switch procedure(op) {
	case "sp_droppublication":
		return true
	case "sp_replicationdboption":
		v, _ := param(op, "@value")
		return strings.EqualFold(v, "N'false'")
	}
	return false
}

// startAndWait starts the snapshot agent of each snapshot ref of
// AgentsToStart (sp_startpublication_snapshot, never sp_start_job: carried
// decision 6), then the pull agents of its pull refs (startPull), then
// waits for the deliveries the test expects. The push distribution refs
// are not started: the push agent runs on its own; the tests assert
// AgentsToStart exactly (wantAgents), so a plan that forgets the snapshot
// agent or a pull agent leaves the delivery undone.
func (e *env) startAndWait(t *testing.T, p *plan.Plan) {
	t.Helper()
	started := map[string]bool{}
	pull := false
	for _, a := range p.AgentsToStart {
		switch {
		case a.Kind == "pull_distribution":
			pull = true
		case a.Kind != "snapshot" || started[a.Publication]:
		default:
			started[a.Publication] = true
			e.startSnapshot(t, p.Database, a.Publication)
		}
	}
	if pull {
		e.startPull(t, p)
	}
	e.waitAll(t)
}

// startPull runs the plan's job_start statements of the pull agents, at
// their subscriber, until the deliveries the test expects have arrived or
// pollTimeout has passed. The pull agent job sp_addpullsubscription_agent
// creates has no schedule, and a run started before the snapshot is
// generated exits without delivering (carried decision 5), so the start is
// repeated every few seconds. The printed start skips a job that has a run
// requested or running (its guard, TestLabJobStartGuardPull); 22022 is
// still read as running, for a run that starts between the guard and the
// start.
func (e *env) startPull(t *testing.T, p *plan.Plan) {
	t.Helper()
	var starts []plan.Statement
	for i, st := range p.Statements() {
		if op := p.Operations[i]; op.Kind == "job_start" && strings.HasSuffix(op.Path, ".pull_agent") {
			starts = append(starts, st)
		}
	}
	if len(starts) == 0 {
		t.Fatalf("a pull agent to start and no job_start of a pull agent\n%s", p.Summary())
	}
	ctx := context.Background()
	conn, err := e.master.Conn(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	begin := time.Now()
	deadline := begin.Add(pollTimeout)
	starts22022, startsOK := 0, 0
	for !e.delivered() && time.Now().Before(deadline) {
		for _, st := range starts {
			if _, err := conn.ExecContext(ctx, "USE "+quoteName(st.Database)); err != nil {
				t.Fatalf("USE %s: %v", st.Database, err)
			}
			_, err := conn.ExecContext(ctx, st.Text)
			var me mssql.Error
			switch {
			case err == nil:
				startsOK++
			case errors.As(err, &me) && me.Number == 22022:
				starts22022++
			default:
				t.Fatalf("start of the pull agent at %s: %v\n%s", st.Server, err, st.Text)
			}
		}
		time.Sleep(3 * time.Second)
	}
	t.Logf("pull agent: %d starts accepted, %d refused with 22022 (running), %s to the deliveries",
		startsOK, starts22022, time.Since(begin).Round(time.Second))
}

// delivered tells whether every delivery the test expects has arrived.
func (e *env) delivered() bool {
	for _, d := range e.deliveries {
		var n int
		q := fmt.Sprintf("SELECT COUNT(*) FROM %s.dbo.%s", quoteName(e.sub), quoteName(d.table))
		if e.master.QueryRow(q).Scan(&n) != nil || n != d.want {
			return false
		}
	}
	return true
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
	e.waitRows(t, table, want, pollTimeout)
}

// waitRows is waitDelivered within timeout.
func (e *env) waitRows(t *testing.T, table string, want int, timeout time.Duration) {
	t.Helper()
	q := fmt.Sprintf("SELECT COUNT(*) FROM %s.dbo.%s", quoteName(e.sub), quoteName(table))
	deadline := time.Now().Add(timeout)
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
	t.Fatalf("%s.dbo.%s: %d rows (%v) after %s, want %d\n%s", e.sub, table, n, err, timeout, want, e.history())
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
