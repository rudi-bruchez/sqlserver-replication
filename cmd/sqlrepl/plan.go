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
	"strconv"
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

// The reads and the build runPlan calls; the tests replace them.
var (
	pullSubscribers = reader.PullSubscribers
	probeDB         = reader.Probe
	readConfig      = reader.Read
	runPrecheck     = precheck.Run
	buildPlan       = plan.Build
)

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
	fs.DurationVar(&f.timeout, "timeout", 2*time.Minute, "timeout of each connection and of the read that follows them")
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
	cp := planConnParams(f)
	address := func(name string) string {
		if e, ok := f.servers.lookup(name); ok {
			return e.Address
		}
		return name
	}
	// Each connection and each read before the plan's own read gets its own
	// -timeout, the connections a driver connection timeout too
	// (planConnParams): go-mssqldb does not abort a connection when its
	// context ends during prelogin, so a silent server would otherwise hold
	// the command well past -timeout (Task 18 fix round 1, measured).
	step := func() (context.Context, context.CancelFunc) {
		return context.WithTimeout(context.Background(), f.timeout)
	}

	// The publisher and the distributor must be reached (R29). The probe
	// runs on master, which is also the publisher's connection for the
	// prechecks.
	publisher := address(desired.Publisher.Server)
	ctx, cancel := step()
	master, err := connect(ctx, publisher, "master", cp)
	cancel()
	if err != nil {
		return fmt.Errorf("publisher: %w", err)
	}
	defer master.Close()
	ctx, cancel = step()
	probe, err := probeDB(ctx, master, desired.Publisher.Database)
	cancel()
	if err != nil {
		return err
	}
	if _, _, err := probe.Start(); err != nil {
		return err
	}
	// The stored name, in its own case, from here on.
	ctx, cancel = step()
	pub, err := connect(ctx, publisher, probe.Name, cp)
	cancel()
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
		ctx, cancel = step()
		dist, err = connect(ctx, address(distName), "", cp)
		cancel()
		if err != nil {
			return fmt.Errorf("distributor: %w", err)
		}
		defer dist.Close()
	}

	subs, unreachable, pulls, err := openPlanSubscribers(step, desired, pub, f.servers, cp)
	defer func() {
		for _, db := range subs {
			db.Close()
		}
	}()
	if err != nil {
		return err
	}
	unusedServers(stderr, desired, append(pulls, distName), f.servers)

	// The read's context starts once every connection is open.
	ctx, cancel = step()
	defer cancel()
	res, err := readConfig(ctx, reader.Source{
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
	checks, err := runPrecheck(ctx, precheck.Conns{
		Publisher:         master,
		Publication:       pub,
		Distributor:       dist,
		Subscribers:       subs,
		Unreachable:       unreachable,
		DistributorServer: distName,
	}, desired)
	if err != nil {
		return err
	}
	p := buildPlan(plan.Inputs{
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

// planConnParams is the connection parameters of every connection plan
// opens: the password read after the .env load, and the driver's
// connection timeout set from -timeout, in whole seconds rounded up and at
// least 1, unless -param sets one.
func planConnParams(f *planFlags) connParams {
	extra := map[string]string{}
	set := false
	for k, v := range f.params {
		extra[k] = v
		// The driver ignores a key with spaces around it, so does this test.
		if strings.EqualFold(k, "connection timeout") {
			set = true
		}
	}
	if !set {
		secs := int64((f.timeout + time.Second - 1) / time.Second)
		if secs < 1 {
			secs = 1
		}
		extra["connection timeout"] = strconv.FormatInt(secs, 10)
	}
	return connParams{User: f.user, Password: os.Getenv("SQLREPL_PASSWORD"), Extra: extra}
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
// the file nor of inUse (the current pull subscribers, the distributor):
// likely a typing error, which would leave a server reached at its name.
// Names compare without regard to case (R7).
func unusedServers(stderr io.Writer, c *model.Config, inUse []string, servers serverFlags) {
	named := map[string]bool{}
	for _, s := range append(fileServers(c), inUse...) {
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
// name first met, each with its own context from step. A subscriber that
// cannot be reached goes to unreachable with its error (R29); only a failed
// read of the pull subscribers is an error. It also returns the pull
// subscribers. The connections opened are returned with any error, for the
// caller to close.
func openPlanSubscribers(step func() (context.Context, context.CancelFunc), desired *model.Config, pub *sql.DB, servers serverFlags, cp connParams) (map[string]*sql.DB, map[string]string, []string, error) {
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
	ctx, cancel := step()
	pulls, err := pullSubscribers(ctx, pub)
	cancel()
	if err != nil {
		return subs, unreachable, nil, err
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
		ctx, cancel := step()
		db, err := connect(ctx, address, "master", cp)
		cancel()
		if err != nil {
			unreachable[name] = err.Error()
			continue
		}
		subs[name] = db
	}
	return subs, unreachable, pulls, nil
}
