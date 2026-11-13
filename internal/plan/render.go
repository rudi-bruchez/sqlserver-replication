package plan

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
)

// The renderings of a plan (spec "What a plan is", R16, R28): the
// statements apply executes, the T-SQL that -sql prints, the human summary
// and the JSON.

// Statement is the batch of one operation, what apply executes.
type Statement struct {
	Seq              int
	Server, Database string
	Text             string            // the batch: Prologue, then the EXEC under its Guard; secrets as @secret_<n>
	Secrets          []StatementSecret // each @secret_<n> the batch uses, in order of first use in it
}

// StatementSecret binds a variable of a statement to the secret it holds.
type StatementSecret struct {
	Var  string // @secret_<n>, numbered once per plan
	Name string // the secret's name, the environment variable apply reads
}

// sqlHeader is the first line of SQL(): the batches declare the same
// variables (@job_id, @profile_id), so run as one batch they fail at
// compile with Msg 134 (measured by the Task 16 review).
const sqlHeader = "-- each operation below is a batch of its own: run them one at a time (sqlrepl apply does); the file does not run as one batch"

// waitHeader follows sqlHeader in a plan with a generate_and_wait (R25,
// minor 15 of the final review): run as printed, the restore of
// immediate_sync would follow a generation the subscriptions have not read.
const waitHeader = "-- a generate_and_wait operation starts the snapshot agent of the added articles: wait until every subscription has received them, its job_start operations starting the agents that deliver them, before running the operations after them (sqlrepl apply waits)"

// startAgainHeader follows them in a plan with a job_start (R51): apply
// runs a job_start of an agent once more when its job ended before the
// delivery the plan owes, so the text it runs is still a printed statement.
const startAgainHeader = "-- sqlrepl apply may run a job_start again when its job ended before the delivery it owes"

// Statements is one statement per operation, in Seq order. A secret
// parameter is rendered @<param> = @secret_<n> (R16), numbered once per
// plan in Seq order of first use (then parameter order), a name keeping its
// number everywhere it is passed. The value is never read here.
func (p *Plan) Statements() []Statement {
	number := map[string]int{}
	out := make([]Statement, 0, len(p.Operations))
	for _, op := range p.Operations {
		st := Statement{Seq: op.Seq, Server: op.Server, Database: op.Database}
		inStatement := map[string]bool{}
		args := make([]string, 0, len(op.Call.Params))
		for _, prm := range op.Call.Params {
			v := prm.Value
			if prm.Secret != "" {
				n, ok := number[prm.Secret]
				if !ok {
					n = len(number) + 1
					number[prm.Secret] = n
				}
				v = secretParam(n)
				if !inStatement[prm.Secret] {
					inStatement[prm.Secret] = true
					st.Secrets = append(st.Secrets, StatementSecret{Var: v, Name: prm.Secret})
				}
			}
			args = append(args, prm.Name+" = "+v)
		}
		var b strings.Builder
		if op.Call.Prologue != "" {
			b.WriteString(strings.TrimRight(op.Call.Prologue, "\n"))
			b.WriteString("\n")
		}
		exec := "EXEC " + op.Call.Procedure
		if len(args) > 0 {
			exec += " " + strings.Join(args, ", ")
		}
		exec += ";"
		if op.Kind == "job_start" {
			// R62: the batch reports whether it started the job, in one row
			// apply reads; sqlcmd prints it harmlessly.
			b.WriteString("DECLARE @started bit = 0, @rc int;\n")
			if op.Call.Guard != "" {
				b.WriteString("IF " + op.Call.Guard + "\n")
			}
			b.WriteString("BEGIN\n" + strings.Replace(exec, "EXEC ", "EXEC @rc = ", 1) + "\n")
			b.WriteString("SET @started = CASE WHEN @rc = 0 THEN 1 ELSE 0 END;\nEND;\n")
			b.WriteString("SELECT @started AS started;")
		} else {
			if op.Call.Guard != "" {
				b.WriteString("IF " + op.Call.Guard + "\n")
			}
			b.WriteString(exec)
		}
		st.Text = b.String()
		out = append(out, st)
	}
	return out
}

func secretParam(n int) string { return "@secret_" + strconv.Itoa(n) }

// oneLine flattens the line breaks of s: on a -- line, a name or a text
// with a line break would end the comment and put the rest into the batch;
// in the summary, it would break the one-line-per-item layout.
func oneLine(s string) string {
	return strings.NewReplacer("\r\n", " ", "\r", " ", "\n", " ").Replace(s)
}

func costList(cs []Cost) string {
	xs := make([]string, len(cs))
	for i, c := range cs {
		xs[i] = string(c)
	}
	return strings.Join(xs, ", ")
}

// SQL is the statements laid out for -sql: sqlHeader (and waitHeader when
// the plan has a generate_and_wait, startAgainHeader when it has a
// job_start), then a "-- server"
// header whenever the server changes, a USE whenever the server or the
// database changes (both compared without regard to case, R7), and for
// each operation its header comment, its warnings, its secret comments
// (R16), then its batch. GO is never written: each operation is one batch
// for apply, and the text is the executed text. A plan without operation
// (empty or refused) renders as the empty string.
func (p *Plan) SQL() string {
	if len(p.Operations) == 0 {
		return ""
	}
	var b strings.Builder
	b.WriteString(sqlHeader + "\n")
	for _, op := range p.Operations {
		if op.Kind == "generate_and_wait" {
			b.WriteString(waitHeader + "\n")
			break
		}
	}
	for _, op := range p.Operations {
		if op.Kind == "job_start" {
			b.WriteString(startAgainHeader + "\n")
			break
		}
	}
	stmts := p.Statements()
	server, database := "", ""
	for i, op := range p.Operations {
		st := stmts[i]
		b.WriteString("\n")
		newServer := i == 0 || !strings.EqualFold(op.Server, server)
		if newServer {
			fmt.Fprintf(&b, "-- server %s\n", oneLine(op.Server))
		}
		if newServer || !strings.EqualFold(op.Database, database) {
			fmt.Fprintf(&b, "USE %s;\n", quoteName(op.Database))
		}
		server, database = op.Server, op.Database
		fmt.Fprintf(&b, "-- %d %s %s %s: %s\n", op.Seq, op.Action, op.Kind, oneLine(op.Path), costList(op.Costs))
		for _, w := range op.Warnings {
			fmt.Fprintf(&b, "-- warning: %s\n", oneLine(w))
		}
		for _, s := range st.Secrets {
			fmt.Fprintf(&b, "-- %s: secret %s\n", s.Var, oneLine(s.Name))
		}
		b.WriteString(st.Text)
		b.WriteString("\n")
	}
	return b.String()
}

// CostOrder is the order of the costs in spec "What a plan is", the order
// of the summary's totals and of apply's question (R44).
func CostOrder() []Cost { return append([]Cost(nil), costOrder...) }

var costOrder = []Cost{
	CostOnline, CostPendingSnapshotStart, CostNewSnapshot, CostFullGenerationDeferred, CostReadySnapshotDropped,
	CostReinitialization, CostDropAndReadd, CostSubscriberDataReplaced, CostSubscriberObjectLeft, CostSharedObjectChanged,
}

// subscriptionsOf names, after the cost list of an operation that
// reinitializes, generates a new snapshot or replaces subscriber data, the
// subscriptions it affects (its Affects.Subscriptions, which the JSON
// holds; minor 6 of the final review).
func subscriptionsOf(op Operation) string {
	if len(op.Affects.Subscriptions) == 0 {
		return ""
	}
	for _, c := range op.Costs {
		if c == CostReinitialization || c == CostSubscriberDataReplaced || c == CostNewSnapshot {
			return " (subscriptions " + strings.Join(op.Affects.Subscriptions, ", ") + ")"
		}
	}
	return ""
}

// sharedWith names, after the cost list of an operation on a shared
// object, the other publication databases it is shared with (minor 13).
func sharedWith(op Operation) string {
	if len(op.Shared) == 0 {
		return ""
	}
	return " (shared with " + strings.Join(op.Shared, ", ") + ")"
}

// Summary is the human summary (R28), every interpolated text on one line
// (oneLine). A refused plan prints its refusals and "Plan refused." only;
// an empty section is not printed.
func (p *Plan) Summary() string {
	var b strings.Builder
	line := func(format string, args ...any) {
		for i, a := range args {
			if s, ok := a.(string); ok {
				args[i] = oneLine(s)
			}
		}
		fmt.Fprintf(&b, format+"\n", args...)
	}
	if len(p.Refusals) > 0 {
		line("Refused:")
		for _, r := range p.Refusals {
			line("  %s: %s", r.Path, r.Reason)
		}
		line("Plan refused.")
		return b.String()
	}
	if len(p.Operations) == 0 {
		line("Plan for %s.%s: no changes.", p.Publisher, p.Database)
	} else {
		line("Plan for %s.%s: %d operations, %d costly.", p.Publisher, p.Database, p.Totals.Operations, p.Totals.Costly)
		for _, op := range p.Operations {
			line("  %d  %s %s %s: %s%s%s", op.Seq, op.Action, op.Kind, op.Path, costList(op.Costs), sharedWith(op), subscriptionsOf(op))
			for _, w := range op.Warnings {
				line("      warning: %s", w)
			}
		}
		var totals []string
		for _, c := range costOrder {
			if n := p.Totals.ByCost[c]; n > 0 {
				totals = append(totals, fmt.Sprintf("%s %d", c, n))
			}
		}
		if len(totals) > 0 {
			line("Totals: %s", strings.Join(totals, ", "))
		}
	}
	section := func(title string, lines []string) {
		if len(lines) == 0 {
			return
		}
		line("%s:", title)
		for _, l := range lines {
			line("  %s", l)
		}
	}
	var lines []string
	for _, s := range p.Secrets {
		set := "not set"
		if s.Set {
			set = "set"
		}
		lines = append(lines, s.Name+" "+set)
	}
	section("Secrets", lines)
	lines = nil
	for _, pc := range p.Preconditions {
		object := pc.Object
		if pc.Name == precondSubscriberDB {
			// Two subscribers can hold a database of the same name.
			object = pc.Server + "/" + pc.Object
		}
		l := pc.Status + " " + pc.Name + " " + object
		if pc.Detail != "" {
			l += ": " + pc.Detail
		}
		lines = append(lines, l)
	}
	section("Preconditions", lines)
	lines = nil
	for _, a := range p.AgentsToStart {
		l := a.Kind + " " + a.Publication
		if a.Subscriber != "" || a.Database != "" {
			l += " " + a.Subscriber + "/" + a.Database
		}
		lines = append(lines, l+": "+a.Reason)
	}
	section("Agents apply will start", lines)
	section("Warnings", p.Warnings)
	section("Notes", p.Notes)
	return b.String()
}

// JSON is the plan as data (-json).
func (p *Plan) JSON() ([]byte, error) { return json.MarshalIndent(p, "", "  ") }
