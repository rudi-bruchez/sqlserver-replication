package apply

import (
	"fmt"
	"strings"

	"github.com/rudi-bruchez/sqlserver-replication/internal/plan"
)

// Outcome is how a run ended (R52).
type Outcome string

// The outcomes of a run.
const (
	// OutcomeEmpty: the plan has nothing to do; nothing asked, nothing run.
	OutcomeEmpty Outcome = "empty"
	// OutcomeRefused: a refusal of the plan, a failed or unchecked
	// precondition apply needs, a secret not set, or a shared operation
	// without the distributor lock (R44, R45, R54, R58); nothing run.
	OutcomeRefused Outcome = "refused"
	// OutcomeCancelled: the answer was not yes, or an interrupt came while
	// the question waited (R44); nothing run.
	OutcomeCancelled Outcome = "cancelled"
	// OutcomeApplied: every operation ran; the deliveries decide between
	// exit 0 and 3.
	OutcomeApplied Outcome = "applied"
	// OutcomeFailed: a statement failed, the test hook stopped the run, a
	// read apply needs failed, or a bound was spent before the last
	// operation; operations are left unrun.
	OutcomeFailed Outcome = "failed"
	// OutcomeInterrupted: SIGINT or SIGTERM during the run. With
	// operations unrun it is exit 1; after the last operation, during the
	// wait for deliveries, the deliveries decide.
	OutcomeInterrupted Outcome = "interrupted"
	// OutcomeUnconfirmed: the deferral's wait timed out (R51, spec
	// "-defer-full-snapshot" step 3): apply stopped with immediate_sync off
	// and operations unrun, exit 3, the one exception to exit 1 for
	// operations left unrun (R52).
	OutcomeUnconfirmed Outcome = "unconfirmed"
)

// Failure is the statement or the step a run stopped at.
type Failure struct {
	Seq, Number int // Number 0: not a server error
	Message     string
	// Step is the text of the step that wrapped the server error (a read
	// apply needs, a wait), "" for a statement's own error.
	Step string
}

// text is the failure as printed (R53): the step's text, then Msg
// <number>: <message> for a server error.
func (f *Failure) text() string {
	t := f.Message
	if f.Number != 0 {
		t = fmt.Sprintf("Msg %d: %s", f.Number, f.Message)
	}
	if f.Step != "" {
		t = f.Step + ": " + t
	}
	return t
}

// Result is what a run did (R52, R53).
type Result struct {
	Plan             *plan.Plan
	Outcome          Outcome
	Ran, Remaining   []int
	Failure          *Failure
	Deliveries       []Delivery
	JobsLeftDisabled []string
	LockLost         bool     // R46: a lock's session ended with its connection
	Notes            []string // 18752 tolerated, retries
	// LockReleaseFailures is every failed release of a lock (R45), as
	// printed: "lock release failed on <server>.<database>: <message>".
	// Any makes the exit code 1 (R52).
	LockReleaseFailures []string
}

// ExitCode is the apply column of R52. Code 2 (a usage error, no terminal
// without -auto-approve) is decided by the command before Run.
func (r *Result) ExitCode() int {
	if r == nil {
		return 1
	}
	if len(r.LockReleaseFailures) > 0 {
		return 1
	}
	switch r.Outcome {
	case OutcomeEmpty:
		return 0
	case OutcomeRefused, OutcomeCancelled, OutcomeFailed:
		return 1
	case OutcomeUnconfirmed:
		return 3
	case OutcomeInterrupted:
		if len(r.Remaining) > 0 {
			return 1
		}
		return r.deliveriesCode()
	case OutcomeApplied:
		return r.deliveriesCode()
	}
	return 1
}

// deliveriesCode is the code of a run whose every operation ran: 0 when
// every delivery owed is confirmed, else 3.
func (r *Result) deliveriesCode() int {
	for _, d := range r.Deliveries {
		if d.Status != deliveryConfirmed {
			return 3
		}
	}
	return 0
}

// question is the confirmation of R44, exactly: the parenthesis lists
// Totals.ByCost in plan.CostOrder() without online, and is left out when no
// operation is costly.
func question(p *plan.Plan) string {
	q := fmt.Sprintf("Apply %d operations to %s.%s, %d costly", p.Totals.Operations, p.Publisher, p.Database, p.Totals.Costly)
	if p.Totals.Costly > 0 {
		var parts []string
		for _, c := range plan.CostOrder() {
			if c == plan.CostOnline {
				continue
			}
			if n := p.Totals.ByCost[c]; n > 0 {
				parts = append(parts, fmt.Sprintf("%s %d", c, n))
			}
		}
		if len(parts) > 0 {
			q += " (" + strings.Join(parts, ", ") + ")"
		}
	}
	return q + "? Type yes to apply: "
}

// units groups the operations into the Seq lists run back to back (R46):
// a push subscription's sp_addsubscription and the
// sp_addpushsubscription_agent that follows it for the same subscription,
// so that the implicit agent never runs before its credentials are set
// (spec "Subscriptions", panel XN); every other operation alone, a pull
// subscription's calls included.
func units(p *plan.Plan) [][]int {
	var out [][]int
	ops := p.Operations
	for i := 0; i < len(ops); i++ {
		op := ops[i]
		if i+1 < len(ops) && pushPair(op, ops[i+1]) {
			out = append(out, []int{op.Seq, ops[i+1].Seq})
			i++
			continue
		}
		out = append(out, []int{op.Seq})
	}
	return out
}

// pushPair tells an sp_addsubscription followed by the
// sp_addpushsubscription_agent of the same subscription.
func pushPair(a, b plan.Operation) bool {
	return a.Kind == "subscription" && a.Action == "add" && b.Kind == "push_agent" && b.Action == "add" &&
		strings.EqualFold(firstString(a.Affects.Publications), firstString(b.Affects.Publications)) &&
		strings.EqualFold(firstString(a.Affects.Subscriptions), firstString(b.Affects.Subscriptions)) &&
		strings.EqualFold(a.Server, b.Server)
}

// seqList is the Seq list of the Remaining line.
func seqList(xs []int) string {
	parts := make([]string, len(xs))
	for i, x := range xs {
		parts[i] = fmt.Sprint(x)
	}
	return strings.Join(parts, ", ")
}

// deliveryLine is the end-of-run line of a delivery owed (R53), on one
// line whatever its history comments hold.
func deliveryLine(d Delivery) string {
	line := fmt.Sprintf("delivery %s to %s: ", d.Publication, d.Subscription)
	switch d.Status {
	case deliveryConfirmed:
		return line + "confirmed (run " + d.Run + ")"
	case deliveryNotAwaited:
		return line + "not awaited"
	}
	state, history := d.JobState, oneLine(d.LastHistory)
	if state == "" {
		state = "unknown"
	}
	if history == "" {
		history = "none"
	}
	return line + "unconfirmed (" + oneLine(d.Detail) + "; job " + state + "; last history: " + history + ")"
}

// oneLine flattens the line breaks of a server text.
func oneLine(s string) string {
	return strings.Join(strings.Fields(strings.NewReplacer("\r\n", " ", "\r", " ", "\n", " ").Replace(s)), " ")
}
