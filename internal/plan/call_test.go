package plan

import (
	"bufio"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"

	"github.com/rudi-bruchez/sqlserver-replication/internal/cost"
	"github.com/rudi-bruchez/sqlserver-replication/internal/decode"
	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
	"github.com/rudi-bruchez/sqlserver-replication/internal/normalize"
)

var str = model.Ptr[string]

func testConfig(pubs ...model.Publication) *model.Config {
	return &model.Config{Version: model.FormatVersion, Publisher: model.Publisher{Server: "S", Database: "D"}, Publications: pubs}
}

func testPub(name string, arts ...model.Article) model.Publication {
	return model.Publication{Name: name, Type: str("transactional"), Status: str("active"), SyncMethod: str("native"), Articles: arts}
}

func testTable(name, schema, table string) model.Article {
	return model.Article{Name: name, Source: model.ObjectName{Schema: schema, Name: table}}
}

func normalized(t *testing.T, c *model.Config) *model.Config {
	t.Helper()
	out, rs := normalize.Normalize(c, nil)
	for _, r := range rs {
		t.Errorf("unexpected refusal %s: %s", r.Path, r.Reason)
	}
	if t.Failed() {
		t.FailNow()
	}
	return out
}

func TestEncodersCoverParameters(t *testing.T) {
	seen := map[string]bool{}
	for _, m := range model.Parameters {
		if m.Kind == model.ParamExcluded || m.Since > "2022" {
			continue
		}
		if _, ok := procContexts[m.Procedure]; !ok {
			continue
		}
		key := m.Procedure + "." + m.Parameter
		seen[key] = true
		_, enc := encoders[key]
		reason, never := neverPassed[key]
		switch {
		case enc && never:
			t.Errorf("%s has both an encoder and a never-passed reason", key)
		case !enc && !never:
			t.Errorf("%s (%s) has no encoder and no never-passed reason", key, m.Kind)
		case never && reason == "":
			t.Errorf("%s: empty never-passed reason", key)
		}
	}
	// No stale entry: every key names a mapped parameter of a known procedure.
	for _, set := range []map[string]bool{keysOf(encoders), keysOf(neverPassed), keysOf(fromIdentity)} {
		for k := range set {
			if !seen[k] {
				t.Errorf("%s names no field or creation_only parameter of model.Parameters", k)
			}
		}
	}
	for k := range fromIdentity {
		if _, ok := encoders[k]; !ok {
			t.Errorf("%s is supplied by the caller but has no encoder", k)
		}
	}
}

func keysOf[V any](m map[string]V) map[string]bool {
	out := map[string]bool{}
	for k := range m {
		out[k] = true
	}
	return out
}

// resultRows reads every R| line of the 2022 result files, keyed
// "<file> <id>", with its result field.
func resultRows(t *testing.T) (map[string]string, map[string]bool) {
	t.Helper()
	paths, err := filepath.Glob("../../lab/results/2022/*.txt")
	if err != nil || len(paths) == 0 {
		t.Fatalf("no result files: %v", err)
	}
	rows, files := map[string]string{}, map[string]bool{}
	for _, p := range paths {
		file := strings.TrimSuffix(filepath.Base(p), ".txt")
		files[file] = true
		f, err := os.Open(p)
		if err != nil {
			t.Fatal(err)
		}
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 1<<20), 1<<20)
		for sc.Scan() {
			parts := strings.SplitN(sc.Text(), "|", 4)
			if len(parts) >= 3 && parts[0] == "R" {
				rows[file+" "+parts[1]] = parts[2]
			}
		}
		f.Close()
	}
	return rows, files
}

func readmeNotes(t *testing.T) map[string]bool {
	t.Helper()
	b, err := os.ReadFile("../../lab/README.md")
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]bool{}
	for _, m := range regexp.MustCompile(`(?m)^\| (O[0-9]+) \|`).FindAllStringSubmatch(string(b), -1) {
		out[m[1]] = true
	}
	return out
}

func TestProcContextsCiteRows(t *testing.T) {
	rows, files := resultRows(t)
	notes := readmeNotes(t)
	roles := map[string]bool{"publisher": true, "distributor": true, "subscriber": true}
	dbs := map[string]bool{"master": true, "publication": true, "distribution": true, "subscription": true, "msdb": true}
	for proc, pc := range procContexts {
		if !roles[pc.Role] || !dbs[pc.Database] {
			t.Errorf("%s: role %q, database %q", proc, pc.Role, pc.Database)
		}
		if pc.Source == "" {
			t.Errorf("%s: no source", proc)
		}
		for _, part := range strings.Split(pc.Source, ", ") {
			file, id, _ := strings.Cut(part, " ")
			switch {
			case file == "note":
				if !notes[id] {
					t.Errorf("%s: note %s is not an O<n> line of lab/README.md", proc, id)
				}
			case !files[file]:
				t.Errorf("%s: %q names no results file", proc, part)
			case strings.HasPrefix(id, "X."):
				if r, ok := rows[file+" "+id]; !ok || r != "ok" {
					t.Errorf("%s: %q: result %q, want ok", proc, part, r)
				}
			case strings.HasSuffix(id, "*"):
				prefix := file + " " + strings.TrimSuffix(id, "*")
				found := false
				for k := range rows {
					found = found || strings.HasPrefix(k, prefix)
				}
				if !found {
					t.Errorf("%s: %q matches no row", proc, part)
				}
			case id != "":
				if _, ok := rows[file+" "+id]; !ok {
					t.Errorf("%s: %q is not a row", proc, part)
				}
			}
		}
	}
}

func TestLiteralQuoting(t *testing.T) {
	if got := literal("a'b"); got != "N'a''b'" {
		t.Errorf("literal(a'b) = %s", got)
	}
}

func TestEncodeValues(t *testing.T) {
	cmdOf := func(mode, schema, name string) *model.Command {
		return &model.Command{Mode: mode, Procedure: &model.ObjectName{Schema: schema, Name: name}}
	}
	names := func(v uint64) *[]string { n := decode.SchemaOptionNames(v); return &n }
	creation := []struct {
		key  string
		v    any
		want string
	}{
		{"sp_addpublication.@immediate_sync", model.Ptr(true), "N'true'"},
		{"sp_addpublication.@allow_pull", model.Ptr(false), "N'false'"},
		{"sp_addpublication.@sync_method", str("database_snapshot"), "N'database snapshot'"},
		{"sp_addpublication.@sync_method", str("database_snapshot_character"), "N'database snapshot character'"},
		{"sp_addpublication.@sync_method", str("concurrent_c"), "N'concurrent_c'"},
		{"sp_addpublication.@repl_freq", str("transactional"), "N'continuous'"},
		{"sp_addpublication.@retention", model.Ptr(100), "100"},
		{"sp_addarticle.@type", str("proc_schema_only"), "N'proc schema only'"},
		{"sp_addarticle.@type", str("logbased_manualfilter"), "N'logbased manualfilter'"},
		{"sp_addarticle.@schema_option", names(0x30073), "0x0000000000030073"},
		{"sp_addarticle.@status", []any{model.Ptr(true), model.Ptr(true)}, "24"},
		{"sp_addarticle.@status", []any{model.Ptr(false), model.Ptr(true)}, "16"},
		{"sp_addarticle.@ins_cmd", cmdOf("CALL", "dbo", "p"), "N'CALL [dbo].[p]'"},
		{"sp_addsubscription.@sync_type", str("snapshot"), "N'automatic'"},
		{"sp_addsubscription.@sync_type", str("replication_support_only"), "N'replication support only'"},
		{"sp_addsubscription.@sync_type", str("backup"), "N'initialize with backup'"},
		{"sp_addpushsubscription_agent.@subscriber_security_mode", str("sql"), "0"},
		{"sp_addpushsubscription_agent.@subscriber_security_mode", str("windows"), "1"},
		{"sp_addpublication_snapshot.@frequency_type", "daily", "4"},
		{"sp_addarticle.@description", str("a'b"), "N'a''b'"},
		{"sp_addarticle.@description", str(""), "NULL"},
	}
	for _, c := range creation {
		enc, ok := encoders[c.key]
		if !ok {
			t.Errorf("%s: no encoder", c.key)
			continue
		}
		got, err := enc(c.v)
		if err != nil || got != c.want {
			t.Errorf("%s(%v) = %s, %v; want %s", c.key, shown(c.v), got, err, c.want)
		}
	}

	// Change calls (R39): each literal is the one the campaign script used
	// for the row the cost table cites, 02-matrix.sql @pubprops and
	// @artprops unless noted. A command is rendered schema-qualified by
	// decode.Command.String, the stored form 11-defaults shows, not the
	// script's unqualified text.
	change := []struct {
		proc, prop string
		v          any
		want       string
	}{
		{"sp_changepublication", "description", str("changed"), "N'changed'"},
		{"sp_changepublication", "retention", model.Ptr(100), "N'100'"},
		{"sp_changepublication", "replicate_ddl", model.Ptr(false), "N'0'"},
		{"sp_changepublication", "allow_pull", model.Ptr(false), "N'false'"},
		{"sp_changepublication", "allow_push", model.Ptr(false), "N'false'"},
		{"sp_changepublication", "allow_initialize_from_backup", model.Ptr(true), "N'true'"},
		{"sp_changepublication", "allow_subscription_copy", model.Ptr(true), "N'true'"},
		{"sp_changepublication", "allow_partition_switch", model.Ptr(true), "N'true'"},
		{"sp_changepublication", "replicate_partition_switch", model.Ptr(true), "N'true'"},
		{"sp_changepublication", "allow_drop", model.Ptr(true), "N'true'"},
		{"sp_changepublication", "status", str("inactive"), "N'inactive'"},
		{"sp_changepublication", "sync_method", str("database_snapshot"), "N'database snapshot'"}, // 09-snapshot-pub-matrix.sql
		{"sp_changepublication", "immediate_sync", model.Ptr(false), "N'false'"},
		{"sp_changepublication", "independent_agent", model.Ptr(true), "N'true'"},
		{"sp_changepublication", "allow_anonymous", model.Ptr(true), "N'true'"},
		{"sp_changepublication", "alt_snapshot_folder", str("/var/opt/mssql/data/ReplAlt"), "N'/var/opt/mssql/data/ReplAlt'"},
		{"sp_changepublication", "snapshot_in_defaultfolder", model.Ptr(false), "N'false'"},
		{"sp_changepublication", "pre_snapshot_script", str("/var/opt/mssql/data/pre.sql"), "N'/var/opt/mssql/data/pre.sql'"},
		{"sp_changepublication", "post_snapshot_script", str("/var/opt/mssql/data/post.sql"), "N'/var/opt/mssql/data/post.sql'"},
		{"sp_changepublication", "ftp_address", str("ftp.example.com"), "N'ftp.example.com'"},
		{"sp_changearticle", "description", str("changed"), "N'changed'"},
		{"sp_changearticle", "dest_table", str("Orders2"), "N'Orders2'"},
		{"sp_changearticle", "destination_owner", str("other"), "N'other'"},
		{"sp_changearticle", "ins_cmd", cmdOf("CALL", "dbo", "sp_MSins_dboOrders"), "N'CALL [dbo].[sp_MSins_dboOrders]'"},
		{"sp_changearticle", "upd_cmd", cmdOf("MCALL", "dbo", "sp_MSupd_dboOrders"), "N'MCALL [dbo].[sp_MSupd_dboOrders]'"},
		{"sp_changearticle", "del_cmd", &model.Command{Mode: "NONE"}, "N'NONE'"},
		{"sp_changearticle", "pre_creation_cmd", str("delete"), "N'delete'"},
		{"sp_changearticle", "schema_option", names(0x803509F), "N'0x000000000803509F'"},
		{"sp_changearticle", "status", "include column names", "N'include column names'"},
		{"sp_changearticle", "creation_script", str("/var/opt/mssql/data/create.sql"), "N'/var/opt/mssql/data/create.sql'"},
		{"sp_changearticle", "fire_triggers_on_snapshot", model.Ptr(true), "N'true'"},
		{"sp_changearticle", "sync_object", &model.ObjectName{Schema: "dbo", Name: "vCustomerFR"}, "N'vCustomerFR'"},
		{"sp_changearticle", "type", str("logbased_manualfilter"), "N'logbased manualfilter'"},
		{"sp_changedistributiondb", "max_distretention", model.Ptr(96), "N'96'"}, // 07-changes.sh db helper
		{"sp_changedistpublisher", "security_mode", str("sql"), "N'0'"},          // 07-changes.sh dp helper
	}
	covered := map[[2]string]bool{}
	for _, c := range change {
		k := [2]string{c.proc, c.prop}
		covered[k] = true
		enc, ok := valueEncoders[k]
		if !ok {
			t.Errorf("%s %s: no value encoder", c.proc, c.prop)
			continue
		}
		got, err := enc(c.v)
		if err != nil || got != c.want {
			t.Errorf("%s %s(%v) = %s, %v; want %s", c.proc, c.prop, shown(c.v), got, err, c.want)
		}
	}
	// Every property the cost table names for a procedure of R39 has a
	// value encoder; those of sp_changepublication and sp_changearticle
	// have a case above.
	r39 := map[string]bool{"sp_changepublication": true, "sp_changearticle": true, "sp_changesubscription": true,
		"sp_changedistributiondb": true, "sp_changedistpublisher": true, "sp_change_subscription_properties": true}
	var missing []string
	for _, e := range cost.Table {
		k := [2]string{e.Procedure, e.Property}
		if !r39[e.Procedure] {
			continue
		}
		if _, ok := valueEncoders[k]; !ok {
			missing = append(missing, "no value encoder for "+e.Procedure+" "+e.Property)
		}
		if (e.Procedure == "sp_changepublication" || e.Procedure == "sp_changearticle") && !covered[k] {
			missing = append(missing, "no case for "+e.Procedure+" "+e.Property)
		}
	}
	sort.Strings(missing)
	for i, m := range missing {
		if i == 0 || m != missing[i-1] {
			t.Error(m)
		}
	}
}

func TestCreationCallPassesOnlyNonDefaults(t *testing.T) {
	p := testPub("P", testTable("A", "dbo", "T"))
	p.RetentionHours = model.Ptr(100)
	p.ImmediateSync = model.Ptr(true)
	p.IndependentAgent = model.Ptr(true)
	c := normalized(t, testConfig(p))
	pub := &c.Publications[0]
	ctx := normalize.Context{Object: "publication", PubType: "transactional", SyncMethod: "native"}
	call, err := creationCall("sp_addpublication", pub, ctx, []Param{{Name: "@publication", Value: literal("P")}})
	if err != nil {
		t.Fatal(err)
	}
	want := []Param{
		{Name: "@publication", Value: "N'P'"},
		{Name: "@status", Value: "N'active'"},
		{Name: "@independent_agent", Value: "N'true'"},
		{Name: "@immediate_sync", Value: "N'true'"},
		{Name: "@retention", Value: "100"},
	}
	if call.Procedure != "sp_addpublication" || len(call.Params) != len(want) {
		t.Fatalf("got %s %v, want %v", call.Procedure, call.Params, want)
	}
	for i := range want {
		if call.Params[i] != want[i] {
			t.Errorf("param %d: %v, want %v", i, call.Params[i], want[i])
		}
	}
}

func TestNeverPassedCreation(t *testing.T) {
	a := testTable("A", "dbo", "T")
	a.Filter = &model.Filter{Clause: "id > 0", Procedure: &model.ObjectName{Schema: "dbo", Name: "FLTR_A"}}
	a.Columns = []string{"id"}
	c := normalized(t, testConfig(testPub("P", a)))
	art := &c.Publications[0].Articles[0]
	ctx := normalize.Context{Object: "article", PubType: "transactional", SyncMethod: "native", ArticleKind: "table"}
	call, err := creationCall("sp_addarticle", art, ctx, []Param{{Name: "@publication", Value: literal("P")}, {Name: "@article", Value: literal("A")}})
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]string{}
	for _, p := range call.Params {
		got[p.Name] = p.Value
	}
	for _, name := range []string{"@filter", "@filter_owner", "@vertical_partition", "@sync_object", "@sync_object_owner", "@source_table"} {
		if v, ok := got[name]; ok {
			t.Errorf("%s passed (%s)", name, v)
		}
	}
	for name, want := range map[string]string{"@source_owner": "N'dbo'", "@source_object": "N'T'", "@filter_clause": "N'id > 0'"} {
		if got[name] != want {
			t.Errorf("%s = %q, want %s (params %v)", name, got[name], want, call.Params)
		}
	}
}

// shown dereferences v for a failure message.
func shown(v any) any {
	if x, ok := value(v); ok {
		return x
	}
	return v
}
