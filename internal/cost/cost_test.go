package cost

import (
	"fmt"
	"strings"
	"testing"
)

func entryKey(e Entry) string { return fmt.Sprintf("%s %s %s", e.Change, e.Dir, e.PubType) }

func TestCostTableMatchesRows(t *testing.T) {
	rows := loadRows(t)
	notes := readmeNotes(t)
	for _, e := range Table {
		key := entryKey(e)
		for _, c := range e.Cites {
			r, ok := rows[c.Row]
			if !ok {
				t.Errorf("%s: cited row %s does not exist", key, c.Row)
				continue
			}
			if r.result != c.Expect {
				t.Errorf("%s: %s: result %q, cite expects %q", key, c.Row, r.result, c.Expect)
				continue
			}
			if ready, stated := rowReady(r); stated && ready != c.Ready {
				t.Errorf("%s: %s: the row's ready state is %v, the cite says %v", key, c.Row, ready, c.Ready)
			}
			if l := rowLabel(r); e.Property != "" && l != "" && !strings.Contains(l, e.Property) {
				t.Errorf("%s: %s: the row's label %q does not name the property %q", key, c.Row, l, e.Property)
			}
			o := rowOutcome(r)
			refusal := e.Class == Refused || e.Class == DropReadd
			switch o.kind {
			case "flags":
				if refusal {
					t.Errorf("%s: %s: the row accepts the call, the entry is %s", key, c.Row, e.Class)
					continue
				}
				inv, rei := Flags(e, FlagState{Ready: c.Ready, At2: c.At2})
				if inv != o.invalidate || rei != o.reint {
					t.Errorf("%s: %s: the row needs invalidate=%v reinit=%v, Flags gives invalidate=%v reinit=%v",
						key, c.Row, o.invalidate, o.reint, inv, rei)
				}
			case "error":
				if !refusal || e.Error != o.err {
					t.Errorf("%s: %s: the row is refused with %d, the entry is %s with error %d", key, c.Row, o.err, e.Class, e.Error)
				}
			}
		}
		for _, c := range e.Counter {
			r, ok := rows[c.Row]
			if !ok {
				t.Errorf("%s: counterexample %s does not exist", key, c.Row)
				continue
			}
			if r.result != c.Expect {
				t.Errorf("%s: counterexample %s: result %q, cite expects %q", key, c.Row, r.result, c.Expect)
				continue
			}
			if rowOutcome(r).kind != "error" {
				t.Errorf("%s: counterexample %s is not an error: %q", key, c.Row, r.result)
			}
		}
		for _, n := range e.Notes {
			if !notes[n] {
				t.Errorf("%s: note %s is not an observation of lab/README.md", key, n)
			}
		}
	}
}

func TestFlagsRule(t *testing.T) {
	for _, ready := range []bool{false, true} {
		for _, at2 := range []bool{false, true} {
			s := FlagState{Ready: ready, At2: at2}
			cases := []struct {
				class    Class
				inv, rei bool
			}{
				{Snapshot, ready, false},
				{SnapshotReinit, ready, at2},
				{Online, false, false},
				{DropsReady, false, false},
			}
			for _, c := range cases {
				inv, rei := Flags(Entry{Class: c.class}, s)
				if inv != c.inv || rei != c.rei {
					t.Errorf("Flags(%s, %+v) = (%v, %v), want (%v, %v)", c.class, s, inv, rei, c.inv, c.rei)
				}
			}
		}
	}
}

func TestLookupDirections(t *testing.T) {
	const tr, sn = "transactional", "snapshot"
	for _, d := range []string{"to_true", "to_false"} {
		if _, ok := Lookup("publications[*].replicate_ddl", d, tr); !ok {
			t.Errorf("replicate_ddl %s not found", d)
		}
	}
	if _, ok := Lookup("publications[*].snapshot.ftp.port", "", tr); ok {
		t.Errorf("snapshot.ftp.port found, it was never measured")
	}
	e, ok := Lookup("publications[*].allow_push", "to_false", tr)
	if !ok {
		t.Fatalf("allow_push to_false not found")
	}
	if e.Class == DropReadd {
		t.Errorf("allow_push to_false is %s", e.Class)
	}
	found := false
	for _, c := range e.Counter {
		if c.Row == "02-matrix P09" {
			found = true
		}
	}
	if !found {
		t.Errorf("allow_push to_false does not have 02-matrix P09 among its counterexamples: %+v", e.Counter)
	}
	e, ok = Lookup("publications[*].replicate_ddl", "to_false", sn)
	if !ok {
		t.Errorf("snapshot replicate_ddl to_false not found")
	} else if len(e.Cites) == 0 || e.Cites[0].Row != "09-snapshot-pub SNAP.P03" {
		t.Errorf("snapshot replicate_ddl to_false does not cite SNAP.P03 first: %+v", e.Cites)
	}
	if _, ok := Lookup("publications[*].replicate_ddl", "to_true", sn); ok {
		t.Errorf("snapshot replicate_ddl to_true found, the reverse directions were measured on transactional publications only")
	}
	// A path with indices finds the entry of its pattern.
	if _, ok := Lookup("publications[SalesPub].articles[Orders].description", "set", tr); !ok {
		t.Errorf("an indexed path does not find its pattern's entry")
	}
}

func TestSyncMethodPairs(t *testing.T) {
	const path = "publications[*].sync_method"
	pairs := map[string]bool{ // pair -> concurrent family (wide reinit)
		"native>concurrent": true, "concurrent>native": true, "concurrent_c>native": true,
		"concurrent>concurrent_c": true, "concurrent_c>concurrent": true,
		"native>character": false, "character>native": false, "database_snapshot>native": false,
	}
	for pair, wide := range pairs {
		e, ok := Lookup(path, pair, "transactional")
		if !ok {
			t.Errorf("%s not found", pair)
			continue
		}
		want := Snapshot
		if wide {
			want = SnapshotReinit
		}
		if e.Class != want || e.Wide != wide {
			t.Errorf("%s: class %s wide %v, want %s wide %v", pair, e.Class, e.Wide, want, wide)
		}
	}
	for _, pair := range []string{"native>concurrent_c", "character>concurrent"} {
		if _, ok := Lookup(path, pair, "transactional"); ok {
			t.Errorf("%s found, it was never measured", pair)
		}
	}
	if e, ok := Lookup(path, "native>character", "snapshot"); !ok || e.Class != Snapshot {
		t.Errorf("snapshot native>character: %+v %v", e, ok)
	}
	if e, ok := Lookup(path, "native>concurrent", "snapshot"); !ok || e.Class != Refused || e.Error != 22547 {
		t.Errorf("snapshot native>concurrent: %+v %v, want refused 22547", e, ok)
	}
}

func TestEveryEntryCites(t *testing.T) {
	seen := map[string]bool{}
	for _, e := range Table {
		key := entryKey(e)
		if len(e.Cites) == 0 && len(e.Notes) == 0 {
			t.Errorf("%s: no cite and no note", key)
		}
		if e.PubType != "transactional" && e.PubType != "snapshot" {
			t.Errorf("%s: publication type %q", key, e.PubType)
		}
		if e.Procedure != "" && e.Property == "" {
			t.Errorf("%s: procedure %s without a property", key, e.Procedure)
		}
		if (e.Class == Refused || e.Class == DropReadd) && e.Error == 0 {
			t.Errorf("%s: %s without its error", key, e.Class)
		}
		dirs := []string{e.Dir}
		if e.Dir == "both" {
			dirs = []string{"to_true", "to_false"}
		}
		for _, d := range dirs {
			k := e.Change + " " + d + " " + e.PubType
			if seen[k] {
				t.Errorf("%s: two entries answer the same lookup", k)
			}
			seen[k] = true
		}
	}
}
