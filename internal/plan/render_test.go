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
		// The article is named x]y, its table is not: the default commands
		// are named after the table (normalize, sp_MSins_{schema}{table}).
		pub := testPub("a'b", testTable("x]y", "dbo", "m_t"))
		pub.IndependentAgent = model.Ptr(true) // a pull subscription needs it (R21)
		pub.Subscriptions = []model.Subscription{newSub("m sub]1", "pull", "snapshot")}
		des.Publications = append(des.Publications, pub)
	})
	withJobs(t, p)
	sql := p.SQL()
	for _, want := range []string{"N'a''b'", "N'x]y'", "USE [m sub]]1];"} {
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
