// Package model defines the declarative description of a transactional
// replication topology, as written to and read from the configuration file.
//
// The model only carries configuration. Runtime state (subscription status,
// sequence numbers, history) and secrets are left out: a password is never
// exported, only the name of the secret that will provide it at apply time.
package model

// FormatVersion is the version of the file format written and read by this
// package.
const FormatVersion = 2

// Ptr returns a pointer to v. Properties are pointers so that a loaded file
// tells an omitted property (nil) from a zero value.
func Ptr[T any](v T) *T { return &v }

// Config is the root of the configuration file. It describes one publication
// database and everything attached to it.
type Config struct {
	Version       int            `yaml:"version"`
	Publisher     Publisher      `yaml:"publisher"`
	Distributor   *Distributor   `yaml:"distributor,omitempty"`
	Publications  []Publication  `yaml:"publications"`
	AgentProfiles []AgentProfile `yaml:"agent_profiles,omitempty"`
	// Findings lists what the export found and how plan 3 must treat it,
	// each with the path of the element concerned.
	Findings []Finding `yaml:"findings,omitempty"`
}

// Kinds of finding.
const (
	// FindingOutOfScope: a feature the tool does not model.
	FindingOutOfScope = "out_of_scope"
	// FindingIncomplete: something the export expected and did not find, or
	// found inconsistent, so the element is partly exported.
	FindingIncomplete = "incomplete"
	// FindingUnreadable: an object the export could not read, possibly for
	// lack of visibility.
	FindingUnreadable = "unreadable"
	// FindingNote: an observation that needs no action.
	FindingNote = "note"
)

// Finding is one observation of the export about a path of the model.
type Finding struct {
	Kind    string `yaml:"kind"`
	Path    string `yaml:"path"`
	Message string `yaml:"message"`
}

// Publisher identifies the published database.
type Publisher struct {
	// Server is the publisher name as registered at the distributor
	// (msdb.dbo.MSdistpublishers.name), normally @@SERVERNAME.
	Server   string `yaml:"server"`
	Database string `yaml:"database"`
	// SyncWithBackup is sp_replicationdboption 'sync with backup'.
	SyncWithBackup *bool `yaml:"sync_with_backup,omitempty"`
	// LogReaderAgent is shared by every publication of the database.
	LogReaderAgent *Agent `yaml:"log_reader_agent,omitempty"`
	// SharedDistributionAgents serve, for one subscriber database, every
	// publication of the database that has no independent agent.
	SharedDistributionAgents []SharedDistributionAgent `yaml:"shared_distribution_agents,omitempty"`
	// SharedPullAgents serve, for one subscriber database, every pull
	// subscription to a publication of the database that has no independent
	// agent.
	SharedPullAgents []SharedPullAgent `yaml:"shared_pull_agents,omitempty"`
}

// SharedDistributionAgent is a distribution agent recorded with
// publication = N'ALL' in MSdistribution_agents.
type SharedDistributionAgent struct {
	Subscriber        string            `yaml:"subscriber"`
	Database          string            `yaml:"database"`
	DistributionAgent DistributionAgent `yaml:"distribution_agent"`
}

// SharedPullAgent is a pull agent shared by the subscriptions of one
// subscriber database: one job at the subscriber, one row with publication =
// N'ALL' and subscription_type 1 in MSdistribution_agents (measured).
type SharedPullAgent struct {
	Subscriber string `yaml:"subscriber"`
	Database   string `yaml:"database"`
	PullAgent  `yaml:",inline"`
}

// Distributor describes the distributor as seen by this publisher.
type Distributor struct {
	Server   string `yaml:"server"`
	Database string `yaml:"database"`
	// Retention of the distribution database, in hours (MSdistributiondbs).
	MinRetentionHours     *int `yaml:"min_retention_hours,omitempty"`
	MaxRetentionHours     *int `yaml:"max_retention_hours,omitempty"`
	HistoryRetentionHours *int `yaml:"history_retention_hours,omitempty"`
	// WorkingDirectory is the default snapshot folder for this publisher.
	WorkingDirectory *string `yaml:"working_directory,omitempty"`
	// PublisherConnection is how the distributor connects to the publisher
	// (MSdistpublishers.security_mode, login, password).
	PublisherConnection *Connection `yaml:"publisher_connection,omitempty"`
	Trusted             *bool       `yaml:"trusted,omitempty"`
	// DeleteBatchSizeXact and DeleteBatchSizeCmd are the cleanup batch sizes
	// of the distribution database (sp_adddistributiondb).
	DeleteBatchSizeXact *int `yaml:"delete_batch_size_xact,omitempty"`
	DeleteBatchSizeCmd  *int `yaml:"delete_batch_size_cmd,omitempty"`
	// The folders and file names of the distribution database, read from its
	// first data and log files (sys.master_files).
	DataFolder *string `yaml:"data_folder,omitempty"`
	DataFile   *string `yaml:"data_file,omitempty"`
	LogFolder  *string `yaml:"log_folder,omitempty"`
	LogFile    *string `yaml:"log_file,omitempty"`
	// DataFileSizeMB, LogFileSizeMB and CreationConnection only serve to
	// create the distribution database; the export never reads them.
	DataFileSizeMB     *int        `yaml:"data_file_size_mb,omitempty"`
	LogFileSizeMB      *int        `yaml:"log_file_size_mb,omitempty"`
	CreationConnection *Connection `yaml:"creation_connection,omitempty"`
	// AdminPasswordSecret names the secret of the distributor_admin login.
	AdminPasswordSecret *string `yaml:"admin_password_secret,omitempty"`
	// AdminLinkSecurity is windows or sql, read from the repl_distributor
	// linked server at the publisher.
	AdminLinkSecurity   *string `yaml:"admin_link_security,omitempty"`
	MultiSubnetFailover *bool   `yaml:"multi_subnet_failover,omitempty"`
	// StorageConnectionStringSecret names the secret of the Azure storage
	// connection string of the publisher, nil when there is none.
	StorageConnectionStringSecret *string `yaml:"storage_connection_string_secret,omitempty"`
	// Properties holds msdb.dbo.MSdistributor as key/value pairs.
	Properties map[string]string `yaml:"properties,omitempty"`
}

// Connection describes how an agent authenticates to a server.
type Connection struct {
	Security *string `yaml:"security,omitempty"` // windows or sql
	Login    *string `yaml:"login,omitempty"`
	// PasswordSecret names the secret holding the password, for SQL Server
	// authentication. The export proposes a name; the value never leaves the
	// server.
	PasswordSecret *string `yaml:"password_secret,omitempty"`
}

// Agent describes a replication agent and its SQL Server Agent job.
type Agent struct {
	JobName *string `yaml:"job_name,omitempty"`
	// JobEnabled is msdb.dbo.sysjobs.enabled of the agent's job.
	JobEnabled *bool `yaml:"job_enabled,omitempty"`
	// JobLogin is the Windows account the agent job runs under, empty when
	// the row has none. JobPasswordSecret names its password secret.
	JobLogin          *string `yaml:"job_login,omitempty"`
	JobPasswordSecret *string `yaml:"job_password_secret,omitempty"`
	// DistributorConnection is how a snapshot agent connects to the
	// distributor, read from its command line.
	DistributorConnection *Connection `yaml:"distributor_connection,omitempty"`
	// Profile is the name of the agent profile, empty when the agent uses
	// the default profile of its type.
	Profile *string `yaml:"profile,omitempty"`
	// RunAs is the credential identity of the job step proxy, empty when the
	// step runs as the SQL Server Agent service account.
	RunAs      *string     `yaml:"run_as,omitempty"`
	Connection *Connection `yaml:"connection,omitempty"`
	// Schedules is compared as a list: a declared schedule is compared in
	// full, so its own fields are plain values.
	Schedules *[]Schedule `yaml:"schedules,omitempty"`
	// Command is the agent command line of the job step, with password
	// arguments masked. It can override profile parameters.
	Command *string `yaml:"command,omitempty"`
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
	Name        string  `yaml:"name"`
	Description *string `yaml:"description,omitempty"`
	Type        *string `yaml:"type,omitempty"`   // transactional or snapshot
	Status      *string `yaml:"status,omitempty"` // active or inactive
	SyncMethod  *string `yaml:"sync_method,omitempty"`
	// RetentionHours is the subscription expiration period.
	RetentionHours            *int  `yaml:"retention_hours,omitempty"`
	IndependentAgent          *bool `yaml:"independent_agent,omitempty"`
	ImmediateSync             *bool `yaml:"immediate_sync,omitempty"`
	AllowPush                 *bool `yaml:"allow_push,omitempty"`
	AllowPull                 *bool `yaml:"allow_pull,omitempty"`
	AllowAnonymous            *bool `yaml:"allow_anonymous,omitempty"`
	AllowSubscriptionCopy     *bool `yaml:"allow_subscription_copy,omitempty"`
	AllowInitializeFromBackup *bool `yaml:"allow_initialize_from_backup,omitempty"`
	ReplicateDDL              *bool `yaml:"replicate_ddl,omitempty"`
	AllowDrop                 *bool `yaml:"allow_drop,omitempty"`
	AllowPartitionSwitch      *bool `yaml:"allow_partition_switch,omitempty"`
	ReplicatePartitionSwitch  *bool `yaml:"replicate_partition_switch,omitempty"`
	EnabledForHetSub          *bool `yaml:"enabled_for_het_sub,omitempty"`

	Snapshot      *Snapshot      `yaml:"snapshot,omitempty"`
	SnapshotAgent *Agent         `yaml:"snapshot_agent,omitempty"`
	Articles      []Article      `yaml:"articles"`
	Subscriptions []Subscription `yaml:"subscriptions,omitempty"`
}

// Snapshot groups the snapshot-related publication properties.
type Snapshot struct {
	InDefaultFolder *bool   `yaml:"in_default_folder,omitempty"`
	AltFolder       *string `yaml:"alt_folder,omitempty"`
	Compress        *bool   `yaml:"compress,omitempty"`
	PreScript       *string `yaml:"pre_script,omitempty"`
	PostScript      *string `yaml:"post_script,omitempty"`
	// EnabledForInternet is set when the snapshot files are served by FTP; the
	// FTP settings are written exactly then.
	EnabledForInternet *bool `yaml:"enabled_for_internet,omitempty"`
	FTP                *FTP  `yaml:"ftp,omitempty"`
}

// FTP holds the snapshot FTP settings, present when enabled_for_internet is
// set.
type FTP struct {
	Address        *string `yaml:"address,omitempty"`
	Port           *int    `yaml:"port,omitempty"`
	Subdirectory   *string `yaml:"subdirectory,omitempty"`
	Login          *string `yaml:"login,omitempty"`
	PasswordSecret *string `yaml:"password_secret,omitempty"`
}

// ObjectName is a schema-qualified object name.
type ObjectName struct {
	Schema string `yaml:"schema,omitempty"`
	Name   string `yaml:"name"`
}

// Article mirrors one row of sysarticles or sysschemaarticles.
type Article struct {
	Name        string      `yaml:"name"`
	Type        *string     `yaml:"type,omitempty"`
	Source      ObjectName  `yaml:"source"`
	Destination Destination `yaml:"destination"`
	Description *string     `yaml:"description,omitempty"`

	PreCreationCmd *string `yaml:"pre_creation_cmd,omitempty"`
	// SchemaOptions lists the schema option names: an empty list is "no
	// option", an omitted one is the default.
	SchemaOptions  *[]string `yaml:"schema_options,omitempty"`
	CreationScript *string   `yaml:"creation_script,omitempty"`

	// The fields below only apply to table articles (sysarticles). The
	// active bit of sysarticles.status is runtime state and is not modelled.
	InsertColumnNames      *bool       `yaml:"insert_column_names,omitempty"`
	Parameterized          *bool       `yaml:"parameterized,omitempty"`
	Commands               *Commands   `yaml:"commands,omitempty"`
	Filter                 *Filter     `yaml:"filter,omitempty"`
	SyncObject             *ObjectName `yaml:"sync_object,omitempty"`
	FireTriggersOnSnapshot *bool       `yaml:"fire_triggers_on_snapshot,omitempty"`
	// IdentityRangeManagement is none or manual (sp_addarticle
	// @identityrangemanagementoption), read the way sp_helparticle derives
	// it: manual when the table's identity column is NOT FOR REPLICATION.
	// auto is out of scope and reported as a finding.
	IdentityRangeManagement *string `yaml:"identity_range_management,omitempty"`
	// Columns lists the published columns, only when the article is
	// vertically filtered. Omitted and empty both mean every column.
	Columns []string `yaml:"columns,omitempty"`
}

// Destination is the destination object of an article. Schema "" is a NULL
// dest_owner.
type Destination struct {
	Schema *string `yaml:"schema,omitempty"`
	Name   *string `yaml:"name,omitempty"`
}

// Commands holds how inserts, updates and deletes are propagated.
type Commands struct {
	Insert *Command `yaml:"insert,omitempty"`
	Update *Command `yaml:"update,omitempty"`
	Delete *Command `yaml:"delete,omitempty"`
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

// Subscription is a push or pull subscription, grouped from the per-article
// rows of syssubscriptions.
type Subscription struct {
	Subscriber string `yaml:"subscriber"`
	Database   string `yaml:"database"`
	// Articles lists the subscribed articles, only when the subscription
	// does not cover every article of the publication.
	Articles []string `yaml:"articles,omitempty"`
	// Type is push, pull or anonymous; SubscriberType is sql_server, odbc or
	// oledb.
	Type              *string `yaml:"type,omitempty"`
	SubscriberType    *string `yaml:"subscriber_type,omitempty"`
	Initialization    *string `yaml:"initialization,omitempty"`
	LoopbackDetection *bool   `yaml:"loopback_detection,omitempty"`
	// DistributionAgent is set when the publication has an independent
	// agent. Otherwise the subscription uses the shared agent of its
	// subscriber database, listed under publisher.shared_distribution_agents.
	DistributionAgent *DistributionAgent `yaml:"distribution_agent,omitempty"`
	// PullAgent is the distribution agent of a pull subscription, read at
	// the subscriber; set only when type is pull and the publication has an
	// independent agent. Otherwise the subscription uses the shared pull
	// agent of its subscriber database, under publisher.shared_pull_agents.
	PullAgent *PullAgent `yaml:"pull_agent,omitempty"`
	// Backup is how an initialize with backup subscription restores its
	// backup (sp_addsubscription @backupdevicetype and the parameters after
	// it). It only serves the creation call; the server stores nothing.
	Backup *BackupInitialization `yaml:"backup,omitempty"`
	// LSN is the hexadecimal @subscriptionlsn of an initialize from lsn
	// subscription. It only serves the creation call: what the server keeps
	// (MSsubscriptions.subscription_seqno) is the subscription's window,
	// runtime state.
	LSN *string `yaml:"lsn,omitempty"`
}

// BackupInitialization holds the parameters of sp_addsubscription read when
// sync_type is initialize with backup (11-defaults, no-column).
type BackupInitialization struct {
	DeviceType          *string `yaml:"device_type,omitempty"`
	DeviceName          *string `yaml:"device_name,omitempty"`
	MediaPasswordSecret *string `yaml:"media_password_secret,omitempty"`
	PasswordSecret      *string `yaml:"password_secret,omitempty"`
	FileIDHint          *int    `yaml:"file_id_hint,omitempty"`
	Unload              *bool   `yaml:"unload,omitempty"`
}

// DistributionAgent extends Agent with the distribution-specific settings.
type DistributionAgent struct {
	Agent               `yaml:",inline"`
	SubscriptionStreams *int  `yaml:"subscription_streams,omitempty"`
	MemoryOptimized     *bool `yaml:"memory_optimized,omitempty"`
}

// PullAgent extends DistributionAgent with the settings a pull subscription
// keeps at the subscriber (MSsubscription_properties,
// MSreplication_subscriptions). Its job lives in the subscriber's msdb.
type PullAgent struct {
	DistributionAgent `yaml:",inline"`
	// Distributor is the distributor the agent connects to, as recorded at
	// the subscriber.
	Distributor       *string `yaml:"distributor,omitempty"`
	AltSnapshotFolder *string `yaml:"alt_snapshot_folder,omitempty"`
	WorkingDirectory  *string `yaml:"working_directory,omitempty"`
	UseFTP            *bool   `yaml:"use_ftp,omitempty"`
	EnabledForSyncmgr *bool   `yaml:"enabled_for_syncmgr,omitempty"`
	Description       *string `yaml:"description,omitempty"`
}

// AgentProfile is a user-defined agent profile (MSagent_profiles.type = 1).
type AgentProfile struct {
	Name        string            `yaml:"name"`
	AgentType   string            `yaml:"agent_type"`
	Description *string           `yaml:"description,omitempty"`
	Default     *bool             `yaml:"default,omitempty"`
	Parameters  map[string]string `yaml:"parameters"`
}
