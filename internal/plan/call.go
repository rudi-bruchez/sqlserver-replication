package plan

import (
	"fmt"
	"reflect"
	"strconv"
	"strings"

	"github.com/rudi-bruchez/sqlserver-replication/internal/decode"
	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
	"github.com/rudi-bruchez/sqlserver-replication/internal/normalize"
)

// procContext is where a procedure runs: the server's role and the
// database, with the rows that measured it.
type procContext struct {
	Role     string // publisher, distributor or subscriber
	Database string // master, publication, distribution, subscription or msdb
	// Source cites the rows, ", "-separated: "<results file> <row id>"
	// (an X. row must have the result ok), "<results file>" alone, or
	// "note O<n>" for an observation of lab/README.md (R40).
	Source string
}

// procContexts gives the context of every procedure the plan calls.
var procContexts = map[string]procContext{
	// 5001 "User must be in the master database" in msdb and tempdb.
	"sp_adddistributor":    {"distributor", "master", "distributor-defaults X.sp_adddistributor.master"},
	"sp_adddistributiondb": {"distributor", "master", "distributor-defaults X.sp_adddistributiondb.master"},
	"sp_adddistpublisher":  {"distributor", "master", "distributor-defaults X.sp_adddistpublisher.master"},

	"sp_replicationdboption":       {"publisher", "master", "12-contexts X.sp_replicationdboption.master"},
	"sp_addpublication":            {"publisher", "publication", "12-contexts X.sp_addpublication.Sales"},
	"sp_addpublication_snapshot":   {"publisher", "publication", "12-contexts X.sp_addpublication_snapshot.Sales"},
	"sp_addarticle":                {"publisher", "publication", "12-contexts X.sp_addarticle.Sales"},
	"sp_articlefilter":             {"publisher", "publication", "12-contexts X.sp_articlefilter.Sales"},
	"sp_articleview":               {"publisher", "publication", "12-contexts X.sp_articleview.Sales"},
	"sp_articlecolumn":             {"publisher", "publication", "12-contexts X.sp_articlecolumn.Sales"},
	"sp_addsubscription":           {"publisher", "publication", "12-contexts X.sp_addsubscription.push.Sales, 12-contexts X.sp_addsubscription.pull.Sales"},
	"sp_addpushsubscription_agent": {"publisher", "publication", "12-contexts X.sp_addpushsubscription_agent.Sales"},
	// The .Sales row is 21831: the log reader of Sales existed.
	"sp_addlogreader_agent": {"publisher", "publication", "12-contexts X.sp_addlogreader_agent.m_ctx"},

	// The change and drop calls of the campaign ran with USE Sales.
	"sp_changepublication":          {"publisher", "publication", "02-matrix, 09-snapshot-pub"},
	"sp_changearticle":              {"publisher", "publication", "02-matrix, 09-snapshot-pub"},
	"sp_changesubscription":         {"publisher", "publication", "07-changes SUB.*"},
	"sp_changelogreader_agent":      {"publisher", "publication", "07-changes AGT.sp_changelogreader_agent.*"},
	"sp_changepublication_snapshot": {"publisher", "publication", "07-changes AGT.sp_changepublication_snapshot.*"},
	"sp_dropsubscription":           {"publisher", "publication", "06-structural, 08-pull P3.*"},
	"sp_droparticle":                {"publisher", "publication", "06-structural"},
	"sp_droppublication":            {"publisher", "publication", "06-structural"},
	"sp_startpublication_snapshot":  {"publisher", "publication", "06-structural, 15-snapshot-scope"},

	"sp_addpullsubscription":            {"subscriber", "subscription", "12-contexts X.sp_addpullsubscription.m_ctx"},
	"sp_addpullsubscription_agent":      {"subscriber", "subscription", "12-contexts X.sp_addpullsubscription_agent.m_ctx"},
	"sp_change_subscription_properties": {"subscriber", "subscription", "08-pull P2.*"},
	"sp_droppullsubscription":           {"subscriber", "subscription", "08-pull P3.*"},

	"sp_add_agent_profile":      {"distributor", "master", "12-contexts X.sp_add_agent_profile.master, 19-profiles"},
	"sp_change_agent_profile":   {"distributor", "master", "19-profiles"},
	"sp_add_agent_parameter":    {"distributor", "master", "19-profiles"},
	"sp_change_agent_parameter": {"distributor", "master", "19-profiles"},
	"sp_drop_agent_parameter":   {"distributor", "master", "19-profiles PF.drop_parameter"},
	"sp_drop_agent_profile":     {"distributor", "master", "19-profiles"},
	// Called [<distribution db>].dbo.sp_update_agent_profile (procedureName):
	// msdb.dbo. and the plain name from a publication database are 21482.
	"sp_update_agent_profile": {"distributor", "distribution", "07-changes PRF.distribution-prefix.cwd-distribution"},

	// The DST.* calls of 07-changes ran with USE Sales, the publication
	// database of the local distributor (run_case).
	"sp_changedistributiondb": {"distributor", "publication", "07-changes DST.*"},
	"sp_changedistpublisher":  {"distributor", "publication", "07-changes DST.*"},

	// The job's server: the distributor for the snapshot agent and a push
	// distribution agent, the subscriber for a pull agent, whose operation
	// names its own Server.
	"msdb.dbo.sp_update_job": {"distributor", "msdb", "note O20"},
	"msdb.dbo.sp_start_job":  {"distributor", "msdb", "note O20"},
}

// procedureName renders proc as it is called. sp_update_agent_profile runs
// in the distribution database, prefixed by it (07-changes
// PRF.distribution-prefix.cwd-distribution).
func procedureName(proc, distributionDB string) string {
	if proc == "sp_update_agent_profile" {
		return quoteName(distributionDB) + ".dbo." + proc
	}
	return proc
}

func quoteName(s string) string { return "[" + strings.ReplaceAll(s, "]", "]]") + "]" }

// literal is the nvarchar literal of s.
func literal(s string) string { return "N'" + strings.ReplaceAll(s, "'", "''") + "'" }

// encoder renders a model value as a T-SQL literal.
type encoder func(v any) (literal string, err error)

// value dereferences v: nil and a nil pointer give ok false.
func value(v any) (any, bool) {
	rv := reflect.ValueOf(v)
	for rv.IsValid() && rv.Kind() == reflect.Pointer {
		if rv.IsNil() {
			return nil, false
		}
		rv = rv.Elem()
	}
	if !rv.IsValid() {
		return nil, false
	}
	return rv.Interface(), true
}

func asString(v any) (string, error) {
	x, ok := value(v)
	if !ok {
		return "", fmt.Errorf("no value")
	}
	rv := reflect.ValueOf(x)
	if rv.Kind() != reflect.String {
		return "", fmt.Errorf("%T is not a string", x)
	}
	return rv.String(), nil
}

func asBool(v any) (bool, error) {
	x, ok := value(v)
	if !ok {
		return false, fmt.Errorf("no value")
	}
	b, ok := x.(bool)
	if !ok {
		return false, fmt.Errorf("%T is not a bool", x)
	}
	return b, nil
}

// asInt accepts an int or a decimal string (a distributor property).
func asInt(v any) (int, error) {
	x, ok := value(v)
	if !ok {
		return 0, fmt.Errorf("no value")
	}
	switch n := x.(type) {
	case int:
		return n, nil
	case string:
		return strconv.Atoi(n)
	}
	return 0, fmt.Errorf("%T is not an int", x)
}

func asStrings(v any) ([]string, error) {
	x, ok := value(v)
	if !ok {
		return nil, fmt.Errorf("no value")
	}
	xs, ok := x.([]string)
	if !ok {
		return nil, fmt.Errorf("%T is not a list", x)
	}
	return xs, nil
}

func encString(v any) (string, error) {
	s, err := asString(v)
	if err != nil {
		return "", err
	}
	if s == "" {
		return "NULL", nil
	}
	return literal(s), nil
}

func encBool(v any) (string, error) {
	b, err := asBool(v)
	if err != nil {
		return "", err
	}
	return literal(strconv.FormatBool(b)), nil
}

func encInt(v any) (string, error) {
	n, err := asInt(v)
	if err != nil {
		return "", err
	}
	return strconv.Itoa(n), nil
}

// encCode encodes a name as its integer code.
func encCode(code func(string) (int, error)) encoder {
	return func(v any) (string, error) {
		s, err := asString(v)
		if err != nil {
			return "", err
		}
		n, err := code(s)
		if err != nil {
			return "", err
		}
		return strconv.Itoa(n), nil
	}
}

// encWord encodes a name as one of the words of words.
func encWord(words map[string]string) encoder {
	return func(v any) (string, error) {
		s, err := asString(v)
		if err != nil {
			return "", err
		}
		w, ok := words[s]
		if !ok {
			return "", fmt.Errorf("%q has no measured form", s)
		}
		return literal(w), nil
	}
}

// encSubday is the @frequency_subday code; "" (no subday) is NULL.
func encSubday(v any) (string, error) {
	if s, err := asString(v); err == nil && s == "" {
		return "NULL", nil
	}
	return encCode(decode.FreqSubdayTypeCode)(v)
}

// syncMethodWords are the @sync_method words: the decode names with
// spaces where sp_addpublication has them.
var syncMethodWords = map[string]string{
	"native": "native", "character": "character", "concurrent": "concurrent", "concurrent_c": "concurrent_c",
	"database_snapshot": "database snapshot", "database_snapshot_character": "database snapshot character",
}

// articleTypeWord is the @type word of an article type: the decode name with
// spaces (proc_schema_only is proc schema only).
func articleTypeWord(v any) (string, error) {
	s, err := asString(v)
	if err != nil {
		return "", err
	}
	if strings.HasPrefix(s, "unknown(") || decode.ArticleType(mustCode(decode.ArticleTypeCode(s))) != s {
		return "", fmt.Errorf("article type %q has no name", s)
	}
	return literal(strings.ReplaceAll(s, "_", " ")), nil
}

func mustCode(n int, err error) int {
	if err != nil {
		return -1
	}
	return n
}

func encPreCreation(v any) (string, error) {
	s, err := asString(v)
	if err != nil {
		return "", err
	}
	if strings.HasPrefix(s, "unknown(") || decode.PreCreationCmd(mustCode(decode.PreCreationCmdCode(s))) != s {
		return "", fmt.Errorf("pre_creation_cmd %q has no name", s)
	}
	return literal(s), nil
}

func schemaOptionValue(v any) (uint64, error) {
	xs, err := asStrings(v)
	if err != nil {
		return 0, err
	}
	return decode.EncodeSchemaOptions(xs)
}

// encSchemaOption is the binary(8) literal of sp_addarticle @schema_option.
func encSchemaOption(v any) (string, error) {
	n, err := schemaOptionValue(v)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("0x%016X", n), nil
}

// encArticleStatus is sp_addarticle @status from insert_column_names and
// parameterized, in the order of their model.Parameters paths.
func encArticleStatus(v any) (string, error) {
	xs, ok := v.([]any)
	if !ok || len(xs) != 2 {
		return "", fmt.Errorf("@status needs insert_column_names and parameterized")
	}
	icn, err := asBool(xs[0])
	if err != nil {
		return "", fmt.Errorf("insert_column_names: %w", err)
	}
	par, err := asBool(xs[1])
	if err != nil {
		return "", fmt.Errorf("parameterized: %w", err)
	}
	n := 0
	if icn {
		n += decode.ArticleStatusInsertColumnNames
	}
	if par {
		n += decode.ArticleStatusParameterized
	}
	return strconv.Itoa(n), nil
}

// commandText renders a command as decode.Command.String, schema-qualified
// (R15). A CALL-family command without its procedure is generated by the
// server and cannot be passed.
func commandText(v any) (string, error) {
	x, ok := value(v)
	if !ok {
		return "", fmt.Errorf("no value")
	}
	c, ok := x.(model.Command)
	if !ok {
		return "", fmt.Errorf("%T is not a command", x)
	}
	switch strings.ToUpper(c.Mode) {
	case "CALL", "SCALL", "MCALL", "XCALL":
		if c.Procedure == nil || c.Procedure.Schema == "" {
			return "", fmt.Errorf("a %s command is passed only with its schema-qualified procedure", c.Mode)
		}
		return decode.Command{Mode: c.Mode, Schema: c.Procedure.Schema, Procedure: c.Procedure.Name}.String(), nil
	}
	if c.Procedure != nil {
		return "", fmt.Errorf("a %s command has no procedure", c.Mode)
	}
	return c.Mode, nil
}

func encCommand(v any) (string, error) {
	s, err := commandText(v)
	if err != nil {
		return "", err
	}
	return literal(s), nil
}

// encObjectName passes the name of an object (a view, a filter procedure);
// its schema is a parameter of its own where the procedure has one.
func encObjectName(v any) (string, error) {
	x, ok := value(v)
	if !ok {
		return "", fmt.Errorf("no value")
	}
	n, ok := x.(model.ObjectName)
	if !ok {
		return "", fmt.Errorf("%T is not an object name", x)
	}
	return literal(n.Name), nil
}

// encArticleList is sp_addsubscription @article for a one-article list; a
// longer subset is one call per article, whose @article the caller passes.
func encArticleList(v any) (string, error) {
	xs, err := asStrings(v)
	if err != nil {
		return "", err
	}
	if len(xs) != 1 {
		return "", fmt.Errorf("@article takes one article, not %d: one call per article", len(xs))
	}
	return literal(xs[0]), nil
}

// encSecret returns the secret's name; creationCall puts it into
// Param.Secret, never into Value (R16).
func encSecret(v any) (string, error) { return asString(v) }

// encFromIdentity marks a parameter the caller always supplies.
func encFromIdentity(any) (string, error) {
	return "", fmt.Errorf("supplied by the caller as an identity parameter")
}

var (
	encSecurity     = encCode(decode.SecurityModeCode) // windows 1, sql 0
	encFreq         = encCode(decode.FreqTypeCode)
	encAgentType    = encCode(decode.AgentTypeCode)
	encSubscriber   = encCode(decode.SubscriberTypeCode)
	encPubTypeCode  = encCode(decode.PublicationTypeCode)
	encSyncMethod   = encWord(syncMethodWords)
	encReplFreq     = encWord(map[string]string{"transactional": "continuous", "snapshot": "snapshot"})
	encSyncType     = encWord(map[string]string{"snapshot": "automatic", "replication_support_only": "replication support only", "backup": "initialize with backup"})
	encSubscription = encWord(map[string]string{"push": "push", "pull": "pull"})
)

// encoders encode the parameters of the creation calls, keyed
// <procedure>.@<param>. Booleans are N'true' and N'false', security modes
// and frequencies their integer codes, strings N'...' with "" as NULL.
var encoders = func() map[string]encoder {
	m := map[string]encoder{}
	set := func(enc encoder, proc string, params ...string) {
		for _, p := range params {
			m[proc+"."+p] = enc
		}
	}
	schedule := func(proc string) {
		set(encFreq, proc, "@frequency_type")
		set(encSubday, proc, "@frequency_subday")
		set(encInt, proc, "@frequency_interval", "@frequency_subday_interval", "@frequency_relative_interval",
			"@frequency_recurrence_factor", "@active_start_date", "@active_end_date",
			"@active_start_time_of_day", "@active_end_time_of_day")
	}
	connection := func(proc, prefix string) {
		set(encSecurity, proc, prefix+"security_mode")
		set(encString, proc, prefix+"login")
		set(encSecret, proc, prefix+"password")
	}

	set(encFromIdentity, "sp_add_agent_parameter", "@profile_id", "@parameter_name", "@parameter_value")
	set(encString, "sp_add_agent_profile", "@profile_name", "@description")
	set(encAgentType, "sp_add_agent_profile", "@agent_type")
	set(encBool, "sp_add_agent_profile", "@default")
	set(encFromIdentity, "sp_update_agent_profile", "@agent_type", "@agent_id", "@profile_id")

	const a = "sp_addarticle"
	set(encString, a, "@publication", "@article", "@destination_table", "@creation_script", "@description",
		"@filter_clause", "@destination_owner", "@source_owner", "@sync_object_owner", "@source_object",
		"@identityrangemanagementoption")
	set(articleTypeWord, a, "@type")
	set(encObjectName, a, "@sync_object")
	set(encCommand, a, "@ins_cmd", "@del_cmd", "@upd_cmd")
	set(encPreCreation, a, "@pre_creation_cmd")
	set(encSchemaOption, a, "@schema_option")
	set(encArticleStatus, a, "@status")
	set(encBool, a, "@fire_triggers_on_snapshot")

	set(encString, "sp_adddistpublisher", "@publisher", "@distribution_db", "@working_directory")
	connection("sp_adddistpublisher", "@")
	set(encBool, "sp_adddistpublisher", "@trusted")
	set(encSecret, "sp_adddistpublisher", "@storage_connection_string")

	const db = "sp_adddistributiondb"
	set(encString, db, "@database", "@data_folder", "@data_file", "@log_folder", "@log_file")
	set(encInt, db, "@data_file_size", "@log_file_size", "@min_distretention", "@max_distretention",
		"@history_retention", "@deletebatchsize_xact", "@deletebatchsize_cmd")
	connection(db, "@")

	set(encString, "sp_adddistributor", "@distributor")
	set(encInt, "sp_adddistributor", "@heartbeat_interval")
	set(encSecret, "sp_adddistributor", "@password")
	set(encSecurity, "sp_adddistributor", "@security_mode")
	set(encBool, "sp_adddistributor", "@multi_subnet_failover")

	set(encString, "sp_addlogreader_agent", "@job_login")
	set(encSecret, "sp_addlogreader_agent", "@job_password")
	connection("sp_addlogreader_agent", "@publisher_")

	const p = "sp_addpublication"
	set(encString, p, "@publication", "@description", "@status", "@alt_snapshot_folder", "@pre_snapshot_script",
		"@post_snapshot_script", "@ftp_address", "@ftp_subdirectory", "@ftp_login")
	set(encSyncMethod, p, "@sync_method")
	set(encReplFreq, p, "@repl_freq")
	set(encBool, p, "@independent_agent", "@immediate_sync", "@enabled_for_internet", "@allow_push", "@allow_pull",
		"@allow_anonymous", "@snapshot_in_defaultfolder", "@compress_snapshot", "@allow_subscription_copy",
		"@allow_initialize_from_backup", "@replicate_ddl", "@enabled_for_het_sub", "@allow_partition_switch",
		"@replicate_partition_switch", "@allow_drop")
	set(encInt, p, "@retention", "@ftp_port")
	set(encSecret, p, "@ftp_password")

	const s = "sp_addpublication_snapshot"
	set(encString, s, "@publication", "@job_login")
	schedule(s)
	connection(s, "@publisher_")
	connection(s, "@distributor_")
	set(encSecret, s, "@job_password")

	const ps = "sp_addpullsubscription"
	set(encString, ps, "@publisher", "@publisher_db", "@publication", "@description")
	set(encBool, ps, "@independent_agent", "@immediate_sync")
	set(encSubscription, ps, "@subscription_type")

	const pa = "sp_addpullsubscription_agent"
	set(encString, pa, "@publisher", "@publisher_db", "@publication", "@subscriber", "@subscriber_db",
		"@distributor", "@alt_snapshot_folder", "@working_directory", "@job_login")
	connection(pa, "@subscriber_")
	connection(pa, "@distributor_")
	schedule(pa)
	set(encBool, pa, "@enabled_for_syncmgr", "@use_ftp")
	set(encPubTypeCode, pa, "@publication_type")
	set(encSecret, pa, "@job_password")

	const ph = "sp_addpushsubscription_agent"
	set(encString, ph, "@publication", "@subscriber", "@subscriber_db", "@job_login")
	connection(ph, "@subscriber_")
	set(encSecret, ph, "@job_password")
	schedule(ph)

	const sub = "sp_addsubscription"
	set(encString, sub, "@publication", "@subscriber", "@destination_db", "@backupdevicetype", "@backupdevicename")
	set(encArticleList, sub, "@article")
	set(encSyncType, sub, "@sync_type")
	set(encSubscription, sub, "@subscription_type")
	set(encBool, sub, "@loopback_detection", "@unload", "@memory_optimized")
	schedule(sub)
	set(encSecret, sub, "@mediapassword", "@password")
	set(encInt, sub, "@fileidhint", "@subscriptionstreams")
	set(encSubscriber, sub, "@subscriber_type")
	connection(sub, "@subscriber_")

	set(encString, "sp_articlecolumn", "@publication", "@article")
	set(encFromIdentity, "sp_articlecolumn", "@column", "@operation")
	set(encString, "sp_articlefilter", "@publication", "@article", "@filter_clause")
	set(encObjectName, "sp_articlefilter", "@filter_name")
	set(encString, "sp_articleview", "@publication", "@article", "@filter_clause")
	set(encObjectName, "sp_articleview", "@view_name")

	set(encString, "sp_replicationdboption", "@dbname")
	set(encFromIdentity, "sp_replicationdboption", "@optname", "@value")
	return m
}()

// fromIdentity are the parameters the caller always supplies in identity:
// creationCall never resolves them from the object.
var fromIdentity = map[string]string{
	"sp_add_agent_parameter.@profile_id":      "the profile's id, found in the batch (Task 14)",
	"sp_add_agent_parameter.@parameter_name":  "one call per parameter of the profile (R6)",
	"sp_add_agent_parameter.@parameter_value": "one call per parameter of the profile (R6)",
	"sp_update_agent_profile.@agent_type":     "the type code of the agent's place in the file",
	"sp_update_agent_profile.@agent_id":       "the agent's id, found in the batch (Task 14)",
	"sp_update_agent_profile.@profile_id":     "the profile's id, found in the batch (Task 14)",
	"sp_articlecolumn.@column":                "one call per column (Task 11)",
	"sp_articlecolumn.@operation":             "add or drop, from the difference of the column lists (Task 11)",
	"sp_replicationdboption.@optname":         "the option the call sets: publish; sync with backup is not passed for a database the plan publishes (R41)",
	"sp_replicationdboption.@value":           "the value of the option the call sets",
}

// neverPassed are the mapped parameters a creation call never passes, with
// the reason. sp_addarticle @sync_object is not among them: a nil
// sync_object (the generated view, R31) is not passed because nil values
// never are, and a user view is passed by its encoder.
var neverPassed = map[string]string{
	"sp_addlogreader_agent.@job_name":                     "job_name is never compared; the server names the job (R41)",
	"sp_addpublication.@logreader_job_name":               "job_name is never compared; the server names the job (R41)",
	"sp_addpublication_snapshot.@snapshot_job_name":       "job_name is never compared; the server names the job (R41)",
	"sp_addpullsubscription_agent.@job_name":              "job_name is never compared; the server names the job (R41)",
	"sp_addpushsubscription_agent.@job_name":              "job_name is never compared; the server names the job (R41)",
	"sp_addpullsubscription_agent.@optional_command_line": "the command line is never compared (R32) and the exported one is the whole generated line, which @optional_command_line would append to (R41: not passed)",
	"sp_addsubscription.@optional_command_line":           "the command line is never compared (R32) and the exported one is the whole generated line, which @optional_command_line would append to (R41: not passed)",
	"sp_addsubscription.@subscriptionlsn":                 "creation_only for a subscription initialized from an LSN, which the plan does not create (R21)",
	"sp_addarticle.@source_table":                         "@source_object names the same table; the campaign scripts pass @source_owner and @source_object (03-add-article.sh)",
	"sp_addarticle.@filter":                               "measured by a reader: 14027, the procedure does not exist before sp_articlefilter creates it, and the call's sys.sp_MSreinit_article adds 20026",
	"sp_addarticle.@filter_owner":                         "the schema of @filter, which is never passed (14027)",
	"sp_addarticle.@vertical_partition":                   "measured by a reader: N'true' publishes the key column alone and later sp_articlecolumn drops leave it so; the article starts with every column and drops (Task 11)",
}

// objectBases gives the model path pattern each Context.Object is relative
// to: normalize's objectBases (internal/normalize/defaults.go), and the
// publisher, which no default is measured for (sp_replicationdboption).
var objectBases = map[string]string{
	"publication":                  "publications[*]",
	"article":                      "publications[*].articles[*]",
	"push_subscription":            "publications[*].subscriptions[*]",
	"snapshot_agent":               "publications[*].snapshot_agent",
	"push_agent":                   "publications[*].subscriptions[*].distribution_agent",
	"shared_push_agent":            "publisher.shared_distribution_agents[*].distribution_agent",
	"pull_subscription":            "publications[*].subscriptions[*]",
	"subscriber_pull_subscription": "publications[*].subscriptions[*]",
	"pull_agent":                   "publications[*].subscriptions[*].pull_agent",
	"log_reader_agent":             "publisher.log_reader_agent",
	"distributor":                  "distributor",
	"distribution_db":              "distributor",
	"distpublisher":                "distributor",
	"profile":                      "agent_profiles[*]",
	"publisher":                    "publisher",
}

// creationCall builds the call of the creation procedure proc for the
// normalized object obj (a pointer to the model struct at ctx.Object's base)
// by R15. It walks the model.Parameters entries of proc in order: an
// identity parameter is taken as given; an excluded, never-passed or later
// than 2022 one is skipped; a field or creation_only one is resolved under
// obj and passed when it has a value that differs from the default of ctx
// (normalize.Lookup). A nil value, a path outside obj, and a zero
// non-pointer value without a default (a schedule's start_date, R37) are not
// passed. Identity parameters that model.Parameters does not list come last.
func creationCall(proc string, obj any, ctx normalize.Context, identity []Param) (Call, error) {
	base, ok := objectBases[ctx.Object]
	if !ok {
		return Call{}, fmt.Errorf("%s: unknown object %q", proc, ctx.Object)
	}
	ids := map[string]Param{}
	for _, p := range identity {
		ids[p.Name] = p
	}
	call := Call{Procedure: proc}
	used := map[string]bool{}
	for _, m := range model.Parameters {
		if m.Procedure != proc {
			continue
		}
		key := proc + "." + m.Parameter
		if p, ok := ids[m.Parameter]; ok {
			call.Params = append(call.Params, p)
			used[m.Parameter] = true
			continue
		}
		if m.Kind == model.ParamExcluded || m.Since > "2022" || neverPassed[key] != "" || fromIdentity[key] != "" {
			continue
		}
		p, ok, err := resolveParam(m, obj, base, ctx)
		if err != nil {
			return Call{}, fmt.Errorf("%s %s: %w", proc, m.Parameter, err)
		}
		if ok {
			call.Params = append(call.Params, p)
		}
	}
	for _, p := range identity {
		if !used[p.Name] {
			call.Params = append(call.Params, p)
		}
	}
	return call, nil
}

// resolveParam resolves the paths of m under obj and encodes the parameter
// when it is to be passed.
func resolveParam(m model.ParamMapping, obj any, base string, ctx normalize.Context) (Param, bool, error) {
	var vals []any
	differs, secret := false, false
	for _, path := range m.Paths {
		rel, ok := strings.CutPrefix(path, base+".")
		if !ok {
			continue
		}
		v, ok := resolve(obj, rel)
		if !ok {
			continue
		}
		d, hasDefault := normalize.Lookup(ctx, rel)
		switch {
		case hasDefault:
			if !equalDefault(rel, v, d.Value, obj) {
				differs = true
			}
		case !isZero(v):
			differs = true
		}
		secret = secret || strings.HasSuffix(rel, "_secret")
		vals = append(vals, v)
	}
	if len(vals) == 0 || !differs {
		return Param{}, false, nil
	}
	enc, ok := encoders[m.Procedure+"."+m.Parameter]
	if !ok {
		return Param{}, false, fmt.Errorf("no encoder")
	}
	var v any = vals[0]
	if len(vals) > 1 {
		v = vals
	}
	lit, err := enc(v)
	if err != nil {
		return Param{}, false, err
	}
	if secret {
		return Param{Name: m.Parameter, Secret: lit}, true, nil
	}
	return Param{Name: m.Parameter, Value: lit}, true, nil
}

// isZero tells a zero non-pointer value (a schedule's 0, an empty clause).
func isZero(v any) bool {
	rv := reflect.ValueOf(v)
	return rv.Kind() != reflect.Pointer && rv.IsZero()
}

// equalDefault compares a resolved value with a defaults table value, in
// the form the export writes it (normalize.Default.Value).
func equalDefault(rel string, v any, def string, obj any) bool {
	if a, ok := obj.(*model.Article); ok {
		def = normalize.Fill(def, a.Source.Schema, a.Source.Name)
	}
	x, ok := value(v)
	if !ok {
		return false
	}
	switch t := x.(type) {
	case model.Command:
		dc := decode.ParseCommand(def)
		if t.Procedure == nil {
			return strings.EqualFold(t.Mode, dc.Mode)
		}
		s, err := commandText(t)
		return err == nil && s == dc.String()
	case model.ObjectName:
		return def != "" && def == t.Name
	case []string:
		dl, ok := normalize.ParseList(def)
		if !ok {
			return false
		}
		if rel == "schema_options" {
			a, errA := decode.EncodeSchemaOptions(t)
			b, errB := decode.EncodeSchemaOptions(dl)
			return errA == nil && errB == nil && a == b
		}
		return strings.Join(t, "\x00") == strings.Join(dl, "\x00")
	case bool:
		return strconv.FormatBool(t) == def
	case int:
		return strconv.Itoa(t) == def
	}
	rv := reflect.ValueOf(x)
	if rv.Kind() == reflect.String {
		return rv.String() == def
	}
	return false
}

// resolve follows the YAML keys of rel from obj; "[*]" takes a list's
// first element (an agent has at most one schedule, R22). ok is false when a
// pointer on the way is nil, a map has no such key, a list is empty, or the
// value is a nil pointer or a nil list.
func resolve(obj any, rel string) (any, bool) {
	cur := reflect.ValueOf(obj)
	for _, seg := range strings.Split(rel, ".") {
		key, elem := strings.CutSuffix(seg, "[*]")
		if cur = indirect(cur); !cur.IsValid() {
			return nil, false
		}
		switch cur.Kind() {
		case reflect.Struct:
			f, ok := field(cur, key)
			if !ok {
				return nil, false
			}
			cur = f
		case reflect.Map:
			f := cur.MapIndex(reflect.ValueOf(key))
			if !f.IsValid() {
				return nil, false
			}
			cur = f
		default:
			return nil, false
		}
		if elem {
			if cur = indirect(cur); !cur.IsValid() || cur.Kind() != reflect.Slice || cur.Len() == 0 {
				return nil, false
			}
			cur = cur.Index(0)
		}
	}
	if (cur.Kind() == reflect.Pointer || cur.Kind() == reflect.Slice || cur.Kind() == reflect.Map) && cur.IsNil() {
		return nil, false
	}
	return cur.Interface(), true
}

func indirect(v reflect.Value) reflect.Value {
	for v.IsValid() && v.Kind() == reflect.Pointer {
		if v.IsNil() {
			return reflect.Value{}
		}
		v = v.Elem()
	}
	return v
}

// field finds the field of struct sv with YAML key key, inlined fields
// included.
func field(sv reflect.Value, key string) (reflect.Value, bool) {
	t := sv.Type()
	for i := range t.NumField() {
		f := t.Field(i)
		tag, ok := f.Tag.Lookup("yaml")
		if !f.IsExported() || !ok {
			continue
		}
		k, opts, _ := strings.Cut(tag, ",")
		if strings.Contains(","+opts+",", ",inline,") {
			if v, ok := field(sv.Field(i), key); ok {
				return v, true
			}
			continue
		}
		if k == "" {
			k = strings.ToLower(f.Name)
		}
		if k == key {
			return sv.Field(i), true
		}
	}
	return reflect.Value{}, false
}

// Change-call @value encoders (R39): always an nvarchar literal, whose form
// depends on the property.

// chgString is a string property; "" clears it with NULL (18-reverse
// RV.*.alt_snapshot_folder.null, .creation_script.null).
func chgString(v any) (string, error) { return encString(v) }

// chgBool is N'true' or N'false'.
func chgBool(v any) (string, error) { return encBool(v) }

// chgBit is N'1' or N'0'.
func chgBit(v any) (string, error) {
	b, err := asBool(v)
	if err != nil {
		return "", err
	}
	if b {
		return literal("1"), nil
	}
	return literal("0"), nil
}

// chgInt is the integer as a string: N'100'.
func chgInt(v any) (string, error) {
	n, err := asInt(v)
	if err != nil {
		return "", err
	}
	return literal(strconv.Itoa(n)), nil
}

// chgSecurity is N'0' for sql, N'1' for windows.
func chgSecurity(v any) (string, error) {
	lit, err := encSecurity(v)
	if err != nil {
		return "", err
	}
	return literal(lit), nil
}

// chgSchemaOption is N'0x' and 16 hex digits: a bare binary literal is
// refused with 21805 and leaves the transaction open (R39).
func chgSchemaOption(v any) (string, error) {
	n, err := schemaOptionValue(v)
	if err != nil {
		return "", err
	}
	return literal(fmt.Sprintf("0x%016X", n)), nil
}

// chgCommand is the command as decode.Command.String, schema-qualified,
// the stored form 11-defaults shows.
func chgCommand(v any) (string, error) { return encCommand(v) }

// articleStatusWords are the @value words of sp_changearticle status: the
// two bits the model holds, each direction.
var articleStatusWords = map[string]bool{
	"include column names": true, // 02-matrix.sql @artprops (A14)
	"no column names":      true, // 18-reverse.sh status.no_column_names
	"parameters":           true, // 18-reverse.sh status.parameters
	"string literals":      true, // 02-matrix.sql @artprops (A16)
}

// articleStatusWord is the sp_changearticle status word that sets the
// property (insert_column_names or parameterized) to on.
func articleStatusWord(property string, on bool) (string, error) {
	switch {
	case property == "insert_column_names" && on:
		return "include column names", nil
	case property == "insert_column_names":
		return "no column names", nil
	case property == "parameterized" && on:
		return "parameters", nil
	case property == "parameterized":
		return "string literals", nil
	}
	return "", fmt.Errorf("%s is not an article status bit", property)
}

// chgArticleStatus takes the word of articleStatusWord.
func chgArticleStatus(v any) (string, error) {
	s, err := asString(v)
	if err != nil {
		return "", err
	}
	if !articleStatusWords[s] {
		return "", fmt.Errorf("article status %q has no measured word", s)
	}
	return literal(s), nil
}

// valueEncoders encode the @value of the change calls, keyed (procedure,
// property) by R39. Each comment names the script line its literal comes
// from.
var valueEncoders = map[[2]string]encoder{
	// 02-matrix.sql @pubprops, and 09-snapshot-pub-matrix.sql for the
	// snapshot publications: the same forms.
	{"sp_changepublication", "description"}:                  chgString,                                                              // (N'SalesPub', N'description', N'changed')
	{"sp_changepublication", "retention"}:                    chgInt,                                                                 // (N'SalesPub', N'retention', N'100')
	{"sp_changepublication", "replicate_ddl"}:                chgBit,                                                                 // (N'SalesPub', N'replicate_ddl', N'0'); N'false' is 245 (R39)
	{"sp_changepublication", "allow_pull"}:                   chgBool,                                                                // (N'SalesPub', N'allow_pull', N'false')
	{"sp_changepublication", "allow_push"}:                   chgBool,                                                                // (N'SalesPub', N'allow_push', N'false')
	{"sp_changepublication", "allow_initialize_from_backup"}: chgBool,                                                                // (N'SalesPub', N'allow_initialize_from_backup', N'true')
	{"sp_changepublication", "allow_subscription_copy"}:      chgBool,                                                                // (N'SalesPub', N'allow_subscription_copy', N'true')
	{"sp_changepublication", "allow_partition_switch"}:       chgBool,                                                                // (N'SalesPub', N'allow_partition_switch', N'true')
	{"sp_changepublication", "replicate_partition_switch"}:   chgBool,                                                                // (N'SalesPub', N'replicate_partition_switch', N'true')
	{"sp_changepublication", "allow_drop"}:                   chgBool,                                                                // (N'SalesPub', N'allow_drop', N'true')
	{"sp_changepublication", "status"}:                       encWord(map[string]string{"active": "active", "inactive": "inactive"}), // (N'SalesPub', N'status', N'inactive')
	{"sp_changepublication", "sync_method"}:                  encSyncMethod,                                                          // 09-snapshot-pub-matrix.sql ('*', N'sync_method', N'database snapshot')
	{"sp_changepublication", "immediate_sync"}:               chgBool,                                                                // (N'SalesPub', N'immediate_sync', N'false')
	{"sp_changepublication", "independent_agent"}:            chgBool,                                                                // (N'SalesRef', N'independent_agent', N'true')
	{"sp_changepublication", "allow_anonymous"}:              chgBool,                                                                // (N'SalesPub', N'allow_anonymous', N'true')
	{"sp_changepublication", "alt_snapshot_folder"}:          chgString,                                                              // (N'SalesPub', N'alt_snapshot_folder', N'/var/opt/mssql/data/ReplAlt')
	{"sp_changepublication", "snapshot_in_defaultfolder"}:    chgBool,                                                                // (N'SalesPub', N'snapshot_in_defaultfolder', N'false')
	{"sp_changepublication", "pre_snapshot_script"}:          chgString,                                                              // (N'SalesPub', N'pre_snapshot_script', N'/var/opt/mssql/data/pre.sql')
	{"sp_changepublication", "post_snapshot_script"}:         chgString,                                                              // (N'SalesPub', N'post_snapshot_script', N'/var/opt/mssql/data/post.sql')
	{"sp_changepublication", "ftp_address"}:                  chgString,                                                              // (N'SalesPub', N'ftp_address', N'ftp.example.com')

	// 02-matrix.sql @artprops.
	{"sp_changearticle", "description"}:               chgString,        // (N'SalesPub', N'Orders', N'description', N'changed')
	{"sp_changearticle", "dest_table"}:                chgString,        // (N'SalesPub', N'Orders', N'dest_table', N'Orders2')
	{"sp_changearticle", "destination_owner"}:         chgString,        // (N'SalesPub', N'Orders', N'destination_owner', N'other')
	{"sp_changearticle", "ins_cmd"}:                   chgCommand,       // (N'SalesPub', N'Orders', N'ins_cmd', N'CALL sp_MSins_dboOrders'), schema-qualified
	{"sp_changearticle", "upd_cmd"}:                   chgCommand,       // (N'SalesPub', N'Orders', N'upd_cmd', N'MCALL sp_MSupd_dboOrders'), schema-qualified
	{"sp_changearticle", "del_cmd"}:                   chgCommand,       // (N'SalesPub', N'Orders', N'del_cmd', N'NONE')
	{"sp_changearticle", "pre_creation_cmd"}:          encPreCreation,   // (N'SalesPub', N'Orders', N'pre_creation_cmd', N'delete')
	{"sp_changearticle", "schema_option"}:             chgSchemaOption,  // (N'SalesPub', N'Orders', N'schema_option', N'0x000000000803509F')
	{"sp_changearticle", "status"}:                    chgArticleStatus, // (N'SalesPub', N'Orders', N'status', N'include column names'); articleStatusWord
	{"sp_changearticle", "creation_script"}:           chgString,        // (N'SalesPub', N'Orders', N'creation_script', N'/var/opt/mssql/data/create.sql')
	{"sp_changearticle", "fire_triggers_on_snapshot"}: chgBool,          // (N'SalesPub', N'Orders', N'fire_triggers_on_snapshot', N'true')
	{"sp_changearticle", "sync_object"}:               encObjectName,    // (N'SalesPub', N'Orders', N'sync_object', N'vCustomerFR')
	{"sp_changearticle", "type"}:                      articleTypeWord,  // (N'SalesPub', N'Orders', N'type', N'logbased manualfilter')

	// 07-changes.sh, the sub helper (@value = N'$2').
	{"sp_changesubscription", "distrib_job_login"}:        chgString,   // run_case AGT.sp_changesubscription.distrib_job_login, N'REPLLAB\m_nobody'
	{"sp_changesubscription", "memory_optimized"}:         chgBit,      // SUB loop memory_optimized=1
	{"sp_changesubscription", "subscriber_security_mode"}: chgSecurity, // SUB loop subscriber_security_mode=0
	{"sp_changesubscription", "subscriptionstreams"}:      chgInt,      // SUB loop subscriptionstreams=2

	// 07-changes.sh, the db and dp helpers.
	{"sp_changedistributiondb", "min_distretention"}: chgInt,      // run_case DST.sp_changedistributiondb.min_distretention, N'2'
	{"sp_changedistributiondb", "max_distretention"}: chgInt,      // run_case DST.sp_changedistributiondb.max_distretention, N'96'
	{"sp_changedistributiondb", "history_retention"}: chgInt,      // run_case DST.sp_changedistributiondb.history_retention, N'24'
	{"sp_changedistpublisher", "working_directory"}:  chgString,   // run_case DST.sp_changedistpublisher.working_directory, N'/var/opt/mssql/data'
	{"sp_changedistpublisher", "security_mode"}:      chgSecurity, // run_case DST.sp_changedistpublisher.security_mode, N'0'

	// 08-pull.sh P2_TABLE, through CHANGE_CALL and sqlq (N'...').
	{"sp_change_subscription_properties", "alt_snapshot_folder"}:       chgString,   // alt_snapshot_folder;...;/var/opt/mssql/data/m_altsnap
	{"sp_change_subscription_properties", "distrib_job_login"}:         chgString,   // distrib_job_login;...;REPLLAB\m_user
	{"sp_change_subscription_properties", "distributor"}:               chgString,   // distributor;...;m_dist
	{"sp_change_subscription_properties", "distributor_security_mode"}: chgSecurity, // distributor_security_mode;...;0;1
	{"sp_change_subscription_properties", "memory_optimized"}:          chgBit,      // memory_optimized;-;0;-;1;0
	{"sp_change_subscription_properties", "use_ftp"}:                   chgBool,     // use_ftp;use_ftp;0;0;true;false
	{"sp_change_subscription_properties", "working_directory"}:         chgString,   // working_directory;...;/var/opt/mssql/data/m_wd
}
