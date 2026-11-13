// Package apply runs a plan (spec step 4): it executes the statements of
// plan.Plan.Statements, byte for byte as plan -sql prints them, on one
// pinned connection per server, under the application lock, and reads what
// it needs to wait, retry and confirm. Its own statements are reads, the
// ROLLBACK of a transaction a refused call left open, and the lock (spec
// anti-goal 2).
package apply

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/rudi-bruchez/sqlserver-replication/internal/plan"
)

// Servers maps a server name of the plan to its pool; lookups ignore case.
type Servers map[string]*sql.DB

// errTranOpen is a statement that succeeded and left a transaction open,
// which exec has rolled back (R46).
var errTranOpen = errors.New("left a transaction open")

// defaultTimeout bounds apply's own reads when no -timeout is given: the
// default of -timeout.
const defaultTimeout = 2 * time.Minute

// pinned is the connection of one server, kept for the whole run (R46).
type pinned struct {
	conn     *sql.Conn
	database string // the current database as apply last set it; "" unknown
	discard  bool   // a release failed on it: never pooled again (R45)
}

// heldLock is an application lock the session holds (R45).
type heldLock struct {
	server, database, resource string
	conn                       *sql.Conn
}

// session holds one pinned connection per server name, compared without
// regard to case (R7, R46), and the locks taken on them.
type session struct {
	pools   map[string]*sql.DB // lower-case name: the pool
	conns   map[string]*pinned // lower-case name: the pinned connection
	timeout time.Duration      // bounds apply's own reads (-timeout)
	locks   []heldLock
	// lost is the locks whose connection healthy replaced: the end of the
	// run prints "lock lost with the connection" for each (R46).
	lost []heldLock
	// releaseFailures is every failed release, unlock's or close's, as
	// "lock release failed on <server>.<database>: <message>", for the run
	// to report (R45): never swallowed.
	releaseFailures []string
}

// newSession takes no connection yet. Two names of s that differ only in
// case are one server: the first in sorted order gives the pool.
func newSession(s Servers) *session {
	names := make([]string, 0, len(s))
	for n := range s {
		names = append(names, n)
	}
	sort.Strings(names)
	pools := map[string]*sql.DB{}
	for _, n := range names {
		k := strings.ToLower(n)
		if _, ok := pools[k]; !ok {
			pools[k] = s[n]
		}
	}
	return &session{pools: pools, conns: map[string]*pinned{}, timeout: defaultTimeout}
}

// fresh is a context bounded by the session timeout that the interrupt does
// not cancel: the @@TRANCOUNT read, its ROLLBACK and the probes run under it
// (R46, panel M).
func (s *session) fresh(ctx context.Context) (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.WithoutCancel(ctx), s.timeout)
}

// conn is the pinned connection of server, taken from its pool the first
// time.
func (s *session) conn(ctx context.Context, server string) (*sql.Conn, error) {
	p, err := s.pin(ctx, server)
	if err != nil {
		return nil, err
	}
	return p.conn, nil
}

func (s *session) pin(ctx context.Context, server string) (*pinned, error) {
	k := strings.ToLower(server)
	if p, ok := s.conns[k]; ok {
		return p, nil
	}
	db, ok := s.pools[k]
	if !ok {
		return nil, fmt.Errorf("no connection to server %s", server)
	}
	c, err := db.Conn(ctx)
	if err != nil {
		return nil, fmt.Errorf("connect to %s: %w", server, err)
	}
	p := &pinned{conn: c}
	s.conns[k] = p
	return p, nil
}

// reconnect discards the pinned connection of server and takes a new one
// from the same pool. The locks taken on the old one are lost with it (the
// discard ends that session, and with it the locks it held).
func (s *session) reconnect(ctx context.Context, server string) (*sql.Conn, error) {
	k := strings.ToLower(server)
	if p, ok := s.conns[k]; ok {
		delete(s.conns, k)
		kept := s.locks[:0:0]
		for _, l := range s.locks {
			if l.conn == p.conn {
				s.lost = append(s.lost, l)
			} else {
				kept = append(kept, l)
			}
		}
		s.locks = kept
		_ = discard(p.conn) // the connection already failed; nothing to report
	}
	return s.conn(ctx, server)
}

// healthy probes the pinned conn under a fresh -timeout context and
// replaces it from the same pool when the probe fails (R46). A transaction
// the probe finds open is rolled back.
func (s *session) healthy(ctx context.Context, server string) (conn *sql.Conn, replaced bool, err error) {
	if _, ok := s.conns[strings.ToLower(server)]; ok {
		c, _ := s.conn(ctx, server)
		if _, perr := s.tranCount(ctx, c); perr == nil {
			return c, false, nil
		}
		replaced = true
	}
	fctx, cancel := s.fresh(ctx)
	defer cancel()
	if replaced {
		conn, err = s.reconnect(fctx, server)
	} else {
		conn, err = s.conn(fctx, server)
	}
	if err != nil {
		return nil, replaced, err
	}
	if _, err := s.tranCount(ctx, conn); err != nil {
		return nil, replaced, err
	}
	return conn, replaced, nil
}

// tranCount reads @@TRANCOUNT under a fresh context and, above 0, rolls the
// transaction back; it returns what it read.
func (s *session) tranCount(ctx context.Context, conn *sql.Conn) (int, error) {
	fctx, cancel := s.fresh(ctx)
	defer cancel()
	var n int
	if err := conn.QueryRowContext(fctx, "SELECT @@TRANCOUNT;").Scan(&n); err != nil {
		return 0, fmt.Errorf("read @@TRANCOUNT: %w", err)
	}
	if n > 0 {
		if _, err := conn.ExecContext(fctx, "IF @@TRANCOUNT > 0 ROLLBACK;"); err != nil {
			return n, fmt.Errorf("roll back the open transaction: %w", err)
		}
	}
	return n, nil
}

// alive probes conn with SELECT 1 under ctx.
func (s *session) alive(ctx context.Context, conn *sql.Conn) bool {
	var one int
	return conn.QueryRowContext(ctx, "SELECT 1;").Scan(&one) == nil
}

func quoteName(s string) string { return "[" + strings.ReplaceAll(s, "]", "]]") + "]" }

// use sets the current database of a pinned connection when it differs
// from the one apply last set (R46).
func (s *session) use(ctx context.Context, p *pinned, database string) error {
	if database == "" || strings.EqualFold(p.database, database) {
		return nil
	}
	if _, err := p.conn.ExecContext(ctx, "USE "+quoteName(database)+";"); err != nil {
		p.database = ""
		return fmt.Errorf("USE %s: %w", database, err)
	}
	p.database = database
	return nil
}

// exec runs one statement by R46 and returns the driver error, or
// errTranOpen when it succeeded and left a transaction, rolled back; a
// refused statement that left one returns both, joined. The
// statement runs under ctx, the interrupt context; the @@TRANCOUNT read and
// its ROLLBACK under a fresh one. A failed read is returned with the
// statement's error.
func (s *session) exec(ctx context.Context, st plan.Statement, secret func(string) (string, bool)) error {
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
	_, execErr := p.conn.ExecContext(ctx, st.Text, args...)
	n, readErr := s.tranCount(ctx, p.conn)
	if execErr != nil && n > 0 && only266(execErr) {
		// Through sp_executesql a success that leaves a transaction comes
		// back as Msg 266 alone: it is errTranOpen, not a refusal.
		execErr = nil
	}
	switch {
	case execErr != nil && readErr != nil:
		return errors.Join(execErr, readErr)
	case execErr != nil && n > 0:
		// R47 tolerates 18752 only when @@TRANCOUNT was 0: the caller
		// tests errors.Is(err, errTranOpen).
		return errors.Join(execErr, errTranOpen)
	case execErr != nil:
		return execErr
	case readErr != nil:
		return readErr
	case n > 0:
		return errTranOpen
	}
	return nil
}

// lock takes the application lock resource on the pinned connection of
// server, in database, and records it for close (R45). A lock the session
// already holds there is not taken again: the Session owner is reentrant,
// and one unlock would leave it held (Task 6 review, P7).
func (s *session) lock(ctx context.Context, server, database, resource string) error {
	p, err := s.pin(ctx, server)
	if err != nil {
		return err
	}
	for _, l := range s.locks {
		if l.conn == p.conn && l.resource == resource && strings.EqualFold(l.database, database) {
			return nil
		}
	}
	p.database = ""
	err = lock(ctx, p.conn, database, resource)
	if err == nil {
		p.database = database
		s.locks = append(s.locks, heldLock{server: server, database: database, resource: resource, conn: p.conn})
	}
	return err
}

// unlock releases resource on the pinned connection of server, in
// database, and forgets the session's lock on that server and resource. A
// failed release is kept in releaseFailures and marks the connection to be
// discarded by close: the lock may still be held, and a pooled session
// would keep it (R45, panel C, M).
func (s *session) unlock(ctx context.Context, server, database, resource string) error {
	p, err := s.pin(ctx, server)
	if err != nil {
		return err
	}
	kept := s.locks[:0:0]
	for _, l := range s.locks {
		if !(l.conn == p.conn && l.resource == resource) {
			kept = append(kept, l)
		}
	}
	s.locks = kept
	p.database = ""
	err = unlock(ctx, p.conn, database, resource)
	if err != nil {
		p.discard = true
		s.releaseFailures = append(s.releaseFailures, fmt.Sprintf("lock release failed on %s.%s: %v", server, database, err))
		return err
	}
	p.database = database
	return nil
}

// close releases the locks still held, the last taken first, under a fresh
// context (R45), then gives every pinned connection back: a connection
// whose release failed is discarded, so that its session ends with the
// lock instead of returning to the pool with it. close can be called more
// than once.
func (s *session) close() {
	ctx, cancel := s.fresh(context.Background())
	defer cancel()
	for i := len(s.locks) - 1; i >= 0; i-- {
		l := s.locks[i]
		if !s.alive(ctx, l.conn) {
			// The session ended (killed, network): the lock went with it
			// (R46 "lock lost with the connection"), there is nothing to
			// release; the conn is not pooled again.
			s.lost = append(s.lost, l)
			if p, ok := s.conns[strings.ToLower(l.server)]; ok && p.conn == l.conn {
				p.discard = true
			}
			continue
		}
		_ = s.unlock(ctx, l.server, l.database, l.resource) // a failure is kept in releaseFailures
	}
	s.locks = nil
	for k, p := range s.conns {
		if p.discard {
			if err := discard(p.conn); err != nil {
				s.releaseFailures = append(s.releaseFailures, fmt.Sprintf("discard the session of %s: %v", k, err))
			}
		} else {
			p.conn.Close()
		}
		delete(s.conns, k)
	}
}
