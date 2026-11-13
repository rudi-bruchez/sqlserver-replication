package main

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/rudi-bruchez/sqlserver-replication/internal/apply"
	"github.com/rudi-bruchez/sqlserver-replication/internal/plan"
)

func TestApplyFlags(t *testing.T) {
	var stderr bytes.Buffer
	f, err := parseApplyFlags([]string{"-f", "x.yaml", "-auto-approve", "-wait", "5m"}, &stderr)
	if err != nil {
		t.Fatal(err)
	}
	if f.file != "x.yaml" || !f.autoApprove || f.wait != 5*time.Minute || f.timeout != 2*time.Minute || f.env != ".env" {
		t.Errorf("flags = %+v", f)
	}
	fakeConnect(t, func(context.Context, string, string, connParams) (*sql.DB, error) {
		t.Error("connect called")
		return nil, errors.New("no connection in this test")
	})
	for _, bad := range []string{"-sql", "-json"} {
		stderr.Reset()
		if code := runApply([]string{"-f", "x.yaml", "-auto-approve", bad}, nil, &bytes.Buffer{}, &stderr); code != 2 {
			t.Errorf("%s: exit %d, want 2 (a usage error)", bad, code)
		}
		// The message once: the flag package prints it (minor 10).
		if n := strings.Count(stderr.String(), "flag provided but not defined"); n != 1 {
			t.Errorf("%s: message printed %d times:\n%s", bad, n, stderr.String())
		}
	}
}

// R44: without -auto-approve and without a terminal on standard input,
// apply exits 2 before connecting.
func TestApplyNoTerminal(t *testing.T) {
	old := isTerminal
	isTerminal = func(*os.File) bool { return false }
	t.Cleanup(func() { isTerminal = old })
	connected := false
	fakeConnect(t, func(context.Context, string, string, connParams) (*sql.DB, error) {
		connected = true
		return nil, errors.New("no connection in this test")
	})
	var stdout, stderr bytes.Buffer
	code := runApply([]string{"-f", planFile(t, smallFile), "-env", noEnv(t)}, strings.NewReader("yes\n"), &stdout, &stderr)
	if code != 2 {
		t.Errorf("exit %d, want 2", code)
	}
	if !strings.Contains(stderr.String(), "apply needs a terminal to confirm, or -auto-approve") {
		t.Errorf("stderr = %q, want the message of R44", stderr.String())
	}
	if connected {
		t.Error("connect called before the terminal check")
	}
}

// Only the line yes confirms, and the question is written once (R44).
func TestConfirmer(t *testing.T) {
	for in, want := range map[string]bool{"yes\n": true, "yes\r\n": true, "y\n": false, "YES\n": false, "": false, "yes please\n": false} {
		var out bytes.Buffer
		ok, err := confirmer(strings.NewReader(in), &out)("Apply? Type yes to apply: ")
		if err != nil {
			t.Errorf("%q: %v", in, err)
		}
		if ok != want {
			t.Errorf("%q: %t, want %t", in, ok, want)
		}
		if got := strings.Count(out.String(), "Apply? Type yes to apply: "); got != 1 || out.Len() != len("Apply? Type yes to apply: ") {
			t.Errorf("%q: question written %d times, output %q", in, got, out.String())
		}
	}
	// Through the run's writer, a question that no line ended (end of
	// input, Ctrl-C) is followed by a newline (minor 2).
	const q = "Apply? Type yes to apply: "
	for in, want := range map[string]string{"yes\n": q, "no\n": q, "": q + "\n", "yes": q + "\n"} {
		var out bytes.Buffer
		if _, err := confirmer(strings.NewReader(in), &promptWriter{w: &out})(q); err != nil {
			t.Fatal(err)
		}
		if out.String() != want {
			t.Errorf("%q: output %q, want %q", in, out.String(), want)
		}
	}
	var out bytes.Buffer
	pw := &promptWriter{w: &out}
	pw.prompt(q)
	fmt.Fprintln(pw, "Apply cancelled.")
	fmt.Fprintln(pw, "next")
	if want := q + "\nApply cancelled.\nnext\n"; out.String() != want {
		t.Errorf("interrupt at the question: %q, want %q", out.String(), want)
	}
}

// The exit code of apply is its Result's (R52); an error of Run, the lock
// held among them, is exit 1 with the sqlrepl: prefix.
func TestApplyExitCodes(t *testing.T) {
	newFakeRun(t, nil)
	var got apply.Target
	var gotOpt apply.Options
	fake := func(res *apply.Result, err error) {
		applyRun = func(_ context.Context, tg apply.Target, o apply.Options) (*apply.Result, error) {
			got, gotOpt = tg, o
			return res, err
		}
	}
	old := applyRun
	t.Cleanup(func() { applyRun = old })
	pending := []apply.Delivery{{Publication: "pub", Subscription: "s/db", Status: "unconfirmed"}}
	cases := []struct {
		res  *apply.Result
		want int
	}{
		{&apply.Result{Outcome: apply.OutcomeEmpty}, 0},
		{&apply.Result{Outcome: apply.OutcomeApplied}, 0},
		{&apply.Result{Outcome: apply.OutcomeApplied, Deliveries: pending}, 3},
		{&apply.Result{Outcome: apply.OutcomeRefused}, 1},
		{&apply.Result{Outcome: apply.OutcomeCancelled}, 1},
		{&apply.Result{Outcome: apply.OutcomeFailed, Remaining: []int{2}}, 1},
		{&apply.Result{Outcome: apply.OutcomeInterrupted, Remaining: []int{2}}, 1},
		{&apply.Result{Outcome: apply.OutcomeInterrupted, Deliveries: pending}, 3},
		{&apply.Result{Outcome: apply.OutcomeUnconfirmed, Remaining: []int{3}}, 3},
		{&apply.Result{Outcome: apply.OutcomeApplied, LockReleaseFailures: []string{"lock release failed on P.D: x"}}, 1},
	}
	for _, c := range cases {
		fake(c.res, nil)
		var stdout, stderr bytes.Buffer
		if code := runApply([]string{"-f", planFile(t, subscribedFile), "-env", noEnv(t), "-auto-approve"}, nil, &stdout, &stderr); code != c.want {
			t.Errorf("%s %v: exit %d, want %d (stderr %q)", c.res.Outcome, c.res.Remaining, code, c.want, stderr.String())
		}
	}
	// What runApply hands Run: the file declares a distributor, so the
	// second lock's place is set (R45).
	if got.Server != "P" || got.Database != "D" || got.Distributor != "D" || got.DistributionDB != "distribution" || got.Plan == nil {
		t.Errorf("target = %+v", got)
	}
	for _, name := range []string{"P", "D", "s1"} {
		if got.Servers[name] == nil {
			t.Errorf("Servers[%s] missing: %v", name, got.Servers)
		}
	}
	if !gotOpt.AutoApprove || gotOpt.Confirm != nil || gotOpt.Wait != 30*time.Minute || gotOpt.Interrupt == nil || gotOpt.Secret == nil {
		t.Errorf("options = %+v", gotOpt)
	}
	t.Setenv("SQLREPL_T10_EMPTY", "")
	if _, ok := gotOpt.Secret("SQLREPL_T10_EMPTY"); ok {
		t.Error("an empty secret is set (R54)")
	}

	fake(nil, fmt.Errorf("%w on P.D", apply.ErrLocked))
	var stdout, stderr bytes.Buffer
	code := runApply([]string{"-f", planFile(t, smallFile), "-env", noEnv(t), "-auto-approve"}, nil, &stdout, &stderr)
	if code != 1 || stderr.String() != "sqlrepl: another sqlrepl apply holds the lock on P.D\n" {
		t.Errorf("lock held: exit %d, stderr %q", code, stderr.String())
	}
	// No distributor nor agent_profiles in the file: no second lock.
	if got.Distributor != "" || got.DistributionDB != "" {
		t.Errorf("target without a shared section = %+v", got)
	}
}

// R58: plan exits 4 for a failed precondition without a refusal, 1 with
// one.
func TestPlanExitFour(t *testing.T) {
	r := newFakeRun(t, nil)
	failed := []plan.Precondition{{Name: "snapshot folder", Server: "P", Object: "x", Status: "failed"}}
	r.built = &plan.Plan{Publisher: "P", Database: "D", Preconditions: failed}
	var stdout, stderr bytes.Buffer
	if code := run([]string{"plan", "-f", planFile(t, smallFile), "-env", noEnv(t)}, &stdout, &stderr); code != 4 {
		t.Errorf("failed precondition: exit %d, want 4 (stderr %q)", code, stderr.String())
	}
	r.built = &plan.Plan{Publisher: "P", Database: "D", Preconditions: failed,
		Refusals: []plan.Refusal{{Path: "publications[x]", Reason: "refused"}}}
	stdout.Reset()
	if code := run([]string{"plan", "-f", planFile(t, smallFile), "-env", noEnv(t)}, &stdout, &stderr); code != 1 {
		t.Errorf("failed precondition and a refusal: exit %d, want 1", code)
	}
}

// statementLine is the line R53 prints before a statement.
var statementLine = regexp.MustCompile(`(?m)^\[\d+/\d+\] `)

// The lab fixture applied to the lab: the lock taken and released in
// Sales, an empty plan, no statement run.
func TestLabApplyCLISalesNoChanges(t *testing.T) {
	_, server := labCLI(t)
	var stdout, stderr bytes.Buffer
	code := runApply([]string{"-f", "../../internal/testdata/lab/sales.yaml", "-env", noEnv(t), "-auto-approve",
		"-server", server + "=tcp:127.0.0.1,11980", "-user", "sa", "-param", "encrypt=disable"}, nil, &stdout, &stderr)
	out := stdout.String()
	if code != 0 {
		t.Fatalf("exit %d\nstdout:\n%s\nstderr:\n%s", code, out, stderr.String())
	}
	if !strings.Contains(out, "lock taken on ") || !strings.Contains(out, "no changes.") {
		t.Errorf("stdout lacks the lock or no changes:\n%s", out)
	}
	if statementLine.MatchString(out) {
		t.Errorf("a statement ran:\n%s", out)
	}
}
