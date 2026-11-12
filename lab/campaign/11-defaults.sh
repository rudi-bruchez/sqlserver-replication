#!/bin/bash
# The value every in-scope replication procedure stores for each optional parameter it is
# not given (campaign item 9, first part): the defaults table of the planner, which
# normalizes a short file ("omitted property = SQL Server default") with it. Run through
# lab/campaign.sh.
#
# Each context calls one procedure with its required parameters only, plus the optional
# parameters that define the context or identify the object (marked "passed" in the
# rows): @source_object of an article, @subscriber and @destination_db of a subscription,
# @publisher_db of a pull subscription, @repl_freq = snapshot, @type of a schema-only
# article, @subscription_type = pull. Then it emits one row per optional parameter of
# the procedure (see lab/defaults-lib.sh for how optional parameters are found and how
# the map of parameter to catalog column is checked against the live procedure):
#   R|D.<procedure>.<context>.<parameter>|<stored value or no-column>|column=<where>
#     declared=<default in the procedure header> [passed] call=<result of the call>
# Values are printed so that two runs give the same file: agent and job names with
# <id> or <guid> for their generated suffix, a generated sync view as syncobj_0x<hex>,
# active_start_date of the run's day as today, an output id as assigned, a password
# as null, empty or set, an empty string as ''; pre-existing(<value>): the value was
# there before the call (not a default; see the row's detail). no-job: the context created no agent job; no-schedule: the job
# has no schedule (on demand); no-row: the table that would hold it has no row for the
# object.
#
# Contexts and objects (all m_, in Sales unless said):
#   sp_addpublication       transactional (m_dp_tran), snapshot (m_dp_snap, @repl_freq)
#   sp_addpublication_snapshot  transactional: on m_dp_tran, the only snapshot agent
#                           created with the default schedule (every 5 minutes); its job is
#                           disabled in the same batch, before anything else runs.
#   sp_addpublication_snapshot  snapshot-pub: on m_dp_snap, created with the default
#                           schedule and disabled in the same batch, as the transactional one.
#   sp_addarticle           table.native (m_pa_nat, @sync_method native), table.concurrent
#                           (m_pa_con), table.character (m_pa_chr), table.snapshot-pub
#                           (m_pa_snp, @repl_freq snapshot): article m_a1 on dbo.m_t;
#                           table.non-dbo-schema: m_a2 on m_s.m_t in m_pa_nat with
#                           @source_owner = m_s and the unqualified @ins_cmd = CALL m_ins;
#                           view-schema-only, proc-schema-only, func-schema-only: m_a3,
#                           m_a4, m_a5 on dbo.m_v, dbo.m_p, dbo.m_f in m_pa_nat.
#                           <kind>.nondbo.<method>: the article kinds table, view-schema-only,
#                           proc-schema-only, func-schema-only on m_s.m_t, m_s.m_v, m_s.m_p,
#                           m_s.m_f (@source_owner = m_s), in m_pa_<method>, a transactional
#                           publication per sync method (native, character, concurrent,
#                           concurrent_c, dbsnap = database snapshot, dbsnap_c = database
#                           snapshot character); <kind>.nondbo.snapshot-pub.<method>: the same
#                           in m_ps_<method>, a snapshot publication, for the four methods a
#                           snapshot publication takes (concurrent is refused, 22547).
#   sp_articlefilter, sp_articleview, sp_articlecolumn  table: on the articles m_af, m_av,
#                           m_ac of m_pa_nat (tables m_tf, m_tv, m_tc), added with
#                           required parameters only before the call.
#   sp_addsubscription      push (to m_dsub1), pull (@subscription_type pull, to m_dsub2),
#                           on m_ps (status active, allow_pull, article m_a on dbo.m_t)
#   sp_addsubscription, single rows (not a context: no full parameter list):
#                           push.fresh-subscriber.@subscriber_type: a push subscription of m_ps
#                           to m_freshsub (database m_dsub5), a subscriber name registered
#                           nowhere before the call; the result is MSsubscriber_info.type, or
#                           the error number when the call is refused.
#                           pull.fresh-subscriber.@subscriber_type: the same with
#                           @subscription_type = pull, to m_freshpull (database m_dpull5),
#                           another name registered nowhere (nor in MSreplservers) before
#                           the call. push.rso.@status,
#                           extend.pull.@status, .@subscription_type, .agents and
#                           extend.rso.@status: on m_pa_ext (native, independent agent,
#                           allow_pull, status active, article m_x1 on dbo.m_tx1), a push
#                           replication support only subscription to m_dsub3 and a pull
#                           subscription registered at the publisher for m_dsub4; then the
#                           article m_x2 (dbo.m_tx2) added and each subscription extended to it
#                           by sp_addsubscription @article = N'm_x2' with @subscription_type
#                           and @sync_type passed (R36). The rows read the m_x2 rows.
#   sp_addpushsubscription_agent  push: the subscription to m_dsub1
#   sp_addpullsubscription, sp_addpullsubscription_agent  pull: in m_dsub2
#   sp_replicationdboption  publish: m_pubdb enabled for publishing
#   sp_addlogreader_agent   publication-db: in m_pubdb
#   sp_add_agent_profile    agent-type-3: m_prof, a distribution agent profile, from msdb
# Every publication other than m_dp_tran gets a snapshot agent whose schedule never fires.
#
# Asserted, exit 1 otherwise (rows on stderr as "row: ..."): every call is ok (the
# sp_addsubscription calls of the single rows excepted: their result is the row); 63
# contexts; TOTAL equals the sum of the per-context counts printed as "count ...", plus the
# single rows; the
# values of the brief: table.native @schema_option 0x0000000000030073, table.snapshot-pub
# @schema_option 0x0000000000030071, table.non-dbo-schema @destination_owner m_s and
# @ins_cmd CALL [dbo].[m_ins]; the agent contexts found their job (no no-job in the
# schedule rows of the push, pull, snapshot agents and in the log reader's job name);
# after the cleanup, distribution keeps no MSpublisher_databases row for an m_ database, and
# m_freshpull is left nowhere (sys.servers, MSsubscriber_info, MSsubscriber_schedule,
# MSreplservers).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/../lib.sh"
DEF_SCRIPT=11-defaults
. "$here/../defaults-lib.sh"

EXPECTED_CONTEXTS=63
# The sync methods of the nondbo contexts: the name in the row, the @sync_method value.
METHODS=(native:native character:character concurrent:concurrent concurrent_c:concurrent_c "dbsnap:database snapshot" "dbsnap_c:database snapshot character")
SNAP_METHODS=(native:native character:character "dbsnap:database snapshot" "dbsnap_c:database snapshot character")

# Preambles: the catalog rows of the object a context created, in #tables.
jobs_of() { # SOURCE_TABLE: the agent job of the agent row(s) in SOURCE_TABLE, its schedule and step
    echo "SELECT j.* INTO #j FROM msdb.dbo.sysjobs j WHERE j.job_id IN (SELECT CONVERT(uniqueidentifier, job_id) FROM $1 WHERE local_job = 1);
SELECT s.* INTO #s FROM msdb.dbo.sysjobschedules js JOIN msdb.dbo.sysschedules s ON s.schedule_id = js.schedule_id WHERE js.job_id IN (SELECT job_id FROM #j);
SELECT CONVERT(nvarchar(4000), st.command) AS command INTO #st FROM msdb.dbo.sysjobsteps st WHERE st.job_id IN (SELECT job_id FROM #j) AND st.subsystem IN (N'Snapshot', N'LogReader', N'Distribution');
IF (SELECT COUNT(*) FROM #j) > 1 OR (SELECT COUNT(*) FROM #s) > 1 OR (SELECT COUNT(*) FROM #st) > 1 THROW 50000, N'preamble: more than one job, schedule or agent step', 1;"
}
PRE_PUB="USE Sales;
SELECT * INTO #p FROM dbo.syspublications WHERE name = N'{P}';
SELECT * INTO #mp FROM distribution.dbo.MSpublications WHERE publisher_db = N'Sales' AND publication = N'{P}';
SELECT * INTO #lr FROM distribution.dbo.MSlogreader_agents WHERE publisher_db = N'Sales';
IF (SELECT COUNT(*) FROM #p) <> 1 OR (SELECT COUNT(*) FROM #mp) <> 1 OR (SELECT COUNT(*) FROM #lr) <> 1 THROW 50000, N'preamble: expected one row in #p, #mp, #lr', 1;"
PRE_ART_TABLE="USE Sales;
SELECT a.* INTO #a FROM dbo.sysarticles a JOIN dbo.syspublications p ON p.pubid = a.pubid WHERE p.name = N'{P}' AND a.name = N'{A}';
SELECT ma.* INTO #ma FROM distribution.dbo.MSarticles ma JOIN distribution.dbo.MSpublications mp ON mp.publication_id = ma.publication_id WHERE mp.publisher_db = N'Sales' AND mp.publication = N'{P}' AND ma.article = N'{A}';
SELECT * INTO #ir FROM distribution.dbo.MSrepl_identity_range WHERE publisher_db = N'Sales' AND tablename IN (SELECT OBJECT_NAME(objid) FROM #a);
IF (SELECT COUNT(*) FROM #a) <> 1 OR (SELECT COUNT(*) FROM #ma) <> 1 OR (SELECT COUNT(*) FROM #ir) > 1 THROW 50000, N'preamble: expected one row in #a and #ma', 1;"
PRE_ART_SCHEMA="USE Sales;
SELECT a.* INTO #sa FROM dbo.sysschemaarticles a JOIN dbo.syspublications p ON p.pubid = a.pubid WHERE p.name = N'{P}' AND a.name = N'{A}';
SELECT ma.* INTO #ma FROM distribution.dbo.MSarticles ma JOIN distribution.dbo.MSpublications mp ON mp.publication_id = ma.publication_id WHERE mp.publisher_db = N'Sales' AND mp.publication = N'{P}' AND ma.article = N'{A}';
IF (SELECT COUNT(*) FROM #sa) <> 1 OR (SELECT COUNT(*) FROM #ma) <> 1 THROW 50000, N'preamble: expected one row in #sa and #ma', 1;"
PRE_SUB="USE Sales;
SELECT s.* INTO #sub FROM dbo.syssubscriptions s JOIN dbo.sysarticles a ON a.artid = s.artid JOIN dbo.syspublications p ON p.pubid = a.pubid WHERE p.name = N'{P}' AND s.dest_db = N'{D}' AND s.srvid >= 0;
SELECT ms.* INTO #msub FROM distribution.dbo.MSsubscriptions ms JOIN distribution.dbo.MSpublications mp ON mp.publication_id = ms.publication_id WHERE mp.publisher_db = N'Sales' AND mp.publication = N'{P}' AND ms.subscriber_db = N'{D}' AND ms.subscriber_id >= 0;
SELECT * INTO #da FROM distribution.dbo.MSdistribution_agents WHERE publisher_db = N'Sales' AND subscriber_db = N'{D}' AND subscriber_id >= 0;
$(jobs_of '#da')
IF (SELECT COUNT(*) FROM #sub) <> 1 OR (SELECT COUNT(*) FROM #msub) <> 1 OR (SELECT COUNT(*) FROM #da) <> 1 THROW 50000, N'preamble: expected one row in #sub, #msub, #da', 1;"
PRE_PULLSUB="USE [{D}];
SELECT * INTO #rs FROM dbo.MSreplication_subscriptions WHERE publication = N'{P}';
IF (SELECT COUNT(*) FROM #rs) <> 1 THROW 50000, N'preamble: expected one row in #rs', 1;"
# The pull agent's job lives at the subscriber (this instance); found by its step, which
# runs in the subscription database.
PRE_PULLAGENT="USE [{D}];
SELECT * INTO #rs FROM dbo.MSreplication_subscriptions WHERE publication = N'{P}';
SELECT * INTO #sp FROM dbo.MSsubscription_properties WHERE publication = N'{P}';
SELECT j.* INTO #j FROM msdb.dbo.sysjobs j WHERE j.job_id IN (SELECT job_id FROM msdb.dbo.sysjobsteps WHERE subsystem = N'Distribution' AND database_name = N'{D}');
SELECT s.* INTO #s FROM msdb.dbo.sysjobschedules js JOIN msdb.dbo.sysschedules s ON s.schedule_id = js.schedule_id WHERE js.job_id IN (SELECT job_id FROM #j);
SELECT CONVERT(nvarchar(4000), st.command) AS command INTO #st FROM msdb.dbo.sysjobsteps st WHERE st.job_id IN (SELECT job_id FROM #j) AND st.subsystem = N'Distribution';
IF (SELECT COUNT(*) FROM #rs) <> 1 OR (SELECT COUNT(*) FROM #sp) <> 1 OR (SELECT COUNT(*) FROM #j) <> 1 OR (SELECT COUNT(*) FROM #s) > 1 OR (SELECT COUNT(*) FROM #st) <> 1 THROW 50000, N'preamble: expected one row in #rs, #sp, #j, #st', 1;"
PRE_LR="SELECT * INTO #la FROM distribution.dbo.MSlogreader_agents WHERE publisher_db = N'{D}';
$(jobs_of '#la')
IF (SELECT COUNT(*) FROM #la) <> 1 THROW 50000, N'preamble: expected one row in #la', 1;"
PRE_SNAP="SELECT * INTO #sn FROM distribution.dbo.MSsnapshot_agents WHERE publisher_db = N'Sales' AND publication = N'{P}' AND local_job = 1;
$(jobs_of '#sn')
IF (SELECT COUNT(*) FROM #sn) <> 1 THROW 50000, N'preamble: expected one row in #sn', 1;"
PRE_PROF="SELECT * INTO #pr FROM msdb.dbo.MSagent_profiles WHERE profile_name = N'{P}';
IF (SELECT COUNT(*) FROM #pr) <> 1 THROW 50000, N'preamble: expected one row in #pr', 1;"
PRE_NONE="SELECT 1 AS x INTO #n;"

NC="N'no-column'"
opt_bit() { echo "(SELECT CONVERT(nvarchar(10), CASE WHEN options & $1 <> 0 THEN 1 ELSE 0 END) FROM #p)"; }

MAP_PUB=$(cat <<EOF
@taskid|no-column: backward compatibility only, not stored|$NC
@restricted|no-column: publication security of SQL Server 7.0, not stored|$NC
@sync_method|Sales.dbo.syspublications.sync_method (0 native, 1 character, 3 concurrent, 4 concurrent_c)|(SELECT sync_method FROM #p)
@repl_freq|syspublications.repl_freq (0 continuous, 1 snapshot)|(SELECT repl_freq FROM #p)
@description|syspublications.description|(SELECT description FROM #p)
@status|syspublications.status (0 inactive, 1 active)|(SELECT status FROM #p)
@independent_agent|syspublications.independent_agent|(SELECT independent_agent FROM #p)
@immediate_sync|syspublications.immediate_sync|(SELECT immediate_sync FROM #p)
@enabled_for_internet|syspublications.enabled_for_internet|(SELECT enabled_for_internet FROM #p)
@allow_push|syspublications.allow_push|(SELECT allow_push FROM #p)
@allow_pull|syspublications.allow_pull|(SELECT allow_pull FROM #p)
@allow_anonymous|syspublications.allow_anonymous|(SELECT allow_anonymous FROM #p)
@allow_sync_tran|syspublications.allow_sync_tran|(SELECT allow_sync_tran FROM #p)
@autogen_sync_procs|syspublications.autogen_sync_procs|(SELECT autogen_sync_procs FROM #p)
@retention|syspublications.retention (hours)|(SELECT retention FROM #p)
@allow_queued_tran|syspublications.allow_queued_tran|(SELECT allow_queued_tran FROM #p)
@snapshot_in_defaultfolder|syspublications.snapshot_in_defaultfolder|(SELECT snapshot_in_defaultfolder FROM #p)
@alt_snapshot_folder|syspublications.alt_snapshot_folder|(SELECT alt_snapshot_folder FROM #p)
@pre_snapshot_script|syspublications.pre_snapshot_script|(SELECT pre_snapshot_script FROM #p)
@post_snapshot_script|syspublications.post_snapshot_script|(SELECT post_snapshot_script FROM #p)
@compress_snapshot|syspublications.compress_snapshot|(SELECT compress_snapshot FROM #p)
@ftp_address|syspublications.ftp_address|(SELECT ftp_address FROM #p)
@ftp_port|syspublications.ftp_port|(SELECT ftp_port FROM #p)
@ftp_subdirectory|syspublications.ftp_subdirectory|(SELECT ftp_subdirectory FROM #p)
@ftp_login|syspublications.ftp_login|(SELECT ftp_login FROM #p)
@ftp_password|syspublications.ftp_password (secret)|$(secret "(SELECT ftp_password FROM #p)")
@allow_dts|syspublications.allow_dts|(SELECT allow_dts FROM #p)
@allow_subscription_copy|syspublications.allow_subscription_copy|(SELECT allow_subscription_copy FROM #p)
@conflict_policy|syspublications.conflict_policy|(SELECT conflict_policy FROM #p)
@centralized_conflicts|syspublications.centralized_conflicts|(SELECT centralized_conflicts FROM #p)
@conflict_retention|syspublications.conflict_retention (days)|(SELECT conflict_retention FROM #p)
@queue_type|syspublications.queue_type|(SELECT queue_type FROM #p)
@add_to_active_directory|syspublications.ad_guidname (NULL: not in Active Directory)|(SELECT ad_guidname FROM #p)
@logreader_job_name|distribution.dbo.MSlogreader_agents.name of the publication database; pre-existing: Sales has its log reader before the call (sp_addpublication creates one in a database that has none), so this is not a default|(SELECT CONCAT(N'pre-existing(', $(norm "(SELECT name FROM #lr)"), N')'))
@qreader_job_name|distribution.dbo.MSqreader_agents.name (one queue reader per distributor, created for queued updating only)|ISNULL((SELECT TOP (1) name FROM distribution.dbo.MSqreader_agents), N'no-row')
@publisher|distribution.dbo.MSpublications.publisher_id (server name)|$(srv "(SELECT publisher_id FROM #mp)")
@allow_initialize_from_backup|syspublications.allow_initialize_from_backup|(SELECT allow_initialize_from_backup FROM #p)
@replicate_ddl|syspublications.replicate_ddl|(SELECT replicate_ddl FROM #p)
@enabled_for_p2p|syspublications.options bit 0x1 (Learn)|$(opt_bit 1)
@publish_local_changes_only|syspublications.options bit 0x2 (Learn)|$(opt_bit 2)
@enabled_for_het_sub|syspublications.options bit 0x4 (Learn)|$(opt_bit 4)
@p2p_conflictdetection|syspublications.options bit 0x8 (Learn)|$(opt_bit 8)
@p2p_originator_id|syspublications.originator_id|(SELECT originator_id FROM #p)
@p2p_continue_onconflict|syspublications.options, bit not documented: whole value|(SELECT CONCAT(N'options=', options) FROM #p)
@allow_partition_switch|syspublications.options, bit not documented: whole value|(SELECT CONCAT(N'options=', options) FROM #p)
@replicate_partition_switch|syspublications.options, bit not documented: whole value|(SELECT CONCAT(N'options=', options) FROM #p)
@allow_drop|syspublications.options, bit not documented: whole value|(SELECT CONCAT(N'options=', options) FROM #p)
@p2p_conflictdetection_policy|syspublications.options bit 0x100 (Learn: lastwriter)|$(opt_bit 256)
EOF
)

objname() { echo "(SELECT CONCAT(OBJECT_SCHEMA_NAME($1), N'.', OBJECT_NAME($1)) FROM $2 WHERE $1 IS NOT NULL AND $1 <> 0)"; }
idr() { echo "ISNULL((SELECT TOP (1) CONVERT(nvarchar(100), $1) FROM #ir), N'no-row')"; }
MAP_ART_TABLE=$(cat <<EOF
@source_table|Sales.dbo.sysarticles.objid (schema.name)|$(objname objid '#a')
@destination_table|sysarticles.dest_table|(SELECT dest_table FROM #a)
@vertical_partition|Sales.dbo.sysarticlecolumns rows of the article / columns of the table|(SELECT CONCAT((SELECT COUNT(*) FROM dbo.sysarticlecolumns WHERE artid = a.artid), N'/', (SELECT COUNT(*) FROM sys.columns WHERE object_id = a.objid)) FROM #a a)
@type|sysarticles.type (1 logbased)|(SELECT type FROM #a)
@filter|sysarticles.filter (object id of the filter procedure, 0 none)|(SELECT CASE WHEN filter = 0 THEN N'0' ELSE CONCAT(OBJECT_SCHEMA_NAME(filter), N'.', OBJECT_NAME(filter)) END FROM #a)
@sync_object|sysarticles.sync_objid (the generated view)|$(norm "(SELECT OBJECT_NAME(sync_objid) FROM #a)")
@ins_cmd|sysarticles.ins_cmd|(SELECT ins_cmd FROM #a)
@del_cmd|sysarticles.del_cmd|(SELECT del_cmd FROM #a)
@upd_cmd|sysarticles.upd_cmd|(SELECT upd_cmd FROM #a)
@creation_script|sysarticles.creation_script|(SELECT creation_script FROM #a)
@description|sysarticles.description|(SELECT description FROM #a)
@pre_creation_cmd|sysarticles.pre_creation_cmd (0 none, 1 drop, 2 delete, 3 truncate)|(SELECT pre_creation_cmd FROM #a)
@filter_clause|sysarticles.filter_clause|(SELECT CONVERT(nvarchar(4000), filter_clause) FROM #a)
@schema_option|sysarticles.schema_option|(SELECT CONVERT(nvarchar(20), schema_option, 1) FROM #a)
@destination_owner|sysarticles.dest_owner|(SELECT dest_owner FROM #a)
@status|sysarticles.status|(SELECT status FROM #a)
@source_owner|sysarticles.objid (schema)|(SELECT OBJECT_SCHEMA_NAME(objid) FROM #a)
@sync_object_owner|sysarticles.sync_objid (schema)|(SELECT OBJECT_SCHEMA_NAME(sync_objid) FROM #a)
@filter_owner|sysarticles.filter (schema; 0 none)|(SELECT CASE WHEN filter = 0 THEN N'0' ELSE OBJECT_SCHEMA_NAME(filter) END FROM #a)
@source_object|sysarticles.objid (name)|(SELECT OBJECT_NAME(objid) FROM #a)
@artid|sysarticles.artid (output)|(SELECT CASE WHEN artid IS NOT NULL THEN N'assigned' END FROM #a)
@auto_identity_range|distribution.dbo.MSrepl_identity_range.identity_support|$(idr identity_support)
@pub_identity_range|MSrepl_identity_range.pub_range|$(idr pub_range)
@identity_range|MSrepl_identity_range.range|$(idr range)
@threshold|MSrepl_identity_range.threshold|$(idr threshold)
@force_invalidate_snapshot|no-column: a flag of the call|$NC
@use_default_datatypes|no-column: data type mapping of non-SQL Server publishers, not stored for a SQL Server one|$NC
@identityrangemanagementoption|MSrepl_identity_range.identity_support (no row: not managed)|$(idr identity_support)
@publisher|distribution.dbo.MSarticles.publisher_id (server name)|$(srv "(SELECT publisher_id FROM #ma)")
@fire_triggers_on_snapshot|sysarticles.fire_triggers_on_snapshot|(SELECT fire_triggers_on_snapshot FROM #a)
EOF
)
SNC="no-column: sysschemaarticles has no such column"
MAP_ART_SCHEMA=$(cat <<EOF
@source_table|Sales.dbo.sysschemaarticles.objid (schema.name)|$(objname objid '#sa')
@destination_table|sysschemaarticles.dest_object|(SELECT dest_object FROM #sa)
@vertical_partition|$SNC|$NC
@type|sysschemaarticles.type (0x20 proc schema only, 0x40 view schema only, 0x80 func schema only)|(SELECT type FROM #sa)
@filter|$SNC|$NC
@sync_object|$SNC|$NC
@ins_cmd|$SNC|$NC
@del_cmd|$SNC|$NC
@upd_cmd|$SNC|$NC
@creation_script|sysschemaarticles.creation_script|(SELECT creation_script FROM #sa)
@description|sysschemaarticles.description|(SELECT description FROM #sa)
@pre_creation_cmd|sysschemaarticles.pre_creation_cmd|(SELECT pre_creation_cmd FROM #sa)
@filter_clause|$SNC|$NC
@schema_option|sysschemaarticles.schema_option|(SELECT CONVERT(nvarchar(20), schema_option, 1) FROM #sa)
@destination_owner|sysschemaarticles.dest_owner|(SELECT dest_owner FROM #sa)
@status|sysschemaarticles.status|(SELECT status FROM #sa)
@source_owner|sysschemaarticles.objid (schema)|(SELECT OBJECT_SCHEMA_NAME(objid) FROM #sa)
@sync_object_owner|$SNC|$NC
@filter_owner|$SNC|$NC
@source_object|sysschemaarticles.objid (name)|(SELECT OBJECT_NAME(objid) FROM #sa)
@artid|sysschemaarticles.artid (output)|(SELECT CASE WHEN artid IS NOT NULL THEN N'assigned' END FROM #sa)
@auto_identity_range|no-column: identity ranges concern tables only|$NC
@pub_identity_range|no-column: identity ranges concern tables only|$NC
@identity_range|no-column: identity ranges concern tables only|$NC
@threshold|no-column: identity ranges concern tables only|$NC
@force_invalidate_snapshot|no-column: a flag of the call|$NC
@use_default_datatypes|no-column: data type mapping of non-SQL Server publishers|$NC
@identityrangemanagementoption|no-column: identity ranges concern tables only|$NC
@publisher|distribution.dbo.MSarticles.publisher_id (server name)|$(srv "(SELECT publisher_id FROM #ma)")
@fire_triggers_on_snapshot|$SNC|$NC
EOF
)
MAP_FILTER=$(cat <<EOF
@filter_name|Sales.dbo.sysarticles.filter (object id of the filter procedure, 0 none)|(SELECT CASE WHEN filter = 0 THEN N'0' ELSE CONCAT(OBJECT_SCHEMA_NAME(filter), N'.', OBJECT_NAME(filter)) END FROM #a)
@filter_clause|sysarticles.filter_clause|(SELECT CONVERT(nvarchar(4000), filter_clause) FROM #a)
@force_invalidate_snapshot|no-column: a flag of the call|$NC
@force_reinit_subscription|no-column: a flag of the call|$NC
@publisher|distribution.dbo.MSarticles.publisher_id (server name)|$(srv "(SELECT publisher_id FROM #ma)")
EOF
)
MAP_VIEW=$(cat <<EOF
@view_name|Sales.dbo.sysarticles.sync_objid (the view)|$(norm "(SELECT OBJECT_NAME(sync_objid) FROM #a)")
@filter_clause|sysarticles.filter_clause|(SELECT CONVERT(nvarchar(4000), filter_clause) FROM #a)
@change_active|no-column: a flag of the call (allows changing an active publication)|$NC
@force_invalidate_snapshot|no-column: a flag of the call|$NC
@force_reinit_subscription|no-column: a flag of the call|$NC
@publisher|distribution.dbo.MSarticles.publisher_id (server name)|$(srv "(SELECT publisher_id FROM #ma)")
@refreshsynctranprocs|no-column: a flag of the call (regenerates synctran procedures)|$NC
@internal|no-column: internal use|$NC
EOF
)
MAP_COLUMN=$(cat <<EOF
@column|Sales.dbo.sysarticlecolumns rows of the article / columns of the table|(SELECT CONCAT((SELECT COUNT(*) FROM dbo.sysarticlecolumns WHERE artid = a.artid), N'/', (SELECT COUNT(*) FROM sys.columns WHERE object_id = a.objid)) FROM #a a)
@operation|sysarticlecolumns rows of the article / columns of the table (add adds, drop removes)|(SELECT CONCAT((SELECT COUNT(*) FROM dbo.sysarticlecolumns WHERE artid = a.artid), N'/', (SELECT COUNT(*) FROM sys.columns WHERE object_id = a.objid)) FROM #a a)
@refresh_synctran_procs|no-column: a flag of the call|$NC
@ignore_distributor|no-column: a flag of the call|$NC
@change_active|no-column: a flag of the call|$NC
@force_invalidate_snapshot|no-column: a flag of the call|$NC
@force_reinit_subscription|no-column: a flag of the call|$NC
@publisher|distribution.dbo.MSarticles.publisher_id (server name)|$(srv "(SELECT publisher_id FROM #ma)")
@internal|no-column: internal use|$NC
EOF
)
DA="distribution.dbo.MSdistribution_agents"
MAP_SUB=$(cat <<EOF
@article|Sales.dbo.syssubscriptions rows of the subscription / articles of the publication|(SELECT CONCAT((SELECT COUNT(*) FROM #sub), N'/', (SELECT COUNT(*) FROM dbo.sysarticles a JOIN dbo.syspublications p ON p.pubid = a.pubid WHERE p.name = N'{P}')))
@subscriber|syssubscriptions.srvname|(SELECT TOP (1) srvname FROM #sub)
@destination_db|syssubscriptions.dest_db|(SELECT TOP (1) dest_db FROM #sub)
@sync_type|syssubscriptions.sync_type and nosync_type (1 automatic)|(SELECT TOP (1) CONCAT(N'sync_type=', sync_type, N' nosync_type=', nosync_type) FROM #sub)
@status|syssubscriptions.status (0 inactive, 1 subscribed, 2 active)|(SELECT TOP (1) status FROM #sub)
@subscription_type|syssubscriptions.subscription_type (0 push, 1 pull)|(SELECT TOP (1) subscription_type FROM #sub)
@update_mode|syssubscriptions.update_mode (0 read only)|(SELECT TOP (1) update_mode FROM #sub)
@loopback_detection|syssubscriptions.loopback_detection|(SELECT TOP (1) loopback_detection FROM #sub)
$(sched_map)
@optional_command_line|msdb.dbo.sysjobsteps.command of the agent job the call created, minus the switches the procedure generates (absent: nothing else)|$(extra_switches)
@reserved|no-column: internal use|$NC
@enabled_for_syncmgr|no-column: Windows Synchronization Manager of a pull subscriber, nothing stored by sp_addsubscription|$NC
@offloadagent|$DA.offload_enabled|(SELECT offload_enabled FROM #da)
@offloadserver|$DA.offload_server|(SELECT offload_server FROM #da)
@dts_package_name|$DA.dts_package_name|(SELECT dts_package_name FROM #da)
@dts_package_password|$DA.dts_package_password (secret)|$(secret "(SELECT dts_package_password FROM #da)")
@dts_package_location|$DA.dts_package_location (0 distributor, 1 subscriber)|(SELECT dts_package_location FROM #da)
@distribution_job_name|no-column: informational only (Learn), not stored|$NC
@publisher|distribution.dbo.MSsubscriptions.publisher_id (server name)|$(srv "(SELECT TOP (1) publisher_id FROM #msub)")
@backupdevicetype|no-column: read only when sync_type is initialize with backup|$NC
@backupdevicename|no-column: read only when sync_type is initialize with backup|$NC
@mediapassword|no-column: read only when sync_type is initialize with backup|$NC
@password|no-column: read only when sync_type is initialize with backup|$NC
@fileidhint|no-column: read only when sync_type is initialize with backup|$NC
@unload|no-column: read only when sync_type is initialize with backup|$NC
@subscriptionlsn|distribution.dbo.MSsubscriptions.subscription_seqno (set from the parameter only with initialize from lsn)|(SELECT TOP (1) CASE WHEN subscription_seqno IS NULL THEN NULL WHEN subscription_seqno = publisher_seqno THEN N'publisher_seqno' ELSE N'other' END FROM #msub)
@subscriptionstreams|$DA.subscriptionstreams|(SELECT subscriptionstreams FROM #da)
@subscriber_type|distribution.dbo.MSsubscriber_info.type of (publisher, subscriber) (0 SQL Server); sp_addsubscription reads it there and never writes MSdistribution_agents.subscriber_type. The row pre-exists on the lab (registered by setup.sql), so the default for an unregistered subscriber is not measured|ISNULL((SELECT TOP (1) CONCAT(N'pre-existing(', type, N')') FROM distribution.dbo.MSsubscriber_info WHERE UPPER(publisher) = UPPER(@@SERVERNAME) AND UPPER(subscriber) = UPPER(@@SERVERNAME)), N'no-row')
@memory_optimized|$DA.memory_optimized|(SELECT memory_optimized FROM #da)
@subscriber_security_mode|$DA.subscriber_security_mode|(SELECT subscriber_security_mode FROM #da)
@subscriber_login|$DA.subscriber_login|(SELECT subscriber_login FROM #da)
@subscriber_password|$DA.subscriber_password (secret)|$(secret "(SELECT subscriber_password FROM #da)")
EOF
)
MAP_PUSHAGENT=$(cat <<EOF
@subscriber|$DA.subscriber_id (server name)|$(srv "(SELECT subscriber_id FROM #da)")
@subscriber_db|$DA.subscriber_db|(SELECT subscriber_db FROM #da)
@subscriber_security_mode|$DA.subscriber_security_mode|(SELECT subscriber_security_mode FROM #da)
@subscriber_login|$DA.subscriber_login|(SELECT subscriber_login FROM #da)
@subscriber_password|$DA.subscriber_password (secret)|$(secret "(SELECT subscriber_password FROM #da)")
@job_login|$DA.job_login|(SELECT job_login FROM #da)
@job_password|$DA.job_password (secret)|$(secret "(SELECT job_password FROM #da)")
@job_name|msdb.dbo.sysjobs.name of the agent job ($DA.job_id)|$(norm "(SELECT name FROM #j)")
$(sched_map)
@dts_package_name|$DA.dts_package_name|(SELECT dts_package_name FROM #da)
@dts_package_password|$DA.dts_package_password (secret)|$(secret "(SELECT dts_package_password FROM #da)")
@dts_package_location|$DA.dts_package_location (0 distributor, 1 subscriber)|(SELECT dts_package_location FROM #da)
@enabled_for_syncmgr|no-column: Windows Synchronization Manager, no column for a push agent|$NC
@distribution_job_name|no-column: informational only (Learn), not stored|$NC
@publisher|$DA.publisher_id (server name)|$(srv "(SELECT publisher_id FROM #da)")
@subscriber_provider|$DA.subscriber_provider|(SELECT subscriber_provider FROM #da)
@subscriber_datasrc|$DA.subscriber_datasrc|(SELECT subscriber_datasrc FROM #da)
@subscriber_location|$DA.subscriber_location|(SELECT subscriber_location FROM #da)
@subscriber_provider_string|$DA.subscriber_provider_string|(SELECT subscriber_provider_string FROM #da)
@subscriber_catalog|$DA.subscriber_catalog|(SELECT subscriber_catalog FROM #da)
@job_security_mode|no-column: Managed Instance only (refused with 41989 elsewhere, 07-changes)|$NC
EOF
)
RS="<subscription db>.dbo.MSreplication_subscriptions"
MAP_PULLSUB=$(cat <<EOF
@publisher_db|$RS.publisher_db|(SELECT publisher_db FROM #rs)
@independent_agent|$RS.independent_agent|(SELECT independent_agent FROM #rs)
@subscription_type|$RS.subscription_type (0 push, 1 pull, 2 anonymous)|(SELECT subscription_type FROM #rs)
@description|$RS.description|(SELECT description FROM #rs)
@update_mode|$RS.update_mode (0 read only)|(SELECT update_mode FROM #rs)
@immediate_sync|$RS.immediate_sync|(SELECT immediate_sync FROM #rs)
EOF
)
SP="<subscription db>.dbo.MSsubscription_properties"
CMD="msdb.dbo.sysjobsteps.command of the pull agent job, switch"
MAP_PULLAGENT=$(cat <<EOF
@publisher_db|$SP.publisher_db|(SELECT publisher_db FROM #sp)
@subscriber|$CMD -Subscriber|$(switch Subscriber)
@subscriber_db|$CMD -SubscriberDB|$(switch SubscriberDB)
@subscriber_security_mode|$CMD -SubscriberSecurityMode|$(switch SubscriberSecurityMode)
@subscriber_login|$CMD -SubscriberLogin|$(switch SubscriberLogin)
@subscriber_password|$CMD -SubscriberPassword (secret)|$(switch_secret SubscriberPassword)
@distributor|$SP.distributor|(SELECT distributor FROM #sp)
@distribution_db|no-column: not in MSsubscription_properties, and the step command has no switch for it (-Publisher -PublisherDB -Publication -Distributor -SubscriptionType -Subscriber -SubscriberSecurityMode -SubscriberDB)|$NC
@distributor_security_mode|$SP.distributor_security_mode|(SELECT distributor_security_mode FROM #sp)
@distributor_login|$SP.distributor_login|(SELECT distributor_login FROM #sp)
@distributor_password|$SP.distributor_password (secret)|$(secret "(SELECT distributor_password FROM #sp)")
@optional_command_line|msdb.dbo.sysjobsteps.command of the pull agent job, minus the switches the procedure generates (absent: nothing else)|$(extra_switches)
$(sched_map)
@distribution_jobid|$RS.agent_id (output)|(SELECT CASE WHEN r.agent_id IS NULL THEN NULL WHEN EXISTS (SELECT 1 FROM #j WHERE job_id = CONVERT(uniqueidentifier, r.agent_id)) THEN N'agent_job_id' ELSE N'assigned' END FROM #rs r)
@encrypted_distributor_password|no-column: a flag of the call (how @distributor_password is passed)|$NC
@enabled_for_syncmgr|$SP.enabled_for_syncmgr|(SELECT enabled_for_syncmgr FROM #sp)
@ftp_address|$SP.ftp_address|(SELECT ftp_address FROM #sp)
@ftp_port|$SP.ftp_port|(SELECT ftp_port FROM #sp)
@ftp_login|$SP.ftp_login|(SELECT ftp_login FROM #sp)
@ftp_password|$SP.ftp_password (secret)|$(secret "(SELECT ftp_password FROM #sp)")
@alt_snapshot_folder|$SP.alt_snapshot_folder|(SELECT alt_snapshot_folder FROM #sp)
@working_directory|$SP.working_directory|(SELECT working_directory FROM #sp)
@use_ftp|$SP.use_ftp|(SELECT use_ftp FROM #sp)
@publication_type|$SP.publication_type (0 transactional)|(SELECT publication_type FROM #sp)
@dts_package_name|$SP.dts_package_name|(SELECT dts_package_name FROM #sp)
@dts_package_password|$SP.dts_package_password (secret)|$(secret "(SELECT dts_package_password FROM #sp)")
@dts_package_location|$SP.dts_package_location (0 distributor, 1 subscriber)|(SELECT dts_package_location FROM #sp)
@reserved|no-column: internal use|$NC
@offloadagent|$SP.offload_agent|(SELECT offload_agent FROM #sp)
@offloadserver|$SP.offload_server|(SELECT offload_server FROM #sp)
@job_name|msdb.dbo.sysjobs.name of the pull agent job|$(norm "(SELECT name FROM #j)")
@job_login|$SP.job_login|(SELECT job_login FROM #sp)
@job_password|$SP.job_password (secret)|$(secret "(SELECT job_password FROM #sp)")
@job_security_mode|no-column: Managed Instance only (refused with 41989 elsewhere, 07-changes)|$NC
EOF
)
LA="distribution.dbo.MSlogreader_agents"
MAP_LR=$(cat <<EOF
@job_login|$LA.job_login|(SELECT job_login FROM #la)
@job_password|$LA.job_password (secret)|$(secret "(SELECT job_password FROM #la)")
@job_name|msdb.dbo.sysjobs.name of the agent job ($LA.job_id)|$(norm "(SELECT name FROM #j)")
@publisher_security_mode|$LA.publisher_security_mode|(SELECT publisher_security_mode FROM #la)
@publisher_login|$LA.publisher_login|(SELECT publisher_login FROM #la)
@publisher_password|$LA.publisher_password (secret)|$(secret "(SELECT publisher_password FROM #la)")
@publisher|$LA.publisher_id (server name)|$(srv "(SELECT publisher_id FROM #la)")
@job_security_mode|no-column: Managed Instance only (refused with 41989 elsewhere, 07-changes)|$NC
EOF
)
SN="distribution.dbo.MSsnapshot_agents"
SCMD="msdb.dbo.sysjobsteps.command of the snapshot agent job, switch"
MAP_SNAP=$(cat <<EOF
$(sched_map)
@snapshot_job_name|msdb.dbo.sysjobs.name of the agent job ($SN.job_id)|$(norm "(SELECT name FROM #j)")
@publisher_security_mode|$SN.publisher_security_mode|(SELECT publisher_security_mode FROM #sn)
@publisher_login|$SN.publisher_login|(SELECT publisher_login FROM #sn)
@publisher_password|$SN.publisher_password (secret); pre-existing: sp_addpublication wrote it before this call, so this is not a default of sp_addpublication_snapshot|(SELECT CONCAT(N'pre-existing(', $(secret "(SELECT publisher_password FROM #sn)"), N')'))
@job_login|$SN.job_login|(SELECT job_login FROM #sn)
@job_password|$SN.job_password (secret)|$(secret "(SELECT job_password FROM #sn)")
@publisher|$SN.publisher_id (server name)|$(srv "(SELECT publisher_id FROM #sn)")
@distributor_security_mode|$SCMD -DistributorSecurityMode|$(switch DistributorSecurityMode)
@distributor_login|$SCMD -DistributorLogin|$(switch DistributorLogin)
@distributor_password|$SCMD -DistributorPassword (secret)|$(switch_secret DistributorPassword)
@job_security_mode|no-column: Managed Instance only (refused with 41989 elsewhere, 07-changes)|$NC
EOF
)
MAP_PROF=$(cat <<EOF
@profile_id|msdb.dbo.MSagent_profiles.profile_id (output variable passed)|(SELECT CASE WHEN profile_id IS NOT NULL THEN N'assigned' END FROM #pr)
@profile_type|MSagent_profiles.type (0 system, 1 custom)|(SELECT type FROM #pr)
@description|MSagent_profiles.description|(SELECT description FROM #pr)
@default|MSagent_profiles.def_profile|(SELECT def_profile FROM #pr)
EOF
)
MAP_RDBO=$(cat <<EOF
@ignore_distributor|no-column: a flag of the call (do not connect to the distributor)|$NC
@from_scripting|no-column: a flag of the call|$NC
EOF
)

cleaned=0
cleanup() {
    [ "$cleaned" = 1 ] && return
    cleaned=1
    ( stop_m_agents ) || true
    sql <<'SQL' >&2 || true
SET NOCOUNT ON;
IF DB_ID(N'm_dsub2') IS NOT NULL
    EXEC (N'USE m_dsub2; IF OBJECT_ID(N''dbo.MSreplication_subscriptions'') IS NOT NULL BEGIN TRY DECLARE @s sysname = @@SERVERNAME; EXEC sp_droppullsubscription @publisher = @s, @publisher_db = N''Sales'', @publication = N''m_ps''; END TRY BEGIN CATCH END CATCH; WHILE @@TRANCOUNT > 0 ROLLBACK;');
GO
USE Sales;
DECLARE @p sysname;
DECLARE c CURSOR LOCAL FOR SELECT name FROM dbo.syspublications WHERE name LIKE N'm\_%' ESCAPE N'\';
OPEN c; FETCH NEXT FROM c INTO @p;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY EXEC sp_dropsubscription @publication = @p, @article = N'all', @subscriber = N'all'; END TRY BEGIN CATCH END CATCH;
    WHILE @@TRANCOUNT > 0 ROLLBACK;
    BEGIN TRY EXEC sp_droppublication @publication = @p; END TRY BEGIN CATCH END CATCH;
    WHILE @@TRANCOUNT > 0 ROLLBACK;
    FETCH NEXT FROM c INTO @p;
END;
CLOSE c; DEALLOCATE c;
GO
-- m_freshsub, m_freshpull: sp_addsubscription registered them (or left them registered
-- after a refusal); sp_dropsubscriber leaves the sys.servers row, so both drops run, each
-- in its own TRY.
USE master;
BEGIN TRY EXEC sp_dropsubscriber @subscriber = N'm_freshsub'; END TRY BEGIN CATCH END CATCH;
WHILE @@TRANCOUNT > 0 ROLLBACK;
BEGIN TRY EXEC sp_dropserver @server = N'm_freshsub'; END TRY BEGIN CATCH END CATCH;
WHILE @@TRANCOUNT > 0 ROLLBACK;
BEGIN TRY EXEC sp_dropsubscriber @subscriber = N'm_freshpull'; END TRY BEGIN CATCH END CATCH;
WHILE @@TRANCOUNT > 0 ROLLBACK;
BEGIN TRY EXEC sp_dropserver @server = N'm_freshpull'; END TRY BEGIN CATCH END CATCH;
WHILE @@TRANCOUNT > 0 ROLLBACK;
GO
-- The distribution database names m_freshpull in MSreplservers too, and no procedure
-- deletes that row. It is deleted only when nothing still refers to it: no int or
-- smallint server id column of a distribution table (publisher_id, subscriber_id, srvid
-- and the like) holds its id, and no subscriber row or linked server has its name. The
-- M_FRESHSUB row an earlier run of this script left is not touched.
USE distribution;
DECLARE @id int = (SELECT srvid FROM dbo.MSreplservers WHERE UPPER(srvname) = N'M_FRESHPULL');
IF @id IS NOT NULL
BEGIN
    DECLARE @q nvarchar(max) = N'SELECT @n = 0', @n int;
    SELECT @q += N' + (SELECT COUNT(*) FROM ' + QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name) + N' WHERE ' + QUOTENAME(c.name) + N' = @id)'
    FROM sys.tables t JOIN sys.columns c ON c.object_id = t.object_id
    WHERE t.name <> N'MSreplservers' AND TYPE_NAME(c.system_type_id) IN (N'int', N'smallint')
      AND (c.name LIKE N'%publisher[_]id' OR c.name LIKE N'%subscriber[_]id' OR c.name LIKE N'%srvid' OR c.name LIKE N'%server[_]id');
    SET @q += N' + (SELECT COUNT(*) FROM dbo.MSsubscriber_info WHERE UPPER(subscriber) = N''M_FRESHPULL'') + (SELECT COUNT(*) FROM dbo.MSsubscriber_schedule WHERE UPPER(subscriber) = N''M_FRESHPULL'') + (SELECT COUNT(*) FROM sys.servers WHERE UPPER(name) = N''M_FRESHPULL'')';
    EXEC sp_executesql @q, N'@id int, @n int OUTPUT', @id, @n OUTPUT;
    IF @n = 0 DELETE FROM dbo.MSreplservers WHERE srvid = @id;
    ELSE PRINT CONCAT(N'm_freshpull: MSreplservers row ', @id, N' kept, ', @n, N' references');
END;
GO
USE Sales;
DROP TABLE IF EXISTS dbo.m_t, dbo.m_tf, dbo.m_tv, dbo.m_tc, dbo.m_tx1, dbo.m_tx2;
DROP VIEW IF EXISTS dbo.m_v, m_s.m_v;
DROP PROCEDURE IF EXISTS dbo.m_p, m_s.m_p;
DROP FUNCTION IF EXISTS dbo.m_f, m_s.m_f;
DROP TABLE IF EXISTS m_s.m_t;
IF SCHEMA_ID(N'm_s') IS NOT NULL DROP SCHEMA m_s;
GO
-- m_pubdb: a publication added and dropped removes the MSpublisher_databases row that
-- sp_addlogreader_agent inserted (sp_MSdrop_publication deletes it with the last
-- publication of the database); disabling publish then drops the log reader and its job.
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = N'm_pubdb' AND is_published = 1)
    EXEC (N'USE m_pubdb; BEGIN TRY EXEC sp_addpublication @publication = N''m_lrp''; EXEC sp_droppublication @publication = N''m_lrp''; END TRY BEGIN CATCH END CATCH; WHILE @@TRANCOUNT > 0 ROLLBACK;
USE master; BEGIN TRY EXEC sp_replicationdboption @dbname = N''m_pubdb'', @optname = N''publish'', @value = N''false''; END TRY BEGIN CATCH END CATCH;');
GO
DECLARE @id int = (SELECT profile_id FROM msdb.dbo.MSagent_profiles WHERE profile_name = N'm_prof');
IF @id IS NOT NULL EXEC msdb.dbo.sp_drop_agent_profile @profile_id = @id;
GO
DECLARE @j uniqueidentifier;
WHILE 1 = 1
BEGIN
    SET @j = (SELECT TOP (1) job_id FROM msdb.dbo.sysjobs WHERE name LIKE N'%-m\_%' ESCAPE N'\');
    IF @j IS NULL BREAK;
    EXEC msdb.dbo.sp_delete_job @job_id = @j;
END;
GO
-- A log reader that was just dropped can still hold its database for a few seconds.
DECLARE @d sysname, @i int, @s nvarchar(400);
DECLARE c CURSOR LOCAL FOR SELECT name FROM sys.databases WHERE name IN (N'm_dsub1', N'm_dsub2', N'm_dsub3', N'm_pubdb');
OPEN c; FETCH NEXT FROM c INTO @d;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @i = 0;
    WHILE DB_ID(@d) IS NOT NULL AND @i < 20
    BEGIN
        SET @s = N'ALTER DATABASE ' + QUOTENAME(@d) + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE ' + QUOTENAME(@d) + N';';
        BEGIN TRY EXEC (@s); END TRY
        BEGIN CATCH WAITFOR DELAY '00:00:02'; END CATCH;
        SET @i += 1;
    END;
    FETCH NEXT FROM c INTO @d;
END;
CLOSE c; DEALLOCATE c;
SQL
    podman exec repllab find /var/opt/mssql/data/ReplData/unc -mindepth 1 -maxdepth 1 -iname '*_m_*' -exec rm -rf {} + >&2 || true
}
trap cleanup EXIT

# Leftovers of an earlier run fail this run; the trap removes them.
left=$(sql_value "SELECT (SELECT COUNT(*) FROM Sales.dbo.syspublications WHERE name LIKE N'm\_%' ESCAPE N'\') + (SELECT COUNT(*) FROM sys.databases WHERE name LIKE N'm\_%' ESCAPE N'\') + (SELECT COUNT(*) FROM Sales.sys.objects WHERE name LIKE N'm\_%' ESCAPE N'\') + (SELECT COUNT(*) FROM Sales.sys.schemas WHERE name LIKE N'm\_%' ESCAPE N'\') + (SELECT COUNT(*) FROM msdb.dbo.MSagent_profiles WHERE profile_name LIKE N'm\_%' ESCAPE N'\') + (SELECT COUNT(*) FROM distribution.dbo.MSpublisher_databases WHERE publisher_db LIKE N'm\_%' ESCAPE N'\') + (SELECT COUNT(*) FROM sys.servers WHERE name LIKE N'm\_%' ESCAPE N'\')")
if [ "$left" != 0 ]; then
    echo "11-defaults: leftovers of an earlier run ($left); removing them and failing" >&2
    exit 1
fi

sql -b <<'SQL' >&2
SET NOCOUNT ON;
CREATE DATABASE m_dsub1; CREATE DATABASE m_dsub2; CREATE DATABASE m_dsub3; CREATE DATABASE m_pubdb;
GO
USE Sales;
CREATE TABLE dbo.m_t (id int PRIMARY KEY, a nvarchar(20));
CREATE TABLE dbo.m_tf (id int PRIMARY KEY, a nvarchar(20));
CREATE TABLE dbo.m_tv (id int PRIMARY KEY, a nvarchar(20));
CREATE TABLE dbo.m_tc (id int PRIMARY KEY, a nvarchar(20));
CREATE TABLE dbo.m_tx1 (id int PRIMARY KEY, a nvarchar(20));
CREATE TABLE dbo.m_tx2 (id int PRIMARY KEY, a nvarchar(20));
GO
CREATE SCHEMA m_s;
GO
CREATE TABLE m_s.m_t (id int PRIMARY KEY, a nvarchar(20));
GO
CREATE VIEW m_s.m_v AS SELECT id, a FROM m_s.m_t;
GO
CREATE PROCEDURE m_s.m_p AS SELECT 1;
GO
CREATE FUNCTION m_s.m_f (@x int) RETURNS int AS BEGIN RETURN @x; END;
GO
CREATE VIEW dbo.m_v AS SELECT id, a FROM dbo.m_t;
GO
CREATE PROCEDURE dbo.m_p AS SELECT 1;
GO
CREATE FUNCTION dbo.m_f (@x int) RETURNS int AS BEGIN RETURN @x; END;
GO
SQL

calls=()
call() { # ID DB STATEMENTS: runs the measured call, records its result
    try_in "$2" "$3"
    calls+=("$1=$TRY_RESULT${TRY_MSG:+ ($TRY_MSG)}")
}
never_fires() { # PUB: the snapshot agent of a setup publication, with a schedule that never fires
    sql -b -Q "SET NOCOUNT ON; USE Sales; EXEC sp_addpublication_snapshot @publication = N'$1', @frequency_type = 1, @active_start_date = 99991231, @job_login = NULL, @job_password = NULL, @publisher_security_mode = 1;" </dev/null >&2
}

# sp_addpublication, and the snapshot agent with the default schedule, disabled at once.
call pub.tran Sales "EXEC @rc = sp_addpublication @publication = N'm_dp_tran';"
measure sp_addpublication transactional "$MAP_PUB" "$PRE_PUB" "$TRY_RESULT" "" m_dp_tran
call snap.tran Sales "EXEC @rc = sp_addpublication_snapshot @publication = N'm_dp_tran';
DECLARE @sj uniqueidentifier = (SELECT CONVERT(uniqueidentifier, job_id) FROM distribution.dbo.MSsnapshot_agents WHERE publisher_db = N'Sales' AND publication = N'm_dp_tran' AND local_job = 1);
IF @sj IS NOT NULL EXEC msdb.dbo.sp_update_job @job_id = @sj, @enabled = 0;"
measure sp_addpublication_snapshot transactional "$MAP_SNAP" "$PRE_SNAP" "$TRY_RESULT" "" m_dp_tran
call pub.snap Sales "EXEC @rc = sp_addpublication @publication = N'm_dp_snap', @repl_freq = N'snapshot';"
measure sp_addpublication snapshot "$MAP_PUB" "$PRE_PUB" "$TRY_RESULT" "@repl_freq" m_dp_snap
call snap.snap Sales "EXEC @rc = sp_addpublication_snapshot @publication = N'm_dp_snap';
DECLARE @sj uniqueidentifier = (SELECT CONVERT(uniqueidentifier, job_id) FROM distribution.dbo.MSsnapshot_agents WHERE publisher_db = N'Sales' AND publication = N'm_dp_snap' AND local_job = 1);
IF @sj IS NOT NULL EXEC msdb.dbo.sp_update_job @job_id = @sj, @enabled = 0;"
measure sp_addpublication_snapshot snapshot-pub "$MAP_SNAP" "$PRE_SNAP" "$TRY_RESULT" "" m_dp_snap

# Publications that host the articles.
sql -b <<'SQL' >&2
SET NOCOUNT ON;
USE Sales;
EXEC sp_addpublication @publication = N'm_pa_nat', @sync_method = N'native';
EXEC sp_addpublication @publication = N'm_pa_con', @sync_method = N'concurrent';
EXEC sp_addpublication @publication = N'm_pa_chr', @sync_method = N'character';
EXEC sp_addpublication @publication = N'm_pa_snp', @repl_freq = N'snapshot';
EXEC sp_addpublication @publication = N'm_ps', @status = N'active', @allow_pull = N'true';
SQL
for p in m_pa_nat m_pa_con m_pa_chr m_pa_snp m_ps; do never_fires "$p"; done

article() { # CONTEXT PUB ARTICLE MAPKIND PASSED STATEMENT_ARGS
    call "art.$1" Sales "EXEC @rc = sp_addarticle @publication = N'$2', @article = N'$3', $6;"
    if [ "$4" = table ]; then
        measure sp_addarticle "$1" "$MAP_ART_TABLE" "$PRE_ART_TABLE" "$TRY_RESULT" "$5" "$2" "$3"
    else
        measure sp_addarticle "$1" "$MAP_ART_SCHEMA" "$PRE_ART_SCHEMA" "$TRY_RESULT" "$5" "$2" "$3"
    fi
}
article table.native m_pa_nat m_a1 table "@source_object" "@source_object = N'm_t'"
article table.concurrent m_pa_con m_a1 table "@source_object" "@source_object = N'm_t'"
article table.character m_pa_chr m_a1 table "@source_object" "@source_object = N'm_t'"
article table.snapshot-pub m_pa_snp m_a1 table "@source_object" "@source_object = N'm_t'"
article table.non-dbo-schema m_pa_nat m_a2 table "@source_owner @source_object @ins_cmd" "@source_owner = N'm_s', @source_object = N'm_t', @ins_cmd = N'CALL m_ins'"
article view-schema-only m_pa_nat m_a3 schema "@source_object @type" "@source_object = N'm_v', @type = N'view schema only'"
article proc-schema-only m_pa_nat m_a4 schema "@source_object @type" "@source_object = N'm_p', @type = N'proc schema only'"
article func-schema-only m_pa_nat m_a5 schema "@source_object @type" "@source_object = N'm_f', @type = N'func schema only'"

# The article kinds on a source in m_s, per sync method, transactional then snapshot.
nondbo() { # CONTEXT_SUFFIX PUB
    article "table.nondbo.$1" "$2" m_n1 table "@source_owner @source_object" "@source_owner = N'm_s', @source_object = N'm_t'"
    article "view-schema-only.nondbo.$1" "$2" m_n3 schema "@source_owner @source_object @type" "@source_owner = N'm_s', @source_object = N'm_v', @type = N'view schema only'"
    article "proc-schema-only.nondbo.$1" "$2" m_n4 schema "@source_owner @source_object @type" "@source_owner = N'm_s', @source_object = N'm_p', @type = N'proc schema only'"
    article "func-schema-only.nondbo.$1" "$2" m_n5 schema "@source_owner @source_object @type" "@source_owner = N'm_s', @source_object = N'm_f', @type = N'func schema only'"
}
for m in "${METHODS[@]}"; do
    name=${m%%:*}; method=${m#*:}
    sql -b -Q "SET NOCOUNT ON; USE Sales; EXEC sp_addpublication @publication = N'm_pa_$name', @sync_method = N'$method';" </dev/null >&2
    never_fires "m_pa_$name"
    nondbo "$name" "m_pa_$name"
done
for m in "${SNAP_METHODS[@]}"; do
    name=${m%%:*}; method=${m#*:}
    sql -b -Q "SET NOCOUNT ON; USE Sales; EXEC sp_addpublication @publication = N'm_ps_$name', @repl_freq = N'snapshot', @sync_method = N'$method';" </dev/null >&2
    never_fires "m_ps_$name"
    nondbo "snapshot-pub.$name" "m_ps_$name"
done

# sp_articlefilter, sp_articleview, sp_articlecolumn, each on its own table article.
sql -b <<'SQL' >&2
SET NOCOUNT ON;
USE Sales;
EXEC sp_addarticle @publication = N'm_pa_nat', @article = N'm_af', @source_object = N'm_tf';
EXEC sp_addarticle @publication = N'm_pa_nat', @article = N'm_av', @source_object = N'm_tv';
EXEC sp_addarticle @publication = N'm_pa_nat', @article = N'm_ac', @source_object = N'm_tc';
SQL
call filter.table Sales "EXEC @rc = sp_articlefilter @publication = N'm_pa_nat', @article = N'm_af';"
measure sp_articlefilter table "$MAP_FILTER" "$PRE_ART_TABLE" "$TRY_RESULT" "" m_pa_nat m_af
call view.table Sales "EXEC @rc = sp_articleview @publication = N'm_pa_nat', @article = N'm_av';"
measure sp_articleview table "$MAP_VIEW" "$PRE_ART_TABLE" "$TRY_RESULT" "" m_pa_nat m_av
call column.table Sales "EXEC @rc = sp_articlecolumn @publication = N'm_pa_nat', @article = N'm_ac';"
measure sp_articlecolumn table "$MAP_COLUMN" "$PRE_ART_TABLE" "$TRY_RESULT" "" m_pa_nat m_ac

# Subscriptions on m_ps.
sql -b -Q "SET NOCOUNT ON; USE Sales; EXEC sp_addarticle @publication = N'm_ps', @article = N'm_a', @source_object = N'm_t';" </dev/null >&2
call sub.push Sales "EXEC @rc = sp_addsubscription @publication = N'm_ps', @subscriber = @@SERVERNAME, @destination_db = N'm_dsub1';"
measure sp_addsubscription push "$MAP_SUB" "$PRE_SUB" "$TRY_RESULT" "@subscriber @destination_db" m_ps "" m_dsub1
call pushagent.push Sales "EXEC @rc = sp_addpushsubscription_agent @publication = N'm_ps', @subscriber = @@SERVERNAME, @subscriber_db = N'm_dsub1';"
measure sp_addpushsubscription_agent push "$MAP_PUSHAGENT" "$PRE_SUB" "$TRY_RESULT" "@subscriber @subscriber_db" m_ps "" m_dsub1
call sub.pull Sales "EXEC @rc = sp_addsubscription @publication = N'm_ps', @subscriber = @@SERVERNAME, @destination_db = N'm_dsub2', @subscription_type = N'pull';"
measure sp_addsubscription pull "$MAP_SUB" "$PRE_SUB" "$TRY_RESULT" "@subscriber @destination_db @subscription_type" m_ps "" m_dsub2
call pullsub.pull m_dsub2 "EXEC @rc = sp_addpullsubscription @publisher = @@SERVERNAME, @publisher_db = N'Sales', @publication = N'm_ps';"
measure sp_addpullsubscription pull "$MAP_PULLSUB" "$PRE_PULLSUB" "$TRY_RESULT" "@publisher_db" m_ps "" m_dsub2
call pullagent.pull m_dsub2 "DECLARE @srv sysname = @@SERVERNAME; EXEC @rc = sp_addpullsubscription_agent @publisher = @srv, @publisher_db = N'Sales', @publication = N'm_ps';"
measure sp_addpullsubscription_agent pull "$MAP_PULLAGENT" "$PRE_PULLAGENT" "$TRY_RESULT" "@publisher_db" m_ps "" m_dsub2

# Single rows of sp_addsubscription. Their calls are not in calls[]: a refusal is the
# measured result, recorded in the row.
EXTRA_ROWS=0
single() { # ID RESULT DETAIL
    r "$1" "$2" "$3"
    EXTRA_ROWS=$((EXTRA_ROWS + 1))
}
optional_params sp_addsubscription
decl_subtype=null
for i in "${!OPT_NAMES[@]}"; do [ "${OPT_NAMES[$i]}" = @subscriber_type ] && decl_subtype=${OPT_DEFAULTS[$i]}; done
# A subscriber name registered nowhere before the call.
pre=$(sql_value "SELECT CONCAT((SELECT COUNT(*) FROM sys.servers WHERE name = N'm_freshsub'), N'/', (SELECT COUNT(*) FROM distribution.dbo.MSsubscriber_info WHERE subscriber = N'm_freshsub'))")
[ "$pre" = 0/0 ] || def_fail "m_freshsub is registered before the call (sys.servers/MSsubscriber_info: $pre)"
try_in Sales "EXEC @rc = sp_addsubscription @publication = N'm_ps', @subscriber = N'm_freshsub', @destination_db = N'm_dsub5';"
fresh_call=$TRY_RESULT; fresh_msg=$TRY_MSG
fresh=$(sql_value "SELECT CONCAT(N'servers=', (SELECT COUNT(*) FROM sys.servers WHERE name = N'm_freshsub'), N' subscriber_info=', ISNULL((SELECT TOP (1) CONVERT(nvarchar(10), type) FROM distribution.dbo.MSsubscriber_info WHERE UPPER(subscriber) = N'M_FRESHSUB'), N'no-row'), N' subscription_rows=', (SELECT COUNT(*) FROM Sales.dbo.syssubscriptions WHERE srvname = N'm_freshsub' AND srvid >= 0))")
fresh_type=$(sql_value "SELECT ISNULL((SELECT TOP (1) CONVERT(nvarchar(10), type) FROM distribution.dbo.MSsubscriber_info WHERE UPPER(subscriber) = N'M_FRESHSUB'), N'no-row')")
[ "$fresh_call" = ok ] || fresh_type=$fresh_call
single D.sp_addsubscription.push.fresh-subscriber.@subscriber_type "$fresh_type" \
    "column=distribution.dbo.MSsubscriber_info.type of (publisher, m_freshsub) (0 SQL Server), m_freshsub registered nowhere before the call; after the call: $fresh declared=$decl_subtype call=$fresh_call${fresh_msg:+ ($fresh_msg)}"
# The same on a pull subscription, to another fresh name; m_ps allows pull.
pre=$(sql_value "SELECT CONCAT((SELECT COUNT(*) FROM sys.servers WHERE UPPER(name) = N'M_FRESHPULL'), N'/', (SELECT COUNT(*) FROM distribution.dbo.MSsubscriber_info WHERE UPPER(subscriber) = N'M_FRESHPULL'), N'/', (SELECT COUNT(*) FROM distribution.dbo.MSreplservers WHERE UPPER(srvname) = N'M_FRESHPULL'))")
[ "$pre" = 0/0/0 ] || def_fail "m_freshpull is registered before the call (sys.servers/MSsubscriber_info/MSreplservers: $pre)"
try_in Sales "EXEC @rc = sp_addsubscription @publication = N'm_ps', @subscriber = N'm_freshpull', @destination_db = N'm_dpull5', @subscription_type = N'pull';"
fpull_call=$TRY_RESULT; fpull_msg=$TRY_MSG
fpull=$(sql_value "SELECT CONCAT(N'servers=', (SELECT COUNT(*) FROM sys.servers WHERE UPPER(name) = N'M_FRESHPULL'), N' subscriber_info=', ISNULL((SELECT TOP (1) CONVERT(nvarchar(10), type) FROM distribution.dbo.MSsubscriber_info WHERE UPPER(subscriber) = N'M_FRESHPULL'), N'no-row'), N' subscriber_schedule_rows=', (SELECT COUNT(*) FROM distribution.dbo.MSsubscriber_schedule WHERE UPPER(subscriber) = N'M_FRESHPULL'), N' replservers=', (SELECT COUNT(*) FROM distribution.dbo.MSreplservers WHERE UPPER(srvname) = N'M_FRESHPULL'), N' subscription_rows=', (SELECT COUNT(*) FROM Sales.dbo.syssubscriptions s JOIN sys.servers v ON v.server_id = s.srvid WHERE UPPER(v.name) = N'M_FRESHPULL' AND s.srvid >= 0), N' subscription_type=', ISNULL((SELECT STRING_AGG(CONVERT(nvarchar(10), s.subscription_type), N'/') FROM Sales.dbo.syssubscriptions s JOIN sys.servers v ON v.server_id = s.srvid WHERE UPPER(v.name) = N'M_FRESHPULL' AND s.srvid >= 0), N'none'))")
fpull_type=$(sql_value "SELECT ISNULL((SELECT TOP (1) CONVERT(nvarchar(10), type) FROM distribution.dbo.MSsubscriber_info WHERE UPPER(subscriber) = N'M_FRESHPULL'), N'no-row')")
[ "$fpull_call" = ok ] || fpull_type=$fpull_call
single D.sp_addsubscription.pull.fresh-subscriber.@subscriber_type "$fpull_type" \
    "column=distribution.dbo.MSsubscriber_info.type of (publisher, m_freshpull) (0 SQL Server), m_freshpull registered nowhere (sys.servers, MSsubscriber_info, MSreplservers) before the pull call; after the call: $fpull declared=$decl_subtype call=$fpull_call${fpull_msg:+ ($fpull_msg)}"

# The statuses of R10 and R36 on m_pa_ext.
sql -b <<'SQL' >&2
SET NOCOUNT ON;
USE Sales;
EXEC sp_addpublication @publication = N'm_pa_ext', @sync_method = N'native', @independent_agent = N'true', @allow_pull = N'true', @status = N'active';
SQL
never_fires m_pa_ext
sql -b -Q "SET NOCOUNT ON; USE Sales; EXEC sp_addarticle @publication = N'm_pa_ext', @article = N'm_x1', @source_object = N'm_tx1';" </dev/null >&2
# sub_rows DB ARTICLE: status, subscription_type and sync_type of the subscription rows of
# ARTICLE in m_pa_ext for DB, distinct values joined by /, no-row when none.
sub_col() { # COLUMN DB ARTICLE
    sql_value "SELECT ISNULL((SELECT STRING_AGG(CONVERT(nvarchar(10), v), N'/') WITHIN GROUP (ORDER BY v) FROM (SELECT DISTINCT s.$1 AS v FROM Sales.dbo.syssubscriptions s JOIN Sales.dbo.sysarticles a ON a.artid = s.artid JOIN Sales.dbo.syspublications p ON p.pubid = a.pubid WHERE p.name = N'm_pa_ext' AND a.name = N'$3' AND s.dest_db = N'$2' AND s.srvid >= 0) x), N'no-row')"
}
SS="column=syssubscriptions.status (0 inactive, 1 subscribed, 2 active)"
try_in Sales "EXEC @rc = sp_addsubscription @publication = N'm_pa_ext', @subscriber = @@SERVERNAME, @destination_db = N'm_dsub3', @sync_type = N'replication support only';"
rso_call=$TRY_RESULT; rso_msg=$TRY_MSG
v=$(sub_col status m_dsub3 m_x1); [ "$rso_call" = ok ] || v=$rso_call
single D.sp_addsubscription.push.rso.@status "$v" \
    "$SS of a push subscription created with @sync_type = replication support only (sync_type=$(sub_col sync_type m_dsub3 m_x1)), m_pa_ext m_x1 to m_dsub3 call=$rso_call${rso_msg:+ ($rso_msg)}"
try_in Sales "EXEC @rc = sp_addsubscription @publication = N'm_pa_ext', @subscriber = @@SERVERNAME, @destination_db = N'm_dsub4', @subscription_type = N'pull';"
pull_call=$TRY_RESULT
[ "$pull_call" = ok ] || def_fail "the pull subscription of m_pa_ext to m_dsub4 was refused: $TRY_RESULT $TRY_MSG"
sql -b -Q "SET NOCOUNT ON; USE Sales; EXEC sp_addarticle @publication = N'm_pa_ext', @article = N'm_x2', @source_object = N'm_tx2';" </dev/null >&2
try_in Sales "EXEC @rc = sp_addsubscription @publication = N'm_pa_ext', @subscriber = @@SERVERNAME, @destination_db = N'm_dsub4', @article = N'm_x2', @subscription_type = N'pull', @sync_type = N'automatic';"
ext_call=$TRY_RESULT; ext_msg=$TRY_MSG
v=$(sub_col status m_dsub4 m_x2); [ "$ext_call" = ok ] || v=$ext_call
single D.sp_addsubscription.extend.pull.@status "$v" \
    "$SS of the m_x2 row of the pull subscription of m_pa_ext to m_dsub4 (m_x1 row: $(sub_col status m_dsub4 m_x1)), extended by sp_addsubscription @article = m_x2, @subscription_type = pull, @sync_type = automatic call=$ext_call${ext_msg:+ ($ext_msg)}"
v=$(sub_col subscription_type m_dsub4 m_x2); [ "$ext_call" = ok ] || v=$ext_call
single D.sp_addsubscription.extend.pull.@subscription_type "$v" \
    "column=syssubscriptions.subscription_type (0 push, 1 pull) of the m_x2 row of the same extension (m_x1 row: $(sub_col subscription_type m_dsub4 m_x1)) call=$ext_call"
v=$(sql_value "SELECT COUNT(*) FROM distribution.dbo.MSdistribution_agents WHERE publisher_db = N'Sales' AND publication = N'm_pa_ext' AND subscriber_db = N'm_dsub4' AND subscriber_id >= 0")
single D.sp_addsubscription.extend.pull.agents "$v" \
    "column=count of distribution.dbo.MSdistribution_agents rows of m_pa_ext for m_dsub4 after the extension (subscription_type of the rows: $(sql_value "SELECT ISNULL(STRING_AGG(CONVERT(nvarchar(10), subscription_type), N'/'), N'none') FROM distribution.dbo.MSdistribution_agents WHERE publisher_db = N'Sales' AND publication = N'm_pa_ext' AND subscriber_db = N'm_dsub4' AND subscriber_id >= 0")) call=$ext_call"
try_in Sales "EXEC @rc = sp_addsubscription @publication = N'm_pa_ext', @subscriber = @@SERVERNAME, @destination_db = N'm_dsub3', @article = N'm_x2', @subscription_type = N'push', @sync_type = N'replication support only';"
rext_call=$TRY_RESULT; rext_msg=$TRY_MSG
v=$(sub_col status m_dsub3 m_x2); [ "$rext_call" = ok ] || v=$rext_call
single D.sp_addsubscription.extend.rso.@status "$v" \
    "$SS of the m_x2 row of the replication support only subscription of m_pa_ext to m_dsub3 (m_x1 row: $(sub_col status m_dsub3 m_x1); sync_type of the m_x2 row: $(sub_col sync_type m_dsub3 m_x2)), extended by sp_addsubscription @article = m_x2, @subscription_type = push, @sync_type = replication support only call=$rext_call${rext_msg:+ ($rext_msg)}"

# The log reader of a newly published database, and the publish option itself.
call rdbo.publish master "EXEC @rc = sp_replicationdboption @dbname = N'm_pubdb', @optname = N'publish', @value = N'true';"
measure sp_replicationdboption publish "$MAP_RDBO" "$PRE_NONE" "$TRY_RESULT" ""
call lr.pubdb m_pubdb "EXEC @rc = sp_addlogreader_agent;"
measure sp_addlogreader_agent publication-db "$MAP_LR" "$PRE_LR" "$TRY_RESULT" "" "" "" m_pubdb

# A distribution agent profile.
call prof.3 msdb "DECLARE @pid int; EXEC @rc = sp_add_agent_profile @profile_id = @pid OUTPUT, @profile_name = N'm_prof', @agent_type = 3;"
measure sp_add_agent_profile agent-type-3 "$MAP_PROF" "$PRE_PROF" "$TRY_RESULT" "@profile_id" m_prof

# Controls.
bad=0
control() { echo "11-defaults: control failed: $*" >&2; bad=1; }
for c in "${calls[@]}"; do
    [[ $c == *=ok ]] || control "call not ok: $c"
done
[ "${#COUNTS[@]}" = "$EXPECTED_CONTEXTS" ] || control "${#COUNTS[@]} contexts, expected $EXPECTED_CONTEXTS"
[ "$((COUNT_SUM + EXTRA_ROWS))" = "${#rows[@]}" ] || control "the per-context counts add up to $COUNT_SUM and the single rows to $EXTRA_ROWS, the script built ${#rows[@]} rows"
expect() { # ID VALUE
    local v; v=$(value "$1")
    [ "$v" = "$2" ] || control "$1 is '$v', expected '$2'"
}
expect D.sp_addarticle.table.native.@schema_option 0x0000000000030073
expect D.sp_addarticle.table.snapshot-pub.@schema_option 0x0000000000030071
expect D.sp_addarticle.table.non-dbo-schema.@destination_owner m_s
expect D.sp_addarticle.table.non-dbo-schema.@ins_cmd "CALL [dbo].[m_ins]"
for id in D.sp_addpushsubscription_agent.push.@frequency_type D.sp_addpublication_snapshot.transactional.@frequency_type \
          D.sp_addpullsubscription_agent.pull.@frequency_type D.sp_addlogreader_agent.publication-db.@job_name; do
    v=$(value "$id")
    [ -n "$v" ] && [ "$v" != no-job ] && [ "$v" != null ] || control "$id is '$v': the context did not find its agent job"
done

cleanup
pubdbs=$(sql_value "SELECT COUNT(*) FROM distribution.dbo.MSpublisher_databases WHERE publisher_db LIKE N'm\_%' ESCAPE N'\'")
[ "$pubdbs" = 0 ] || control "distribution keeps $pubdbs MSpublisher_databases rows for m_ databases after the cleanup"
fpull_left=$(sql_value "SELECT CONCAT((SELECT COUNT(*) FROM sys.servers WHERE UPPER(name) = N'M_FRESHPULL'), N'/', (SELECT COUNT(*) FROM distribution.dbo.MSsubscriber_info WHERE UPPER(subscriber) = N'M_FRESHPULL'), N'/', (SELECT COUNT(*) FROM distribution.dbo.MSsubscriber_schedule WHERE UPPER(subscriber) = N'M_FRESHPULL'), N'/', (SELECT COUNT(*) FROM distribution.dbo.MSreplservers WHERE UPPER(srvname) = N'M_FRESHPULL'))")
[ "$fpull_left" = 0/0/0/0 ] || control "m_freshpull is left after the cleanup (sys.servers/MSsubscriber_info/MSsubscriber_schedule/MSreplservers: $fpull_left)"
for c in "${COUNTS[@]}"; do echo "count $c"; done
echo "count sum: $COUNT_SUM, single rows: $EXTRA_ROWS"
if [ "$bad" != 0 ]; then
    for c in "${calls[@]}"; do echo "call: $c" >&2; done
    for row in "${rows[@]}"; do echo "row: $row" >&2; done
    exit 1
fi
for row in "${rows[@]}"; do printf '%s\n' "$row"; done
echo "R|TOTAL|${#rows[@]}"
