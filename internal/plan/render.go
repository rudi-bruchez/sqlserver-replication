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
	Text             string   // the batch: Prologue, then the EXEC; secrets as @secret_<n>
	Secrets          []string // the secret names, @secret_1 first
}

// Statements is one statement per operation, in Seq order. A secret
// parameter is rendered @<param> = @secret_<n> (R16), numbered within the
// statement in the order of its parameters, a name passed twice keeping
// its number, so that Secrets[n-1] is the secret apply binds to
// @secret_<n> of that statement. The value is never read here.
func (p *Plan) Statements() []Statement {
	out := make([]Statement, 0, len(p.Operations))
	for _, op := range p.Operations {
		st := Statement{Seq: op.Seq, Server: op.Server, Database: op.Database}
		number := map[string]int{}
		args := make([]string, 0, len(op.Call.Params))
		for _, prm := range op.Call.Params {
			v := prm.Value
			if prm.Secret != "" {
				n, ok := number[prm.Secret]
				if !ok {
					st.Secrets = append(st.Secrets, prm.Secret)
					n = len(st.Secrets)
					number[prm.Secret] = n
				}
				v = secretParam(n)
			}
			args = append(args, prm.Name+" = "+v)
		}
		var b strings.Builder
		if op.Call.Prologue != "" {
			b.WriteString(strings.TrimRight(op.Call.Prologue, "\n"))
			b.WriteString("\n")
		}
		b.WriteString("EXEC " + op.Call.Procedure)
		if len(args) > 0 {
			b.WriteString(" " + strings.Join(args, ", "))
		}
		b.WriteString(";")
		st.Text = b.String()
		out = append(out, st)
	}
	return out
}

func secretParam(n int) string { return "@secret_" + strconv.Itoa(n) }

// comment makes s safe on a -- line: a name or a text with a line break
// would otherwise end the comment and put the rest into the batch.
func comment(s string) string {
	return strings.NewReplacer("\r\n", " ", "\r", " ", "\n", " ").Replace(s)
}

func costList(cs []Cost) string {
	xs := make([]string, len(cs))
	for i, c := range cs {
		xs[i] = string(c)
	}
	return strings.Join(xs, ", ")
}

// SQL is the statements laid out for -sql: a "-- server" header whenever
// the server changes, a USE whenever the server or the database changes,
// and for each operation its header comment, its warnings, its secret
// comments (R16), then its batch. GO is never written: each operation is
// one batch for apply, and the text is the executed text.
func (p *Plan) SQL() string {
	var b strings.Builder
	stmts := p.Statements()
	server, database := "", ""
	for i, op := range p.Operations {
		st := stmts[i]
		if i > 0 {
			b.WriteString("\n")
		}
		newServer := i == 0 || !strings.EqualFold(op.Server, server)
		if newServer {
			fmt.Fprintf(&b, "-- server %s\n", comment(op.Server))
		}
		if newServer || !strings.EqualFold(op.Database, database) {
			fmt.Fprintf(&b, "USE %s;\n", quoteName(op.Database))
		}
		server, database = op.Server, op.Database
		fmt.Fprintf(&b, "-- %d %s %s %s: %s\n", op.Seq, op.Action, op.Kind, comment(op.Path), costList(op.Costs))
		for _, w := range op.Warnings {
			fmt.Fprintf(&b, "-- warning: %s\n", comment(w))
		}
		for n, name := range st.Secrets {
			fmt.Fprintf(&b, "-- %s: secret %s\n", secretParam(n+1), comment(name))
		}
		b.WriteString(st.Text)
		b.WriteString("\n")
	}
	return b.String()
}

// costOrder is the order of the costs in spec "What a plan is".
var costOrder = []Cost{
	CostOnline, CostPendingSnapshotStart, CostNewSnapshot, CostFullGenerationDeferred, CostReadySnapshotDropped,
	CostReinitialization, CostDropAndReadd, CostSubscriberDataReplaced, CostSubscriberObjectLeft, CostSharedObjectChanged,
}

// Summary is the human summary (R28). A refused plan prints its refusals
// and "Plan refused." only; an empty section is not printed.
func (p *Plan) Summary() string {
	var b strings.Builder
	if len(p.Refusals) > 0 {
		b.WriteString("Refused:\n")
		for _, r := range p.Refusals {
			fmt.Fprintf(&b, "  %s: %s\n", r.Path, r.Reason)
		}
		b.WriteString("Plan refused.\n")
		return b.String()
	}
	if len(p.Operations) == 0 {
		fmt.Fprintf(&b, "Plan for %s.%s: no changes.\n", p.Publisher, p.Database)
	} else {
		fmt.Fprintf(&b, "Plan for %s.%s: %d operations, %d costly.\n", p.Publisher, p.Database, p.Totals.Operations, p.Totals.Costly)
		for _, op := range p.Operations {
			fmt.Fprintf(&b, "  %d  %s %s %s: %s\n", op.Seq, op.Action, op.Kind, op.Path, costList(op.Costs))
			for _, w := range op.Warnings {
				fmt.Fprintf(&b, "      warning: %s\n", w)
			}
		}
		var totals []string
		for _, c := range costOrder {
			if n := p.Totals.ByCost[c]; n > 0 {
				totals = append(totals, fmt.Sprintf("%s %d", c, n))
			}
		}
		if len(totals) > 0 {
			fmt.Fprintf(&b, "Totals: %s\n", strings.Join(totals, ", "))
		}
	}
	section := func(title string, lines []string) {
		if len(lines) == 0 {
			return
		}
		b.WriteString(title + ":\n")
		for _, l := range lines {
			b.WriteString("  " + l + "\n")
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
		l := pc.Status + " " + pc.Name + " " + pc.Object
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
