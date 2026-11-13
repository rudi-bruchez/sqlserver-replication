package apply

import (
	"database/sql"
	"errors"
	"fmt"
	"reflect"
	"strings"
	"testing"

	mssql "github.com/microsoft/go-mssqldb"

	"github.com/rudi-bruchez/sqlserver-replication/internal/plan"
)

// The 22022 wordings measured on the lab (lab/README.md "SQL Server Agent
// stopped", lab/results/2022/16-snapshot-report-sources.txt and
// agent-stopped.txt).
const (
	busyRunning = "SQLServerAgent Error: Request to run job m_job (from User sa) refused because the job is already running from a request by User sa."
	busyPending = "SQLServerAgent Error: Request to run job m_job (from User sa) refused because the job already has a pending request from User sa."
	agentDown   = "SQLServerAgent is not currently running so it cannot be notified of this action."
)

func TestClassify(t *testing.T) {
	cases := []struct {
		name   string
		err    error
		class  class
		number int
	}{
		{"busy running", mssql.Error{Number: 22022, Class: 16, Message: busyRunning}, classBusy, 22022},
		{"busy pending", mssql.Error{Number: 22022, Class: 16, Message: busyPending}, classBusy, 22022},
		{"agent stopped", mssql.Error{Number: 22022, Class: 16, Message: agentDown}, classAgentStopped, 22022},
		{"generating 21854", mssql.Error{Number: 21854, Class: 16, Message: "m"}, classGenerating, 21854},
		{"generating 21861", mssql.Error{Number: 21861, Class: 16, Message: "m"}, classGenerating, 21861},
		{"log reader", mssql.Error{Number: 18752, Class: 16, Message: "m"}, classLogReader, 18752},
		{"deadlock", mssql.Error{Number: 1205, Class: 13, Message: "m"}, classDeadlock, 1205},
		{"245", mssql.Error{Number: 245, Class: 16, Message: "Conversion failed"}, classOther, 245},
		{"wrapped busy", errors.Join(errors.New("op 3"), mssql.Error{Number: 22022, Class: 16, Message: busyRunning}), classBusy, 22022},
		{"not a driver error", errors.New("bad connection"), classOther, 0},
		{"fmt wrapped 18752", fmt.Errorf("op 2: %w", mssql.Error{Number: 18752, Class: 16, Message: "m"}), classLogReader, 18752},
		{"unknown 22022 wording", mssql.Error{Number: 22022, Class: 16, Message: "SQLServerAgent Error: something else"}, classOther, 22022},
		// Through sp_executesql the server adds 266 after the real error
		// (Task 6 review P1a, P1c): the first entry that is not 266 counts.
		{"50000 then 266", with266(50000, "m"), classOther, 50000},
		{"21854 then 266", with266(21854, "m"), classGenerating, 21854},
		{"266 alone", mssql.Error{Number: 266, Class: 16, Message: "Transaction count after EXECUTE", All: []mssql.Error{{Number: 266, Class: 16}}}, classOther, 266},
	}
	for _, c := range cases {
		gotClass, gotNumber := classify(c.err)
		if gotClass != c.class || gotNumber != c.number {
			t.Errorf("%s: classify = (%d, %d), want (%d, %d)", c.name, gotClass, gotNumber, c.class, c.number)
		}
	}
}

// with266 is the error go-mssqldb returns for a refusal inside
// sp_executesql that leaves a transaction: the real error, then 266, which
// is also the error's Number and Message.
func with266(number int32, message string) mssql.Error {
	const m266 = "Transaction count after EXECUTE indicates a mismatching number of BEGIN and COMMIT statements."
	return mssql.Error{Number: 266, Class: 16, Message: m266, All: []mssql.Error{
		{Number: number, Class: 16, Message: message},
		{Number: 266, Class: 16, Message: m266},
	}}
}

func TestRetryDecision(t *testing.T) {
	cases := []struct {
		invalidate, ready, want bool
	}{
		{false, false, true},
		{false, true, false},
		{true, false, true},
		{true, true, true},
	}
	for _, c := range cases {
		if got := retryDecision(c.invalidate, c.ready); got != c.want {
			t.Errorf("retryDecision(%t, %t) = %t, want %t", c.invalidate, c.ready, got, c.want)
		}
	}
}

func op(procedure string, params ...plan.Param) plan.Operation {
	return plan.Operation{Server: "PUB", Database: "m_db", Call: plan.Call{Procedure: procedure, Params: params}}
}

func prm(name, value string) plan.Param { return plan.Param{Name: name, Value: value} }

func TestEffectQueryCovers(t *testing.T) {
	covered := map[string]plan.Operation{
		"sp_droppublication": op("sp_droppublication", prm("@publication", "N'm_p'")),
		"sp_replicationdboption false": op("sp_replicationdboption",
			prm("@dbname", "N'm_db'"), prm("@optname", "N'publish'"), prm("@value", "N'false'")),
		"sp_changepublication sync_method": op("sp_changepublication",
			prm("@publication", "N'm_p'"), prm("@property", "N'sync_method'"), prm("@value", "N'database snapshot'"),
			prm("@force_reinit_subscription", "1")),
		"sp_articlefilter reinit": op("sp_articlefilter",
			prm("@publication", "N'm_p'"), prm("@article", "N'm_a'"), prm("@filter_name", "N'[dbo].[m_f]'"),
			prm("@filter_clause", "N'[id] > 10'"), prm("@force_reinit_subscription", "1")),
		"sp_articlefilter reinit NULL": op("sp_articlefilter",
			prm("@publication", "N'm_p'"), prm("@article", "N'm_a'"),
			prm("@filter_clause", "NULL"), prm("@force_reinit_subscription", "1")),
	}
	for name, o := range covered {
		q, args, ok := effectQuery(o)
		if !ok || q == "" {
			t.Errorf("%s: no re-read", name)
			continue
		}
		if !strings.HasPrefix(q, "SELECT ") {
			t.Errorf("%s: the re-read is not a SELECT: %s", name, q)
		}
		if len(args) == 0 {
			t.Errorf("%s: the re-read binds nothing", name)
		}
	}
	// The values the re-reads compare, decoded from the call's literals.
	if _, args, _ := effectQuery(covered["sp_changepublication sync_method"]); !hasNamed(args, "sync_method", 5) || !hasNamed(args, "publication", "m_p") {
		t.Errorf("sync_method re-read args = %v, want the code 5 of database snapshot and m_p", args)
	}
	if _, args, _ := effectQuery(covered["sp_articlefilter reinit"]); !hasNamed(args, "filter_clause", "[id] > 10") || !hasNamed(args, "article", "m_a") {
		t.Errorf("articlefilter re-read args = %v", args)
	}
	empty := op("sp_articlefilter", prm("@publication", "N'm_p'"), prm("@article", "N'm_a'"),
		prm("@filter_clause", "N''"), prm("@force_reinit_subscription", "1"))
	if q, _, ok := effectQuery(empty); !ok || !strings.Contains(q, "filter_clause IS NULL") {
		t.Errorf("N'' clause re-read = %s, want the NULL re-read", q)
	}
	if q, _, _ := effectQuery(covered["sp_articlefilter reinit"]); !strings.Contains(q, "COLLATE Latin1_General_BIN2 = @filter_clause COLLATE Latin1_General_BIN2") {
		t.Errorf("the clause re-read does not compare in binary: %s", q)
	}
	if q, args, _ := effectQuery(covered["sp_articlefilter reinit NULL"]); !strings.Contains(q, "filter_clause IS NULL") || hasName(args, "filter_clause") {
		t.Errorf("NULL clause re-read = %s %v, want filter_clause IS NULL and no clause bound", q, args)
	}

	none := map[string]plan.Operation{
		"sp_droparticle":      op("sp_droparticle", prm("@publication", "N'm_p'"), prm("@article", "N'm_a'")),
		"sp_dropsubscription": op("sp_dropsubscription", prm("@publication", "N'm_p'"), prm("@article", "N'all'"), prm("@subscriber", "N'S'")),
		"sp_addarticle":       op("sp_addarticle", prm("@publication", "N'm_p'"), prm("@article", "N'm_a'")),
		"sp_articlefilter without reinit": op("sp_articlefilter",
			prm("@publication", "N'm_p'"), prm("@article", "N'm_a'"), prm("@filter_clause", "N'[id] > 10'")),
		"sp_changepublication retention": op("sp_changepublication",
			prm("@publication", "N'm_p'"), prm("@property", "N'retention'"), prm("@value", "N'0'")),
		"sp_replicationdboption true": op("sp_replicationdboption",
			prm("@dbname", "N'm_db'"), prm("@optname", "N'publish'"), prm("@value", "N'true'")),
	}
	for name, o := range none {
		if q, _, ok := effectQuery(o); ok {
			t.Errorf("%s: unexpected re-read %s", name, q)
		}
	}
}

func hasName(args []any, name string) bool {
	for _, a := range args {
		if n, ok := a.(sql.NamedArg); ok && n.Name == name {
			return true
		}
	}
	return false
}

func hasNamed(args []any, name string, value any) bool {
	for _, a := range args {
		if n, ok := a.(sql.NamedArg); ok && n.Name == name {
			return reflect.DeepEqual(n.Value, value)
		}
	}
	return false
}

func TestMaskSecrets(t *testing.T) {
	const secret = "s3cr3t-value"
	msg := "Conversion failed when converting the varchar value '" + secret + "' to data type int. (" + secret + ")"
	got := mask(msg, []string{secret})
	if strings.Contains(got, secret) {
		t.Fatalf("mask left a secret value in the message (%d occurrences)", strings.Count(got, secret))
	}
	if want := "Conversion failed when converting the varchar value '****' to data type int. (****)"; got != want {
		t.Errorf("mask = %q, want %q", got, want)
	}
	plain := "Conversion failed when converting the varchar value 'abc' to data type int."
	if got := mask(plain, []string{secret}); got != plain {
		t.Errorf("mask changed a message without the value: %q", got)
	}
	if got := mask("pw=abcdef and abc", []string{"abc", "abcdef"}); got != "pw=**** and ****" {
		t.Errorf("mask of a value inside another = %q", got)
	}
	if got := mask(plain, []string{""}); got != plain {
		t.Errorf("mask with an empty value changed the message: %q", got)
	}
}

func TestSecretArgs(t *testing.T) {
	values := map[string]string{"SQLREPL_SQL_X": "x-value", "SQLREPL_SQL_Y": "y-value"}
	lookup := func(name string) (string, bool) { v, ok := values[name]; return v, ok }
	st := plan.Statement{Seq: 1, Text: "EXEC sp_x @password = @secret_1;", Secrets: []plan.StatementSecret{{Var: "@secret_1", Name: "SQLREPL_SQL_X"}}}
	args, err := secretArgs(st, lookup)
	if err != nil {
		t.Fatalf("secretArgs: %v", err)
	}
	if want := []any{sql.Named("secret_1", "x-value")}; !reflect.DeepEqual(args, want) {
		t.Errorf("secretArgs gave a different binding (count %d)", len(args))
	}

	others := map[string]string{"SQLREPL_SQL_Y": "y-value", "SQLREPL_SQL_Z": "z-value"}
	_, err = secretArgs(st, func(name string) (string, bool) { v, ok := others[name]; return v, ok })
	if err == nil {
		t.Fatal("secretArgs accepted a secret the function does not return")
	}
	if !strings.Contains(err.Error(), "SQLREPL_SQL_X") {
		t.Errorf("the error does not name SQLREPL_SQL_X: %q", err)
	}
	for name, v := range others {
		if strings.Contains(err.Error(), v) {
			t.Errorf("the error contains the value of %s", name)
		}
	}
}
