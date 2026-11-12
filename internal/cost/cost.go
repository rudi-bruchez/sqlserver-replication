// Package cost holds the measured cost table of the planner: for each
// property change or structural operation, the class that decides the force
// flags, the server error of a refusal, and the result rows of
// lab/results/2022 the entry comes from. Only measured entries exist: a change
// that Lookup does not find is refused by the planner as not measured.
//
// The package is pure: it imports neither database/sql nor the reader nor
// the precheck package.
package cost

import "regexp"

// Class is what a change costs in flags.
type Class string

const (
	Online         Class = "online"          // no flag in any state
	Snapshot       Class = "snapshot"        // @force_invalidate_snapshot when ready
	SnapshotReinit Class = "snapshot_reinit" // and @force_reinit_subscription when a row is at 2
	DropsReady     Class = "drops_ready"     // no flag; a ready snapshot is dropped
	DropReadd      Class = "drop_readd"      // refused while subscriptions exist: drop and re-add them
	Refused        Class = "refused"         // the server refuses it in every combination
)

// Cite names one result row an entry comes from.
type Cite struct {
	Row    string // "02-matrix P21", "15-snapshot-scope C.native.sync_method"
	Expect string // the row's result field, exactly: "ok", "dropsub=ok,droparticle=ok", "f00=20607,f10=ok,...", "21022" (R40)
	Ready  bool   // immediate_sync_ready before the call, in the state the row measured
	At2    bool   // the operated rows were at status 2
}

// Entry is the measured cost of one change.
type Entry struct {
	Change    string // a model path pattern, or an operation name (Operations below)
	Dir       string // "", to_true, to_false, both, set, clear, or "<from>><to>" (R8)
	PubType   string // transactional or snapshot, always stated (a property measured on both is two entries)
	Procedure string // sp_changepublication; "" for an operation without one
	Property  string // the @property value: retention
	Class     Class  // decides the flags; the costs of operations are R34's
	Wide      bool   // the reinit condition looks at every row of the publication
	Error     int    // Refused, DropReadd: the server's error
	Cites     []Cite
	Counter   []Cite   // counterexamples: rows that show the refusal the entry avoids, checked to be errors
	Notes     []string // lab/README.md observations ("O20"), checked to exist, never parsed as rows
}

// FlagState is the predicted state an operation runs in: the publication's
// immediate_sync_ready, and whether a subscription row the reinit condition
// looks at (the operated article's, or every row for a Wide entry) is at
// publisher status 2.
type FlagState struct{ Ready, At2 bool }

// Operation names used as Entry.Change for the operations that are not a
// property change.
const (
	OpAddArticle              = "add_article"
	OpDropArticle             = "drop_article"
	OpArticleFilter           = "article_filter"
	OpArticleView             = "article_view"
	OpArticleColumn           = "article_column"
	OpAddSubscription         = "add_subscription"
	OpExtendSubscription      = "extend_subscription"
	OpDropSubscription        = "drop_subscription"
	OpDropSubscriptionArticle = "drop_subscription_article"
	OpAddPublication          = "add_publication"
	OpDropPublication         = "drop_publication"
	OpAddProfile              = "add_profile"
	OpDropProfile             = "drop_profile"
	OpProfileBinding          = "profile_binding"
	OpJobEnabled              = "job_enabled"
	OpGenerateAndWait         = "generate_and_wait"
	OpJobDisable              = "job_disable"
	OpJobRestore              = "job_restore"
	OpJobStart                = "job_start"
)

var indexRE = regexp.MustCompile(`\[[^\]]*\]`)

// Pattern turns a model path with indices or names
// ("publications[P].articles[A].type") into the pattern the table is keyed
// by ("publications[*].articles[*].type"). An operation name is returned as
// it is.
func Pattern(path string) string { return indexRE.ReplaceAllString(path, "[*]") }

// Lookup finds the entry of a change (a path, with or without indices, or
// an operation name), its direction (R8) and the publication type. An entry
// whose Dir is "both" answers to_true and to_false.
//
// The changes outside a publication (distributor, log reader agent, agent
// profiles, profile bindings, job operations) are measured once and stored
// under PubType "transactional": callers pass "transactional" for them.
// add_publication and generate_and_wait have no entry: they are costed
// outside the table, by the creation cost of Task 11 and by R34's strategy
// cost.
func Lookup(change, dir, pubType string) (Entry, bool) {
	p := Pattern(change)
	for _, e := range Table {
		if e.Change != p || e.PubType != pubType {
			continue
		}
		if e.Dir == dir || (e.Dir == "both" && (dir == "to_true" || dir == "to_false")) {
			return e, true
		}
	}
	return Entry{}, false
}

// Flags is the flag rule (R9): @force_invalidate_snapshot exactly when the
// snapshot is ready and the class touches the snapshot, and
// @force_reinit_subscription exactly when the class needs a
// reinitialization and a row the condition looks at is at status 2. The
// caller computes s.At2 over every row of the publication when e.Wide.
func Flags(e Entry, s FlagState) (invalidate, reinit bool) {
	switch e.Class {
	case Snapshot:
		return s.Ready, false
	case SnapshotReinit:
		return s.Ready, s.At2
	}
	return false, false
}
