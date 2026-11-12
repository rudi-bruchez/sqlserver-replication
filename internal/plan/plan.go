// Package plan holds the planner: the plan and its operations, the calls
// they generate, the state prediction, the comparison, the strategies, the
// order and the rendering (plan 3, R1).
//
// The package is pure: it imports neither database/sql nor the reader nor
// the precheck package (spec "Engine as a library").
package plan

import (
	"time"

	"github.com/rudi-bruchez/sqlserver-replication/internal/cost"
	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
	"github.com/rudi-bruchez/sqlserver-replication/internal/normalize"
	"github.com/rudi-bruchez/sqlserver-replication/internal/state"
)

// Refusal is a property of the desired file the plan cannot act on.
type Refusal = normalize.Refusal

// Cost is one of the costs an operation is listed with (spec "What a plan
// is").
type Cost string

// The ten costs of spec "What a plan is".
const (
	CostOnline                 Cost = "online"
	CostPendingSnapshotStart   Cost = "pending_snapshot_start"
	CostNewSnapshot            Cost = "new_snapshot"
	CostFullGenerationDeferred Cost = "full_generation_deferred"
	CostReadySnapshotDropped   Cost = "ready_snapshot_dropped"
	CostReinitialization       Cost = "reinitialization"
	CostDropAndReadd           Cost = "drop_and_readd"
	CostSubscriberDataReplaced Cost = "subscriber_data_replaced"
	CostSubscriberObjectLeft   Cost = "subscriber_object_left"
	CostSharedObjectChanged    Cost = "shared_object_changed"
)

// The moments apply records a delivery owed at (R50, Operation.OwesAt).
const (
	OwesBefore = "before"
	OwesAfter  = "after"
	OwesMarked = "marked"
)

// Operation is one procedure call of the plan (R2).
type Operation struct {
	Seq  int `json:"seq"` // 1-based, after ordering
	Step int `json:"step"`
	// Step is 1 to 11 of spec "Order"; R24's job operations are in 0 and
	// 12, and in 8 after a created snapshot agent.
	Order string `json:"-"` // sort key within the step
	// Kind is one of distributor, distribution_db, distpublisher,
	// distributor_property, profile, profile_property, publication_db,
	// log_reader_agent, publication, publication_property, snapshot_agent,
	// article, article_property, article_filter, article_view,
	// article_column, subscription, subscription_extension,
	// subscription_article_drop, push_agent, pull_subscription, pull_agent,
	// agent_property, agent_binding, agent_schedule, job_enabled,
	// generate_and_wait, job_disable, job_restore, job_start.
	Kind     string           `json:"kind"`
	Action   string           `json:"action"` // add, change, drop, start, disable, restore
	Path     string           `json:"path"`   // model path of the object
	Changes  []PropertyChange `json:"changes"`
	Server   string           `json:"server"`   // the server name as the file writes it
	Database string           `json:"database"` // the database the call runs in
	Call     Call             `json:"call"`
	Costs    []Cost           `json:"costs"`
	Affects  Affects          `json:"affects"`
	Reason   string           `json:"reason"`
	Sources  []string         `json:"sources"` // cite rows and spec sections
	Shared   []string         `json:"shared"`  // other publication databases, "<publisher>.<database>"
	Warnings []string         `json:"warnings"`
	// Owes is the subscriptions (Subscription.Key()) the operation owes a
	// delivery, OwesAt when apply records it: before, after or marked
	// (R50). finish sets them from the predicted state.
	Owes   []string    `json:"owes,omitempty"`
	OwesAt string      `json:"owes_at,omitempty"`
	entry  *cost.Entry // set by the strategy; the flags pass reads it
	// wideMarkCheck marks an sp_addarticle that finish refuses on an
	// immediate_sync publication whose every subscription row an earlier
	// sync_method change of the plan marked (spec "Strategies", Articles).
	wideMarkCheck bool
	// replacesData: a reinitialization of the operated article replaces
	// subscriber data, its pre_creation_cmd being drop, delete or truncate
	// (spec anti-goal 4); finish adds subscriber_data_replaced when it
	// costs the call reinitialization.
	replacesData bool
	// keepsRows is the articles whose pre_creation_cmd is none that a
	// reinitialization by this operation covers: finish warns on each when
	// it costs the call reinitialization (fix round 1 of Task 13, measured:
	// the bulk copy fails on duplicate keys, 2601 then 20253, retried).
	keepsRows []string
	// readd: the sp_addsubscription that adds back a subscription the plan
	// dropped for a change of independent_agent (spec "Publication
	// properties"); finish costs it reinitialization.
	readd bool
	// namedExtensionCheck marks a named sp_addsubscription on an existing
	// subscription that finish refuses on a native or character
	// publication whose every row a sync_method change of the plan marked
	// (spec "Strategies", Articles).
	namedExtensionCheck bool
	// leaves is the subscriber tables a drop operation stops maintaining,
	// delivers those an addition delivers by snapshot: redeliveriesStrategy
	// reads both (redeliver.go).
	leaves, delivers []subscriberTable
}

// PropertyChange is one property an operation changes.
type PropertyChange struct {
	Path   string `json:"path"`
	Before string `json:"before"`
	After  string `json:"after"`
}

// Affects names the objects an operation affects, by key.
type Affects struct {
	Publications  []string `json:"publications"`
	Articles      []string `json:"articles"`
	Subscriptions []string `json:"subscriptions"`
}

// Call is the procedure call of an operation.
type Call struct {
	// Procedure is the name as rendered: sp_addarticle,
	// msdb.dbo.sp_update_job, [distribution].dbo.sp_update_agent_profile.
	Procedure string `json:"procedure"`
	// Prologue holds the statements before the EXEC in the same batch
	// (Task 14's id lookups); usually empty.
	Prologue string `json:"prologue"`
	// Guard, when not empty, is the condition the EXEC runs under: the
	// batch writes IF <Guard> before it (R24's job_start).
	Guard  string  `json:"guard,omitempty"`
	Params []Param `json:"params"`
}

// Param is one parameter of a call.
type Param struct {
	Name  string `json:"name"`  // @publication
	Value string `json:"value"` // a T-SQL literal: N'x', 1, 0x0000000000030073, NULL
	// Secret, when not empty, is a secret name and Value is empty (R16).
	Secret string `json:"secret,omitempty"`
}

// Plan is what `plan` computes for one publication database.
type Plan struct {
	Publisher     string         `json:"publisher"`
	Database      string         `json:"database"`
	Options       Options        `json:"options"`
	Operations    []Operation    `json:"operations"`
	Refusals      []Refusal      `json:"refusals"`
	Warnings      []string       `json:"warnings"`
	Notes         []string       `json:"notes"`
	Secrets       []SecretUse    `json:"secrets"`
	Preconditions []Precondition `json:"preconditions"`
	AgentsToStart []AgentRef     `json:"agents_to_start"`
	Totals        Totals         `json:"totals"`
	// OwedBefore is the deliveries pending before the plan: the
	// subscriptions with a row at 1, or an inactive subscribed article
	// without immediate_sync, in the state observed (R50).
	OwedBefore     []Owed `json:"owed_before"`
	DistributionDB string `json:"distribution_db"`
	// SnapshotRoots is, by publication, the folder its snapshot runs are
	// written under: its alt_snapshot_folder when set, else the
	// distributor's working_directory (R50, folder rule).
	SnapshotRoots map[string]string `json:"snapshot_roots"`
	// SnapshotRootsBefore is, by publication that exists before the plan,
	// the folder its runs were written under then: its current
	// alt_snapshot_folder when set, else the current distributor's
	// working_directory. When it differs from SnapshotRoots (the plan
	// changes the root), apply lists the publication's folder under both
	// roots at T and refuses a run present in either, so that a run
	// generated under the old root is never confirmed as new (controller's
	// ruling, review of Task 4, Important 2). A publication the plan creates
	// has no entry.
	SnapshotRootsBefore map[string]string `json:"snapshot_roots_before"`
	// SnapshotJobs is, by publication, the prologue that sets @job_id to its
	// snapshot job, the lookup of its job operations (R62).
	SnapshotJobs map[string]string `json:"snapshot_jobs"`
}

// Owed is a delivery a subscription of a publication awaits.
type Owed struct {
	Publication  string `json:"publication"`
	Subscription string `json:"subscription"` // Subscription.Key()
}

// SnapshotJobLookup is the batch prologue that sets @job_id to the snapshot
// job of a publication of the plan, the one its job operations use (R62),
// so that every wait on the job has a batch that declares @job_id.
func (p *Plan) SnapshotJobLookup(publication string) (string, bool) {
	s, ok := p.SnapshotJobs[publication]
	return s, ok
}

// Empty tells whether the plan has no operation, no refusal and no agent to
// start.
func (p *Plan) Empty() bool {
	return len(p.Operations) == 0 && len(p.Refusals) == 0 && len(p.AgentsToStart) == 0
}

// SecretUse is a secret the plan's calls pass, whether it is set, and the
// operations (by Seq) that pass it.
type SecretUse struct {
	Name       string `json:"name"`
	Set        bool   `json:"set"`
	Operations []int  `json:"operations"`
}

// Precondition is a check the plan depends on.
type Precondition struct {
	Name   string `json:"name"`
	Server string `json:"server"`
	Object string `json:"object"`
	Status string `json:"status"` // ok, failed, unchecked
	Detail string `json:"detail"`
}

// AgentRef is an agent the plan's apply starts.
type AgentRef struct {
	Kind        string `json:"kind"`
	Publication string `json:"publication"`
	Subscriber  string `json:"subscriber"`
	Database    string `json:"database"`
	Reason      string `json:"reason"`
}

// Totals counts the operations, the costly ones, and the operations per
// cost.
type Totals struct {
	Operations int          `json:"operations"`
	Costly     int          `json:"costly"`
	ByCost     map[Cost]int `json:"by_cost"`
}

// Options are the command line options that change the plan.
type Options struct {
	DeferFullSnapshot bool          `json:"defer_full_snapshot"`
	Wait              time.Duration `json:"wait"`
}

// Inputs is what a plan is built from.
type Inputs struct {
	Desired, Current *model.Config
	Facts            *state.Facts
	Checks           *state.Checks          // nil: every precondition unchecked
	SecretSet        func(name string) bool // nil: every secret not set
}
