package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"

	"github.com/rudi-bruchez/sqlserver-replication/internal/apply"
	"github.com/rudi-bruchez/sqlserver-replication/internal/plan"
	"github.com/rudi-bruchez/sqlserver-replication/internal/reader"
)

// The run and the checks runApply calls; the tests replace them.
var (
	applyRun = apply.Run
	// isTerminal tells whether f, standard input, is a terminal: a
	// character device (R44). nil is not one.
	isTerminal = func(f *os.File) bool {
		if f == nil {
			return false
		}
		fi, err := f.Stat()
		return err == nil && fi.Mode()&os.ModeCharDevice != 0
	}
	distributionDBOf = reader.DistributionDB
)

// noTerminal is the refusal of R44 for a run that could not be confirmed.
const noTerminal = "apply needs a terminal to confirm, or -auto-approve"

func parseApplyFlags(args []string, stderr io.Writer) (*planFlags, error) {
	return parseFlags("apply", args, stderr)
}

// runApply applies a desired file (spec "apply", R44): the flags, the
// terminal check before any connection, the connections plan opens, then
// apply.Run, which takes the locks, reads and builds the plan once, asks
// and runs it. It returns the exit code of R52.
func runApply(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	f, err := parseApplyFlags(args, stderr)
	if err != nil {
		return usageExit(err, stderr)
	}
	if !f.autoApprove {
		file, _ := stdin.(*os.File)
		if !isTerminal(file) {
			fmt.Fprintln(stderr, "sqlrepl:", noTerminal)
			return 2
		}
	}
	if p, err := deferRefusal(f); err != nil {
		return errorExit(err, stderr)
	} else if p != nil {
		fmt.Fprint(stdout, p.Summary())
		return 1
	}

	ctx := context.Background()
	w, err := prepare(ctx, f)
	if err != nil {
		return errorExit(err, stderr)
	}
	defer w.close()
	unusedServers(stderr, w.desired, append(w.pulls, w.distName), f.servers)

	opt := plan.Options{DeferFullSnapshot: f.deferFull, Wait: f.wait}
	t := apply.Target{
		Server:   w.desired.Publisher.Server,
		Database: w.probe.Name,
		Servers:  w.servers(),
		Plan: func(ctx context.Context) (*plan.Plan, error) {
			return w.compute(ctx, opt)
		},
	}
	// The second lock, only for a file that declares a part shared with
	// other publication databases (R45).
	if w.desired.Distributor != nil || w.desired.AgentProfiles != nil {
		t.Distributor = w.distName
		if t.DistributionDB, err = w.distributionDB(ctx); err != nil {
			return errorExit(err, stderr)
		}
	}

	// From here on an interrupt is the run's: Run restores and unlocks
	// before it returns (R48). Before, nothing is held.
	intr := make(chan os.Signal, 1)
	signal.Notify(intr, os.Interrupt, syscall.SIGTERM)
	defer signal.Stop(intr)
	out := &promptWriter{w: stdout}
	o := apply.Options{
		Wait:        f.wait,
		Timeout:     f.timeout,
		AutoApprove: f.autoApprove,
		Secret:      secretEnv,
		Out:         out,
		Interrupt:   intr,
	}
	if !f.autoApprove {
		o.Confirm = confirmer(stdin, out)
	}
	res, err := applyRun(ctx, t, o)
	if err != nil {
		// Before any operation: a lock held or not taken, the plan not
		// read (R53: to standard error).
		return errorExit(err, stderr)
	}
	return res.ExitCode()
}

// servers is Target.Servers: every subscriber to its pool, the distributor
// to its pool and the publisher to its master pool. The publisher is set
// last, which decides only an identical key: apply's session folds names to
// lower case and keeps the first of a case variant in sorted order, whose
// pool reaches the same server (the -server lookup ignores case).
func (w *wiring) servers() apply.Servers {
	s := apply.Servers{}
	for name, db := range w.subs {
		s[name] = db
	}
	if w.dist != nil {
		s[w.distName] = w.dist
	}
	s[w.desired.Publisher.Server] = w.master
	return s
}

// distributionDB tells that the distributor lock is due (R45; the lock
// itself is taken in master, R45a): the file's distributor database, else
// the one the distributor records for the publisher, "" when there is no
// distributor (Run then refuses every shared operation).
func (w *wiring) distributionDB(ctx context.Context) (string, error) {
	if d := w.desired.Distributor; d != nil && d.Database != "" {
		return d.Database, nil
	}
	if w.dist == nil {
		return "", nil
	}
	ctx, cancel := context.WithTimeout(ctx, w.f.timeout)
	defer cancel()
	db, err := distributionDBOf(ctx, w.dist, w.desired.Publisher.Server)
	if err != nil {
		return "", fmt.Errorf("distributor: %w", err)
	}
	return db, nil
}

// confirmer is Options.Confirm (R44): it writes the question, reads one
// line, and is true only for the line yes. Through a promptWriter, the
// question stays open until a line ends it, so that what is printed next
// (Apply cancelled. after Ctrl-C or end of input) starts on a line of its
// own.
func confirmer(r io.Reader, w io.Writer) func(string) (bool, error) {
	br := bufio.NewReader(r)
	return func(question string) (bool, error) {
		pw, _ := w.(*promptWriter)
		var err error
		if pw != nil {
			err = pw.prompt(question)
		} else {
			_, err = io.WriteString(w, question)
		}
		if err != nil {
			return false, err
		}
		line, err := br.ReadString('\n')
		if err != nil && !errors.Is(err, io.EOF) {
			return false, err
		}
		if pw != nil {
			// A terminated line was echoed by the terminal; one ended by
			// end of input was not.
			pw.answered(strings.HasSuffix(line, "\n"))
		}
		return strings.TrimRight(line, "\r\n") == "yes", nil
	}
}

// promptWriter is standard output during a run: after a question no line
// has ended, it writes a newline before anything else.
type promptWriter struct {
	mu   sync.Mutex
	w    io.Writer
	open bool // a question awaits its line
}

func (p *promptWriter) Write(b []byte) (int, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.open && len(b) > 0 {
		p.open = false
		if _, err := io.WriteString(p.w, "\n"); err != nil {
			return 0, err
		}
	}
	return p.w.Write(b)
}

func (p *promptWriter) prompt(question string) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	_, err := io.WriteString(p.w, question)
	p.open = err == nil
	return err
}

// answered closes the question: echoed tells that the terminal ended its
// line, else the newline is written now.
func (p *promptWriter) answered(echoed bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.open && !echoed {
		io.WriteString(p.w, "\n")
	}
	p.open = false
}
