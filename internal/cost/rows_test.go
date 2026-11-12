package cost

import (
	"bufio"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

// resultsDir holds the campaign result files the table cites.
const resultsDir = "../../lab/results/2022"

// row is one "R|id|result|detail" line of a result file.
type row struct {
	file, id, result, detail string
}

// loadRows reads every result file, keyed "<file> <id>" as a Cite names it.
func loadRows(t *testing.T) map[string]row {
	t.Helper()
	paths, err := filepath.Glob(filepath.Join(resultsDir, "*.txt"))
	if err != nil || len(paths) == 0 {
		t.Fatalf("no result files in %s: %v", resultsDir, err)
	}
	rows := map[string]row{}
	for _, p := range paths {
		f, err := os.Open(p)
		if err != nil {
			t.Fatal(err)
		}
		file := strings.TrimSuffix(filepath.Base(p), ".txt")
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 1<<20), 1<<20)
		for sc.Scan() {
			parts := strings.SplitN(sc.Text(), "|", 4)
			if len(parts) < 3 || parts[0] != "R" {
				continue
			}
			r := row{file: file, id: parts[1], result: parts[2]}
			if len(parts) == 4 {
				r.detail = parts[3]
			}
			rows[file+" "+r.id] = r
		}
		f.Close()
		if err := sc.Err(); err != nil {
			t.Fatal(err)
		}
	}
	return rows
}

// outcome is what a row says about the call it measured.
type outcome struct {
	kind              string // "flags", "error", or "" when the row has no flag result
	invalidate, reint bool
	err               int
}

var flagRowRE = regexp.MustCompile(`^f00=[^,]+(,f10=[^,]+(,f01=[^,]+,f11=[^,]+)?)?$`)

// combos are the flag combinations from the least to the most.
var combos = []struct {
	cell              string
	invalidate, reint bool
}{{"f00", false, false}, {"f10", true, false}, {"f01", false, true}, {"f11", true, true}}

func errNumber(s string) (int, bool) {
	n, err := strconv.Atoi(s)
	return n, err == nil
}

// rowOutcome reads a row's result. A flag row (f00=..,f10=..,f01=..,f11=..)
// gives the least combination whose cell is ok, or the error of its last
// cell (f11) when none is. A 15-snapshot-scope row gives the combination its
// result names, or that of its change= cell. A bare number is an error.
func rowOutcome(r row) outcome {
	if flagRowRE.MatchString(r.result) {
		cells := map[string]string{}
		var last string
		for _, kv := range strings.Split(r.result, ",") {
			k, v, _ := strings.Cut(kv, "=")
			cells[k] = v
			last = v
		}
		for _, c := range combos {
			if cells[c.cell] == "ok" {
				return outcome{kind: "flags", invalidate: c.invalidate, reint: c.reint}
			}
		}
		n, _ := errNumber(last)
		return outcome{kind: "error", err: n}
	}
	v := r.result
	if r.file == "15-snapshot-scope" {
		for _, part := range strings.Split(v, ",") {
			if cell, ok := strings.CutPrefix(part, "change="); ok {
				v = cell
			}
		}
		if v == "ok" {
			return outcome{kind: "flags"}
		}
		for _, c := range combos {
			if v == c.cell {
				return outcome{kind: "flags", invalidate: c.invalidate, reint: c.reint}
			}
		}
	}
	if n, ok := errNumber(v); ok {
		return outcome{kind: "error", err: n}
	}
	return outcome{}
}

var (
	readyBeforeRE = regexp.MustCompile(`(?:^|[\s(;,])ready_before=(\d)`)
	readyRE       = regexp.MustCompile(`(?:^|[\s(;,])ready=(\d)`)
	immReadyRE    = regexp.MustCompile(`immediate_sync_ready=(\d)`)
)

// rowReady is the ready state a row's detail states before the call:
// ready_before= when present, else ready= or immediate_sync_ready= (R40).
// in_tran:ready= and after:ready= are the state after the call and never
// read.
func rowReady(r row) (ready, stated bool) {
	for _, re := range []*regexp.Regexp{readyBeforeRE, readyRE, immReadyRE} {
		if m := re.FindStringSubmatch(r.detail); m != nil {
			return m[1] == "1", true
		}
	}
	return false, false
}

var (
	artStatusRE = regexp.MustCompile(`(?:^|\s)art_status=(\S+)`)
	subStatusRE = regexp.MustCompile(`(?:^|\s)sub_status=(\S+)`)
	statusRE    = regexp.MustCompile(`(?:^|[\s(])status=([0-9a-z/]+)`)
)

// rowAt2 is whether the rows the reinit condition looks at were at status 2,
// when the row states it. In 05-snapshot-flag, the operated article's row is
// art_status= (n/a when the article does not exist yet), and every row of the
// publication is sub_status= (2, 1 or 1/2): wide reads sub_status=. In
// 09-snapshot-pub and 18-reverse, status= is the one subscription's row
// (none when there is no subscription).
func rowAt2(r row, wide bool) (at2, stated bool) {
	switch r.file {
	case "05-snapshot-flag":
		if wide {
			if m := subStatusRE.FindStringSubmatch(r.detail); m != nil {
				return strings.Contains(m[1], "2"), true
			}
			return false, false
		}
		if m := artStatusRE.FindStringSubmatch(r.detail); m != nil && m[1] != "n/a" {
			return m[1] == "2", true
		}
	case "09-snapshot-pub", "18-reverse":
		if m := statusRE.FindStringSubmatch(r.detail); m != nil {
			return m[1] == "2", true
		}
	}
	return false, false
}

var flagsRE = regexp.MustCompile(`(?:^|[\s;])flags=([^\s;]+)`)

// rowDetailFlags reads the flags= of a row's detail, the flags the
// accepted calls passed: "none", "inv=0,reinit=1", "reinit=1", or per
// procedure "sp_droparticle:inv=1,sp_addarticle:inv=0". A procedure's
// flags are read only when it is proc; unprefixed ones always. stated is
// false when the detail has no flags= or none that applies.
func rowDetailFlags(r row, proc string) (inv, reinit, stated bool) {
	m := flagsRE.FindStringSubmatch(r.detail)
	if m == nil {
		return false, false, false
	}
	if m[1] == "none" {
		return false, false, true
	}
	for _, part := range strings.Split(m[1], ",") {
		if p, kv, ok := strings.Cut(part, ":"); ok {
			if p != proc {
				continue
			}
			part = kv
		}
		k, v, _ := strings.Cut(part, "=")
		switch k {
		case "inv":
			inv, stated = v == "1", true
		case "reinit":
			reinit, stated = v == "1", true
		}
	}
	return inv, reinit, stated
}

// hasErrorCell reports a compound result one of whose cells is an error
// number ("m_t7:14100,all:ok").
func hasErrorCell(result string) bool {
	for _, part := range strings.Split(result, ",") {
		if i := strings.LastIndexAny(part, ":="); i >= 0 {
			part = part[i+1:]
		}
		if _, ok := errNumber(part); ok {
			return true
		}
	}
	return false
}

// rowLabel is the text naming the call of a row, when the row has one: the
// detail of a matrix row ("SalesPub publication retention = 100 ..."), or the
// id of a 07-changes SUB or DST row and of an 08-pull P2 row, which ends with
// the property.
func rowLabel(r row) string {
	switch r.file {
	case "02-matrix", "09-snapshot-pub", "18-reverse":
		return r.detail
	case "07-changes":
		if strings.HasPrefix(r.id, "SUB.") || strings.HasPrefix(r.id, "DST.") {
			return r.id
		}
	case "08-pull":
		if strings.HasPrefix(r.id, "P2.") {
			return r.id
		}
	}
	return ""
}

// readmeNotes are the O<n> lines of the observation table of lab/README.md.
func readmeNotes(t *testing.T) map[string]bool {
	t.Helper()
	b, err := os.ReadFile("../../lab/README.md")
	if err != nil {
		t.Fatal(err)
	}
	notes := map[string]bool{}
	for _, m := range regexp.MustCompile(`(?m)^\| (O\d+) \|`).FindAllStringSubmatch(string(b), -1) {
		notes[m[1]] = true
	}
	return notes
}
