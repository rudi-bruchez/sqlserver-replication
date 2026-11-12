// Package state holds the observed runtime facts of a replication: snapshot
// readiness, the last snapshot generation, the status of each subscription
// row at the publisher and at the distributor, the state of the agents' jobs
// and their last history rows, and which agents use a user-defined profile.
//
// The facts are what the planner needs to know besides the configuration.
// They are never part of the declarative file: the export writes them, on
// request, to a JSON file of their own.
package state

// Facts is what the reader observed, at ReadAt.
type Facts struct {
	ReadAt        string              `json:"read_at"` // distributor SYSDATETIME()
	Publications  []PublicationFacts  `json:"publications"`
	Subscriptions []SubscriptionFacts `json:"subscriptions"`
	Agents        []AgentFacts        `json:"agents"`
	ProfileUses   []ProfileUse        `json:"profile_uses"`
}

// PublicationFacts is the snapshot state of a publication.
type PublicationFacts struct {
	Name string `json:"name"`
	// ImmediateSyncReady is syspublications.immediate_sync_ready.
	ImmediateSyncReady bool `json:"immediate_sync_ready"`
	// LastGeneration is the time of the latest successful run (runstatus 2)
	// of the publication's snapshot agent; empty when there is none.
	LastGeneration string         `json:"last_generation,omitempty"`
	Articles       []ArticleFacts `json:"articles"`
}

// ArticleFacts is the state of an article.
type ArticleFacts struct {
	Name string `json:"name"`
	// Active is bit 0x1 of sysarticles.status, set by the snapshot
	// generation; it is never a witness of a delivery. A schema-only
	// article is listed with Active false.
	Active bool `json:"active"`
}

// SubscriptionFacts holds the rows of one subscription, one per article.
type SubscriptionFacts struct {
	Publication string            `json:"publication"`
	Subscriber  string            `json:"subscriber"`
	Database    string            `json:"database"`
	Rows        []SubscriptionRow `json:"rows"`
}

// SubscriptionRow is the status of one subscribed article.
type SubscriptionRow struct {
	Article string `json:"article"`
	// PublisherStatus is syssubscriptions.status.
	PublisherStatus int `json:"publisher_status"`
	// DistributorStatus is MSsubscriptions.status of the subscription's own
	// row; nil when the distributor has no such row.
	DistributorStatus *int `json:"distributor_status"`
}

// AgentFacts is the state of one agent.
type AgentFacts struct {
	Kind        string `json:"kind"`                  // log_reader, snapshot, distribution, pull_distribution
	Publication string `json:"publication,omitempty"` // ALL for a shared agent
	Subscriber  string `json:"subscriber,omitempty"`
	Database    string `json:"database,omitempty"`
	// AgentID is the id of the agent's row at the distributor; 0 for a pull
	// agent the distributor has no row for. Job is also nil for a pull agent
	// whose row at the subscriber, which holds the job id, cannot be read.
	AgentID     int         `json:"agent_id"`
	Job         *JobState   `json:"job"` // nil: the job's server is not connected
	LastHistory *HistoryRow `json:"last_history,omitempty"`
	LastFailure *HistoryRow `json:"last_failure,omitempty"`
}

// JobState is the state of an agent's SQL Server Agent job.
type JobState struct {
	Exists  bool `json:"exists"`
	Enabled bool `json:"enabled"`
	Running bool `json:"running"`
}

// HistoryRow is a row of an agent history table.
type HistoryRow struct {
	Time      string `json:"time"`
	RunStatus int    `json:"runstatus"`
	Comments  string `json:"comments"`
	ErrorText string `json:"error_text,omitempty"`
}

// ProfileUse is an agent that uses a user-defined profile, in any
// distribution database of the distributor.
type ProfileUse struct {
	Profile        string `json:"profile"`
	AgentType      string `json:"agent_type"`
	DistributionDB string `json:"distribution_db"`
	PublisherDB    string `json:"publisher_db"`
	Publication    string `json:"publication,omitempty"`
	Subscriber     string `json:"subscriber,omitempty"`
	Database       string `json:"database,omitempty"`
}
