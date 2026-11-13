package apply

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	mssql "github.com/microsoft/go-mssqldb"

	"github.com/rudi-bruchez/sqlserver-replication/internal/plan"
)

// Target is what a run applies to: the place of its locks, the pools of
// its servers and the function that reads, prechecks and builds the plan.
type Target struct {
	Server, Database string // the publisher and publication database, the lock's place
	// Distributor and DistributionDB are the second lock's place (R45);
	// empty when the file declares neither distributor nor agent_profiles.
	Distributor, DistributionDB string
	Servers                     Servers
	Plan                        func(ctx context.Context) (*plan.Plan, error) // the read, the prechecks and Build
}

// Options are the command line options of a run and its test hooks.
type Options struct {
	Wait, Timeout time.Duration
	AutoApprove   bool
	Confirm       func(question string) (bool, error) // nil with AutoApprove
	Secret        func(name string) (string, bool)    // R54: empty is not set
	Out           io.Writer
	Interrupt     <-chan os.Signal // nil: none
	// BeforeStatement is a test hook (Task 12): an error stops the run
	// before that statement, as a failure. It fires when the statement is
	// about to be sent: for a held job_start of step 12, after the wait for
	// its generation (R51), and not at all when that wait ends the run. A
	// second start (again) does not call it.
	BeforeStatement func(seq int) error
}

// The resources of the application locks (R45).
const (
	lockResource            = "sqlrepl apply"
	distributorLockResource = "sqlrepl apply distributor"
)

// The preconditions apply refuses on when unchecked (R58).
const (
	precondJobPermission = "msdb job permission"
	precondAgent         = "sql server agent"
)

// runner is the state of one run.
type runner struct {
	t     Target
	o     Options
	p     *plan.Plan
	s     *session
	out   io.Writer // every line goes through mask (R53)
	res   *Result
	ops   map[int]plan.Operation
	stmts map[int]plan.Statement
	n     int // operations of the plan

	parent  context.Context
	runCtx  context.Context // cancelled by the first interrupt
	intr    chan struct{}   // closed by the first interrupt
	waitCtx context.Context // -wait from the confirmation (R52)

	distributor string
	tr          *tracker
	jb          jobs
	ran         map[int]bool
	starts      []*startRec // the agent job_starts run, for R51's second start
	deferPub    string      // a generate_and_wait whose deliveries are not yet awaited (R51)
	waited      bool        // a wait for deliveries ran: pending ones are unconfirmed, not "not awaited"
	stopped     bool
	values      []string // the bound secret values, masked in every message
}

// startRec is an agent job_start that ran, which R51 may run once more.
type startRec struct {
	op    plan.Operation
	st    plan.Statement
	subs  []string
	again bool
}

// Run applies a plan (spec "apply", R44 to R54): the session and the locks,
// the plan read once under them, the refusals, the confirmation racing the
// interrupt, every unit of statements, the held agent starts and the wait
// for the deliveries owed, then on every way out the restores and the
// unlock. The error is for a run that ends before it has a plan: a lock
// held or not taken, the plan not read; the locks taken are released
// first.
func Run(ctx context.Context, t Target, o Options) (*Result, error) {
	if o.Timeout <= 0 {
		o.Timeout = defaultTimeout
	}
	if o.Wait < 0 {
		o.Wait = 0
	}
	r := &runner{t: t, o: o, parent: ctx, res: &Result{}, ran: map[int]bool{}}
	out := o.Out
	if out == nil {
		out = io.Discard
	}
	r.out = maskWriter{w: out, values: &r.values}
	r.s = newSession(t.Servers)
	r.s.timeout = o.Timeout

	runCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	r.runCtx = runCtx
	r.intr = make(chan struct{})
	done := make(chan struct{})
	defer close(done)
	if o.Interrupt != nil {
		go func() {
			select {
			case <-o.Interrupt:
				close(r.intr)
				cancel()
			case <-done:
				return
			}
			// R48: a second signal, during the restores, is ignored.
			for {
				select {
				case <-o.Interrupt:
				case <-done:
					return
				}
			}
		}()
	}

	if err := r.lock(t.Server, t.Database, lockResource); err != nil {
		return nil, r.abort(err)
	}
	if t.DistributionDB != "" {
		dist := t.Distributor
		if dist == "" {
			dist = t.Server
		}
		if err := r.lock(dist, t.DistributionDB, distributorLockResource); err != nil {
			return nil, r.abort(err)
		}
	}
	p, err := t.Plan(runCtx)
	if err == nil && p == nil {
		err = errors.New("the plan was not built")
	}
	if err != nil {
		return nil, r.abort(err)
	}
	r.setPlan(p)
	if err := r.recordOwedBefore(); err != nil {
		// Before any operation: an error of Run, as a held lock is (R53:
		// to standard error), the locks released first.
		return nil, r.abort(fmt.Errorf("record the deliveries owed before the plan: %w", err))
	}
	r.apply()
	r.finish()
	return r.res, nil
}

// lock takes one application lock and prints it (R45, R53).
func (r *runner) lock(server, database, resource string) error {
	ctx, cancel := context.WithTimeout(r.runCtx, r.o.Timeout)
	defer cancel()
	if err := r.s.lock(ctx, server, database, resource); err != nil {
		if errors.Is(err, ErrLocked) {
			return fmt.Errorf("%w on %s.%s", ErrLocked, server, database)
		}
		return fmt.Errorf("take the lock on %s.%s: %w", server, database, err)
	}
	fmt.Fprintf(r.out, "lock taken on %s.%s\n", server, database)
	return nil
}

// abort ends a run that has no plan: the locks taken are released, and a
// release that fails is reported with the error (R45).
func (r *runner) abort(err error) error {
	r.s.close()
	errs := []error{err}
	for _, f := range r.s.releaseFailures {
		errs = append(errs, errors.New(f))
	}
	return errors.Join(errs...)
}

// setPlan indexes the plan and reads the values of its secrets to mask.
func (r *runner) setPlan(p *plan.Plan) {
	r.p, r.res.Plan = p, p
	r.n = len(p.Operations)
	r.ops = map[int]plan.Operation{}
	r.stmts = map[int]plan.Statement{}
	for _, op := range p.Operations {
		r.ops[op.Seq] = op
	}
	for _, st := range p.Statements() {
		r.stmts[st.Seq] = st
	}
	for _, s := range p.Secrets {
		if v, ok := r.secret(s.Name); ok {
			r.values = append(r.values, v)
		}
	}
	r.distributor = r.distributorName()
	r.tr = newTracker(r.distributor, p.Publisher)
}

// secret is Options.Secret with R54: an empty value is not set.
func (r *runner) secret(name string) (string, bool) {
	if r.o.Secret == nil {
		return "", false
	}
	v, ok := r.o.Secret(name)
	return v, ok && v != ""
}

// distributorName is the server the snapshot jobs and the distribution
// database are read at: the Target's distributor, else the server of the
// plan's snapshot job operations, else the publisher (the remote
// distributor is out of scope, R17).
func (r *runner) distributorName() string {
	if r.t.Distributor != "" {
		return r.t.Distributor
	}
	for _, op := range r.p.Operations {
		if strings.HasPrefix(op.Kind, "job_") && strings.HasSuffix(op.Path, ".snapshot_agent") {
			return op.Server
		}
	}
	return r.t.Server
}

// interrupted tells whether the run was interrupted (a signal, or the
// caller's context).
func (r *runner) interrupted() bool {
	select {
	case <-r.intr:
		return true
	default:
	}
	return r.parent.Err() != nil
}

// readCtx bounds one of apply's own reads during the run by -timeout; an
// interrupt cancels it.
func (r *runner) readCtx() (context.Context, context.CancelFunc) {
	return context.WithTimeout(r.runCtx, r.o.Timeout)
}

// apply is the run from the plan to the last operation and the wait for
// deliveries.
func (r *runner) apply() {
	p := r.p
	fmt.Fprint(r.out, p.Summary())
	if r.refuse() {
		r.stop(OutcomeRefused, nil)
		return
	}
	if len(p.Operations) == 0 {
		r.stop(OutcomeEmpty, nil)
		return
	}
	if !r.confirm() {
		fmt.Fprintln(r.out, "Apply cancelled.")
		r.stop(OutcomeCancelled, nil)
		return
	}
	waitCtx, cancel := context.WithTimeout(r.runCtx, r.o.Wait)
	defer cancel()
	r.waitCtx = waitCtx

	for _, u := range units(p) {
		if r.interrupted() {
			r.stop(OutcomeInterrupted, nil)
			return
		}
		first := r.ops[u[0]]
		if r.deferPub != "" && first.Kind != "job_start" && !r.deferWait() {
			return
		}
		if len(u) == 1 && held(first) {
			continue
		}
		if !r.runUnit(u) {
			return
		}
	}
	if r.deferPub != "" && !r.deferWait() {
		return
	}
	if !r.heldPhase() {
		return
	}
	if r.o.Wait > 0 {
		r.deliveryWait()
		if r.stopped {
			return
		}
	}
	if r.interrupted() {
		r.stop(OutcomeInterrupted, nil)
		return
	}
	r.stop(OutcomeApplied, nil)
}

// recordOwedBefore records Plan.OwedBefore, by publication, right after
// the plan is read: T is that reading (R50). A plan that will not run
// (no operation, or refused) is not read at the distributor.
func (r *runner) recordOwedBefore() error {
	if len(r.p.Operations) == 0 || len(r.p.Refusals) > 0 || len(r.p.OwedBefore) == 0 {
		return nil
	}
	ctx, cancel := r.readCtx()
	defer cancel()
	var pubs []string
	subs := map[string][]string{}
	for _, o := range r.p.OwedBefore {
		if _, ok := subs[o.Publication]; !ok {
			pubs = append(pubs, o.Publication)
		}
		subs[o.Publication] = append(subs[o.Publication], o.Subscription)
	}
	for _, pub := range pubs {
		if err := r.tr.record(ctx, r.s, r.p, pub, subs[pub]); err != nil {
			return err
		}
	}
	return nil
}

// refuse prints every reason the run stops before the question (R44,
// R45, R54, R58) and tells whether there is one.
func (r *runner) refuse() bool {
	p := r.p
	refused := len(p.Refusals) > 0 // the summary printed them
	if r.o.Wait <= 0 {
		for _, op := range p.Operations {
			if op.Kind == "generate_and_wait" {
				// Its waits are -wait's: with none, it would stop as the
				// deferral's timeout right after starting the snapshot.
				fmt.Fprintln(r.out, "refused: -defer-full-snapshot needs -wait above 0")
				refused = true
				break
			}
		}
	}
	for _, pc := range p.Preconditions {
		needed := pc.Name == precondJobPermission || pc.Name == precondAgent
		if pc.Status == "failed" || (pc.Status == "unchecked" && needed) {
			line := fmt.Sprintf("refused: precondition %s %s at %s is %s", pc.Name, pc.Object, pc.Server, pc.Status)
			if pc.Detail != "" {
				line += ": " + pc.Detail
			}
			fmt.Fprintln(r.out, line)
			refused = true
		}
	}
	for _, s := range p.Secrets {
		if _, ok := r.secret(s.Name); !ok {
			fmt.Fprintf(r.out, "secret %s is not set\n", s.Name)
			refused = true
		}
	}
	if r.t.DistributionDB == "" {
		for _, op := range p.Operations {
			if sharedPath(op.Path) {
				fmt.Fprintf(r.out, "refused: operation %d changes %s, shared with other publication databases, without the distributor lock\n", op.Seq, op.Path)
				refused = true
			}
		}
	}
	return refused
}

// sharedPath tells a path under distributor or agent_profiles, the objects
// shared with other publication databases (R45).
func sharedPath(path string) bool {
	for _, root := range []string{"distributor", "agent_profiles"} {
		if path == root || strings.HasPrefix(path, root+".") || strings.HasPrefix(path, root+"[") {
			return true
		}
	}
	return false
}

// confirm asks the question unless AutoApprove, racing the interrupt
// (R44): only true from Confirm applies.
func (r *runner) confirm() bool {
	if r.o.AutoApprove {
		return true
	}
	if r.o.Confirm == nil {
		return false
	}
	type answer struct {
		ok  bool
		err error
	}
	ch := make(chan answer, 1)
	q := question(r.p)
	go func() {
		ok, err := r.o.Confirm(q)
		ch <- answer{ok, err}
	}()
	select {
	case a := <-ch:
		return a.err == nil && a.ok && !r.interrupted()
	case <-r.intr:
		return false
	case <-r.parent.Done():
		return false
	}
}

// held tells a job_start of step 12 that starts a distribution or pull
// agent: run after the generation its delivery waits for (R51), not in
// plan order.
func held(op plan.Operation) bool {
	return op.Kind == "job_start" && op.Step == 12 && !strings.HasSuffix(op.Path, ".snapshot_agent")
}

// stop ends the run with an outcome, once.
func (r *runner) stop(o Outcome, f *Failure) {
	if r.stopped {
		return
	}
	r.stopped = true
	r.res.Outcome = o
	r.res.Failure = f
}

// failure builds the Failure of err at seq, through driverError (never
// err.Error() of a driver error, which can be Msg 266, Task 6), masked.
// The text a step wrapped around the driver error is kept in Step.
func (r *runner) failure(seq int, err error) *Failure {
	f := &Failure{Seq: seq}
	if de, ok := driverError(err); ok {
		f.Step = mask(wrapText(err), r.values)
		f.Number, f.Message = int(de.Number), de.Message
		if errors.Is(err, errTranOpen) {
			f.Message += " (" + errTranOpen.Error() + ", rolled back)"
		}
	} else {
		f.Message = err.Error()
	}
	f.Message = mask(f.Message, r.values)
	return f
}

// failStatement stops the run at a statement that failed and prints its
// line (R53); an interrupt that cancelled it is an interrupt.
func (r *runner) failStatement(seq int, err error) {
	if r.interrupted() {
		fmt.Fprintln(r.out, "  interrupted")
		r.stop(OutcomeInterrupted, nil)
		return
	}
	f := r.failure(seq, err)
	fmt.Fprintf(r.out, "  failed: %s\n", f.text())
	r.stop(OutcomeFailed, f)
}

// wrapText is the text fmt.Errorf wrappers put before the driver error in
// err's message, without its final ": "; "" when the driver error is the
// error itself.
func wrapText(err error) string {
	var inner string
	var e mssql.Error
	var pe *mssql.Error
	switch {
	case errors.As(err, &e):
		inner = e.Error()
	case errors.As(err, &pe) && pe != nil:
		inner = pe.Error()
	default:
		return ""
	}
	full := err.Error()
	i := strings.Index(full, inner)
	if i <= 0 {
		return ""
	}
	return strings.TrimSuffix(strings.TrimSpace(full[:i]), ":")
}

// failStep stops the run at a step that is not a statement: a read apply
// needs, the test hook, a spent bound.
func (r *runner) failStep(seq int, err error) {
	if r.interrupted() {
		r.stop(OutcomeInterrupted, nil)
		return
	}
	r.stop(OutcomeFailed, r.failure(seq, err))
}

// spent stops the run on a wait that ended: an interrupt, else the -wait
// budget spent before the last operation (R52), exit 1, or in the
// deferral (deferral true) the exception of exit 3.
func (r *runner) spent(seq int, what string, err error, deferral bool) {
	if r.interrupted() {
		r.stop(OutcomeInterrupted, nil)
		return
	}
	if deferral {
		fmt.Fprintf(r.out, "the wait of the deferral ended: %s: immediate_sync stays off\n", what)
		f := r.failure(seq, fmt.Errorf("%s: %w", what, err))
		r.stop(OutcomeUnconfirmed, f)
		return
	}
	r.stop(OutcomeFailed, r.failure(seq, fmt.Errorf("-wait %s spent %s: %w", r.o.Wait, what, err)))
}

// log prints a statement before it runs (R53).
func (r *runner) log(op plan.Operation, again bool) {
	word := ""
	if again {
		word = "again "
	}
	fmt.Fprintf(r.out, "[%d/%d] %s%s %s %s at %s, database %s\n", op.Seq, r.n, word, op.Action, op.Kind, op.Path, op.Server, op.Database)
	for _, l := range strings.Split(r.stmts[op.Seq].Text, "\n") {
		fmt.Fprintf(r.out, "  %s\n", l)
	}
}

func (r *runner) ok(t0 time.Time) {
	fmt.Fprintf(r.out, "  ok (%d ms)\n", time.Since(t0).Milliseconds())
}

func (r *runner) note(format string, args ...any) {
	n := mask(fmt.Sprintf(format, args...), r.values)
	r.res.Notes = append(r.res.Notes, n)
}

// runUnit runs one unit (R46, R50): the deliveries owed before it, the
// test hook, its statements, the deliveries owed after it or marked by
// it, and the status read of the subscriptions it creates.
func (r *runner) runUnit(u []int) bool {
	ops := make([]plan.Operation, len(u))
	for i, seq := range u {
		ops[i] = r.ops[seq]
	}
	for _, op := range ops {
		if op.OwesAt == plan.OwesBefore && len(op.Owes) > 0 {
			if !r.record(op, op.Owes) {
				return false
			}
		}
	}
	var after func(context.Context) ([]string, error)
	for _, op := range ops {
		if op.OwesAt == plan.OwesMarked && len(op.Owes) > 0 {
			ctx, cancel := r.readCtx()
			f, err := r.tr.marked(ctx, r.s, op)
			cancel()
			if err != nil {
				r.failStep(op.Seq, fmt.Errorf("read the subscription statuses before operation %d: %w", op.Seq, err))
				return false
			}
			after = f
		}
	}
	for _, seq := range u {
		if r.o.BeforeStatement != nil {
			if err := r.o.BeforeStatement(seq); err != nil {
				r.failStep(seq, err)
				return false
			}
		}
	}
	if len(ops) == 2 {
		if !r.runPush(ops[0], ops[1]) {
			return false
		}
	} else if !r.runOp(ops[0]) {
		return false
	}
	for _, op := range ops {
		switch {
		case op.OwesAt == plan.OwesAfter && len(op.Owes) > 0:
			if !r.record(op, op.Owes) {
				return false
			}
		case op.OwesAt == plan.OwesMarked && after != nil:
			ctx, cancel := r.readCtx()
			went, err := after(ctx)
			cancel()
			if err != nil {
				r.failStep(op.Seq, fmt.Errorf("read the subscription statuses after operation %d: %w", op.Seq, err))
				return false
			}
			if len(went) > 0 && !r.record(op, went) {
				return false
			}
		}
	}
	for _, op := range ops {
		if op.Kind == "subscription" && op.Action == "add" && len(op.Owes) > 0 {
			ctx, cancel := r.readCtx()
			for _, sub := range op.Owes {
				if err := r.tr.settle(ctx, r.s, r.p, firstString(op.Affects.Publications), sub); err != nil {
					cancel()
					r.failStep(op.Seq, fmt.Errorf("read the status of the subscription %s created by operation %d: %w", sub, op.Seq, err))
					return false
				}
			}
			cancel()
		}
	}
	return true
}

// record records the deliveries op owes to subs (R50).
func (r *runner) record(op plan.Operation, subs []string) bool {
	ctx, cancel := r.readCtx()
	defer cancel()
	if err := r.tr.record(ctx, r.s, r.p, firstString(op.Affects.Publications), subs); err != nil {
		r.failStep(op.Seq, fmt.Errorf("record the deliveries owed by operation %d: %w", op.Seq, err))
		return false
	}
	return true
}

// runOp runs one operation by its kind.
func (r *runner) runOp(op plan.Operation) bool {
	switch op.Kind {
	case "job_start":
		if strings.HasSuffix(op.Path, ".snapshot_agent") {
			return r.runSnapshotStart(op)
		}
		return r.runAgentStart(op, false)
	case "generate_and_wait":
		return r.runGenerate(op)
	case "job_disable":
		// R48: armed before the statement is sent.
		r.jb.arm(r.p, op)
		if !r.execOp(op) {
			return false
		}
		pub := firstString(op.Affects.Publications)
		lookup, ok := r.p.SnapshotJobLookup(pub)
		if !ok {
			lookup = op.Call.Prologue
		}
		ctx, cancel := r.readCtx()
		defer cancel()
		if err := waitIdle(ctx, r.s, op.Server, pub, lookup, r.out); err != nil {
			r.failStep(op.Seq, err)
			return false
		}
		return true
	case "job_restore":
		if !r.execOp(op) {
			return false
		}
		r.jb.done(op.Seq)
		return true
	}
	return r.execOp(op)
}

// execOp runs one statement by R46 and R47: 18752 tolerated on the
// measured procedures once the re-read shows the change done, 21854 and
// 21861 retried once after the snapshot job is idle when retryDecision
// allows it; every other error a failure.
func (r *runner) execOp(op plan.Operation) bool {
	st := r.stmts[op.Seq]
	r.log(op, false)
	t0 := time.Now()
	err := r.s.exec(r.runCtx, st, r.secret)
	if err == nil {
		r.ok(t0)
		r.ran[op.Seq] = true
		return true
	}
	if r.interrupted() {
		r.failStatement(op.Seq, err)
		return false
	}
	c, num := classify(err)
	switch {
	case c == classLogReader && !errors.Is(err, errTranOpen):
		if q, args, ok := effectQuery(op); ok {
			done, rerr := r.reRead(op, q, args...)
			if rerr == nil && done {
				fmt.Fprintf(r.out, "  18752 tolerated, %s %s re-read\n", op.Kind, op.Path)
				r.note("operation %d: 18752 tolerated, %s %s re-read", op.Seq, op.Kind, op.Path)
				r.ran[op.Seq] = true
				return true
			}
		}
	case c == classGenerating && !errors.Is(err, errTranOpen):
		retry, rerr := r.mayRetryGenerating(op)
		if rerr != nil {
			r.failStatement(op.Seq, errors.Join(err, rerr))
			return false
		}
		if retry {
			t1 := time.Now()
			if err2 := r.s.exec(r.runCtx, st, r.secret); err2 != nil {
				r.failStatement(op.Seq, err2)
				return false
			}
			fmt.Fprintf(r.out, "  retried after generating (Msg %d)\n", num)
			r.note("operation %d: retried after Msg %d", op.Seq, num)
			r.ok(t1)
			r.ran[op.Seq] = true
			return true
		}
	}
	r.failStatement(op.Seq, err)
	return false
}

// reRead runs the re-read of R47 in the operation's database on its
// connection, under a fresh context: 1 is the change done.
func (r *runner) reRead(op plan.Operation, q string, args ...any) (bool, error) {
	ctx, cancel := r.s.fresh(r.runCtx)
	defer cancel()
	conn, err := r.s.connIn(ctx, op.Server, op.Database)
	if err != nil {
		return false, err
	}
	var v int
	if err := conn.QueryRowContext(ctx, q, args...).Scan(&v); err != nil {
		return false, err
	}
	return v == 1, nil
}

// mayRetryGenerating waits, within -timeout, for the publication's
// snapshot job to be idle, reads immediate_sync_ready and tells whether
// the statement refused with 21854 or 21861 runs once more (R47).
func (r *runner) mayRetryGenerating(op plan.Operation) (bool, error) {
	pub := firstString(op.Affects.Publications)
	lookup, ok := r.p.SnapshotJobLookup(pub)
	if !ok {
		return false, fmt.Errorf("no snapshot job lookup for %s", pub)
	}
	ctx, cancel := r.readCtx()
	defer cancel()
	if err := waitIdle(ctx, r.s, r.distributor, pub, lookup, r.out); err != nil {
		return false, err
	}
	conn, err := r.s.connIn(ctx, op.Server, op.Database)
	if err != nil {
		return false, err
	}
	var ready int
	if err := conn.QueryRowContext(ctx, qImmediateSyncReady, pub).Scan(&ready); err != nil {
		return false, fmt.Errorf("read immediate_sync_ready of %s: %w", pub, err)
	}
	v, _ := param(op, "@force_invalidate_snapshot")
	return retryDecision(strings.TrimSpace(v) == "1", ready == 1), nil
}

// execNoRead runs a statement without the @@TRANCOUNT read: the first
// statement of a push subscription unit (R46).
func (s *session) execNoRead(ctx context.Context, st plan.Statement, secret func(string) (string, bool)) error {
	args, err := secretArgs(st, secret)
	if err != nil {
		return err
	}
	p, err := s.pin(ctx, st.Server)
	if err != nil {
		return err
	}
	if err := s.use(ctx, p, st.Database); err != nil {
		return err
	}
	_, err = p.conn.ExecContext(ctx, st.Text, args...)
	return err
}

// runPush runs a push subscription unit back to back (R46): no read
// between sp_addsubscription and sp_addpushsubscription_agent, so that the
// implicit agent never runs before its credentials are set; @@TRANCOUNT is
// read after the second. A failure of the first stops before the second,
// its transaction rolled back.
func (r *runner) runPush(a, b plan.Operation) bool {
	r.log(a, false)
	t0 := time.Now()
	if err := r.s.execNoRead(r.runCtx, r.stmts[a.Seq], r.secret); err != nil {
		if conn, cerr := r.s.conn(r.runCtx, a.Server); cerr == nil {
			if _, rerr := r.s.tranCount(r.runCtx, conn); rerr != nil {
				err = errors.Join(err, rerr)
			}
		}
		r.failStatement(a.Seq, err)
		return false
	}
	r.ok(t0)
	r.ran[a.Seq] = true
	r.log(b, false)
	t1 := time.Now()
	if err := r.s.exec(r.runCtx, r.stmts[b.Seq], r.secret); err != nil {
		r.failStatement(b.Seq, err)
		return false
	}
	r.ok(t1)
	r.ran[b.Seq] = true
	return true
}

// agentText names the agent of a job_start for the start lines (R53):
// its kind, its publication (ALL for a shared agent) and its subscription.
func agentText(op plan.Operation) (kind, text string) {
	kind = "distribution"
	switch {
	case strings.HasSuffix(op.Path, ".snapshot_agent"):
		kind = "snapshot"
	case strings.HasSuffix(op.Path, ".pull_agent"):
		kind = "pull_distribution"
	}
	pub := firstString(op.Affects.Publications)
	if pub == "" {
		pub = "ALL"
	}
	text = kind + " " + pub
	if kind != "snapshot" {
		if subs := startSubs(op); len(subs) > 0 {
			text += " " + subs[0]
		}
	}
	return kind, text
}

// startSubs is the subscriptions a distribution or pull agent's job_start
// serves: its Affects, or for a shared agent the key in its path,
// publisher.shared_distribution_agents[<key>].distribution_agent.
func startSubs(op plan.Operation) []string {
	if len(op.Affects.Subscriptions) > 0 {
		return op.Affects.Subscriptions
	}
	const prefix = "publisher.shared_distribution_agents["
	if !strings.HasPrefix(op.Path, prefix) {
		return nil
	}
	rest := op.Path[len(prefix):]
	var b strings.Builder
	for i := 0; i < len(rest); i++ {
		if rest[i] == ']' {
			if i+1 < len(rest) && rest[i+1] == ']' {
				b.WriteByte(']')
				i++
				continue
			}
			return []string{b.String()}
		}
		b.WriteByte(rest[i])
	}
	return nil
}

// runAgentStart runs a distribution or pull agent's job_start (R51): 22022
// and a skipped guard are running; SQL Server Agent stopped and every
// other error stop the run.
func (r *runner) runAgentStart(op plan.Operation, again bool) bool {
	st := r.stmts[op.Seq]
	r.log(op, again)
	t0 := time.Now()
	started, err := r.s.start(r.runCtx, st)
	if err != nil {
		r.failStatement(op.Seq, err)
		return false
	}
	r.ok(t0)
	_, text := agentText(op)
	if started {
		fmt.Fprintf(r.out, "started %s\n", text)
	} else {
		fmt.Fprintf(r.out, "%s already running\n", text)
	}
	r.ran[op.Seq] = true
	if !again {
		r.starts = append(r.starts, &startRec{op: op, st: st, subs: startSubs(op)})
	}
	return true
}

// runSnapshotStart runs a snapshot agent's job_start (R49): started, done;
// skipped (a run in progress, or 22022), wait within -wait for that run to
// end, and run the statement again only while the publication is still
// pending, once per wait. A record whose job ran at T is retaken once the
// job is idle, before apply's own run (R50).
func (r *runner) runSnapshotStart(op plan.Operation) bool {
	pub := firstString(op.Affects.Publications)
	if r.tr.runningAtT(pub) && r.o.Wait > 0 {
		if err := waitIdle(r.waitCtx, r.s, op.Server, pub, op.Call.Prologue, r.out); err != nil {
			r.spent(op.Seq, "waiting for the snapshot job of "+pub, err, false)
			return false
		}
		if !r.retake(op.Seq, pub) {
			return false
		}
	}
	again := false
	for {
		r.log(op, again)
		t0 := time.Now()
		started, err := r.s.start(r.runCtx, r.stmts[op.Seq])
		if err != nil {
			r.failStatement(op.Seq, err)
			return false
		}
		r.ok(t0)
		r.ran[op.Seq] = true
		if started {
			fmt.Fprintf(r.out, "started snapshot %s\n", pub)
			return true
		}
		fmt.Fprintf(r.out, "snapshot %s already running\n", pub)
		if r.o.Wait == 0 {
			return true
		}
		if err := waitIdle(r.waitCtx, r.s, op.Server, pub, op.Call.Prologue, r.out); err != nil {
			r.spent(op.Seq, "waiting for the snapshot job of "+pub, err, false)
			return false
		}
		if !r.retake(op.Seq, pub) {
			return false
		}
		pending, err := r.pending(pub)
		if err != nil {
			r.failStep(op.Seq, err)
			return false
		}
		if !pending {
			return true
		}
		if !r.sleep(r.waitCtx) {
			r.spent(op.Seq, "waiting to start the snapshot agent of "+pub, r.waitCtx.Err(), false)
			return false
		}
		again = true
	}
}

// pending reads pendingQuery at the publisher (R49).
func (r *runner) pending(pub string) (bool, error) {
	ctx, cancel := r.readCtx()
	defer cancel()
	conn, err := r.s.connIn(ctx, r.p.Publisher, r.p.Database)
	if err != nil {
		return false, err
	}
	var v int
	if err := conn.QueryRowContext(ctx, pendingQuery, pub).Scan(&v); err != nil {
		return false, fmt.Errorf("read whether a snapshot of %s is pending: %w", pub, err)
	}
	return v == 1, nil
}

// retake retakes the records of pub whose job ran at T (R50).
func (r *runner) retake(seq int, pub string) bool {
	ctx, cancel := r.readCtx()
	defer cancel()
	if err := r.tr.retake(ctx, r.s, r.p, pub); err != nil {
		r.failStep(seq, fmt.Errorf("retake the deliveries owed by %s: %w", pub, err))
		return false
	}
	return true
}

// runningAtT tells whether a pending record of pub found its snapshot job
// running at T.
func (t *tracker) runningAtT(pub string) bool {
	for _, rec := range t.records {
		if rec.run == "" && rec.unlisted == "" && rec.RunningAtT && strings.EqualFold(rec.Publication, pub) {
			return true
		}
	}
	return false
}

// sleep waits one poll interval; false when ctx ended first.
func (r *runner) sleep(ctx context.Context) bool {
	t := time.NewTimer(idlePoll)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-t.C:
		return true
	}
}

// runGenerate runs the deferral's generate_and_wait (R25, R49, R51): the
// deliveries of the subscriptions it names are recorded before it starts
// the snapshot agent; 22022 is retried every second after the job reads
// idle, within -wait; then apply waits, within -wait, for the run to end.
// A spent wait stops with immediate_sync off, exit 3.
func (r *runner) runGenerate(op plan.Operation) bool {
	pub := firstString(op.Affects.Publications)
	lookup, ok := r.p.SnapshotJobLookup(pub)
	if !ok {
		r.failStep(op.Seq, fmt.Errorf("no snapshot job lookup for %s", pub))
		return false
	}
	if len(op.Affects.Subscriptions) > 0 && !r.record(op, op.Affects.Subscriptions) {
		return false
	}
	if r.tr.runningAtT(pub) {
		if err := waitIdle(r.waitCtx, r.s, r.distributor, pub, lookup, r.out); err != nil {
			r.spent(op.Seq, "waiting for the snapshot job of "+pub, err, true)
			return false
		}
		if !r.retake(op.Seq, pub) {
			return false
		}
	}
	st := r.stmts[op.Seq]
	again := false
	for {
		r.log(op, again)
		t0 := time.Now()
		err := r.s.exec(r.runCtx, st, r.secret)
		if err == nil {
			r.ok(t0)
			break
		}
		if c, _ := classify(err); c != classBusy || errors.Is(err, errTranOpen) || r.interrupted() {
			r.failStatement(op.Seq, err)
			return false
		}
		fmt.Fprintln(r.out, "  the snapshot job is running: retried once it is idle")
		if err := waitIdle(r.waitCtx, r.s, r.distributor, pub, lookup, r.out); err != nil {
			r.spent(op.Seq, "waiting to start the snapshot agent of "+pub, err, true)
			return false
		}
		if !r.sleep(r.waitCtx) {
			r.spent(op.Seq, "waiting to start the snapshot agent of "+pub, r.waitCtx.Err(), true)
			return false
		}
		again = true
	}
	r.ran[op.Seq] = true
	r.note("operation %d: generate_and_wait started the snapshot agent of %s", op.Seq, pub)
	if err := waitIdle(r.waitCtx, r.s, r.distributor, pub, lookup, r.out); err != nil {
		r.spent(op.Seq, "waiting for the generation of "+pub, err, true)
		return false
	}
	r.deferPub = pub
	return true
}

// deferWait waits for every delivery the deferred publication owes so far,
// before the first operation after its job_start statements that is not a
// job_start (R51). Not all confirmed: apply stops with immediate_sync off
// and the remaining operations unrun, exit 3.
func (r *runner) deferWait() bool {
	pub := r.deferPub
	r.deferPub = ""
	r.waited = true
	r.waitFor(func(rec *record) bool { return strings.EqualFold(rec.Publication, pub) })
	if r.interrupted() {
		r.stop(OutcomeInterrupted, nil)
		return false
	}
	for _, rec := range r.tr.records {
		if strings.EqualFold(rec.Publication, pub) && rec.run == "" {
			seq := 0
			for _, op := range r.p.Operations {
				if op.Kind == "generate_and_wait" && strings.EqualFold(firstString(op.Affects.Publications), pub) {
					seq = op.Seq
				}
			}
			r.spent(seq, "the deliveries of "+pub+" are not confirmed", errors.New(rec.reason()), true)
			return false
		}
	}
	return true
}

// heldPhase runs the held job_start statements of step 12 (R51), each
// after the generation its subscription's delivery waits for has ended:
// at once for an S7 subscription, and with -wait 0 at once too (R52).
func (r *runner) heldPhase() bool {
	for _, op := range r.p.Operations {
		if !held(op) {
			continue
		}
		if r.interrupted() {
			r.stop(OutcomeInterrupted, nil)
			return false
		}
		if r.o.Wait > 0 && !r.awaitGeneration(op) {
			return false
		}
		// The hook fires when the statement is sent, after the wait for
		// its generation (Task 11 fix round 1: the scenario's hook reads
		// the generation's end at that moment). When awaitGeneration ends
		// the run (-wait spent, an interrupt), the hook of this held
		// statement never fires.
		if r.o.BeforeStatement != nil {
			if err := r.o.BeforeStatement(op.Seq); err != nil {
				r.failStep(op.Seq, err)
				return false
			}
		}
		if !r.runAgentStart(op, false) {
			return false
		}
	}
	return true
}

// awaitGeneration waits, within -wait, until the snapshot job of every
// publication whose delivery to op's subscription is owed (not S7), or of
// op's own publication when none is owed, reads idle: the end of the
// generation, whoever started it (R51). The records whose job ran at T are
// retaken then.
func (r *runner) awaitGeneration(op plan.Operation) bool {
	subs := startSubs(op)
	var pubs []string
	seen := map[string]bool{}
	owedAny := false
	for _, rec := range r.tr.records {
		if rec.run != "" || rec.unlisted != "" || !hasFold(subs, rec.Subscription) {
			continue
		}
		owedAny = true
		if rec.S7 || seen[strings.ToLower(rec.Publication)] {
			continue
		}
		seen[strings.ToLower(rec.Publication)] = true
		pubs = append(pubs, rec.Publication)
	}
	if !owedAny {
		if pub := firstString(op.Affects.Publications); pub != "" {
			pubs = append(pubs, pub)
		}
	}
	for _, pub := range pubs {
		lookup, ok := r.p.SnapshotJobLookup(pub)
		if !ok {
			continue
		}
		if err := waitIdle(r.waitCtx, r.s, r.distributor, pub, lookup, r.out); err != nil {
			r.spent(op.Seq, "waiting for the generation of "+pub, err, false)
			return false
		}
		if !r.retake(op.Seq, pub) {
			return false
		}
	}
	return true
}

func hasFold(xs []string, s string) bool {
	for _, x := range xs {
		if strings.EqualFold(x, s) {
			return true
		}
	}
	return false
}

// deliveryWait waits, within -wait, for every delivery owed (R50, R51),
// after the last operation.
func (r *runner) deliveryWait() {
	if len(r.tr.records) == 0 {
		return
	}
	r.waited = true
	r.waitFor(func(*record) bool { return true })
}

// waitFor polls the history every second until no record that in selects
// is pending, -wait is spent or the run is interrupted. At each pass, a
// record whose job ran at T is retaken once the job reads idle (R50), and
// an agent job_start whose job reads idle while its delivery is still
// owed runs once more, and not again (R51).
func (r *runner) waitFor(in func(*record) bool) {
	told := map[string]bool{}
	for {
		if err := r.tr.poll(r.waitCtx, r.s, r.p); err != nil {
			if r.waitCtx.Err() == nil {
				r.note("the wait for deliveries stopped: %v", err)
			}
			return
		}
		var pend []*record
		for _, rec := range r.tr.records {
			if rec.run == "" && rec.unlisted == "" && in(rec) {
				pend = append(pend, rec)
			}
		}
		if len(pend) == 0 {
			return
		}
		for _, rec := range pend {
			if k := strings.ToLower(rec.Publication); !told[k] {
				told[k] = true
				fmt.Fprintf(r.out, "waiting for the deliveries of %s\n", rec.Publication)
			}
		}
		r.retakeIdle(pend)
		if r.stopped {
			return
		}
		r.startAgain(pend)
		if r.stopped {
			return
		}
		if !r.sleep(r.waitCtx) {
			return
		}
	}
}

// retakeIdle retakes the pending records whose job ran at T once that job
// reads idle (R50).
func (r *runner) retakeIdle(pend []*record) {
	done := map[string]bool{}
	for _, rec := range pend {
		k := strings.ToLower(rec.Publication)
		if !rec.RunningAtT || done[k] {
			continue
		}
		done[k] = true
		if r.jobIdle(r.distributor, rec.Publication) {
			ctx, cancel := r.readCtx()
			if err := r.tr.retake(ctx, r.s, r.p, rec.Publication); err != nil {
				r.note("retake the deliveries owed by %s: %v", rec.Publication, err)
			}
			cancel()
		}
	}
}

// jobIdle reads once whether the snapshot job of pub is idle; false on an
// error.
func (r *runner) jobIdle(server, pub string) bool {
	lookup, ok := r.p.SnapshotJobLookup(pub)
	if !ok {
		return false
	}
	return r.idle(server, lookup)
}

// idle reads idleQuery(lookup) once at server; false on an error (the
// lookup throws for a job that does not exist).
func (r *runner) idle(server, lookup string) bool {
	ctx, cancel := r.readCtx()
	defer cancel()
	conn, err := r.s.conn(ctx, server)
	if err != nil {
		return false
	}
	var v int
	if err := conn.QueryRowContext(ctx, idleQuery(lookup)).Scan(&v); err != nil {
		return false
	}
	return v == 1
}

// startAgain runs once more, and not again, every agent job_start whose
// job reads idle while a delivery to its subscription is still owed
// (R51): the printed statement, logged "again".
func (r *runner) startAgain(pend []*record) {
	for _, sr := range r.starts {
		if sr.again {
			continue
		}
		owed := false
		for _, rec := range pend {
			owed = owed || hasFold(sr.subs, rec.Subscription)
		}
		if !owed || !r.idle(sr.op.Server, sr.op.Call.Prologue) {
			continue
		}
		sr.again = true
		if !r.runAgentStart(sr.op, true) {
			return
		}
	}
}

// finish is every way out (R45, R46, R48, R53): the restores armed and not
// run, the unlock, the deliveries, then the last lines.
func (r *runner) finish() {
	r.jb.before = func(seq int) { r.log(r.ops[seq], false) }
	r.jb.after = func(seq int, t0 time.Time, err error) {
		if err == nil {
			r.ok(t0)
			return
		}
		fmt.Fprintf(r.out, "  failed: %s\n", r.failure(seq, err).text())
	}
	r.res.JobsLeftDisabled = r.jb.restoreRemaining(r.s, r.p, r.o.Timeout, r.secret)
	for seq, ok := range r.jb.ran {
		if ok {
			r.ran[seq] = true
		}
	}
	r.describeDeliveries()
	r.s.close()
	r.res.LockLost = len(r.s.lost) > 0
	r.res.LockReleaseFailures = append([]string(nil), r.s.releaseFailures...)
	r.res.Deliveries = r.tr.results(r.o.Wait == 0 || !r.waited)
	r.res.Ran, r.res.Remaining = nil, nil
	for _, op := range r.p.Operations {
		if r.ran[op.Seq] {
			r.res.Ran = append(r.res.Ran, op.Seq)
		} else {
			r.res.Remaining = append(r.res.Remaining, op.Seq)
		}
	}
	r.printEnd()
}

// describeDeliveries reads, before the unlock, the job state and last
// history of every delivery not confirmed (R53), under a fresh context on
// a distributor connection that passed the probe of R46.
func (r *runner) describeDeliveries() {
	if r.tr == nil || len(r.tr.records) == 0 {
		return
	}
	ctx, cancel := r.s.fresh(context.Background())
	defer cancel()
	if _, _, err := r.s.healthy(ctx, r.distributor); err != nil {
		return
	}
	r.tr.describe(ctx, r.s, r.p)
}

// printEnd prints the last lines (R53).
func (r *runner) printEnd() {
	ran := r.res.Outcome == OutcomeApplied || r.res.Outcome == OutcomeFailed ||
		r.res.Outcome == OutcomeInterrupted || r.res.Outcome == OutcomeUnconfirmed
	k, u, a := 0, 0, 0
	if ran {
		for _, d := range r.res.Deliveries {
			switch d.Status {
			case deliveryConfirmed:
				k++
			case deliveryNotAwaited:
				a++
			default:
				u++
			}
			fmt.Fprintln(r.out, deliveryLine(d))
		}
	}
	for _, j := range r.res.JobsLeftDisabled {
		fmt.Fprintf(r.out, "job left disabled: %s\n", j)
	}
	for range r.s.lost {
		fmt.Fprintln(r.out, "lock lost with the connection")
	}
	for _, f := range r.res.LockReleaseFailures {
		fmt.Fprintln(r.out, f)
	}
	if !ran {
		return
	}
	if f := r.res.Failure; f != nil {
		fmt.Fprintf(r.out, "Failed at operation %d: %s\n", f.Seq, f.text())
	}
	if len(r.res.Remaining) > 0 {
		fmt.Fprintf(r.out, "Remaining: %s\n", seqList(r.res.Remaining))
	}
	fmt.Fprintf(r.out, "Applied %d of %d operations; deliveries: %d confirmed, %d unconfirmed, %d not awaited.\n",
		len(r.res.Ran), r.n, k, u, a)
}

// maskWriter writes every line through mask (R53): server messages can
// echo a bound value. Each write is one whole line or more, so a value is
// never split between two writes.
type maskWriter struct {
	w      io.Writer
	values *[]string
}

func (m maskWriter) Write(b []byte) (int, error) {
	if _, err := io.WriteString(m.w, mask(string(b), *m.values)); err != nil {
		return 0, err
	}
	return len(b), nil
}
