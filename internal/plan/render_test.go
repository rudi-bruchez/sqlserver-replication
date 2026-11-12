package plan

import (
	"bytes"
	"encoding/json"
	"flag"
	"os"
	"reflect"
	"strings"
	"testing"

	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
)

var update = flag.Bool("update", false, "rewrite the golden files of the renderings")

// orderStepsPlan is the plan of TestBuildOrderSteps's file.
func orderStepsPlan(t *testing.T) *Plan {
	t.Helper()
	p := buildFull(t, nil, nil, orderStepsEdit(t))
	withJobs(t, p)
	return p
}

// golden compares got with the file, or rewrites it under -update.
func golden(t *testing.T, path, got string) {
	t.Helper()
	if *update {
		if err := os.WriteFile(path, []byte(got), 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if got != string(want) {
		gl, wl := strings.Split(got, "\n"), strings.Split(string(want), "\n")
		for i := 0; i < len(gl) || i < len(wl); i++ {
			var g, w string
			if i < len(gl) {
				g = gl[i]
			}
			if i < len(wl) {
				w = wl[i]
			}
			if g != w {
				t.Fatalf("%s differs at line %d:\n got  %q\n want %q", path, i+1, g, w)
			}
		}
	}
}

func TestRenderSQLGolden(t *testing.T) {
	golden(t, "testdata/create.sql", orderStepsPlan(t).SQL())
}

// A plan with a generate_and_wait says, under sqlHeader, to wait for the
// deliveries before the operations after it (minor 15 of the final
// review); one without says nothing of it.
func TestRenderSQLWaitHeader(t *testing.T) {
	p := buildLabWith(t, deferOpt, func(des, cur *model.Config) { deferPub(t, des, cur, "native") })
	planned(t, p)
	if lines := strings.SplitN(p.SQL(), "\n", 3); len(lines) < 2 || lines[0] != sqlHeader || lines[1] != waitHeader {
		t.Errorf("the deferral's SQL does not start with sqlHeader and waitHeader:\n%s", p.SQL())
	}
	if strings.Contains(orderStepsPlan(t).SQL(), waitHeader) {
		t.Errorf("a plan without generate_and_wait has the waitHeader")
	}
}

func TestSummaryGolden(t *testing.T) {
	golden(t, "testdata/create.txt", orderStepsPlan(t).Summary())
}

func TestRenderSecretsNeverValues(t *testing.T) {
	const value = "p4ss!"
	t.Setenv("SQLREPL_SQL_S_U", value)
	des, facts := loadLab(t)
	cur, _ := loadLab(t)
	s := newSub("m_sdb", "push", "snapshot")
	s.DistributionAgent = &model.DistributionAgent{Agent: model.Agent{Connection: &model.Connection{Security: str("sql"),
		Login: str("u"), PasswordSecret: str("SQLREPL_SQL_S_U")}}}
	addSub(t, des, "SalesPub", s)
	p := Build(Inputs{Desired: des, Current: cur, Facts: facts, SecretSet: func(string) bool { return true }}, Options{})
	withJobs(t, p)
	js, err := p.JSON()
	if err != nil {
		t.Fatal(err)
	}
	sql := p.SQL()
	for _, out := range []struct{ name, text string }{{"SQL", sql}, {"Summary", p.Summary()}, {"JSON", string(js)}} {
		// The offset only: the message must not print the value.
		if i := strings.Index(out.text, value); i >= 0 {
			t.Errorf("%s() holds the secret's value at offset %d", out.name, i)
		}
	}
	for _, want := range []string{"@subscriber_password = @secret_1", "-- @secret_1: secret SQLREPL_SQL_S_U"} {
		if !strings.Contains(sql, want) {
			t.Errorf("SQL() lacks %q", want)
		}
	}
}

func TestRenderQuotesNames(t *testing.T) {
	p := buildFull(t, nil, nil, func(des, _ *model.Config) {
		// The server refuses [ and ] in publication and article names
		// (15006, normalize refuses them), not in a subscription database
		// name. The second article's table has a ] in its name, which the
		// default commands double (normalize.Fill).
		pub := testPub("a'b é", testTable("x y'é", "dbo", "m_t"), testTable("m_a", "dbo", "x]y"))
		pub.IndependentAgent = model.Ptr(true) // a pull subscription needs it (R21)
		pub.Subscriptions = []model.Subscription{newSub("m sub]1", "pull", "snapshot")}
		des.Publications = append(des.Publications, pub)
	})
	withJobs(t, p)
	sql := p.SQL()
	for _, want := range []string{"@publication = N'a''b é'", "@article = N'x y''é'", "@source_object = N'x]y'", "USE [m sub]]1];"} {
		if !strings.Contains(sql, want) {
			t.Errorf("SQL() lacks %s:\n%s", want, sql)
		}
	}
}

// exportedOnly clears what JSON does not carry: Order and the unexported
// fields of the operations.
func exportedOnly(p *Plan) {
	for i := range p.Operations {
		op := &p.Operations[i]
		op.Order, op.entry = "", nil
		op.wideMarkCheck, op.replacesData, op.keepsRows, op.readd, op.namedExtensionCheck = false, false, nil, false, false
		op.leaves, op.delivers = nil, nil
	}
}

func TestPlanJSONRoundTrip(t *testing.T) {
	p := orderStepsPlan(t)
	js, err := p.JSON()
	if err != nil {
		t.Fatal(err)
	}
	var back Plan
	if err := json.Unmarshal(js, &back); err != nil {
		t.Fatal(err)
	}
	exportedOnly(p)
	if !reflect.DeepEqual(&back, p) {
		t.Errorf("the plan read back from JSON differs from the plan:\n%s", js)
	}
	dec := json.NewDecoder(bytes.NewReader(js))
	var keys []string
	if _, err := dec.Token(); err != nil {
		t.Fatal(err)
	}
	for dec.More() {
		k, err := dec.Token()
		if err != nil {
			t.Fatal(err)
		}
		keys = append(keys, k.(string))
		var skip json.RawMessage
		if err := dec.Decode(&skip); err != nil {
			t.Fatal(err)
		}
	}
	want := []string{"publisher", "database", "options", "operations", "refusals", "warnings", "notes", "secrets",
		"preconditions", "agents_to_start", "totals"}
	if !reflect.DeepEqual(keys, want) {
		t.Errorf("top-level keys %v, want %v", keys, want)
	}
}

func TestRenderUseOnlyWhenDatabaseChanges(t *testing.T) {
	op := func(seq int, db string) Operation {
		return Operation{Seq: seq, Kind: "article", Action: "add", Path: "publications[P].articles[a]", Server: "repllab",
			Database: db, Call: Call{Procedure: "sp_addarticle", Params: []Param{{Name: "@publication", Value: literal("P")}}},
			Costs: []Cost{CostOnline}}
	}
	p := &Plan{Publisher: "repllab", Database: "Sales",
		Operations: []Operation{op(1, "Sales"), op(2, "Sales"), op(3, "Sales"), op(4, "master")}}
	sql := p.SQL()
	n := 0
	for _, l := range strings.Split(sql, "\n") {
		if strings.HasPrefix(l, "USE ") {
			n++
		}
	}
	if n != 2 {
		t.Errorf("%d USE lines, want 2:\n%s", n, sql)
	}
	for _, want := range []string{"USE [Sales];", "USE [master];"} {
		if !strings.Contains(sql, want) {
			t.Errorf("SQL() lacks %s:\n%s", want, sql)
		}
	}
	if n := strings.Count(sql, "-- server "); n != 1 {
		t.Errorf("%d server headers, want 1:\n%s", n, sql)
	}
}

// formsPlan is a hand-built plan for the rules of the layouts the plan of
// TestBuildOrderSteps does not exercise: a server change and back, server
// and database names compared without regard to case, a USE when only the
// server changes, an operation warning, line breaks in texts, secrets
// numbered once per plan (one passed twice in one call, one set and one
// not), a trimmed prologue, the order of the totals, and the notes.
func formsPlan() *Plan {
	op := func(seq int, server, db, path string, costs []Cost, params ...Param) Operation {
		return Operation{Seq: seq, Kind: "publication_property", Action: "change", Path: path, Server: server, Database: db,
			Call: Call{Procedure: "sp_changepublication", Params: params}, Costs: costs}
	}
	ops := []Operation{
		op(1, "srvA", "Sales", "publications[P]", []Cost{CostDropAndReadd, CostReinitialization},
			Param{Name: "@publication", Value: "N'P'"}, Param{Name: "@password", Secret: "A"}, Param{Name: "@other", Secret: "A"}),
		op(2, "SRVA", "sales", "publications[P]", []Cost{CostOnline}, Param{Name: "@password", Secret: "B"}),
		op(3, "srvB", "sales", "publications[a\nb]", []Cost{CostOnline}, Param{Name: "@publication", Value: "N'x'"}),
		op(4, "srva", "Sales", "publications[P]", []Cost{CostOnline}, Param{Name: "@b", Secret: "B"}, Param{Name: "@a", Secret: "A"}),
	}
	ops[0].Warnings = []string{"line one\nline two"}
	ops[0].Call.Prologue = "DECLARE @x int;\n\n"
	return &Plan{Publisher: "srvA", Database: "Sales", Operations: ops, Totals: totals(ops),
		Secrets:  []SecretUse{{Name: "A", Set: true, Operations: []int{1, 4}}, {Name: "B", Operations: []int{2, 4}}},
		Warnings: []string{"plan\nwarning"}, Notes: []string{"note one"}}
}

func TestRenderForms(t *testing.T) {
	p := formsPlan()
	wantSQL := sqlHeader + `

-- server srvA
USE [Sales];
-- 1 change publication_property publications[P]: drop_and_readd, reinitialization
-- warning: line one line two
-- @secret_1: secret A
DECLARE @x int;
EXEC sp_changepublication @publication = N'P', @password = @secret_1, @other = @secret_1;

-- 2 change publication_property publications[P]: online
-- @secret_2: secret B
EXEC sp_changepublication @password = @secret_2;

-- server srvB
USE [sales];
-- 3 change publication_property publications[a b]: online
EXEC sp_changepublication @publication = N'x';

-- server srva
USE [Sales];
-- 4 change publication_property publications[P]: online
-- @secret_2: secret B
-- @secret_1: secret A
EXEC sp_changepublication @b = @secret_2, @a = @secret_1;
`
	if got := p.SQL(); got != wantSQL {
		t.Errorf("SQL():\n%s\nwant:\n%s", got, wantSQL)
	}
	wantSummary := `Plan for srvA.Sales: 4 operations, 1 costly.
  1  change publication_property publications[P]: drop_and_readd, reinitialization
      warning: line one line two
  2  change publication_property publications[P]: online
  3  change publication_property publications[a b]: online
  4  change publication_property publications[P]: online
Totals: online 3, reinitialization 1, drop_and_readd 1
Secrets:
  A set
  B not set
Warnings:
  plan warning
Notes:
  note one
`
	if got := p.Summary(); got != wantSummary {
		t.Errorf("Summary():\n%s\nwant:\n%s", got, wantSummary)
	}
	st := p.Statements()
	want := []StatementSecret{{Var: "@secret_2", Name: "B"}, {Var: "@secret_1", Name: "A"}}
	if !reflect.DeepEqual(st[3].Secrets, want) || len(st[0].Secrets) != 1 || len(st[2].Secrets) != 0 {
		t.Errorf("statement secrets %+v, %+v, %+v; want one, none, %+v", st[0].Secrets, st[2].Secrets, st[3].Secrets, want)
	}
}

func TestRenderRefusedForm(t *testing.T) {
	p := &Plan{Publisher: "srvA", Database: "Sales", Refusals: []Refusal{{Path: "publications[P]", Reason: "bad\nreason"},
		{Path: "publications[Q]", Reason: "other"}}, Warnings: []string{"w"}, Notes: []string{"n"}}
	want := "Refused:\n  publications[P]: bad reason\n  publications[Q]: other\nPlan refused.\n"
	if got := p.Summary(); got != want {
		t.Errorf("Summary() %q, want %q", got, want)
	}
	if got := p.SQL(); got != "" {
		t.Errorf("SQL() of a refused plan %q, want empty", got)
	}
}

func TestRenderEmptyForm(t *testing.T) {
	p := &Plan{Publisher: "srvA", Database: "Sales", Notes: []string{"n"}}
	want := "Plan for srvA.Sales: no changes.\nNotes:\n  n\n"
	if got := p.Summary(); got != want {
		t.Errorf("Summary() %q, want %q", got, want)
	}
	if got := p.SQL(); got != "" {
		t.Errorf("SQL() of an empty plan %q, want empty", got)
	}
}
