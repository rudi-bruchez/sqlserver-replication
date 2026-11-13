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

// planFlags are the flags of the plan and apply commands.
type planFlags struct {
	file, user, env      string
	sql, json, deferFull bool
	autoApprove          bool // apply only
	wait, timeout        time.Duration
	params               paramFlags
	servers              serverFlags
}

func parsePlanFlags(args []string, stderr io.Writer) (*planFlags, error) {
	return parseFlags("plan", args, stderr)
}

// parseFlags parses the flags of plan or apply: apply has those of plan
// without -sql and -json, plus -auto-approve, and its -wait is the budget
// of R52.
func parseFlags(command string, args []string, stderr io.Writer) (*planFlags, error) {
	f := &planFlags{params: paramFlags{}, servers: serverFlags{}}
	fs := flag.NewFlagSet(command, flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.StringVar(&f.file, "f", "", "the desired file (required)")
	fs.Var(f.servers, "server", "address of a server of the file by name, NAME=ADDRESS, repeatable (default: the name)")
	fs.StringVar(&f.user, "user", "", "SQL Server login; the password is read from SQLREPL_PASSWORD (default: Windows authentication)")
	fs.Var(f.params, "param", "extra connection parameter key=value, repeatable (e.g. -param encrypt=disable)")
	fs.StringVar(&f.env, "env", ".env", "the .env file read before the connections; a missing file is no error, and the real environment wins")
	fs.BoolVar(&f.deferFull, "defer-full-snapshot", false, "defer the full snapshot of a publication whose added articles would make one")
	if command == "apply" {
		fs.BoolVar(&f.autoApprove, "auto-approve", false, "apply without asking for confirmation")
		fs.DurationVar(&f.wait, "wait", 30*time.Minute, "budget of the waits for snapshot generations and deliveries, from the first operation; 0 waits for no delivery")
		fs.DurationVar(&f.timeout, "timeout", 2*time.Minute, "timeout of each connection, of the read, of each read and wait of a running operation and of each restore")
	} else {
		fs.BoolVar(&f.sql, "sql", false, "append the T-SQL to the summary")
		fs.BoolVar(&f.json, "json", false, "print the plan as JSON only")
		fs.DurationVar(&f.wait, "wait", 30*time.Minute, "how long the generate and wait step of -defer-full-snapshot waits")
		fs.DurationVar(&f.timeout, "timeout", 2*time.Minute, "timeout of each connection and of the read that follows them")
	}
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil, err
		}
		// The flag package has printed it, with the usage.
		return nil, printedError{err}
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

// usageExit is the exit code of a flag error, printed: 0 for -h, else 2
// (R52).
func usageExit(err error, stderr io.Writer) int {
	if errors.Is(err, flag.ErrHelp) {
		return 0
	}
	if !errors.As(err, new(printedError)) {
		fmt.Fprintln(stderr, "sqlrepl:", err)
	}
	return 2
}

// printedError is a flag error the flag package has printed already: a
// usage error prints its message once.
type printedError struct{ error }

func (e printedError) Unwrap() error { return e.error }

// errorExit prints an error that ends a command and returns 1.
func errorExit(err error, stderr io.Writer) int {
	fmt.Fprintln(stderr, "sqlrepl:", err)
	return 1
}

// deferRefusal is the plan refused before any connection for
// -defer-full-snapshot with -wait 0, nil without that pair.
func deferRefusal(f *planFlags) (*plan.Plan, error) {
	if !f.deferFull || f.wait > 0 {
		return nil, nil
	}
	desired, err := loadFile(f.file)
	if err != nil {
		return nil, err
	}
	return &plan.Plan{
		Publisher: desired.Publisher.Server, Database: desired.Publisher.Database,
		Options:  plan.Options{DeferFullSnapshot: f.deferFull, Wait: f.wait},
		Refusals: []plan.Refusal{{Path: "-wait", Reason: deferNeedsWait}},
	}, nil
}

// runPlan computes the plan of a desired file against the servers it names
// and prints it (R28), and returns the exit code of R52: 0, 1 for an error
// or a refusal, 2 for a usage error, 4 for a failed precondition without a
// refusal (R58). It changes nothing: the reads are SELECT statements.
func runPlan(args []string, stdout, stderr io.Writer) int {
	f, err := parsePlanFlags(args, stderr)
	if err != nil {
		return usageExit(err, stderr)
	}
	p, err := deferRefusal(f)
	if err != nil {
		return errorExit(err, stderr)
	}
	if p == nil {
		w, err := prepare(context.Background(), f)
		if err != nil {
			return errorExit(err, stderr)
		}
		defer w.close()
		unusedServers(stderr, w.desired, append(w.pulls, w.distName), f.servers)
		p, err = w.compute(context.Background(), plan.Options{DeferFullSnapshot: f.deferFull, Wait: f.wait})
		if err != nil {
			return errorExit(err, stderr)
		}
	}
	switch err := printPlan(stdout, p, f); {
	case errors.Is(err, errRefused):
		return 1
	case err != nil:
		return errorExit(err, stderr)
	}
	for _, pc := range p.Preconditions {
		if pc.Status == "failed" {
			return 4
		}
	}
	return 0
}

// wiring is what plan and apply share from the .env load to Build: the
// desired file, the probe and the pools, closed by close.
type wiring struct {
	f           *planFlags
	desired     *model.Config
	probe       reader.PublisherProbe
	master, pub *sql.DB // the publisher, at master and at the publication database
	dist        *sql.DB // nil without a distributor
	distName    string  // the file's distributor, else the probe's
	subs        map[string]*sql.DB
	unreachable map[string]string
	pulls       []string // the current pull subscribers
}

// prepare loads the .env and the desired file, then opens the publisher,
// probes it, and opens the distributor and the subscribers, each
// connection and each read under its own -timeout within ctx. On an error
// the connections opened are closed.
func prepare(ctx context.Context, f *planFlags) (*wiring, error) {
	if err := dotenv.Load(f.env); err != nil {
		return nil, err
	}
	desired, err := loadFile(f.file)
	if err != nil {
		return nil, err
	}
	w := &wiring{f: f, desired: desired}
	if err := w.open(ctx); err != nil {
		w.close()
		return nil, err
	}
	return w, nil
}

// open opens the connections of prepare and probes the publisher.
func (w *wiring) open(ctx context.Context) error {
	f, desired := w.f, w.desired
	var err error
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
		return context.WithTimeout(ctx, f.timeout)
	}

	// The publisher and the distributor must be reached (R29). The probe
	// runs on master, which is also the publisher's connection for the
	// prechecks.
	publisher := address(desired.Publisher.Server)
	c, cancel := step()
	w.master, err = connect(c, publisher, "master", cp)
	cancel()
	if err != nil {
		return fmt.Errorf("publisher: %w", err)
	}
	c, cancel = step()
	w.probe, err = probeDB(c, w.master, desired.Publisher.Database)
	cancel()
	if err != nil {
		return err
	}
	if _, _, err = w.probe.Start(); err != nil {
		return err
	}
	if err = w.probe.Writable(); err != nil {
		return err
	}
	// The stored name, in its own case, from here on.
	c, cancel = step()
	w.pub, err = connect(c, publisher, w.probe.Name, cp)
	cancel()
	if err != nil {
		return fmt.Errorf("publisher: %w", err)
	}

	w.distName = w.probe.Distributor
	if d := desired.Distributor; d != nil && d.Server != "" {
		w.distName = d.Server
	}
	if w.distName != "" {
		c, cancel = step()
		w.dist, err = connect(c, address(w.distName), "", cp)
		cancel()
		if err != nil {
			return fmt.Errorf("distributor: %w", err)
		}
	}

	w.subs, w.unreachable, w.pulls, err = openPlanSubscribers(step, desired, w.pub, f.servers, cp)
	if err != nil {
		return err
	}
	return nil
}

// compute reads the servers, runs the prechecks and builds the plan, the
// read and the prechecks under one -timeout within ctx, which starts once
// every connection is open.
func (w *wiring) compute(ctx context.Context, opt plan.Options) (*plan.Plan, error) {
	ctx, cancel := context.WithTimeout(ctx, w.f.timeout)
	defer cancel()
	res, err := readConfig(ctx, reader.Source{
		Publisher:   w.pub,
		Distributor: w.dist,
		Database:    w.probe.Name,
		Probe:       w.probe,
		Subscribers: w.subs,
		Facts:       true,
	})
	if err != nil {
		return nil, err
	}
	checks, err := runPrecheck(ctx, precheck.Conns{
		Publisher:         w.master,
		Publication:       w.pub,
		Distributor:       w.dist,
		Subscribers:       w.subs,
		Unreachable:       w.unreachable,
		DistributorServer: w.distName,
	}, w.desired, res.Config)
	if err != nil {
		return nil, err
	}
	return buildPlan(plan.Inputs{
		Desired:   w.desired,
		Current:   res.Config,
		Facts:     res.Facts,
		Checks:    checks,
		SecretSet: func(name string) bool { _, ok := secretEnv(name); return ok },
	}, opt), nil
}

// secretEnv reads a secret from the environment; an empty variable is not
// set (R54), for plan and apply alike.
func secretEnv(name string) (string, bool) {
	v, ok := os.LookupEnv(name)
	return v, ok && v != ""
}

// close closes every pool of the wiring.
func (w *wiring) close() {
	for _, db := range []*sql.DB{w.master, w.pub, w.dist} {
		if db != nil {
			db.Close()
		}
	}
	for _, db := range w.subs {
		db.Close()
	}
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
