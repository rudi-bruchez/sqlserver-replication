package apply

import (
	"context"
	"database/sql"
	"strings"
	"testing"
	"time"
)

// The unit tests of the deliveries owed (R50). The listings are shaped as
// Task 3's row DL.listing records them and as the lab lists its own
// /var/opt/mssql/data/ReplData: the listed root's children at level 0,
// parent_directory ending with "/", full_filesystem_path without one.

const labRoot = "/var/opt/mssql/data/ReplData"

func dir(parent, name string) fsEntry {
	return fsEntry{FullPath: parent + name, Parent: parent, Name: name, IsDir: true}
}

func file(parent, name string) fsEntry {
	return fsEntry{FullPath: parent + name, Parent: parent, Name: name}
}

// labListing is a listing of labRoot: unc, the folders of m_p (database
// m_pdb_x) and of SalesPub, their runs and their files.
func labListing() []fsEntry {
	unc := labRoot + "/unc/"
	mp := unc + "REPLLAB_M_PDB_X_M_P/"
	sp := unc + "REPLLAB_SALES_SALESPUB/"
	return []fsEntry{
		dir(labRoot+"/", "unc"),
		dir(unc, "REPLLAB_M_PDB_X_M_P"),
		dir(mp, "20261112224217"),
		file(mp+"20261112224217/", "m_t_2.bcp"),
		dir(mp, "20261112224300"),
		dir(unc, "REPLLAB_SALES_SALESPUB"),
		dir(sp, "20261112010800"),
		file(sp+"20261112010800/", "Customer_2.bcp"),
		dir(sp, "20261113004004"),
	}
}

func TestParseDelivered(t *testing.T) {
	cases := []struct {
		comments, folder, run string
		ok                    bool
	}{
		{`Delivered snapshot from the 'unc\REPLLAB_SALES_SALESPUB\20261111162904\' sub-folder in 812 milliseconds`,
			"REPLLAB_SALES_SALESPUB", "20261111162904", true},
		{`Delivered snapshot from the 'unc\REPLLAB_M DB_M PUB\20261112224217\' sub-folder in 128 milliseconds`,
			"REPLLAB_M DB_M PUB", "20261112224217", true}, // O19: a space is kept
		{`Applied the snapshot to the subscriber.`, "", "", false},
		{`Delivered snapshot from the '' sub-folder in 1 milliseconds`, "", "", false},
		{`Delivered snapshot from the 'other\REPLLAB_SALES_SALESPUB\20261111162904\' sub-folder in 812 milliseconds`, "", "", false},
		{`Delivered snapshot from the 'unc\REPLLAB_SALES_SALESPUB\' sub-folder in 812 milliseconds`, "", "", false},
		{``, "", "", false},
	}
	for _, c := range cases {
		folder, run, ok := parseDelivered(c.comments)
		if folder != c.folder || run != c.run || ok != c.ok {
			t.Errorf("parseDelivered(%q) = %q, %q, %v, want %q, %q, %v", c.comments, folder, run, ok, c.folder, c.run, c.ok)
		}
	}
}

func TestAcceptRunFolder(t *testing.T) {
	listed := []string{"20261112224217"}
	cases := []struct {
		name string
		o    owed
		run  string
		want bool
	}{
		{"S7, a run present at T", owed{S7: true, Listing: listed}, "20261112224217", true},
		{"S7, a run absent at T", owed{S7: true, Listing: listed}, "20261112224400", true},
		{"not S7, a run present at T", owed{Listing: listed}, "20261112224217", false},
		{"not S7, a run absent at T", owed{Listing: listed}, "20261112224400", true},
		{"running at T, a run absent at T", owed{RunningAtT: true, Listing: listed}, "20261112224400", false},
		{"running at T, S7", owed{RunningAtT: true, S7: true, Listing: listed}, "20261112224217", false},
	}
	for _, c := range cases {
		if got := acceptRun(c.o, c.run); got != c.want {
			t.Errorf("%s: acceptRun = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestPubFolderIdentified(t *testing.T) {
	unc := labRoot + "/unc/"
	// One directory under <root>/unc named <PUBLISHER>_<DB>_<PUB>, upper-cased
	// as SQL Server writes it, matched without regard to case.
	got, err := pubFolder(labListing(), labRoot, "repllab", "m_pdb_x", "m_p")
	if err != nil || got != unc+"REPLLAB_M_PDB_X_M_P" {
		t.Errorf("one folder: %q, %v", got, err)
	}
	// The root written with a trailing separator, or with backslashes, is
	// the same root.
	for _, root := range []string{labRoot + "/", strings.ReplaceAll(labRoot, "/", `\`)} {
		if got, err := pubFolder(labListing(), root, "REPLLAB", "M_PDB_X", "M_P"); err != nil || got != unc+"REPLLAB_M_PDB_X_M_P" {
			t.Errorf("root %q: %q, %v", root, got, err)
		}
	}
	// The review's case (fix round 1): x_m_db_m_p of m_db has the folder
	// REPLLAB_M_DB_X_M_DB_M_P, which ends with _M_DB_M_P. It is never m_p's,
	// whether m_p's own folder is there or not.
	other := []fsEntry{dir(labRoot+"/", "unc"), dir(unc, "REPLLAB_M_DB_X_M_DB_M_P"), dir(unc+"REPLLAB_M_DB_X_M_DB_M_P/", "20261113005951")}
	if got, err := pubFolder(other, labRoot, "repllab", "m_db", "m_p"); !isNoFolder(err) {
		t.Errorf("m_p beside x_m_db_m_p only: %q, %v, want the no-folder error", got, err)
	}
	both := append(other, dir(unc, "REPLLAB_M_DB_M_P"))
	if got, err := pubFolder(both, labRoot, "repllab", "m_db", "m_p"); err != nil || got != unc+"REPLLAB_M_DB_M_P" {
		t.Errorf("m_p beside x_m_db_m_p: %q, %v", got, err)
	}
	// Two publishers with the same database and publication sharing one
	// root: each finds its own.
	shared := []fsEntry{dir(labRoot+"/", "unc"), dir(unc, "SRVA_SALES_ORDERS"), dir(unc, "SRVB_SALES_ORDERS")}
	for _, srv := range []string{"SrvA", "srvb"} {
		if got, err := pubFolder(shared, labRoot, srv, "Sales", "Orders"); err != nil || got != unc+strings.ToUpper(srv)+"_SALES_ORDERS" {
			t.Errorf("publisher %s on a shared root: %q, %v", srv, got, err)
		}
	}
	// Two directories with that name in different case: not identified.
	two := append(labListing(), dir(unc, "repllab_m_pdb_x_m_p"))
	if _, err := pubFolder(two, labRoot, "repllab", "m_pdb_x", "m_p"); err == nil || err.Error() != "snapshot folder of m_p not identified" {
		t.Errorf("two folders: %v", err)
	}
	// A named instance: its folder form is not measured.
	named := []fsEntry{dir(labRoot+"/", "unc"), dir(unc, "SRV$INST_SALES_ORDERS"), dir(unc, "SRV_INST_SALES_ORDERS")}
	if _, err := pubFolder(named, labRoot, `SRV\INST`, "Sales", "Orders"); err == nil || isNoFolder(err) ||
		err.Error() != "snapshot folder of Orders not identified: the folder form of a named instance is not measured" {
		t.Errorf("named instance: %v", err)
	}
	// A run folder or a file deeper down with that name is ignored.
	deep := []fsEntry{
		dir(labRoot+"/", "unc"),
		dir(unc, "REPLLAB_SALES_SALESPUB"),
		dir(unc+"REPLLAB_SALES_SALESPUB/", "REPLLAB_M_PDB_X_M_P"),
		file(unc+"REPLLAB_SALES_SALESPUB/REPLLAB_M_PDB_X_M_P/", "REPLLAB_M_PDB_X_M_P"),
		dir(labRoot+"/", "REPLLAB_M_PDB_X_M_P"), // beside unc, not under it
		file(unc, "REPLLAB_M_PDB_X_M_P"),        // a file under unc
	}
	deep = append(deep, labListing()...)
	if got, err := pubFolder(deep, labRoot, "repllab", "m_pdb_x", "m_p"); err != nil || got != unc+"REPLLAB_M_PDB_X_M_P" {
		t.Errorf("deeper entries: %q, %v", got, err)
	}
	// None: the publication's folder cannot be listed there.
	if _, err := pubFolder(deep[:6], labRoot, "repllab", "m_pdb_x", "m_p"); err == nil || err.Error() != "snapshot folder of m_p cannot be listed at "+labRoot {
		t.Errorf("none: %v", err)
	}
	if _, err := pubFolder(nil, labRoot, "repllab", "m_pdb_x", "m_p"); !isNoFolder(err) {
		t.Errorf("an empty listing: %v, want the no-folder error", err)
	}
}

func TestRunFolders(t *testing.T) {
	unc := labRoot + "/unc/"
	got := runFolders(labListing(), unc+"REPLLAB_M_PDB_X_M_P")
	if strings.Join(got, ",") != "20261112224217,20261112224300" {
		t.Errorf("runs of m_p: %v", got)
	}
	got = runFolders(labListing(), unc+"REPLLAB_SALES_SALESPUB/")
	if strings.Join(got, ",") != "20261112010800,20261113004004" {
		t.Errorf("runs of SalesPub, folder with a trailing separator: %v", got)
	}
	if got := runFolders(labListing(), unc+"REPLLAB_NONE"); len(got) != 0 {
		t.Errorf("runs of a folder not listed: %v", got)
	}
}

func TestQueriesSubstituted(t *testing.T) {
	for _, db := range []string{"distribution", "m d]2"} {
		for _, servers := range []string{"", fallbackServers} {
			for name, q := range applyQueries() {
				got := distQuery(q, db, servers)
				if strings.Contains(got, "{dist}") || strings.Contains(got, "{servers}") {
					t.Errorf("%s for %q, servers %q keeps a placeholder:\n%s", name, db, servers, got)
				}
				if strings.Contains(q, "{dist}") && !strings.Contains(got, quoteName(db)+".dbo.") {
					t.Errorf("%s for %q does not name %s", name, db, quoteName(db))
				}
				if strings.Contains(q, "{servers}") {
					want := servers
					if want == "" {
						want = quoteName(db) + ".dbo.MSreplservers"
					}
					if !strings.Contains(got, want) {
						t.Errorf("%s for %q does not read the servers from %s", name, db, want)
					}
				}
			}
		}
	}
}

func TestDeliveryResults(t *testing.T) {
	at := time.Date(2026, 11, 12, 22, 43, 43, 853e6, time.UTC)
	mark := []byte{0, 0, 0, 0, 0, 0, 0x10, 0}
	newRec := func(sub string) *record {
		return &record{owed: owed{Publication: "m_p", Subscription: sub, T: at, Mark: mark,
			Folder: "REPLLAB_M_PDB_X_M_P", Listing: []string{"20261112224217"}}, agents: []int{7}}
	}
	tr := &tracker{lines: map[lineKey]line{}}
	confirmed, pending := newRec("SUB/m_sdb_1"), newRec("SUB/m_sdb_2")
	never := newRec("SUB/m_sdb_3")
	never.Folder, never.unlisted = "", "snapshot folder of m_p not identified"
	tr.records = []*record{confirmed, pending, never}
	// A line of agent 7 above the mark, at T, naming a run absent at T.
	tr.keep(line{agent: 7, ts: []byte{0, 0, 0, 0, 0, 0, 0x10, 1}, time: at,
		comments: `Delivered snapshot from the 'unc\REPLLAB_M_PDB_X_M_P\20261112224353\' sub-folder in 107 milliseconds`})
	// Lines that confirm nothing: at the mark, before T, a run listed at T,
	// another publication's folder.
	tr.keep(line{agent: 7, ts: mark, time: at,
		comments: `Delivered snapshot from the 'unc\REPLLAB_M_PDB_X_M_P\20261112224400\' sub-folder in 1 milliseconds`})
	tr.keep(line{agent: 7, ts: []byte{0, 0, 0, 0, 0, 0, 0x10, 2}, time: at.Add(-time.Millisecond),
		comments: `Delivered snapshot from the 'unc\REPLLAB_M_PDB_X_M_P\20261112224401\' sub-folder in 1 milliseconds`})
	tr.keep(line{agent: 7, ts: []byte{0, 0, 0, 0, 0, 0, 0x10, 3}, time: at,
		comments: `Delivered snapshot from the 'unc\REPLLAB_M_PDB_X_M_P\20261112224217\' sub-folder in 1 milliseconds`})
	tr.keep(line{agent: 7, ts: []byte{0, 0, 0, 0, 0, 0, 0x10, 4}, time: at,
		comments: `Delivered snapshot from the 'unc\REPLLAB_SALES_SALESPUB\20261112224402\' sub-folder in 1 milliseconds`})
	pending.agents = []int{8} // its agent wrote nothing
	tr.confirm()
	if confirmed.run != `REPLLAB_M_PDB_X_M_P\20261112224353` {
		t.Fatalf("the record of agent 7 confirmed %q", confirmed.run)
	}
	if p := tr.pending("M_P"); len(p) != 1 || p[0].Subscription != "SUB/m_sdb_2" {
		t.Errorf("pending: %+v", p)
	}
	want := []Delivery{
		{Publication: "m_p", Subscription: "SUB/m_sdb_1", Status: "confirmed", Run: `REPLLAB_M_PDB_X_M_P\20261112224353`},
		{Publication: "m_p", Subscription: "SUB/m_sdb_2", Status: "unconfirmed"},
	}
	// A record whose folder is never identified keeps its reason, with
	// notAwaited too (fix round 1).
	unidentified := Delivery{Publication: "m_p", Subscription: "SUB/m_sdb_3", Status: "unconfirmed", Detail: "snapshot folder of m_p not identified"}
	got := tr.results(false)
	if len(got) != 3 || got[0] != want[0] || got[1].Status != want[1].Status || got[1].Detail == "" || got[2] != unidentified {
		t.Errorf("results(false) = %+v", got)
	}
	got = tr.results(true)
	if len(got) != 3 || got[0] != want[0] || got[1].Status != "not_awaited" || got[1].Run != "" || got[2] != unidentified {
		t.Errorf("results(true) = %+v", got)
	}
}

// TestConfirmGates drives each gate of confirm with one line that confirms
// the record when no gate is set.
func TestConfirmGates(t *testing.T) {
	at := time.Date(2026, 11, 12, 22, 43, 43, 853e6, time.UTC)
	mark := []byte{0, 0, 0, 0, 0, 0, 0x10, 0}
	good := line{agent: 7, ts: []byte{0, 0, 0, 0, 0, 0, 0x10, 1}, time: at,
		comments: `Delivered snapshot from the 'unc\REPLLAB_M_PDB_X_M_P\20261112224353\' sub-folder in 107 milliseconds`}
	cases := []struct {
		name string
		edit func(r *record, l *line)
		want string
	}{
		{"no gate", func(*record, *line) {}, `REPLLAB_M_PDB_X_M_P\20261112224353`},
		{"folder case differs", func(r *record, _ *line) { r.Folder = "repllab_m_pdb_x_m_p" }, `repllab_m_pdb_x_m_p\20261112224353`},
		{"another agent", func(r *record, _ *line) { r.agents = []int{8} }, ""},
		{"no agent row", func(r *record, _ *line) { r.agents = nil }, ""},
		{"at the mark", func(_ *record, l *line) { l.ts = mark }, ""},
		{"before T", func(_ *record, l *line) { l.time = at.Add(-time.Millisecond) }, ""},
		{"another folder", func(r *record, _ *line) { r.Folder = "REPLLAB_M_DB_X_M_DB_M_P" }, ""},
		{"folder not identified yet", func(r *record, _ *line) { r.Folder = "" }, ""},
		{"never identified", func(r *record, _ *line) { r.unlisted = "snapshot folder of m_p not identified" }, ""},
		{"run listed at T", func(r *record, _ *line) { r.Listing = []string{"20261112224353"} }, ""},
		{"run listed at T, S7", func(r *record, _ *line) { r.Listing, r.S7 = []string{"20261112224353"}, true }, `REPLLAB_M_PDB_X_M_P\20261112224353`},
		{"running at T", func(r *record, _ *line) { r.RunningAtT = true }, ""},
		{"concurrent, rows not at 2", func(r *record, _ *line) { r.Concurrent = true }, ""},
		{"concurrent, rows at 2", func(r *record, _ *line) { r.Concurrent, r.concurrentOK = true, true }, `REPLLAB_M_PDB_X_M_P\20261112224353`},
		{"not a delivered line", func(_ *record, l *line) { l.comments = "Applied the snapshot to the subscriber." }, ""},
	}
	for _, c := range cases {
		r := &record{owed: owed{Publication: "m_p", Subscription: "SUB/m_sdb", T: at, Mark: mark,
			Folder: "REPLLAB_M_PDB_X_M_P"}, agents: []int{7}}
		l := good
		c.edit(r, &l)
		tr := &tracker{lines: map[lineKey]line{}, records: []*record{r}}
		tr.keep(l)
		tr.confirm()
		if r.run != c.want {
			t.Errorf("%s: confirmed %q, want %q", c.name, r.run, c.want)
		}
	}
}

// TestIdentify: the folder of a publication the plan creates, absent at T,
// is taken from a later listing by its whole name, never from another
// publication's folder that ends the same way.
func TestIdentify(t *testing.T) {
	unc := labRoot + "/unc/"
	r := &record{owed: owed{Publication: "m_p", Created: true}}
	other := []fsEntry{dir(labRoot+"/", "unc"), dir(unc, "REPLLAB_M_DB_X_M_DB_M_P")}
	r.identifyIn(other, labRoot, "repllab", "m_db")
	if r.Folder != "" || r.unlisted != "" {
		t.Fatalf("beside x_m_db_m_p only: folder %q, unlisted %q", r.Folder, r.unlisted)
	}
	r.identifyIn(append(other, dir(unc, "REPLLAB_M_DB_M_P")), labRoot, "repllab", "m_db")
	if r.Folder != "REPLLAB_M_DB_M_P" || r.unlisted != "" {
		t.Errorf("once listed: folder %q, unlisted %q", r.Folder, r.unlisted)
	}
	r = &record{owed: owed{Publication: "m_p", Created: true}}
	r.identifyIn(append(other, dir(unc, "REPLLAB_M_DB_M_P"), dir(unc, "repllab_m_db_m_p")), labRoot, "repllab", "m_db")
	if r.Folder != "" || r.unlisted != "snapshot folder of m_p not identified" {
		t.Errorf("two case variants: folder %q, unlisted %q", r.Folder, r.unlisted)
	}
	r = &record{owed: owed{Publication: "m_p", Created: true}}
	r.identifyIn(other, labRoot, `SRV\INST`, "m_db")
	if r.unlisted == "" {
		t.Errorf("named instance: not refused")
	}
}

// TestApplyQueriesParse checks the syntax of every query of queries.go on
// the lab, with both server tables and a distribution database name that
// needs quoting, as internal/reader's TestQueriesParse does.
func TestApplyQueriesParse(t *testing.T) {
	db, err := sql.Open("sqlserver", labDSN(t))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	ctx := context.Background()
	// PARSEONLY only applies to the batches that follow it in the session,
	// so it is set on a dedicated connection, in a batch of its own.
	conn, err := db.Conn(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if _, err := conn.ExecContext(ctx, "SET PARSEONLY ON"); err != nil {
		t.Fatal(err)
	}
	n := 0
	for _, dist := range []string{"distribution", "m d]2"} {
		for _, servers := range []string{"", fallbackServers} {
			for name, q := range applyQueries() {
				// Parameters are declared so that the batch parses on its own.
				batch := "DECLARE @p1 nvarchar(256), @p2 nvarchar(256), @p3 nvarchar(256), @p4 nvarchar(256), @p5 nvarchar(256);\n" +
					distQuery(q, dist, servers)
				if _, err := conn.ExecContext(ctx, batch); err != nil {
					t.Errorf("%s (%s, %q): %v", name, dist, servers, err)
				}
				n++
			}
		}
	}
	if n == 0 {
		t.Fatal("no query parsed")
	}
}
