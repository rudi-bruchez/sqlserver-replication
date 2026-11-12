package main

import (
	"context"
	"database/sql"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/rudi-bruchez/sqlserver-replication/internal/dotenv"
	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
	"github.com/rudi-bruchez/sqlserver-replication/internal/plan"
	"github.com/rudi-bruchez/sqlserver-replication/internal/precheck"
	"github.com/rudi-bruchez/sqlserver-replication/internal/reader"
)

// errRefused is returned by runPlan for a refused plan, after the plan was
// printed: main exits 1 without printing it again (R28).
var errRefused = errors.New("plan refused")

// connect opens a server; the tests replace it.
var connect = func(ctx context.Context, server, database string, cp connParams) (*sql.DB, error) {
	return open(ctx, server, database, cp)
}

// pullSubscribers reads the servers of the current pull subscriptions; the
// tests replace it.
var pullSubscribers = reader.PullSubscribers

// deferNeedsWait refuses -defer-full-snapshot with -wait 0 before any
// connection: the generate and wait step of a deferred publication waits
// for the deliveries of its added articles (R25).
const deferNeedsWait = "-defer-full-snapshot needs a -wait above 0: the generate and wait step waits for the deliveries of the added articles (R25)"

// planFlags are the flags of the plan command.
type planFlags struct {
	file, user, env      string
	sql, json, deferFull bool
	wait, timeout        time.Duration
	params               paramFlags
	servers              serverFlags
}

func parsePlanFlags(args []string, stderr io.Writer) (*planFlags, error) {
	f := &planFlags{params: paramFlags{}, servers: serverFlags{}}
	fs := flag.NewFlagSet("plan", flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.StringVar(&f.file, "f", "", "the desired file (required)")
	fs.Var(f.servers, "server", "address of a server of the file by name, NAME=ADDRESS, repeatable (default: the name)")
	fs.StringVar(&f.user, "user", "", "SQL Server login; the password is read from SQLREPL_PASSWORD (default: Windows authentication)")
	fs.Var(f.params, "param", "extra connection parameter key=value, repeatable (e.g. -param encrypt=disable)")
	fs.StringVar(&f.env, "env", ".env", "the .env file read before the connections; a missing file is no error, and the real environment wins")
	fs.BoolVar(&f.sql, "sql", false, "append the T-SQL to the summary")
	fs.BoolVar(&f.json, "json", false, "print the plan as JSON only")
	fs.BoolVar(&f.deferFull, "defer-full-snapshot", false, "defer the full snapshot of a publication whose added articles would make one")
	fs.DurationVar(&f.wait, "wait", 30*time.Minute, "how long the generate and wait step of -defer-full-snapshot waits")
	fs.DurationVar(&f.timeout, "timeout", 2*time.Minute, "overall timeout")
	if err := fs.Parse(args); err != nil {
		return nil, err
	}
	if fs.NArg() > 0 {
		return nil, fmt.Errorf("unexpected argument %q", fs.Arg(0))
	}
	if f.file == "" {
		fs.Usage()
		return nil, fmt.Errorf("-f is required")
	}
	return f, nil
}

// runPlan computes the plan of a desired file against the servers it names
// and prints it (R28). It changes nothing: the reads are SELECT statements.
func runPlan(args []string, stdout, stderr io.Writer) error {
	f, err := parsePlanFlags(args, stderr)
	if err != nil {
		return err
	}
	if err := dotenv.Load(f.env); err != nil {
		return err
	}
	desired, err := loadFile(f.file)
	if err != nil {
		return err
	}
	opt := plan.Options{DeferFullSnapshot: f.deferFull, Wait: f.wait}
	if f.deferFull && f.wait <= 0 {
		return printPlan(stdout, &plan.Plan{
			Publisher: desired.Publisher.Server, Database: desired.Publisher.Database, Options: opt,
			Refusals: []plan.Refusal{{Path: "-wait", Reason: deferNeedsWait}},
		}, f)
	}
	unusedServers(stderr, desired, f.servers)

	ctx, cancel := context.WithTimeout(context.Background(), f.timeout)
	defer cancel()
	cp := connParams{User: f.user, Password: os.Getenv("SQLREPL_PASSWORD"), Extra: f.params}
	address := func(name string) string {
		if e, ok := f.servers.lookup(name); ok {
			return e.Address
		}
		return name
	}

	// The publisher and the distributor must be reached (R29). The probe
	// runs on master, which is also the publisher's connection for the
	// prechecks.
	publisher := address(desired.Publisher.Server)
	master, err := connect(ctx, publisher, "master", cp)
	if err != nil {
		return fmt.Errorf("publisher: %w", err)
	}
	defer master.Close()
	probe, err := reader.Probe(ctx, master, desired.Publisher.Database)
	if err != nil {
		return err
	}
	if _, _, err := probe.Start(); err != nil {
		return err
	}
	pub, err := connect(ctx, publisher, probe.Name, cp)
	if err != nil {
		return fmt.Errorf("publisher: %w", err)
	}
	defer pub.Close()

	distName := probe.Distributor
	if d := desired.Distributor; d != nil && d.Server != "" {
		distName = d.Server
	}
	var dist *sql.DB
	if distName != "" {
		dist, err = connect(ctx, address(distName), "", cp)
		if err != nil {
			return fmt.Errorf("distributor: %w", err)
		}
		defer dist.Close()
	}

	subs, unreachable, err := openPlanSubscribers(ctx, desired, pub, f.servers, cp)
	defer func() {
		for _, db := range subs {
			db.Close()
		}
	}()
	if err != nil {
		return err
	}

	res, err := reader.Read(ctx, reader.Source{
		Publisher:   pub,
		Distributor: dist,
		Database:    probe.Name,
		Probe:       probe,
		Subscribers: subs,
		Facts:       true,
	})
	if err != nil {
		return err
	}
	checks, err := precheck.Run(ctx, precheck.Conns{
		Publisher:   master,
		Publication: pub,
		Distributor: dist,
		Subscribers: subs,
		Unreachable: unreachable,
	}, desired)
	if err != nil {
		return err
	}
	p := plan.Build(plan.Inputs{
		Desired: desired,
		Current: res.Config,
		Facts:   res.Facts,
		Checks:  checks,
		SecretSet: func(name string) bool {
			_, ok := os.LookupEnv(name)
			return ok
		},
	}, opt)
	return printPlan(stdout, p, f)
}

func loadFile(path string) (*model.Config, error) {
	r, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer r.Close()
	cfg, err := model.Load(r)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return cfg, nil
}

// printPlan prints the plan by R28: the summary, then the T-SQL with -sql,
// or the JSON only with -json. A refused plan returns errRefused once
// printed.
func printPlan(stdout io.Writer, p *plan.Plan, f *planFlags) error {
	if f.json {
		b, err := p.JSON()
		if err != nil {
			return err
		}
		if _, err := stdout.Write(append(b, '\n')); err != nil {
			return err
		}
	} else {
		out := p.Summary()
		if s := p.SQL(); f.sql && s != "" {
			out += "\n" + s
		}
		if _, err := io.WriteString(stdout, out); err != nil {
			return err
		}
	}
	if len(p.Refusals) > 0 {
		return errRefused
	}
	return nil
}

// fileServers returns the servers the file names, each once whatever its
// case (R7), in the order of their first mention.
func fileServers(c *model.Config) []string {
	var out []string
	seen := map[string]bool{}
	add := func(name string) {
		if name != "" && !seen[strings.ToUpper(name)] {
			seen[strings.ToUpper(name)] = true
			out = append(out, name)
		}
	}
	add(c.Publisher.Server)
	if c.Distributor != nil {
		add(c.Distributor.Server)
	}
	for _, p := range c.Publications {
		for _, s := range p.Subscriptions {
			add(s.Subscriber)
		}
	}
	return out
}

// unusedServers notes on stderr each -server entry that names no server of
// the file: likely a typing error, which would leave a server reached at
// its name.
func unusedServers(stderr io.Writer, c *model.Config, servers serverFlags) {
	named := map[string]bool{}
	for _, s := range fileServers(c) {
		named[strings.ToUpper(s)] = true
	}
	keys := make([]string, 0, len(servers))
	for k := range servers {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		if !named[k] {
			fmt.Fprintf(stderr, "note: -server %s names no server of the file\n", servers[k].Name)
		}
	}
}

// openPlanSubscribers opens, to master, the union without regard to case of
// the subscribers the file names, those of the current pull subscriptions
// (a pull subscription removed from the file is still read, and dropped
// where it must be), and every -server entry, each once and keyed by the
// name first met. A subscriber that cannot be reached goes to unreachable
// with its error (R29); only a failed read of the pull subscribers is an
// error. The connections opened are returned with any error, for the
// caller to close.
func openPlanSubscribers(ctx context.Context, desired *model.Config, pub *sql.DB, servers serverFlags, cp connParams) (map[string]*sql.DB, map[string]string, error) {
	subs := map[string]*sql.DB{}
	unreachable := map[string]string{}
	var names []string
	seen := map[string]bool{}
	add := func(name string) {
		if name != "" && !seen[strings.ToUpper(name)] {
			seen[strings.ToUpper(name)] = true
			names = append(names, name)
		}
	}
	for _, p := range desired.Publications {
		for _, s := range p.Subscriptions {
			add(s.Subscriber)
		}
	}
	pulls, err := pullSubscribers(ctx, pub)
	if err != nil {
		return subs, unreachable, err
	}
	for _, s := range pulls {
		add(s)
	}
	keys := make([]string, 0, len(servers))
	for k := range servers {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		add(servers[k].Name)
	}
	for _, name := range names {
		address := name
		if e, ok := servers.lookup(name); ok {
			address = e.Address
		}
		db, err := connect(ctx, address, "master", cp)
		if err != nil {
			unreachable[name] = err.Error()
			continue
		}
		subs[name] = db
	}
	return subs, unreachable, nil
}
