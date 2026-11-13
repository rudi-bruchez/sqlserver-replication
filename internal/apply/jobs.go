package apply

import (
	"context"
	"errors"
	"fmt"
	"io"
	"sort"
	"strings"
	"time"

	"github.com/rudi-bruchez/sqlserver-replication/internal/plan"
)

// The jobs of a run (R48, R49): the restore each job_disable arms, the
// restores run on every way out, the idle wait on a job and the start of a
// printed job_start. Every text these write to a server is a printed
// plan.Statement (spec anti-goal 2): a restore is the plan's own
// job_restore, never a batch built here.

// restoreFor is the job_restore of the plan with the Path of disable: the
// restore of the file's job_enabled (R23), or for a dropped publication the
// guarded restore of the value found (R61). ok is false for an operation
// that is not a job_disable or whose job the plan does not restore.
func restoreFor(p *plan.Plan, disable plan.Operation) (plan.Operation, bool) {
	if disable.Kind != "job_disable" {
		return plan.Operation{}, false
	}
	for _, op := range p.Operations {
		if op.Kind == "job_restore" && op.Path == disable.Path {
			return op, true
		}
	}
	return plan.Operation{}, false
}

// jobs is the restores a run has armed and those it has run.
type jobs struct {
	armed []int        // Seq of restores, in plan order
	ran   map[int]bool // Seq of restores run successfully
	// before and after, when set, print a restore restoreRemaining runs as
	// any statement is printed (R53, spec anti-goal 2): its line and text
	// before, its outcome after.
	before func(seq int)
	after  func(seq int, t0 time.Time, err error)
}

// arm records the restore of disable; the caller arms it before the
// disable is sent, not after it returns (R48, panel XD, XN): a disable that
// committed while its call returned an error is still restored.
func (j *jobs) arm(p *plan.Plan, disable plan.Operation) {
	r, ok := restoreFor(p, disable)
	if !ok {
		return
	}
	if j.ran == nil {
		j.ran = map[int]bool{}
	}
	for _, s := range j.armed {
		if s == r.Seq {
			return
		}
	}
	j.armed = append(j.armed, r.Seq)
	sort.Ints(j.armed)
}

// done marks the restore seq run, as the run does for a restore it runs in
// plan order on success.
func (j *jobs) done(seq int) {
	if j.ran == nil {
		j.ran = map[int]bool{}
	}
	j.ran[seq] = true
}

// restoreRemaining runs the armed restores not run yet (R48) and returns
// the paths left disabled. Each runs, in plan order, by session.restore:
// under a context of its own, bounded by timeout and cancelled by no
// interrupt, on the server's pinned connection once healthy has cleared its
// @@TRANCOUNT, or on a new one from the same pool when its probe fails (a
// cancelled statement leaves the connection bad, Task 6); a restore that
// fails on a connection that no longer answers, with time left, reconnects
// once and runs again. What still fails is left disabled.
//
// The budget is per restore, not shared (Task 7 review, minor 3): every
// armed restore gets its chance, those at a healthy server included, after
// one at a blocked server spent its own. The worst case is the sum: a lock
// on one job's row of msdb.dbo.sysjobs blocks sp_update_job of every job at
// that server (review probe E), so n restores there take n times timeout,
// and a connect to a server that withholds the prelogin waits the driver's
// connection timeout instead of the restore's deadline (go-mssqldb ignores
// the context there, review probe F), once per restore that connects.
func (j *jobs) restoreRemaining(s *session, p *plan.Plan, timeout time.Duration, secret func(string) (string, bool)) []string {
	bySeq := map[int]plan.Statement{}
	for _, st := range p.Statements() {
		bySeq[st.Seq] = st
	}
	paths := map[int]string{}
	for _, op := range p.Operations {
		paths[op.Seq] = op.Path
	}
	var left []string
	for _, seq := range j.armed {
		if j.ran[seq] {
			continue
		}
		st, ok := bySeq[seq]
		if !ok {
			left = append(left, paths[seq])
			continue
		}
		if j.before != nil {
			j.before(seq)
		}
		t0 := time.Now()
		err := s.restore(st, timeout, secret)
		if j.after != nil {
			j.after(seq, t0, err)
		}
		if err != nil {
			left = append(left, paths[seq])
			continue
		}
		j.done(seq)
	}
	return left
}

// restore runs one printed job_restore by restoreRemaining's rules. Its
// deadline bounds every step, the probe, the @@TRANCOUNT reads and the
// reconnect included: the session's fresh contexts end at it while the
// restore runs (session.bound), except for a connect the driver does not
// bound by its context (restoreRemaining). A failure once the deadline is
// spent is not retried: the retry would run past it, and the next
// restore's probe replaces a connection the timeout left bad.
func (s *session) restore(st plan.Statement, timeout time.Duration, secret func(string) (string, bool)) error {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	deadline, _ := ctx.Deadline()
	s.bound = deadline
	defer func() { s.bound = time.Time{} }()
	if _, _, err := s.healthy(ctx, st.Server); err != nil {
		return err
	}
	err := s.exec(ctx, st, secret)
	if err == nil {
		return nil
	}
	if ctx.Err() != nil {
		return err // the timeout is spent: no time left for a retry
	}
	conn, cerr := s.conn(ctx, st.Server)
	if cerr == nil && s.alive(ctx, conn) {
		return err // the server refused the restore: not a connection error
	}
	if _, rerr := s.reconnect(ctx, st.Server); rerr != nil {
		return errors.Join(err, rerr)
	}
	return s.exec(ctx, st, secret)
}

// idleQuery is the read of R48: the job lookup of the plan (R62), then
// whether plan.JobIdle holds, 1 or 0.
func idleQuery(lookup string) string {
	return strings.TrimRight(lookup, "\n") + "\nSELECT CASE WHEN " + plan.JobIdle + " THEN 1 ELSE 0 END;"
}

// idlePoll is the interval between two reads of waitIdle (R48: every
// second).
const idlePoll = time.Second

// waitIdle reads idleQuery(lookup) on the pinned connection of server every
// second until the job reads idle, bounded by ctx (-timeout after a
// job_disable, -wait for a generation, R52). The line "waiting for the
// snapshot job of <publication> to be idle" is printed to out once, when
// the first read finds the job busy, so that it proves a wait happened; an
// idle job returns at once and prints nothing.
func waitIdle(ctx context.Context, s *session, server, publication, lookup string, out io.Writer) error {
	q := idleQuery(lookup)
	printed := false
	for {
		conn, err := s.conn(ctx, server)
		if err != nil {
			return err
		}
		var idle int
		if err := conn.QueryRowContext(ctx, q).Scan(&idle); err != nil {
			return fmt.Errorf("read whether the snapshot job of %s is idle: %w", publication, err)
		}
		if idle == 1 {
			return nil
		}
		if !printed {
			fmt.Fprintf(out, "waiting for the snapshot job of %s to be idle\n", publication)
			printed = true
		}
		t := time.NewTimer(idlePoll)
		select {
		case <-ctx.Done():
			t.Stop()
			return fmt.Errorf("the snapshot job of %s is not idle: %w", publication, ctx.Err())
		case <-t.C:
		}
	}
}

// start runs a printed job_start and reads its started row (R49, R62): 1
// when its JobIdle guard let sp_start_job run and it returned 0, 0 when the
// guard skipped it. On any 22022 the batch returns an error and no row
// (Task 2 review): busy (a run in progress, someone else's, or one that
// started between the guard and the call) is started false with no error,
// SQL Server Agent stopped and every other error an error. The statement
// runs under ctx; the @@TRANCOUNT read after it, as exec does (R46).
func (s *session) start(ctx context.Context, st plan.Statement) (started bool, err error) {
	p, err := s.pin(ctx, st.Server)
	if err != nil {
		return false, err
	}
	if err := s.use(ctx, p, st.Database); err != nil {
		return false, err
	}
	started, runErr := readStarted(ctx, p, st.Text)
	n, readErr := s.tranCount(ctx, p.conn)
	return startOutcome(started, runErr, n, readErr)
}

// startOutcome is the decision of start from what the batch returned
// (started, runErr) and the @@TRANCOUNT read after it (n, readErr): a busy
// 22022 with no transaction left is started false and no error, SQL
// Server Agent stopped and every other error an error, a transaction left
// open errTranOpen; only a batch with no error gives its started row.
func startOutcome(started bool, runErr error, n int, readErr error) (bool, error) {
	if runErr != nil {
		if c, _ := classify(runErr); c == classBusy && readErr == nil && n == 0 {
			return false, nil
		}
		return false, errors.Join(runErr, readErr)
	}
	switch {
	case readErr != nil:
		return false, readErr
	case n > 0:
		return false, errTranOpen
	}
	return started, nil
}

// readStarted runs text and scans its one row, the started column.
func readStarted(ctx context.Context, p *pinned, text string) (bool, error) {
	rows, err := p.conn.QueryContext(ctx, text)
	if err != nil {
		return false, err
	}
	var started, got bool
	if rows.Next() {
		if err := rows.Scan(&started); err != nil {
			rows.Close()
			return false, err
		}
		got = true
	}
	err = rows.Err()
	if cerr := rows.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return false, err
	}
	if !got {
		return false, errors.New("the job_start returned no started row")
	}
	return started, nil
}
