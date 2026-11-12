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
	// PublisherDatabases is every row of MSpublisher_databases of every
	// distribution database of the distributor.
	PublisherDatabases []PublisherDatabase `json:"publisher_databases"`
	// TemplateProfileParameters are, for each agent type, the parameters
	// sp_add_agent_profile copies into a new profile: those of the system
	// profile MIN(profile_id) of the type (sp_add_agent_profile.sql:82),
	// which is not always the default profile.
	TemplateProfileParameters []ProfileParameter `json:"template_profile_parameters"`
	// DefaultProfiles is the profile with def_profile = 1 of each agent type,
	// the one an agent without a profile uses.
	DefaultProfiles []DefaultProfile `json:"default_profiles"`
}

// PublisherDatabase is a publication database registered in a distribution
// database. Publisher is named through that database's own server table.
type PublisherDatabase struct {
	DistributionDB string `json:"distribution_db"`
	Publisher      string `json:"publisher"`
	Database       string `json:"database"`
}

// ProfileParameter is a parameter of an agent profile. AgentType is the name
// the model uses (snapshot, logreader, distribution...).
type ProfileParameter struct {
	AgentType string `json:"agent_type"`
	Name      string `json:"name"`
	Value     string `json:"value"`
}

// DefaultProfile is the default profile of an agent type.
type DefaultProfile struct {
	AgentType string `json:"agent_type"`
	Name      string `json:"name"`
}

// PublicationFacts is the snapshot state of a publication.
type PublicationFacts struct {
	Name string `json:"name"`
	// ImmediateSyncReady is syspublications.immediate_sync_ready.
	ImmediateSyncReady bool `json:"immediate_sync_ready"`
	// LastGeneration is the end of the latest run of the publication's
	// snapshot agent that generated a snapshot, not of a run that found
	// nothing to do; empty when there is none.
	LastGeneration string         `json:"last_generation,omitempty"`
	Articles       []ArticleFacts `json:"articles"`
}

// ArticleFacts is the state of an article.
type ArticleFacts struct {
	Name string `json:"name"`
	// Active is bit 0x1 of the article status (sysarticles or
	// sysschemaarticles), set by the snapshot generation; it is never a
	// witness of a delivery.
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
	Publisher      string `json:"publisher"`
	PublisherDB    string `json:"publisher_db"`
	Publication    string `json:"publication,omitempty"`
	Subscriber     string `json:"subscriber,omitempty"`
	Database       string `json:"database,omitempty"`
	// Virtual is set for the distribution agent of a virtual subscriber
	// (subscriber_id < 0), whose Subscriber is empty: a profile bound to it
	// may still block a profile drop.
	Virtual bool `json:"virtual,omitempty"`
}

// Checks is what the precondition checks read, beside the facts: the
// servers of the file, the source tables, the subscriber databases and the
// folders the configuration names, and the agent profiles at the
// distributor. The planner reads them; a nil Checks leaves every
// precondition unchecked.
type Checks struct {
	Servers             []ServerCheck   `json:"servers"`
	Tables              []TableCheck    `json:"tables"`
	SubscriberDatabases []DatabaseCheck `json:"subscriber_databases"`
	Folders             []FolderCheck   `json:"folders"`
	// Profiles is every row of msdb.dbo.MSagent_profiles at the
	// distributor, system profiles included; empty when it was not read.
	Profiles []ProfileCheck `json:"profiles"`
}

// ServerCheck is a server of the file, as it was reached.
type ServerCheck struct {
	Name string `json:"name"`
	// ServerName is @@SERVERNAME as the server answers it.
	ServerName string `json:"server_name"`
	Version    string `json:"version"`
	Edition    string `json:"edition"`
	Error      string `json:"error"` // why it could not be reached
	Reachable  bool   `json:"reachable"`
	Major      int    `json:"major"`
}

// TableCheck is a source table of an article, in the publication database.
type TableCheck struct {
	Schema        string   `json:"schema"`
	Name          string   `json:"name"`
	Exists        bool     `json:"exists"`
	HasPrimaryKey bool     `json:"has_primary_key"`
	Columns       []string `json:"columns"` // in column_id order
	// KeyColumns is the columns of its primary key, in key order: a column
	// subset cannot leave one out (21250, measured).
	KeyColumns []string `json:"key_columns"`
}

// DatabaseCheck is a subscriber database; Checked is false when its server
// could not be reached.
type DatabaseCheck struct {
	Server   string `json:"server"`
	Database string `json:"database"`
	Checked  bool   `json:"checked"`
	Exists   bool   `json:"exists"`
}

// ProfileCheck is an agent profile at the distributor; AgentType is a
// decode.AgentType name (snapshot, logreader, distribution...).
type ProfileCheck struct {
	Name      string `json:"name"`
	AgentType string `json:"agent_type"`
}

// FolderCheck is a folder the configuration names on a server; Checked is
// false when it could not be read.
type FolderCheck struct {
	Server  string `json:"server"`
	Path    string `json:"path"`
	Checked bool   `json:"checked"`
	Exists  bool   `json:"exists"`
}
