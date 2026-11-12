package normalize

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"
	"testing"

	"github.com/rudi-bruchez/sqlserver-replication/internal/decode"
	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
)

// resultRow is one line R|<id>|<result>|<detail> of a campaign results file.
type resultRow struct {
	id, result, detail string
}

// resultsDir holds the results files the defaults cite.
const resultsDir = "../../lab/results/2022/"

// readResults returns the rows of lab/results/2022/<file>.txt by id, and the
// ids in file order.
func readResults(t *testing.T, file string) (map[string]resultRow, []string) {
	t.Helper()
	f, err := os.Open(resultsDir + file + ".txt")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	rows := map[string]resultRow{}
	var order []string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		if !strings.HasPrefix(line, "R|") {
			continue
		}
		parts := strings.SplitN(line, "|", 4)
		if len(parts) < 3 {
			t.Fatalf("%s: malformed row %q", file, line)
		}
		r := resultRow{id: parts[1], result: parts[2]}
		if len(parts) == 4 {
			r.detail = parts[3]
		}
		if _, dup := rows[r.id]; dup {
			t.Fatalf("%s: row %s twice", file, r.id)
		}
		rows[r.id] = r
		order = append(order, r.id)
	}
	if err := sc.Err(); err != nil {
		t.Fatal(err)
	}
	return rows, order
}

// results reads both files the defaults cite.
func results(t *testing.T) map[string]map[string]resultRow {
	t.Helper()
	out := map[string]map[string]resultRow{}
	for _, f := range []string{"11-defaults", "distributor-defaults"} {
		out[f], _ = readResults(t, f)
	}
	return out
}

// splitRow splits "11-defaults D.x.@y" into the file and the row id.
func splitRow(t *testing.T, row string) (file, id string) {
	t.Helper()
	file, id, ok := strings.Cut(row, " ")
	if !ok {
		t.Fatalf("row %q: want \"<file> <id>\"", row)
	}
	return file, id
}

// listedContexts are the row contexts the defaults table is built from (plan
// 3, Task 5), with the fresh-subscriber row of sp_addsubscription
// @subscriber_type (Task 2).
var listedContexts = func() []string {
	out := []string{
		"11-defaults D.sp_addpublication.transactional",
		"11-defaults D.sp_addpublication.snapshot",
		"11-defaults D.sp_addarticle.table.native",
		"11-defaults D.sp_addarticle.table.concurrent",
		"11-defaults D.sp_addarticle.table.character",
		"11-defaults D.sp_addarticle.table.snapshot-pub",
		"11-defaults D.sp_addarticle.view-schema-only",
		"11-defaults D.sp_addarticle.proc-schema-only",
		"11-defaults D.sp_addarticle.func-schema-only",
	}
	for _, kind := range []string{"table", "view-schema-only", "proc-schema-only", "func-schema-only"} {
		for _, m := range []string{"native", "character", "concurrent", "concurrent_c", "dbsnap", "dbsnap_c"} {
			out = append(out, "11-defaults D.sp_addarticle."+kind+".nondbo."+m)
		}
		for _, m := range []string{"native", "character", "dbsnap", "dbsnap_c"} {
			out = append(out, "11-defaults D.sp_addarticle."+kind+".nondbo.snapshot-pub."+m)
		}
	}
	return append(out,
		"11-defaults D.sp_addpublication_snapshot.transactional",
		"11-defaults D.sp_addpublication_snapshot.snapshot-pub",
		"11-defaults D.sp_addlogreader_agent.publication-db",
		"11-defaults D.sp_addsubscription.push",
		"11-defaults D.sp_addsubscription.push.fresh-subscriber",
		"11-defaults D.sp_addsubscription.pull",
		"11-defaults D.sp_addpushsubscription_agent.push",
		"11-defaults D.sp_addpullsubscription.pull",
		"11-defaults D.sp_addpullsubscription_agent.pull",
		"11-defaults D.sp_add_agent_profile.agent-type-3",
		"distributor-defaults D.sp_adddistributor.fresh",
		"distributor-defaults D.sp_adddistributiondb.fresh",
		"distributor-defaults D.sp_adddistpublisher.fresh",
	)
}()

// contextOf returns the listed context of a row ("<file> D.<proc>.<ctx>.@p")
// and its parameter; ok is false for a row of no listed context.
func contextOf(row string) (ctx, param string, ok bool) {
	ctx, param, found := strings.Cut(row, ".@")
	if !found || strings.Contains(param, ".") {
		return "", "", false
	}
	for _, c := range listedContexts {
		if c == ctx {
			return ctx, "@" + param, true
		}
	}
	return "", "", false
}

// procedureOf returns the procedure of a context: sp_addarticle for
// "11-defaults D.sp_addarticle.table.native".
func procedureOf(ctx string) string {
	_, id, _ := strings.Cut(ctx, " ")
	return strings.Split(id, ".")[1]
}

func mapping(proc, param string) (model.ParamMapping, bool) {
	for _, m := range model.Parameters {
		if m.Procedure == proc && m.Parameter == param {
			return m, true
		}
	}
	return model.ParamMapping{}, false
}

// notADefault tells the results that are not a value the procedure stored by
// default (plan 3, Task 5).
func notADefault(result string) bool {
	switch result {
	case "no-column", "no-row", "assigned":
		return true
	}
	return strings.HasPrefix(result, "pre-existing(")
}

func TestDefaultsCiteRows(t *testing.T) {
	rs := results(t)
	if len(Defaults) == 0 {
		t.Fatal("Defaults is empty")
	}
	for _, d := range Defaults {
		file, id := splitRow(t, d.Row)
		r, ok := rs[file][id]
		switch {
		case !ok:
			t.Errorf("%s: no such row", d.Row)
		case r.result != d.Stored:
			t.Errorf("%s: Stored %q, the row's result is %q", d.Row, d.Stored, r.result)
		}
	}
	for row := range notDefaults {
		file, id := splitRow(t, row)
		if _, ok := rs[file][id]; !ok {
			t.Errorf("notDefaults %s: no such row", row)
		}
	}
}

func TestDefaultsCoverRows(t *testing.T) {
	entries := map[string][]Default{}
	for _, d := range Defaults {
		entries[d.Row] = append(entries[d.Row], d)
	}
	seen := map[string]int{}
	for _, file := range []string{"11-defaults", "distributor-defaults"} {
		rows, order := readResults(t, file)
		for _, id := range order {
			row := file + " " + id
			ctx, param, ok := contextOf(row)
			if !ok {
				continue
			}
			seen[ctx]++
			m, ok := mapping(procedureOf(ctx), param)
			if !ok {
				t.Errorf("%s: %s.%s has no model.Parameters entry", row, procedureOf(ctx), param)
				continue
			}
			if m.Kind != model.ParamField || notADefault(rows[id].result) {
				if len(entries[row]) > 0 {
					t.Errorf("%s: an entry for a row that is not a default (kind %s, result %q)", row, m.Kind, rows[id].result)
				}
				continue
			}
			_, reason := notDefaults[row]
			switch {
			case len(entries[row]) == 0 && !reason:
				t.Errorf("%s maps to a field and has neither an entry nor a notDefaults reason", row)
			case len(entries[row]) > 0 && reason:
				t.Errorf("%s has both an entry and a notDefaults reason", row)
			}
			for _, d := range entries[row] {
				base, ok := objectBases[d.Context.Object]
				if !ok {
					t.Errorf("%s: unknown object %q", row, d.Context.Object)
					continue
				}
				full := model.Join(base, d.Path)
				found := false
				for _, p := range m.Paths {
					found = found || p == full
				}
				if !found {
					t.Errorf("%s: path %s is not one of the parameter's paths %v", row, full, m.Paths)
				}
			}
		}
	}
	for _, c := range listedContexts {
		if seen[c] == 0 {
			t.Errorf("context %s: no row", c)
		}
	}
	for row := range entries {
		if _, _, ok := contextOf(row); !ok {
			t.Errorf("entry %s: not a row of a listed context", row)
		}
	}
	for row := range notDefaults {
		if _, _, ok := contextOf(row); !ok {
			t.Errorf("notDefaults %s: not a row of a listed context", row)
		}
	}
}

// Paths by how their stored value decodes.
var (
	boolPaths = set("independent_agent", "immediate_sync", "snapshot.enabled_for_internet", "allow_push",
		"allow_pull", "allow_anonymous", "snapshot.in_default_folder", "snapshot.compress",
		"allow_subscription_copy", "allow_initialize_from_backup", "replicate_ddl", "enabled_for_het_sub",
		"fire_triggers_on_snapshot", "loopback_detection", "distribution_agent.memory_optimized",
		"pull_agent.memory_optimized", "memory_optimized", "enabled_for_syncmgr", "use_ftp", "default", "trusted")
	intPaths = set("retention_hours", "snapshot.ftp.port", "min_retention_hours", "max_retention_hours",
		"history_retention_hours", "delete_batch_size_xact", "delete_batch_size_cmd",
		"properties.heartbeat_interval")
	// stringPaths are nullable strings: NULL, '' and an absent command
	// switch all read as "" (the reader's ISNULL and Ptr("")).
	stringPaths = set("description", "snapshot.alt_folder", "snapshot.pre_script", "snapshot.post_script",
		"snapshot.ftp.address", "snapshot.ftp.subdirectory", "snapshot.ftp.login", "creation_script",
		"filter.clause", "job_login", "connection.login", "distributor_connection.login",
		"distribution_agent.connection.login", "publisher_connection.login", "pull_agent.description",
		"alt_snapshot_folder", "working_directory")
	securityPaths = set("connection.security", "distributor_connection.security",
		"distribution_agent.connection.security", "publisher_connection.security")
	// optionBits are the syspublications.options bits the rows show as
	// options=<n>.
	optionBits = map[string]int{
		"allow_partition_switch":     decode.PubOptionAllowPartitionSwitch,
		"replicate_partition_switch": decode.PubOptionReplicatePartitionSwitch,
		"allow_drop":                 decode.PubOptionAllowDrop,
	}
)

func set(xs ...string) map[string]bool {
	out := map[string]bool{}
	for _, x := range xs {
		out[x] = true
	}
	return out
}

func atoi(s string) (int, error) { return strconv.Atoi(s) }

// decodeStored decodes the result field of a row with the decoder of the
// entry's path, as the reader would read the stored value.
func decodeStored(d Default) (string, error) {
	s, p := d.Stored, d.Path
	num := func(f func(int) string) (string, error) {
		n, err := atoi(s)
		if err != nil {
			return "", err
		}
		return f(n), nil
	}
	if _, key, ok := strings.Cut(p, "schedules[*]."); ok {
		switch key {
		case "frequency":
			return num(decode.FreqType)
		case "subday":
			// The reader leaves subday empty for 0 and for agent start
			// schedules (internal/reader/agents.go).
			return num(func(n int) string {
				if n == 0 {
					return ""
				}
				return decode.FreqSubdayType(n)
			})
		}
		return num(strconv.Itoa)
	}
	switch {
	case boolPaths[p]:
		return num(func(n int) string { return strconv.FormatBool(n != 0) })
	case optionBits[p] != 0:
		v, ok := strings.CutPrefix(s, "options=")
		if !ok {
			return "", fmt.Errorf("want options=<n>")
		}
		n, err := atoi(v)
		return strconv.FormatBool(n&optionBits[p] != 0), err
	case intPaths[p]:
		return num(strconv.Itoa)
	case stringPaths[p]:
		switch s {
		case "null", "''", "absent":
			return "", nil
		}
		return s, nil
	case securityPaths[p]:
		return num(decode.SecurityMode)
	}
	switch p {
	case "sync_method":
		return num(decode.SyncMethod)
	case "type":
		switch d.Context.Object {
		case "publication":
			return num(decode.PublicationType)
		case "article":
			return num(decode.ArticleType)
		case "push_subscription":
			return num(decode.SubscriptionType)
		}
	case "status":
		return num(decode.PublicationStatus)
	case "pre_creation_cmd":
		return num(decode.PreCreationCmd)
	case "schema_options":
		v, err := strconv.ParseUint(strings.TrimPrefix(s, "0x"), 16, 64)
		return formatList(decode.SchemaOptionNames(v)), err
	case "commands.insert", "commands.update", "commands.delete":
		return decode.ParseCommand(s).String(), nil
	case "destination.schema", "destination.name":
		if s == "null" {
			return "", nil
		}
		return s, nil
	case "columns", "articles":
		// <rows of the article or subscription>/<columns or articles>: all
		// of them is the omitted list (R30).
		a, b, ok := strings.Cut(s, "/")
		if !ok || a != b {
			return "", fmt.Errorf("want n/n")
		}
		return "[]", nil
	case "filter.procedure", "filter.procedure.schema":
		if s != "0" {
			return "", fmt.Errorf("want 0, no filter procedure")
		}
		return "", nil
	case "sync_object":
		if s != "syncobj_0x<hex>" {
			return "", fmt.Errorf("want the generated view")
		}
		return "", nil
	case "insert_column_names":
		return num(func(n int) string { return strconv.FormatBool(n&decode.ArticleStatusInsertColumnNames != 0) })
	case "parameterized":
		return num(func(n int) string { return strconv.FormatBool(n&decode.ArticleStatusParameterized != 0) })
	case "initialization":
		var st, nst int
		if _, err := fmt.Sscanf(s, "sync_type=%d nosync_type=%d", &st, &nst); err != nil {
			return "", err
		}
		return decode.Initialization(st, nst), nil
	case "subscriber_type":
		return num(decode.SubscriberType)
	case "distribution_agent.subscription_streams", "pull_agent.subscription_streams", "subscription_streams":
		// The reader reads ISNULL(subscriptionstreams, 0).
		if s == "null" {
			return "0", nil
		}
		return num(strconv.Itoa)
	case "multi_subnet_failover":
		// No provider string: no MultiSubnetFailover=Yes key.
		if s == "null" {
			return "false", nil
		}
	case "admin_link_security":
		// internal/reader linkSettings.
		switch s {
		case "uses_self_credential=1":
			return "windows", nil
		case "uses_self_credential=0 remote_name=distributor_admin":
			return "sql", nil
		}
	}
	return "", fmt.Errorf("no decoder for path %s and value %q", p, s)
}

func TestDefaultsDecodeStored(t *testing.T) {
	rs := results(t)
	type key struct {
		ctx  Context
		path string
	}
	values := map[key]Default{}
	for _, d := range Defaults {
		got, err := decodeStored(d)
		if err != nil {
			t.Errorf("%s %s: %v", d.Row, d.Path, err)
			continue
		}
		want := d.Value
		if d.Context.Object == "article" {
			// The row's source object, from the @source_table row of the
			// same context: dbo.m_t, m_s.m_v.
			file, id := splitRow(t, d.Row)
			ctx, _, _ := strings.Cut(id, ".@")
			src, ok := rs[file][ctx+".@source_table"]
			schema, name, dotted := strings.Cut(src.result, ".")
			if !ok || !dotted {
				t.Errorf("%s: no @source_table row giving schema.name", d.Row)
				continue
			}
			want = Fill(d.Value, schema, name)
		}
		if got != want {
			t.Errorf("%s %s: stored %q decodes to %q, the entry's value gives %q", d.Row, d.Path, d.Stored, got, want)
		}
		k := key{d.Context, d.Path}
		if prev, ok := values[k]; ok && prev.Value != d.Value {
			t.Errorf("%v %s: %s gives %q, %s gives %q", d.Context, d.Path, prev.Row, prev.Value, d.Row, d.Value)
		}
		values[k] = d
	}
}

func TestDefaultsSpecSample(t *testing.T) {
	opts := func(v uint64) string { return formatList(decode.SchemaOptionNames(v)) }
	art := func(pub, method, kind string) Context {
		return Context{Object: "article", PubType: pub, SyncMethod: method, ArticleKind: kind}
	}
	pub := Context{Object: "publication", PubType: "transactional"}
	cases := []struct {
		ctx         Context
		path, value string
	}{
		{art("transactional", "native", "table"), "schema_options", opts(0x30073)},
		{art("transactional", "native", "table"), "commands.insert", "CALL [dbo].[sp_MSins_{schema}{table}]"},
		{art("transactional", "native", "table"), "commands.update", "SCALL [dbo].[sp_MSupd_{schema}{table}]"},
		{art("transactional", "native", "table"), "destination.schema", "{source_schema}"},
		{art("transactional", "native", "table"), "parameterized", "true"},
		{art("transactional", "native", "table"), "insert_column_names", "false"},
		{art("transactional", "native", "table"), "pre_creation_cmd", "drop"},
		{art("transactional", "character", "table"), "commands.insert", "SQL"},
		{art("transactional", "character", "table"), "destination.schema", ""},
		{art("snapshot", "native", "table"), "schema_options", opts(0x30071)},
		{art("snapshot", "native", "table"), "commands.insert", "SQL"},
		{art("snapshot", "native", "table"), "commands.update", "SQL"},
		{art("snapshot", "native", "table"), "commands.delete", "SQL"},
		{art("snapshot", "native", "table"), "destination.schema", "{source_schema}"},
		{art("transactional", "native", "view_schema_only"), "schema_options", "[object_creation]"},
		{pub, "sync_method", "native"},
		{pub, "retention_hours", "336"},
		{pub, "independent_agent", "false"},
		{pub, "immediate_sync", "false"},
		{pub, "allow_push", "true"},
		{pub, "allow_pull", "false"},
		{pub, "replicate_ddl", "true"},
		{pub, "status", "inactive"},
	}
	for _, c := range cases {
		d, ok := Lookup(c.ctx, c.path)
		switch {
		case !ok:
			t.Errorf("%v %s: no default", c.ctx, c.path)
		case d.Value != c.value:
			t.Errorf("%v %s: %q (%s), want %q", c.ctx, c.path, d.Value, d.Row, c.value)
		}
	}
}

func TestDefaultsLookup(t *testing.T) {
	// A schema-only article has no status bit entries a caller could fill
	// (Article.OmittedOK).
	for _, k := range []string{"view_schema_only", "proc_schema_only", "func_schema_only"} {
		for _, path := range []string{"insert_column_names", "parameterized"} {
			if d, ok := Lookup(Context{Object: "article", PubType: "transactional", SyncMethod: "native", ArticleKind: k}, path); ok {
				t.Errorf("%s %s: entry %s", k, path, d.Row)
			}
		}
	}
	anyMethod := Default{Context: Context{Object: "article", PubType: "transactional", ArticleKind: "table"}, Path: "x", Value: "any"}
	chr := Default{Context: Context{Object: "article", PubType: "transactional", SyncMethod: "character", ArticleKind: "table"}, Path: "x", Value: "character"}
	kind := Default{Context: Context{Object: "article", PubType: "transactional"}, Path: "y", Value: "any kind"}
	view := Default{Context: Context{Object: "article", PubType: "transactional", ArticleKind: "view_schema_only"}, Path: "y", Value: "view"}
	// The "" entries come first: the most specific wins, not the first.
	table := []Default{anyMethod, kind, chr, view}
	cases := []struct {
		ctx       Context
		path, val string
		ok        bool
	}{
		{Context{"article", "transactional", "character", "table"}, "x", "character", true},
		{Context{"article", "transactional", "native", "table"}, "x", "any", true},
		{Context{"article", "snapshot", "character", "table"}, "x", "", false},
		{Context{"article", "transactional", "native", "view_schema_only"}, "y", "view", true},
		{Context{"article", "transactional", "native", "table"}, "y", "any kind", true},
		{Context{"publication", "transactional", "", ""}, "x", "", false},
	}
	for _, c := range cases {
		d, ok := lookup(table, c.ctx, c.path)
		if ok != c.ok || d.Value != c.val {
			t.Errorf("lookup(%v, %s) = %q, %v; want %q, %v", c.ctx, c.path, d.Value, ok, c.val, c.ok)
		}
	}
	if d, ok := Lookup(Context{Object: "no_such_object"}, "retention_hours"); ok {
		t.Errorf("Lookup of an unknown context found %s", d.Row)
	}
	if d, ok := Lookup(Context{"article", "transactional", "unknown(9)", "table"}, "commands.insert"); ok {
		t.Errorf("Lookup of an unmeasured sync method found %s", d.Row)
	}
	if d, ok := Lookup(Context{"article", "transactional", "character", "table"}, "commands.insert"); !ok || d.Value != "SQL" {
		t.Errorf("Lookup of character commands.insert = %q, %v; want SQL", d.Value, ok)
	}
}
