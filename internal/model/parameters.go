package model

// ParamKind tells how a parameter of a replication creation procedure maps to
// the model.
type ParamKind string

const (
	ParamField        ParamKind = "field"         // in the model and read by the export; whether plan 3 compares it is the cost table's
	ParamCreationOnly ParamKind = "creation_only" // in the model, passed at creation, never read
	ParamExcluded     ParamKind = "excluded"      // not in the model
)

// ParamMapping maps one parameter of a creation procedure, as listed by
// lab/results/<version>/17-parameters.txt, to the model.
type ParamMapping struct {
	Procedure string // sp_addarticle
	Parameter string // @schema_option
	Kind      ParamKind
	// Paths are path patterns of the model ([*] for a list element), e.g.
	// publications[*].articles[*].schema_options; empty when excluded.
	Paths []string
	// Reason is required for creation_only and excluded: the source (an
	// 11-defaults row, Learn, a measurement).
	Reason string
	// Since is "2019", "2022" or "2025": the first listed version that has
	// the parameter.
	Since string
}

// Path patterns of the model elements the procedures create.
const (
	pPubs       = "publications[*]"
	pArts       = pPubs + ".articles[*]"
	pSubs       = pPubs + ".subscriptions[*]"
	pPushAgent  = pSubs + ".distribution_agent"
	pSharedPush = "publisher.shared_distribution_agents[*].distribution_agent"
	pPullAgent  = pSubs + ".pull_agent"
	pSharedPull = "publisher.shared_pull_agents[*]"
	pSnapAgent  = pPubs + ".snapshot_agent"
	pLogAgent   = "publisher.log_reader_agent"
	pProfiles   = "agent_profiles[*]"
	pDist       = "distributor"
)

// Reasons shared by several entries.
const (
	rFlag       = "a flag or an output of the call, not configuration"
	rPublisher  = "names a non-SQL Server publisher (Learn); the publisher of the file is publisher.server; reported as out_of_scope when set"
	rNonSQL     = "non-SQL Server publishers or subscribers (Learn); reported as out_of_scope when set"
	rMI         = "Managed Instance only (41989, 07-changes AGT.*.job_security_mode)"
	rOffload    = "no longer supported (21698, 08-pull P2.offload_*)"
	rOutOfScope = "out of scope (updatable, queued, peer-to-peer, DTS); reported as out_of_scope when set"
	rIdentity   = "identity range management serves updatable subscriptions and stores no row by default (11-defaults no-row)"
	rBackup     = "read only when sync_type is initialize with backup, stored nowhere (11-defaults D.sp_addsubscription.push.@backupdevicetype and following, no-column)"
	rCreateDB   = "only serves to create the distribution database, never read (distributor-defaults D.sp_adddistributiondb.fresh)"
)

const sinceDefault = "2022"

func field(proc, param string, paths ...string) ParamMapping {
	return ParamMapping{Procedure: proc, Parameter: param, Kind: ParamField, Paths: paths, Since: sinceDefault}
}

func creationOnly(proc, param, reason string, paths ...string) ParamMapping {
	return ParamMapping{Procedure: proc, Parameter: param, Kind: ParamCreationOnly, Paths: paths, Reason: reason, Since: sinceDefault}
}

func excluded(proc, param, reason string) ParamMapping {
	return ParamMapping{Procedure: proc, Parameter: param, Kind: ParamExcluded, Reason: reason, Since: sinceDefault}
}

// under joins key to each base path.
func under(key string, bases ...string) []string {
	out := make([]string, len(bases))
	for i, b := range bases {
		out[i] = Join(b, key)
	}
	return out
}

// schedule maps the @frequency_* and @active_* parameters of proc to the
// schedules of the agents at bases.
func schedule(proc string, bases ...string) []ParamMapping {
	keys := []struct{ param, key string }{
		{"@frequency_type", "frequency"},
		{"@frequency_interval", "interval"},
		{"@frequency_subday", "subday"},
		{"@frequency_subday_interval", "subday_interval"},
		{"@frequency_relative_interval", "relative_interval"},
		{"@frequency_recurrence_factor", "recurrence_factor"},
		{"@active_start_date", "start_date"},
		{"@active_end_date", "end_date"},
		{"@active_start_time_of_day", "start_time"},
		{"@active_end_time_of_day", "end_time"},
	}
	out := make([]ParamMapping, 0, len(keys))
	for _, k := range keys {
		out = append(out, field(proc, k.param, under("schedules[*]."+k.key, bases...)...))
	}
	return out
}

// connection maps the security mode, login and password parameters named
// prefix+"security_mode" and so on to the connection at each base.
func connection(proc, prefix, conn string, bases ...string) []ParamMapping {
	return []ParamMapping{
		field(proc, prefix+"security_mode", under(conn+".security", bases...)...),
		field(proc, prefix+"login", under(conn+".login", bases...)...),
		field(proc, prefix+"password", under(conn+".password_secret", bases...)...),
	}
}

func concat(groups ...[]ParamMapping) []ParamMapping {
	var out []ParamMapping
	for _, g := range groups {
		out = append(out, g...)
	}
	return out
}

// The agents of a push subscription, independent or shared, and of a pull
// subscription.
var (
	pushAgents = []string{pPushAgent, pSharedPush}
	pullAgents = []string{pPullAgent, pSharedPull}
	allAgents  = []string{pLogAgent, pSnapAgent, pPushAgent, pSharedPush, pPullAgent, pSharedPull}
)

// Parameters maps every parameter of the creation procedures listed by
// lab/results/<version>/17-parameters.txt. TestParametersCovered checks that
// each listed parameter has exactly one entry.
var Parameters = concat(
	agentProfileParameters(),
	articleParameters(),
	distributorParameters(),
	publicationParameters(),
	pullParameters(),
	pushParameters(),
	subscriptionParameters(),
	articleChangeParameters(),
	[]ParamMapping{
		field("sp_replicationdboption", "@dbname", "publisher.database"),
		{
			Procedure: "sp_replicationdboption", Parameter: "@optname", Kind: ParamField,
			Paths:  []string{"publisher.sync_with_backup"},
			Reason: "'sync with backup' is publisher.sync_with_backup; 'publish' is implied by a file with publications; 'subscribe' and 'merge publish' are not this database's configuration",
			Since:  sinceDefault,
		},
		{
			Procedure: "sp_replicationdboption", Parameter: "@value", Kind: ParamField,
			Paths:  []string{"publisher.sync_with_backup"},
			Reason: "the value of @optname: publisher.sync_with_backup for 'sync with backup'; the other options are not this database's configuration",
			Since:  sinceDefault,
		},
		excluded("sp_replicationdboption", "@ignore_distributor", rFlag),
		excluded("sp_replicationdboption", "@from_scripting", rFlag),
	},
)

func agentProfileParameters() []ParamMapping {
	const add, upd = "sp_add_agent_profile", "sp_update_agent_profile"
	agentKey := "the agent is named by its place in the file, not by a key field"
	return []ParamMapping{
		field("sp_add_agent_parameter", "@profile_id", pProfiles+".name"),
		field("sp_add_agent_parameter", "@parameter_name", pProfiles+".parameters"),
		field("sp_add_agent_parameter", "@parameter_value", pProfiles+".parameters"),
		excluded(add, "@profile_id", rFlag),
		field(add, "@profile_name", pProfiles+".name"),
		field(add, "@agent_type", pProfiles+".agent_type"),
		excluded(add, "@profile_type", "a profile the file holds is always user-defined (1); system profiles are not in the file"),
		field(add, "@description", pProfiles+".description"),
		field(add, "@default", pProfiles+".default"),
		{Procedure: upd, Parameter: "@agent_type", Kind: ParamField, Paths: allAgents, Reason: agentKey, Since: sinceDefault},
		{Procedure: upd, Parameter: "@agent_id", Kind: ParamField, Paths: allAgents, Reason: agentKey, Since: sinceDefault},
		field(upd, "@profile_id", under("profile", allAgents...)...),
	}
}

func articleParameters() []ParamMapping {
	const p = "sp_addarticle"
	return []ParamMapping{
		field(p, "@publication", pPubs+".name"),
		field(p, "@article", pArts+".name"),
		field(p, "@source_table", pArts+".source"),
		field(p, "@destination_table", pArts+".destination.name"),
		field(p, "@vertical_partition", pArts+".columns"),
		field(p, "@type", pArts+".type"),
		field(p, "@filter", pArts+".filter.procedure"),
		field(p, "@sync_object", pArts+".sync_object"),
		field(p, "@ins_cmd", pArts+".commands.insert"),
		field(p, "@del_cmd", pArts+".commands.delete"),
		field(p, "@upd_cmd", pArts+".commands.update"),
		field(p, "@creation_script", pArts+".creation_script"),
		field(p, "@description", pArts+".description"),
		field(p, "@pre_creation_cmd", pArts+".pre_creation_cmd"),
		field(p, "@filter_clause", pArts+".filter.clause"),
		field(p, "@schema_option", pArts+".schema_options"),
		field(p, "@destination_owner", pArts+".destination.schema"),
		{
			Procedure: p, Parameter: "@status", Kind: ParamField,
			Paths:  []string{pArts + ".insert_column_names", pArts + ".parameterized"},
			Reason: "the active bit of sysarticles.status is runtime state, read as a fact",
			Since:  sinceDefault,
		},
		field(p, "@source_owner", pArts+".source.schema"),
		field(p, "@sync_object_owner", pArts+".sync_object.schema"),
		field(p, "@filter_owner", pArts+".filter.procedure.schema"),
		field(p, "@source_object", pArts+".source.name"),
		excluded(p, "@artid", rFlag),
		excluded(p, "@auto_identity_range", rIdentity),
		excluded(p, "@pub_identity_range", rIdentity),
		excluded(p, "@identity_range", rIdentity),
		excluded(p, "@threshold", rIdentity),
		excluded(p, "@force_invalidate_snapshot", rFlag),
		excluded(p, "@use_default_datatypes", rNonSQL),
		excluded(p, "@identityrangemanagementoption", rIdentity),
		excluded(p, "@publisher", rPublisher),
		field(p, "@fire_triggers_on_snapshot", pArts+".fire_triggers_on_snapshot"),
	}
}

func distributorParameters() []ParamMapping {
	const dp, db, d = "sp_adddistpublisher", "sp_adddistributiondb", "sp_adddistributor"
	return concat(
		[]ParamMapping{
			field(dp, "@publisher", "publisher.server"),
			field(dp, "@distribution_db", pDist+".database"),
		},
		connection(dp, "@", "publisher_connection", pDist),
		[]ParamMapping{
			field(dp, "@working_directory", pDist+".working_directory"),
			field(dp, "@trusted", pDist+".trusted"),
			excluded(dp, "@encrypted_password", rFlag),
			excluded(dp, "@thirdparty_flag", rNonSQL),
			excluded(dp, "@publisher_type", rNonSQL),
			field(dp, "@storage_connection_string", pDist+".storage_connection_string_secret"),

			field(db, "@database", pDist+".database"),
			field(db, "@data_folder", pDist+".data_folder"),
			field(db, "@data_file", pDist+".data_file"),
			creationOnly(db, "@data_file_size", rCreateDB+", @data_file_size", pDist+".data_file_size_mb"),
			field(db, "@log_folder", pDist+".log_folder"),
			field(db, "@log_file", pDist+".log_file"),
			creationOnly(db, "@log_file_size", rCreateDB+", @log_file_size", pDist+".log_file_size_mb"),
			field(db, "@min_distretention", pDist+".min_retention_hours"),
			field(db, "@max_distretention", pDist+".max_retention_hours"),
			field(db, "@history_retention", pDist+".history_retention_hours"),
			creationOnly(db, "@security_mode", "checked by the procedure, stored nowhere (distributor-defaults D.sp_adddistributiondb.fresh.@security_mode, no-column)", pDist+".creation_connection.security"),
			creationOnly(db, "@login", "checked by the procedure, stored nowhere (distributor-defaults D.sp_adddistributiondb.fresh.@login, no-column)", pDist+".creation_connection.login"),
			creationOnly(db, "@password", "the server stores nothing of it: it only serves the creation connection", pDist+".creation_connection.password_secret"),
			excluded(db, "@createmode", rFlag),
			excluded(db, "@from_scripting", rFlag),
			field(db, "@deletebatchsize_xact", pDist+".delete_batch_size_xact"),
			field(db, "@deletebatchsize_cmd", pDist+".delete_batch_size_cmd"),

			field(d, "@distributor", pDist+".server"),
			field(d, "@heartbeat_interval", pDist+".properties.heartbeat_interval"),
			field(d, "@password", pDist+".admin_password_secret"),
			excluded(d, "@from_scripting", rFlag),
			field(d, "@security_mode", pDist+".admin_link_security"),
			field(d, "@multi_subnet_failover", pDist+".multi_subnet_failover"),
		},
	)
}

func publicationParameters() []ParamMapping {
	const lr, p, s = "sp_addlogreader_agent", "sp_addpublication", "sp_addpublication_snapshot"
	notStored := func(param, source string) ParamMapping {
		return excluded(p, param, "not stored and not needed ("+source+")")
	}
	return concat(
		[]ParamMapping{
			field(lr, "@job_login", pLogAgent+".job_login"),
			field(lr, "@job_password", pLogAgent+".job_password_secret"),
			field(lr, "@job_name", pLogAgent+".job_name"),
		},
		connection(lr, "@publisher_", "connection", pLogAgent),
		[]ParamMapping{
			excluded(lr, "@publisher", rPublisher),
			excluded(lr, "@job_security_mode", rMI),

			field(p, "@publication", pPubs+".name"),
			notStored("@taskid", "11-defaults D.sp_addpublication.transactional.@taskid, no-column: backward compatibility only"),
			notStored("@restricted", "11-defaults D.sp_addpublication.transactional.@restricted, no-column: publication security of SQL Server 7.0"),
			field(p, "@sync_method", pPubs+".sync_method"),
			field(p, "@repl_freq", pPubs+".type"),
			field(p, "@description", pPubs+".description"),
			field(p, "@status", pPubs+".status"),
			field(p, "@independent_agent", pPubs+".independent_agent"),
			field(p, "@immediate_sync", pPubs+".immediate_sync"),
			field(p, "@enabled_for_internet", pPubs+".snapshot.enabled_for_internet"),
			field(p, "@allow_push", pPubs+".allow_push"),
			field(p, "@allow_pull", pPubs+".allow_pull"),
			field(p, "@allow_anonymous", pPubs+".allow_anonymous"),
			excluded(p, "@allow_sync_tran", rOutOfScope),
			excluded(p, "@autogen_sync_procs", rOutOfScope),
			field(p, "@retention", pPubs+".retention_hours"),
			excluded(p, "@allow_queued_tran", rOutOfScope),
			field(p, "@snapshot_in_defaultfolder", pPubs+".snapshot.in_default_folder"),
			field(p, "@alt_snapshot_folder", pPubs+".snapshot.alt_folder"),
			field(p, "@pre_snapshot_script", pPubs+".snapshot.pre_script"),
			field(p, "@post_snapshot_script", pPubs+".snapshot.post_script"),
			field(p, "@compress_snapshot", pPubs+".snapshot.compress"),
			field(p, "@ftp_address", pPubs+".snapshot.ftp.address"),
			field(p, "@ftp_port", pPubs+".snapshot.ftp.port"),
			field(p, "@ftp_subdirectory", pPubs+".snapshot.ftp.subdirectory"),
			field(p, "@ftp_login", pPubs+".snapshot.ftp.login"),
			field(p, "@ftp_password", pPubs+".snapshot.ftp.password_secret"),
			excluded(p, "@allow_dts", rOutOfScope),
			field(p, "@allow_subscription_copy", pPubs+".allow_subscription_copy"),
			excluded(p, "@conflict_policy", rOutOfScope),
			excluded(p, "@centralized_conflicts", rOutOfScope),
			excluded(p, "@conflict_retention", rOutOfScope),
			excluded(p, "@queue_type", rOutOfScope),
			notStored("@add_to_active_directory", "11-defaults D.sp_addpublication.transactional.@add_to_active_directory: syspublications.ad_guidname stays NULL"),
			field(p, "@logreader_job_name", pLogAgent+".job_name"),
			excluded(p, "@qreader_job_name", rOutOfScope),
			excluded(p, "@publisher", rPublisher),
			field(p, "@allow_initialize_from_backup", pPubs+".allow_initialize_from_backup"),
			field(p, "@replicate_ddl", pPubs+".replicate_ddl"),
			excluded(p, "@enabled_for_p2p", rOutOfScope),
			excluded(p, "@publish_local_changes_only", rOutOfScope),
			field(p, "@enabled_for_het_sub", pPubs+".enabled_for_het_sub"),
			excluded(p, "@p2p_conflictdetection", rOutOfScope),
			excluded(p, "@p2p_originator_id", rOutOfScope),
			excluded(p, "@p2p_continue_onconflict", rOutOfScope),
			field(p, "@allow_partition_switch", pPubs+".allow_partition_switch"),
			field(p, "@replicate_partition_switch", pPubs+".replicate_partition_switch"),
			field(p, "@allow_drop", pPubs+".allow_drop"),
			excluded(p, "@p2p_conflictdetection_policy", rOutOfScope),

			field(s, "@publication", pPubs+".name"),
		},
		schedule(s, pSnapAgent),
		[]ParamMapping{field(s, "@snapshot_job_name", pSnapAgent+".job_name")},
		connection(s, "@publisher_", "connection", pSnapAgent),
		[]ParamMapping{
			field(s, "@job_login", pSnapAgent+".job_login"),
			field(s, "@job_password", pSnapAgent+".job_password_secret"),
			excluded(s, "@publisher", rPublisher),
		},
		connection(s, "@distributor_", "distributor_connection", pSnapAgent),
		[]ParamMapping{excluded(s, "@job_security_mode", rMI)},
	)
}

func pullParameters() []ParamMapping {
	const ps, pa = "sp_addpullsubscription", "sp_addpullsubscription_agent"
	publisher := "the publisher the pull procedures connect to, required (14043 on NULL, panel review)"
	stored := "stored at the subscriber with a default of 1, not copied from the publication: plan 3 passes the publication's value and the reader reports a disagreement (panel review, Task 10)"
	pullFTP := "inserted as NULL whatever is passed (stored-procedures/sp_addpullsubscription_agent.sql:754-767, 08-pull P2.ftp_*)"
	return concat(
		[]ParamMapping{
			{Procedure: ps, Parameter: "@publisher", Kind: ParamField, Paths: []string{"publisher.server"}, Reason: publisher, Since: sinceDefault},
			field(ps, "@publisher_db", "publisher.database"),
			field(ps, "@publication", pPubs+".name"),
			{Procedure: ps, Parameter: "@independent_agent", Kind: ParamField, Paths: []string{pPubs + ".independent_agent"}, Reason: stored, Since: sinceDefault},
			excluded(ps, "@subscription_type", "not stored and not needed: the subscription's type is publications[*].subscriptions[*].type, from sp_addsubscription (11-defaults D.sp_addpullsubscription.pull.@subscription_type)"),
			field(ps, "@description", under("description", pullAgents...)...),
			excluded(ps, "@update_mode", rOutOfScope),
			{Procedure: ps, Parameter: "@immediate_sync", Kind: ParamField, Paths: []string{pPubs + ".immediate_sync"}, Reason: stored, Since: sinceDefault},

			{Procedure: pa, Parameter: "@publisher", Kind: ParamField, Paths: []string{"publisher.server"}, Reason: publisher, Since: sinceDefault},
			field(pa, "@publisher_db", "publisher.database"),
			field(pa, "@publication", pPubs+".name"),
			field(pa, "@subscriber", pSubs+".subscriber", pSharedPull+".subscriber"),
			field(pa, "@subscriber_db", pSubs+".database", pSharedPull+".database"),
		},
		connection(pa, "@subscriber_", "connection", pullAgents...),
		[]ParamMapping{
			field(pa, "@distributor", under("distributor", pullAgents...)...),
			excluded(pa, "@distribution_db", "not stored and not needed: not in MSsubscription_properties, and the step command has no switch for it (11-defaults D.sp_addpullsubscription_agent.pull.@distribution_db)"),
		},
		connection(pa, "@distributor_", "distributor_connection", pullAgents...),
		[]ParamMapping{
			{Procedure: pa, Parameter: "@optional_command_line", Kind: ParamField, Paths: under("command", pullAgents...), Reason: "shown, never compared (spec, What is not compared)", Since: sinceDefault},
		},
		schedule(pa, pullAgents...),
		[]ParamMapping{
			excluded(pa, "@distribution_jobid", rFlag),
			excluded(pa, "@encrypted_distributor_password", rFlag),
			field(pa, "@enabled_for_syncmgr", under("enabled_for_syncmgr", pullAgents...)...),
			excluded(pa, "@ftp_address", pullFTP),
			excluded(pa, "@ftp_port", pullFTP),
			excluded(pa, "@ftp_login", pullFTP),
			excluded(pa, "@ftp_password", pullFTP),
			field(pa, "@alt_snapshot_folder", under("alt_snapshot_folder", pullAgents...)...),
			field(pa, "@working_directory", under("working_directory", pullAgents...)...),
			field(pa, "@use_ftp", under("use_ftp", pullAgents...)...),
			excluded(pa, "@publication_type", "not needed: stored in MSsubscription_properties.publication_type, 0 for a transactional publication, which publications[*].type gives (11-defaults D.sp_addpullsubscription_agent.pull.@publication_type)"),
			excluded(pa, "@dts_package_name", rOutOfScope),
			excluded(pa, "@dts_package_password", rOutOfScope),
			excluded(pa, "@dts_package_location", rOutOfScope),
			excluded(pa, "@reserved", rFlag),
			excluded(pa, "@offloadagent", rOffload),
			excluded(pa, "@offloadserver", rOffload),
			{Procedure: pa, Parameter: "@job_name", Kind: ParamField, Paths: under("job_name", pullAgents...), Reason: "shown, never compared (spec, What is not compared)", Since: sinceDefault},
			field(pa, "@job_login", under("job_login", pullAgents...)...),
			field(pa, "@job_password", under("job_password_secret", pullAgents...)...),
			excluded(pa, "@job_security_mode", rMI),
		},
	)
}

func pushParameters() []ParamMapping {
	const pa = "sp_addpushsubscription_agent"
	return concat(
		[]ParamMapping{
			field(pa, "@publication", pPubs+".name"),
			field(pa, "@subscriber", pSubs+".subscriber", "publisher.shared_distribution_agents[*].subscriber"),
			field(pa, "@subscriber_db", pSubs+".database", "publisher.shared_distribution_agents[*].database"),
		},
		connection(pa, "@subscriber_", "connection", pushAgents...),
		[]ParamMapping{
			field(pa, "@job_login", under("job_login", pushAgents...)...),
			field(pa, "@job_password", under("job_password_secret", pushAgents...)...),
			{Procedure: pa, Parameter: "@job_name", Kind: ParamField, Paths: under("job_name", pushAgents...), Reason: "shown, never compared (spec, What is not compared)", Since: sinceDefault},
		},
		schedule(pa, pushAgents...),
		[]ParamMapping{
			excluded(pa, "@dts_package_name", rOutOfScope),
			excluded(pa, "@dts_package_password", rOutOfScope),
			excluded(pa, "@dts_package_location", rOutOfScope),
			excluded(pa, "@enabled_for_syncmgr", "not stored and not needed: no column for a push agent (11-defaults D.sp_addpushsubscription_agent.push.@enabled_for_syncmgr, no-column)"),
			excluded(pa, "@distribution_job_name", "not stored and not needed: informational only (Learn; 11-defaults D.sp_addpushsubscription_agent.push.@distribution_job_name, no-column)"),
			excluded(pa, "@publisher", rPublisher),
			excluded(pa, "@subscriber_provider", rNonSQL),
			excluded(pa, "@subscriber_datasrc", rNonSQL),
			excluded(pa, "@subscriber_location", rNonSQL),
			excluded(pa, "@subscriber_provider_string", rNonSQL),
			excluded(pa, "@subscriber_catalog", rNonSQL),
			excluded(pa, "@job_security_mode", rMI),
		},
	)
}

func subscriptionParameters() []ParamMapping {
	const p = "sp_addsubscription"
	return concat(
		[]ParamMapping{
			field(p, "@publication", pPubs+".name"),
			field(p, "@article", pSubs+".articles"),
			field(p, "@subscriber", pSubs+".subscriber"),
			field(p, "@destination_db", pSubs+".database"),
			field(p, "@sync_type", pSubs+".initialization"),
			excluded(p, "@status", "the stored status is runtime state, read as a fact (11-defaults D.sp_addsubscription.push.@status)"),
			field(p, "@subscription_type", pSubs+".type"),
			excluded(p, "@update_mode", rOutOfScope),
			field(p, "@loopback_detection", pSubs+".loopback_detection"),
		},
		schedule(p, pushAgents...),
		[]ParamMapping{
			{Procedure: p, Parameter: "@optional_command_line", Kind: ParamField, Paths: under("command", pushAgents...), Reason: "shown, never compared (spec, What is not compared)", Since: sinceDefault},
			excluded(p, "@reserved", "not stored and not needed: internal use (11-defaults D.sp_addsubscription.push.@reserved, no-column)"),
			excluded(p, "@enabled_for_syncmgr", "not stored and not needed: nothing stored by sp_addsubscription (11-defaults D.sp_addsubscription.push.@enabled_for_syncmgr, no-column)"),
			excluded(p, "@offloadagent", rOffload),
			excluded(p, "@offloadserver", rOffload),
			excluded(p, "@dts_package_name", rOutOfScope),
			excluded(p, "@dts_package_password", rOutOfScope),
			excluded(p, "@dts_package_location", rOutOfScope),
			excluded(p, "@distribution_job_name", "not stored and not needed: informational only (Learn; 11-defaults D.sp_addsubscription.push.@distribution_job_name, no-column)"),
			excluded(p, "@publisher", rPublisher),
			creationOnly(p, "@backupdevicetype", rBackup, pSubs+".backup.device_type"),
			creationOnly(p, "@backupdevicename", rBackup, pSubs+".backup.device_name"),
			creationOnly(p, "@mediapassword", rBackup+"; the server stores nothing", pSubs+".backup.media_password_secret"),
			creationOnly(p, "@password", rBackup+"; the server stores nothing", pSubs+".backup.password_secret"),
			creationOnly(p, "@fileidhint", rBackup, pSubs+".backup.file_id_hint"),
			creationOnly(p, "@unload", rBackup, pSubs+".backup.unload"),
			creationOnly(p, "@subscriptionlsn", "11-defaults D.sp_addsubscription.push.@subscriptionlsn maps it to MSsubscriptions.subscription_seqno, set only by an initialization from an LSN: that is the subscription's window, runtime state", pSubs+".lsn"),
			field(p, "@subscriptionstreams", under("subscription_streams", pushAgents...)...),
			field(p, "@subscriber_type", pSubs+".subscriber_type"),
			field(p, "@memory_optimized", under("memory_optimized", pushAgents...)...),
		},
		connection(p, "@subscriber_", "connection", pushAgents...),
	)
}

// articleChangeParameters maps sp_articlecolumn, sp_articlefilter and
// sp_articleview, which complete an article after sp_addarticle.
func articleChangeParameters() []ParamMapping {
	const c, f, v = "sp_articlecolumn", "sp_articlefilter", "sp_articleview"
	return []ParamMapping{
		field(c, "@publication", pPubs+".name"),
		field(c, "@article", pArts+".name"),
		field(c, "@column", pArts+".columns"),
		{Procedure: c, Parameter: "@operation", Kind: ParamField, Paths: []string{pArts + ".columns"}, Reason: "add or drop: the difference between the declared and the exported columns", Since: sinceDefault},
		excluded(c, "@refresh_synctran_procs", rFlag),
		excluded(c, "@ignore_distributor", rFlag),
		excluded(c, "@change_active", rFlag),
		excluded(c, "@force_invalidate_snapshot", rFlag),
		excluded(c, "@force_reinit_subscription", rFlag),
		excluded(c, "@publisher", rPublisher),
		excluded(c, "@internal", rFlag),

		field(f, "@publication", pPubs+".name"),
		field(f, "@article", pArts+".name"),
		field(f, "@filter_name", pArts+".filter.procedure"),
		field(f, "@filter_clause", pArts+".filter.clause"),
		excluded(f, "@force_invalidate_snapshot", rFlag),
		excluded(f, "@force_reinit_subscription", rFlag),
		excluded(f, "@publisher", rPublisher),

		field(v, "@publication", pPubs+".name"),
		field(v, "@article", pArts+".name"),
		field(v, "@view_name", pArts+".sync_object"),
		field(v, "@filter_clause", pArts+".filter.clause"),
		excluded(v, "@change_active", rFlag),
		excluded(v, "@force_invalidate_snapshot", rFlag),
		excluded(v, "@force_reinit_subscription", rFlag),
		excluded(v, "@publisher", rPublisher),
		excluded(v, "@refreshsynctranprocs", rFlag),
		excluded(v, "@internal", rFlag),
	}
}
