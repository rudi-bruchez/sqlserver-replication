package main

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
	"github.com/rudi-bruchez/sqlserver-replication/internal/plan"
	"github.com/rudi-bruchez/sqlserver-replication/internal/precheck"
	"github.com/rudi-bruchez/sqlserver-replication/internal/reader"
	"github.com/rudi-bruchez/sqlserver-replication/internal/state"
)

// planFile writes a small desired file and returns its path.
func planFile(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "desired.yaml")
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

const smallFile = `version: 2
publisher:
    server: P
    database: D
publications: []
`

// noEnv is a -env path that does not exist: the tests read no .env.
func noEnv(t *testing.T) string { return filepath.Join(t.TempDir(), "none.env") }

// fakeConnect replaces connect for the test.
func fakeConnect(t *testing.T, f func(ctx context.Context, server, database string, cp connParams) (*sql.DB, error)) {
	t.Helper()
	old := connect
	connect = f
	t.Cleanup(func() { connect = old })
}

func TestPlanFlags(t *testing.T) {
	var stderr bytes.Buffer
	f, err := parsePlanFlags([]string{"-f", "x.yaml", "-server", "a=b", "-sql", "-defer-full-snapshot", "-wait", "5m"}, &stderr)
	if err != nil {
		t.Fatal(err)
	}
	if f.file != "x.yaml" || !f.sql || f.json || !f.deferFull || f.wait != 5*time.Minute || f.timeout != 2*time.Minute || f.env != ".env" {
		t.Errorf("flags = %+v", f)
	}
	if e, ok := f.servers.lookup("A"); !ok || e.Address != "b" {
		t.Errorf("-server a=b: %+v %t", e, ok)
	}
	d, err := parsePlanFlags([]string{"-f", "x.yaml"}, &stderr)
	if err != nil || d.wait != 30*time.Minute {
		t.Errorf("default -wait = %v, %v; want 30m", d.wait, err)
	}
	if _, err := parsePlanFlags([]string{"-sql"}, &stderr); err == nil || !strings.Contains(err.Error(), "-f") {
		t.Errorf("no -f: %v, want an error naming -f", err)
	}
}

// -defer-full-snapshot with -wait 0 is refused before any connection, as a
// refused plan: the summary is printed and runPlan returns errRefused.
func TestPlanRefusesWaitZeroWithDefer(t *testing.T) {
	fakeConnect(t, func(context.Context, string, string, connParams) (*sql.DB, error) {
		t.Error("connect called")
		return nil, errors.New("no connection in this test")
	})
	var stdout, stderr bytes.Buffer
	err := runPlan([]string{"-f", planFile(t, smallFile), "-env", noEnv(t), "-defer-full-snapshot", "-wait", "0"}, &stdout, &stderr)
	if !errors.Is(err, errRefused) {
		t.Fatalf("err = %v, want errRefused", err)
	}
	if !strings.Contains(stdout.String(), "Plan refused.") || !strings.Contains(stdout.String(), "-wait") {
		t.Errorf("stdout = %q", stdout.String())
	}
	stdout.Reset()
	err = runPlan([]string{"-f", planFile(t, smallFile), "-env", noEnv(t), "-json", "-defer-full-snapshot", "-wait", "0"}, &stdout, &stderr)
	if !errors.Is(err, errRefused) || !strings.Contains(stdout.String(), `"refusals"`) {
		t.Errorf("-json: err = %v, stdout = %q", err, stdout.String())
	}
}

// fakeRun replaces every connection, read and check of runPlan and records
// what runPlan hands them. connect fails for the servers of fail.
type fakeRun struct {
	connects []connectCall
	dbs      map[string]*sql.DB // by "<server>/<database>"
	pulls    []string
	pullErr  error
	probe    reader.PublisherProbe
	source   reader.Source
	conns    precheck.Conns
	inputs   plan.Inputs
	built    *plan.Plan // buildPlan returns it, or an empty plan
}

type connectCall struct {
	server, database string
	cp               connParams
}

func newFakeRun(t *testing.T, fail map[string]string) *fakeRun {
	t.Helper()
	r := &fakeRun{dbs: map[string]*sql.DB{},
		probe: reader.PublisherProbe{State: "ONLINE", Published: true, Distributor: "P", Name: "D"}}
	fakeConnect(t, func(_ context.Context, server, database string, cp connParams) (*sql.DB, error) {
		r.connects = append(r.connects, connectCall{server, database, cp})
		if msg, ok := fail[server]; ok {
			return nil, errors.New(msg)
		}
		db, err := sql.Open("sqlserver", "sqlserver://localhost")
		r.dbs[server+"/"+database] = db
		return db, err
	})
	oldPull, oldProbe, oldRead, oldCheck, oldBuild := pullSubscribers, probeDB, readConfig, runPrecheck, buildPlan
	t.Cleanup(func() {
		pullSubscribers, probeDB, readConfig, runPrecheck, buildPlan = oldPull, oldProbe, oldRead, oldCheck, oldBuild
	})
	pullSubscribers = func(context.Context, *sql.DB) ([]string, error) { return r.pulls, r.pullErr }
	probeDB = func(context.Context, *sql.DB, string) (reader.PublisherProbe, error) { return r.probe, nil }
	readConfig = func(_ context.Context, src reader.Source) (*reader.Result, error) {
		r.source = src
		return &reader.Result{Config: &model.Config{Version: model.FormatVersion,
			Publisher: model.Publisher{Server: "P", Database: r.probe.Name}}, Facts: &state.Facts{}}, nil
	}
	runPrecheck = func(_ context.Context, c precheck.Conns, _, _ *model.Config) (*state.Checks, error) {
		r.conns = c
		return &state.Checks{}, nil
	}
	buildPlan = func(in plan.Inputs, opt plan.Options) *plan.Plan {
		r.inputs = in
		if r.built != nil {
			return r.built
		}
		return &plan.Plan{Publisher: in.Desired.Publisher.Server, Database: in.Desired.Publisher.Database, Options: opt}
	}
	return r
}

const subscribedFile = `version: 2
publisher:
    server: P
    database: sales
distributor:
    server: D
    database: distribution
publications:
    - name: pub
      subscriptions:
        - subscriber: s1
          database: db
`

// The -server note leaves out the entries in use: a server of the file in
// another case, the publisher, a current pull subscriber the file no
// longer names (items 5 and M2 of fix round 1).
func TestPlanUnusedServerNote(t *testing.T) {
	r := newFakeRun(t, nil)
	r.pulls = []string{"OLDPULL"}
	var stdout, stderr bytes.Buffer
	err := runPlan([]string{"-f", planFile(t, subscribedFile), "-env", noEnv(t),
		"-server", "other=x", "-server", "p=y", "-server", "S1=z", "-server", "oldpull=w", "-server", "d=v"}, &stdout, &stderr)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := stderr.String(), "note: -server other names no server of the file\n"; got != want {
		t.Errorf("stderr = %q, want %q", got, want)
	}
	// The publisher is reached at its -server address, whatever the case.
	if len(r.connects) == 0 || r.connects[0].server != "y" {
		t.Errorf("connected to %+v, want the publisher at y first", r.connects)
	}
}

// What runPlan hands the reads, the checks and Build (M3 to M5, M8 to M11
// of fix round 1).
func TestPlanWiring(t *testing.T) {
	env := filepath.Join(t.TempDir(), "test.env")
	if err := os.WriteFile(env, []byte("SQLREPL_PASSWORD=fromfile\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SQLREPL_PASSWORD", "")
	os.Unsetenv("SQLREPL_PASSWORD")
	t.Setenv("SQLREPL_T18_SET", "x")
	r := newFakeRun(t, map[string]string{"s1": "boom at s1"})
	r.probe.Name = "Sales"
	var stdout, stderr bytes.Buffer
	if err := runPlan([]string{"-f", planFile(t, subscribedFile), "-env", env, "-server", "D=dist-addr"}, &stdout, &stderr); err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, c := range r.connects {
		got = append(got, c.server+"/"+c.database)
		if c.cp.Password != "fromfile" {
			t.Errorf("%s/%s: password %q, want the .env's (M8)", c.server, c.database, c.cp.Password)
		}
		if c.cp.Extra["connection timeout"] != "120" {
			t.Errorf("%s/%s: connection timeout %q, want 120 (item 2)", c.server, c.database, c.cp.Extra["connection timeout"])
		}
	}
	// M11: the publication database by the probe's stored name; M3: the
	// file's distributor through -server, whose entry is then opened as a
	// subscriber too, as every -server entry is.
	if want := []string{"P/master", "P/Sales", "dist-addr/", "s1/master", "dist-addr/master"}; !reflect.DeepEqual(got, want) {
		t.Errorf("connections %q, want %q", got, want)
	}
	if !r.source.Facts {
		t.Error("reader.Read without Facts (M5)")
	}
	if r.conns.Publisher == nil || r.conns.Publisher != r.dbs["P/master"] {
		t.Error("precheck's Publisher is not the master connection (M9)")
	}
	if r.conns.Publication == nil || r.conns.Publication != r.dbs["P/Sales"] {
		t.Error("precheck's Publication is not the publication database's connection")
	}
	if e := r.conns.Unreachable["s1"]; e != "boom at s1" {
		t.Errorf("Unreachable[s1] = %q, want the connection error (M10)", e)
	}
	if r.conns.DistributorServer != "D" {
		t.Errorf("DistributorServer = %q, want D (item 6)", r.conns.DistributorServer)
	}
	if r.inputs.SecretSet == nil || !r.inputs.SecretSet("SQLREPL_T18_SET") || r.inputs.SecretSet("SQLREPL_T18_UNSET") {
		t.Error("SecretSet does not read the environment (M4)")
	}
}

// With no distributor section, the probe's distributor is the one
// resolved and handed to the checks (item 6).
func TestPlanDistributorFromProbe(t *testing.T) {
	r := newFakeRun(t, nil)
	r.probe.Distributor = "REMOTEDIST"
	var stdout, stderr bytes.Buffer
	if err := runPlan([]string{"-f", planFile(t, smallFile), "-env", noEnv(t), "-server", "remotedist=rd"}, &stdout, &stderr); err != nil {
		t.Fatal(err)
	}
	if r.conns.DistributorServer != "REMOTEDIST" {
		t.Errorf("DistributorServer = %q", r.conns.DistributorServer)
	}
	if stderr.Len() != 0 {
		t.Errorf("stderr = %q, want no note for the distributor's entry", stderr.String())
	}
}

// A failed read of the pull subscribers is an error (M7).
func TestPlanPullSubscribersError(t *testing.T) {
	r := newFakeRun(t, nil)
	r.pullErr = errors.New("reading the pull subscribers: denied")
	var stdout, stderr bytes.Buffer
	err := runPlan([]string{"-f", planFile(t, smallFile), "-env", noEnv(t)}, &stdout, &stderr)
	if err == nil || !strings.Contains(err.Error(), "denied") {
		t.Errorf("err = %v, want the pull subscribers' error", err)
	}
}

// -sql appends the T-SQL to the summary (M6).
func TestPlanSQLAppended(t *testing.T) {
	r := newFakeRun(t, nil)
	r.built = &plan.Plan{Publisher: "P", Database: "D", Operations: []plan.Operation{{Seq: 1, Step: 3, Kind: "publication",
		Action: "add", Path: "publications[pub]", Server: "P", Database: "D", Call: plan.Call{Procedure: "sp_fakeprocedure"}}},
		Totals: plan.Totals{Operations: 1}}
	for _, withSQL := range []bool{false, true} {
		args := []string{"-f", planFile(t, smallFile), "-env", noEnv(t)}
		if withSQL {
			args = append(args, "-sql")
		}
		var stdout, stderr bytes.Buffer
		if err := runPlan(args, &stdout, &stderr); err != nil {
			t.Fatal(err)
		}
		out := stdout.String()
		if !strings.HasPrefix(out, "Plan for P.D: 1 operations") || strings.Contains(out, "EXEC sp_fakeprocedure") != withSQL {
			t.Errorf("-sql %t: stdout\n%s", withSQL, out)
		}
	}
}

// main's run maps errRefused to exit 1 and prints nothing more (M16).
func TestRunRefusedExit(t *testing.T) {
	fakeConnect(t, func(context.Context, string, string, connParams) (*sql.DB, error) {
		return nil, errors.New("no connection in this test")
	})
	var stdout, stderr bytes.Buffer
	code := run([]string{"plan", "-f", planFile(t, smallFile), "-env", noEnv(t), "-defer-full-snapshot", "-wait", "0"}, &stdout, &stderr)
	if code != 1 || stderr.Len() != 0 || !strings.Contains(stdout.String(), "Plan refused.") {
		t.Errorf("exit %d, stderr %q, stdout %q", code, stderr.String(), stdout.String())
	}
	stdout.Reset()
	if code := run([]string{"plan", "-f", planFile(t, smallFile), "-env", noEnv(t)}, &stdout, &stderr); code != 1 || !strings.Contains(stderr.String(), "sqlrepl: publisher: no connection in this test") {
		t.Errorf("an error: exit %d, stderr %q", code, stderr.String())
	}
}

// A subscriber that accepts the TCP connection and never answers is
// unreachable within about -timeout, through the driver's connection
// timeout (item 2: the driver does not abort a prelogin when its context
// ends). No lab: a local listener.
func TestPlanSilentSubscriberTimeout(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	var held []net.Conn
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			held = append(held, c) // accepted, never answered
		}
	}()
	defer func() {
		for _, c := range held {
			c.Close()
		}
	}()
	old := pullSubscribers
	pullSubscribers = func(context.Context, *sql.DB) ([]string, error) { return nil, nil }
	defer func() { pullSubscribers = old }()

	port := ln.Addr().(*net.TCPAddr).Port
	servers := serverFlags{}
	servers.Set(fmt.Sprintf("SILENT=tcp:127.0.0.1,%d", port))
	f := &planFlags{params: paramFlags{"encrypt": "disable"}, servers: servers, timeout: 2 * time.Second}
	desired := &model.Config{Version: model.FormatVersion, Publisher: model.Publisher{Server: "P", Database: "D"},
		Publications: []model.Publication{{Name: "pub", Subscriptions: []model.Subscription{{Subscriber: "SILENT", Database: "db"}}}}}
	step := func() (context.Context, context.CancelFunc) {
		return context.WithTimeout(context.Background(), f.timeout)
	}

	begin := time.Now()
	subs, unreachable, _, err := openPlanSubscribers(step, desired, nil, servers, planConnParams(f))
	elapsed := time.Since(begin)
	for _, db := range subs {
		db.Close()
	}
	if err != nil {
		t.Fatal(err)
	}
	if elapsed > 6*time.Second {
		t.Errorf("took %v with -timeout 2s", elapsed)
	}
	if e := unreachable["SILENT"]; !strings.Contains(e, fmt.Sprintf("127.0.0.1,%d", port)) {
		t.Errorf("Unreachable = %v, want SILENT with an error naming its address", unreachable)
	}
}

// The driver's connection timeout: -timeout in whole seconds rounded up,
// at least 1, unless -param sets one (item 2).
func TestPlanConnParamsTimeout(t *testing.T) {
	for timeout, want := range map[time.Duration]string{2 * time.Minute: "120", 1500 * time.Millisecond: "2", 10 * time.Millisecond: "1"} {
		if got := planConnParams(&planFlags{params: paramFlags{}, timeout: timeout}).Extra["connection timeout"]; got != want {
			t.Errorf("-timeout %v: %q, want %q", timeout, got, want)
		}
	}
	cp := planConnParams(&planFlags{params: paramFlags{"Connection Timeout": "7"}, timeout: time.Minute})
	if len(cp.Extra) != 1 || cp.Extra["Connection Timeout"] != "7" {
		t.Errorf("-param kept: %v", cp.Extra)
	}
}

// The subscribers opened are the union, without regard to case, of the
// file's, the current pull subscribers and the -server entries, each once
// (item N of the panel).
func TestPlanOpensSubscribers(t *testing.T) {
	desired := func(sub string) *model.Config {
		return &model.Config{Version: model.FormatVersion, Publisher: model.Publisher{Server: "P", Database: "D"},
			Publications: []model.Publication{{Name: "pub", Subscriptions: []model.Subscription{{Subscriber: sub, Database: "db"}}}}}
	}
	run := func(cfg *model.Config, pulls []string, servers serverFlags, fail string) ([]string, map[string]*sql.DB, map[string]string) {
		t.Helper()
		old := pullSubscribers
		pullSubscribers = func(context.Context, *sql.DB) ([]string, error) { return pulls, nil }
		defer func() { pullSubscribers = old }()
		var addresses []string
		fakeConnect(t, func(_ context.Context, server, database string, _ connParams) (*sql.DB, error) {
			if database != "master" {
				t.Errorf("subscriber %s opened in %q, want master", server, database)
			}
			addresses = append(addresses, server)
			if server == fail {
				return nil, errors.New("refused")
			}
			return sql.Open("sqlserver", "sqlserver://localhost")
		})
		step := func() (context.Context, context.CancelFunc) { return context.WithCancel(context.Background()) }
		subs, unreachable, _, err := openPlanSubscribers(step, cfg, nil, servers, connParams{})
		if err != nil {
			t.Fatal(err)
		}
		for _, db := range subs {
			db.Close()
		}
		sort.Strings(addresses)
		return addresses, subs, unreachable
	}
	keys := func(m map[string]*sql.DB) []string {
		var out []string
		for k := range m {
			out = append(out, k)
		}
		sort.Strings(out)
		return out
	}

	servers := serverFlags{}
	servers.Set("S3=x")
	got, subs, unreachable := run(desired("S1"), []string{"s2"}, servers, "")
	if want := []string{"S1", "s2", "x"}; !reflect.DeepEqual(got, want) {
		t.Errorf("opened %q, want %q", got, want)
	}
	if want := []string{"S1", "S3", "s2"}; !reflect.DeepEqual(keys(subs), want) || len(unreachable) != 0 {
		t.Errorf("subscribers %q, unreachable %v; want %q", keys(subs), unreachable, want)
	}

	got, subs, _ = run(desired("s1"), []string{"S1"}, serverFlags{}, "")
	if len(got) != 1 || len(subs) != 1 {
		t.Errorf("desired s1, current S1: opened %q, want one connection", got)
	}

	// A subscriber that cannot be reached is unreachable, not an error.
	_, subs, unreachable = run(desired("S1"), nil, serverFlags{}, "S1")
	if len(subs) != 0 || !strings.Contains(unreachable["S1"], "refused") {
		t.Errorf("unreachable S1: subscribers %q, unreachable %v", keys(subs), unreachable)
	}
}

// labCLI opens the lab for a test of the command, skipped unless
// SQLREPL_TEST_LAB is set, and returns the pool and @@SERVERNAME; it sets
// SQLREPL_PASSWORD for runPlan.
func labCLI(t *testing.T) (*sql.DB, string) {
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
	password, _ := u.User.Password()
	db, err := sql.Open("sqlserver", d)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	var server string
	if err := db.QueryRow("SELECT @@SERVERNAME").Scan(&server); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SQLREPL_PASSWORD", password)
	return db, server
}

// The plan of the lab fixture against the lab is empty, the subscriber
// REPLLAB of the file answering as repllab (carried decision 4).
func TestLabPlanCLISalesEmpty(t *testing.T) {
	_, server := labCLI(t)
	var stdout, stderr bytes.Buffer
	err := runPlan([]string{"-f", "../../internal/testdata/lab/sales.yaml", "-env", noEnv(t),
		"-server", server + "=tcp:127.0.0.1,11980", "-user", "sa", "-param", "encrypt=disable"}, &stdout, &stderr)
	if err != nil {
		t.Fatalf("runPlan: %v\nstdout:\n%s\nstderr:\n%s", err, stdout.String(), stderr.String())
	}
	first, _, _ := strings.Cut(stdout.String(), "\n")
	if !strings.HasSuffix(first, "no changes.") {
		t.Errorf("first line %q, want it to end with \"no changes.\"\nstdout:\n%s\nstderr:\n%s", first, stdout.String(), stderr.String())
	}
}

// A read-only publication database is refused before any operation, as an
// offline one is: its plan would fail at the first write with 3906, after
// the job_disable (final review item 2, measured). The database rv_ff_ro is
// created for the test and dropped after it.
func TestLabPlanCLIReadOnly(t *testing.T) {
	db, server := labCLI(t)
	const name = "rv_ff_ro"
	drop := func() {
		if _, err := db.Exec("IF DB_ID(N'" + name + "') IS NOT NULL DROP DATABASE " + name); err != nil {
			t.Errorf("drop %s: %v", name, err)
		}
	}
	drop()
	t.Cleanup(drop)
	if _, err := db.Exec("CREATE DATABASE " + name); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec("ALTER DATABASE " + name + " SET READ_ONLY"); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(t.TempDir(), "ro.yaml")
	if err := os.WriteFile(file, []byte("version: 2\npublisher:\n  server: "+server+"\n  database: "+name+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	var stdout, stderr bytes.Buffer
	err := runPlan([]string{"-f", file, "-env", noEnv(t),
		"-server", server + "=tcp:127.0.0.1,11980", "-user", "sa", "-param", "encrypt=disable"}, &stdout, &stderr)
	if err == nil || err.Error() != "database is read only" {
		t.Fatalf("runPlan: %v, want \"database is read only\"\nstdout:\n%s\nstderr:\n%s", err, stdout.String(), stderr.String())
	}
	if stdout.Len() != 0 {
		t.Errorf("a plan printed for a read-only database:\n%s", stdout.String())
	}
}

// R54: a secret variable set to the empty string is not set, and the plan
// lists it so.
func TestPlanSecretEmptyNotSet(t *testing.T) {
	t.Setenv("SQLREPL_T4_EMPTY", "")
	t.Setenv("SQLREPL_T4_FULL", "x")
	r := newFakeRun(t, nil)
	buildPlan = func(in plan.Inputs, opt plan.Options) *plan.Plan {
		r.inputs = in
		p := &plan.Plan{Publisher: in.Desired.Publisher.Server, Database: in.Desired.Publisher.Database, Options: opt}
		for _, n := range []string{"SQLREPL_T4_EMPTY", "SQLREPL_T4_FULL"} {
			p.Secrets = append(p.Secrets, plan.SecretUse{Name: n, Set: in.SecretSet(n)})
		}
		return p
	}
	var stdout, stderr bytes.Buffer
	if err := runPlan([]string{"-f", planFile(t, smallFile), "-env", noEnv(t)}, &stdout, &stderr); err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"  SQLREPL_T4_EMPTY not set\n", "  SQLREPL_T4_FULL set\n"} {
		if !strings.Contains(stdout.String(), want) {
			t.Errorf("output lacks %q:\n%s", want, stdout.String())
		}
	}
}
