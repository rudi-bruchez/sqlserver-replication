package main

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
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

func TestPlanUnusedServerNote(t *testing.T) {
	var addresses []string
	fakeConnect(t, func(_ context.Context, server, _ string, _ connParams) (*sql.DB, error) {
		addresses = append(addresses, server)
		return nil, errors.New("fake: unreachable")
	})
	var stdout, stderr bytes.Buffer
	err := runPlan([]string{"-f", planFile(t, smallFile), "-env", noEnv(t), "-server", "other=x", "-server", "p=y"}, &stdout, &stderr)
	if err == nil || !strings.Contains(err.Error(), "fake: unreachable") {
		t.Errorf("err = %v, want the publisher's connection error", err)
	}
	if got := stderr.String(); !strings.Contains(got, "note: -server other names no server of the file\n") || strings.Contains(got, "-server p ") {
		t.Errorf("stderr = %q, want the note for other only", got)
	}
	// The publisher is reached at its -server address, whatever the case.
	if len(addresses) != 1 || addresses[0] != "y" {
		t.Errorf("connected to %q, want the publisher at y", addresses)
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
		subs, unreachable, err := openPlanSubscribers(context.Background(), cfg, nil, servers, connParams{})
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

// The plan of the lab fixture against the lab is empty, the subscriber
// REPLLAB of the file answering as repllab (carried decision 4).
func TestLabPlanCLISalesEmpty(t *testing.T) {
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
	defer db.Close()
	var server string
	if err := db.QueryRow("SELECT @@SERVERNAME").Scan(&server); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SQLREPL_PASSWORD", password)

	var stdout, stderr bytes.Buffer
	err = runPlan([]string{"-f", "../../internal/testdata/lab/sales.yaml", "-env", noEnv(t),
		"-server", server + "=tcp:127.0.0.1,11980", "-user", "sa", "-param", "encrypt=disable"}, &stdout, &stderr)
	if err != nil {
		t.Fatalf("runPlan: %v\nstdout:\n%s\nstderr:\n%s", err, stdout.String(), stderr.String())
	}
	first, _, _ := strings.Cut(stdout.String(), "\n")
	if !strings.HasSuffix(first, "no changes.") {
		t.Errorf("first line %q, want it to end with \"no changes.\"\nstdout:\n%s\nstderr:\n%s", first, stdout.String(), stderr.String())
	}
}
