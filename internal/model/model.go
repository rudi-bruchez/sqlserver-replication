// Package model defines the declarative description of a transactional
// replication topology, as written to and read from the configuration file.
//
// The model only carries configuration. Runtime state (subscription status,
// sequence numbers, history) and secrets are left out: a password is never
// exported, only the name of the secret that will provide it at apply time.
package model

// FormatVersion is the version of the file format written by this package.
const FormatVersion = 1

// Config is the root of the configuration file. It describes one publication
// database and everything attached to it.
type Config struct {
	Version       int            `yaml:"version"`
	Publisher     Publisher      `yaml:"publisher"`
	Distributor   Distributor    `yaml:"distributor"`
	Publications  []Publication  `yaml:"publications"`
	AgentProfiles []AgentProfile `yaml:"agent_profiles,omitempty"`
	// Warnings lists what the export found but cannot represent faithfully:
	// out-of-scope features, undecoded bits, inconsistent rows.
	Warnings []string `yaml:"warnings,omitempty"`
}

// Publisher identifies the published database.
type Publisher struct {
	// Server is the publisher name as registered at the distributor
	// (msdb.dbo.MSdistpublishers.name), normally @@SERVERNAME.
	Server   string `yaml:"server"`
	Database string `yaml:"database"`
	// LogReaderAgent is shared by every publication of the database.
	LogReaderAgent *Agent `yaml:"log_reader_agent,omitempty"`
	// SharedDistributionAgents serve, for one subscriber database, every
	// publication of the database that has no independent agent.
	SharedDistributionAgents []SharedDistributionAgent `yaml:"shared_distribution_agents,omitempty"`
}

// SharedDistributionAgent is a distribution agent recorded with
// publication = N'ALL' in MSdistribution_agents.
type SharedDistributionAgent struct {
	Subscriber        string            `yaml:"subscriber"`
	Database          string            `yaml:"database"`
	DistributionAgent DistributionAgent `yaml:"distribution_agent"`
}

// Distributor describes the distributor as seen by this publisher.
type Distributor struct {
	Server   string `yaml:"server"`
	Database string `yaml:"database"`
	// Retention of the distribution database, in hours (MSdistributiondbs).
	MinRetentionHours     int `yaml:"min_retention_hours"`
	MaxRetentionHours     int `yaml:"max_retention_hours"`
	HistoryRetentionHours int `yaml:"history_retention_hours"`
	// WorkingDirectory is the default snapshot folder for this publisher.
	WorkingDirectory string `yaml:"working_directory"`
	// PublisherConnection is how the distributor connects to the publisher
	// (MSdistpublishers.security_mode, login, password).
	PublisherConnection Connection `yaml:"publisher_connection"`
	Trusted             bool       `yaml:"trusted"`
	// Properties holds msdb.dbo.MSdistributor as key/value pairs.
	Properties map[string]string `yaml:"properties,omitempty"`
}

// Connection describes how an agent authenticates to a server.
type Connection struct {
	Security string `yaml:"security"` // windows or sql
	Login    string `yaml:"login,omitempty"`
	// PasswordSecret names the secret holding the password, for SQL Server
	// authentication. The export proposes a name; the value never leaves the
	// server.
	PasswordSecret string `yaml:"password_secret,omitempty"`
}

// Agent describes a replication agent and its SQL Server Agent job.
type Agent struct {
	JobName string `yaml:"job_name,omitempty"`
	// Profile is the name of the agent profile, empty when the agent uses
	// the default profile of its type.
	Profile string `yaml:"profile,omitempty"`
	// RunAs is the credential identity of the job step proxy, empty when the
	// step runs as the SQL Server Agent service account.
	RunAs      string      `yaml:"run_as,omitempty"`
	Connection *Connection `yaml:"connection,omitempty"`
	Schedules  []Schedule  `yaml:"schedules,omitempty"`
	// Command is the agent command line of the job step, with password
	// arguments masked. It can override profile parameters.
	Command string `yaml:"command,omitempty"`
}

// Schedule mirrors msdb.dbo.sysschedules. Dates are yyyymmdd and times
// hhmmss, as stored.
type Schedule struct {
	Name             string `yaml:"name"`
	Enabled          bool   `yaml:"enabled"`
	Frequency        string `yaml:"frequency"`
	Interval         int    `yaml:"interval,omitempty"`
	Subday           string `yaml:"subday,omitempty"`
	SubdayInterval   int    `yaml:"subday_interval,omitempty"`
	RelativeInterval int    `yaml:"relative_interval,omitempty"`
	RecurrenceFactor int    `yaml:"recurrence_factor,omitempty"`
	StartDate        int    `yaml:"start_date,omitempty"`
	EndDate          int    `yaml:"end_date,omitempty"`
	StartTime        int    `yaml:"start_time,omitempty"`
	EndTime          int    `yaml:"end_time,omitempty"`
}

// Publication mirrors syspublications for one publication.
type Publication struct {
	Name        string `yaml:"name"`
	Description string `yaml:"description,omitempty"`
	Type        string `yaml:"type"`   // transactional or snapshot
	Status      string `yaml:"status"` // active or inactive
	SyncMethod  string `yaml:"sync_method"`
	// RetentionHours is the subscription expiration period.
	RetentionHours            int  `yaml:"retention_hours"`
	IndependentAgent          bool `yaml:"independent_agent"`
	ImmediateSync             bool `yaml:"immediate_sync"`
	AllowPush                 bool `yaml:"allow_push"`
	AllowPull                 bool `yaml:"allow_pull"`
	AllowAnonymous            bool `yaml:"allow_anonymous"`
	AllowSubscriptionCopy     bool `yaml:"allow_subscription_copy"`
	AllowInitializeFromBackup bool `yaml:"allow_initialize_from_backup"`
	ReplicateDDL              bool `yaml:"replicate_ddl"`
	AllowDrop                 bool `yaml:"allow_drop"`

	Snapshot      Snapshot       `yaml:"snapshot"`
	SnapshotAgent *Agent         `yaml:"snapshot_agent,omitempty"`
	Articles      []Article      `yaml:"articles"`
	Subscriptions []Subscription `yaml:"subscriptions,omitempty"`
}

// Snapshot groups the snapshot-related publication properties.
type Snapshot struct {
	InDefaultFolder bool   `yaml:"in_default_folder"`
	AltFolder       string `yaml:"alt_folder,omitempty"`
	Compress        bool   `yaml:"compress"`
	PreScript       string `yaml:"pre_script,omitempty"`
	PostScript      string `yaml:"post_script,omitempty"`
	FTP             *FTP   `yaml:"ftp,omitempty"`
}

// FTP holds the snapshot FTP settings, present when enabled_for_internet is
// set.
type FTP struct {
	Address        string `yaml:"address,omitempty"`
	Port           int    `yaml:"port,omitempty"`
	Subdirectory   string `yaml:"subdirectory,omitempty"`
	Login          string `yaml:"login,omitempty"`
	PasswordSecret string `yaml:"password_secret,omitempty"`
}

// ObjectName is a schema-qualified object name.
type ObjectName struct {
	Schema string `yaml:"schema,omitempty"`
	Name   string `yaml:"name"`
}

// Article mirrors one row of sysarticles or sysschemaarticles.
type Article struct {
	Name        string     `yaml:"name"`
	Type        string     `yaml:"type"`
	Source      ObjectName `yaml:"source"`
	Destination ObjectName `yaml:"destination"`
	Description string     `yaml:"description,omitempty"`

	PreCreationCmd string   `yaml:"pre_creation_cmd"`
	SchemaOptions  []string `yaml:"schema_options"`
	CreationScript string   `yaml:"creation_script,omitempty"`

	// The fields below only apply to table articles (sysarticles).
	Active                 bool        `yaml:"active,omitempty"`
	InsertColumnNames      bool        `yaml:"insert_column_names,omitempty"`
	Parameterized          bool        `yaml:"parameterized,omitempty"`
	Commands               *Commands   `yaml:"commands,omitempty"`
	Filter                 *Filter     `yaml:"filter,omitempty"`
	SyncObject             *ObjectName `yaml:"sync_object,omitempty"`
	FireTriggersOnSnapshot bool        `yaml:"fire_triggers_on_snapshot,omitempty"`
	// Columns lists the published columns, only when the article is
	// vertically filtered. Empty means every column is published.
	Columns []string `yaml:"columns,omitempty"`
}

// Commands holds how inserts, updates and deletes are propagated.
type Commands struct {
	Insert Command `yaml:"insert"`
	Update Command `yaml:"update"`
	Delete Command `yaml:"delete"`
}

// Command is one decoded ins_cmd, upd_cmd or del_cmd.
type Command struct {
	Mode      string      `yaml:"mode"`
	Procedure *ObjectName `yaml:"procedure,omitempty"`
}

// Filter is a horizontal (row) filter.
type Filter struct {
	Clause    string      `yaml:"clause"`
	Procedure *ObjectName `yaml:"procedure,omitempty"`
}

// Subscription is a push subscription, grouped from the per-article rows of
// syssubscriptions.
type Subscription struct {
	Subscriber string `yaml:"subscriber"`
	Database   string `yaml:"database"`
	// Articles lists the subscribed articles, only when the subscription
	// does not cover every article of the publication.
	Articles          []string `yaml:"articles,omitempty"`
	Initialization    string   `yaml:"initialization"`
	LoopbackDetection bool     `yaml:"loopback_detection,omitempty"`
	// DistributionAgent is set when the publication has an independent
	// agent. Otherwise the subscription uses the shared agent of its
	// subscriber database, listed under publisher.shared_distribution_agents.
	DistributionAgent *DistributionAgent `yaml:"distribution_agent,omitempty"`
}

// DistributionAgent extends Agent with the distribution-specific settings.
type DistributionAgent struct {
	Agent               `yaml:",inline"`
	SubscriptionStreams int  `yaml:"subscription_streams,omitempty"`
	MemoryOptimized     bool `yaml:"memory_optimized,omitempty"`
}

// AgentProfile is a user-defined agent profile (MSagent_profiles.type = 1).
type AgentProfile struct {
	Name        string            `yaml:"name"`
	AgentType   string            `yaml:"agent_type"`
	Description string            `yaml:"description,omitempty"`
	Default     bool              `yaml:"default,omitempty"`
	Parameters  map[string]string `yaml:"parameters"`
}
