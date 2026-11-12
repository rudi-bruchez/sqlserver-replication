package precheck

import (
	"context"
	"encoding/hex"
	"strings"
	"testing"

	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
)

func lsnBytes(t *testing.T, h string) [10]byte {
	t.Helper()
	var b [10]byte
	n, err := hex.Decode(b[:], []byte(h))
	if err != nil || n != 10 {
		t.Fatalf("bad test LSN %q: %v", h, err)
	}
	return b
}

func TestParseLSN(t *testing.T) {
	got, err := parseLSN("0x00000025000001080001")
	if err != nil || got != lsnBytes(t, "00000025000001080001") {
		t.Errorf("0x00000025000001080001: %x %v", got, err)
	}
	for _, bad := range []string{"0x0025", "00000025000001080001", "0xZZ000025000001080001", "0xZZ0000250000010800", ""} {
		if _, err := parseLSN(bad); err == nil {
			t.Errorf("%q parses", bad)
		}
	}
}

func TestLSNFromNumeric(t *testing.T) {
	// 10-init-modes.sh lines 194 to 199: vlf = lsn / 10^15, block =
	// (lsn % 10^15) / 10^5, slot = lsn % 10^5.
	got, err := lsnFromNumeric("37000000026400001")
	if err != nil || got != lsnBytes(t, "00000025000001080001") {
		t.Errorf("37000000026400001: %x %v", got, err)
	}
	// A slot above 65535 does not fit binary(2).
	if got, err := lsnFromNumeric("37000000026465536"); err == nil {
		t.Errorf("slot 65536 converts to %x", got)
	}
	// A block above 2^32-1 does not fit binary(4).
	if got, err := lsnFromNumeric("37429496729600001"); err == nil {
		t.Errorf("block 4294967296 converts to %x", got)
	}
	for _, bad := range []string{"", "-1", "12a", "1.5"} {
		if _, err := lsnFromNumeric(bad); err == nil {
			t.Errorf("%q converts", bad)
		}
	}
}

func TestLSNFromLogEnd(t *testing.T) {
	got, err := lsnFromLogEnd("00000025:00000108:0001")
	if err != nil || got != lsnBytes(t, "00000025000001080001") {
		t.Errorf("00000025:00000108:0001: %x %v", got, err)
	}
	for _, bad := range []string{"", "25:108:1", "00000025-00000108-0001", "0000002G:00000108:0001", "00000025:00000108:00011"} {
		if _, err := lsnFromLogEnd(bad); err == nil {
			t.Errorf("%q parses", bad)
		}
	}
}

func TestCheckLSN(t *testing.T) {
	restored := lsnBytes(t, "00000025000001080001")
	logEnd := lsnBytes(t, "00000030000000100002")
	cases := []struct {
		name, lsn string
		ok        bool
		reason    string
	}{
		{"zero", "00000000000000000000", false, "zero"},
		{"beyond the log end", "00000030000000100003", false, "beyond the end of the log"},
		{"below the backup", "00000025000001070001", false, "below the last_lsn"},
		{"above the backup, below the log end", "00000025000001080002", false, "above the last_lsn"},
		{"equal to the backup (I3.lsn.create)", "00000025000001080001", true, ""},
	}
	for _, c := range cases {
		ok, reason := checkLSN(lsnBytes(t, c.lsn), restored, logEnd)
		if ok != c.ok || !strings.Contains(reason, c.reason) || ok && reason != "" {
			t.Errorf("%s: %t %q, want %t containing %q", c.name, ok, reason, c.ok, c.reason)
		}
	}
}

// R59 minor 12: a file that omits the working directory checks the
// current one.
func TestPrecheckFolderFromCurrent(t *testing.T) {
	db := fakeDB(t, "repllab")
	current := &model.Config{Version: model.FormatVersion, Publisher: model.Publisher{Server: "repllab", Database: "Sales"},
		Distributor: &model.Distributor{WorkingDirectory: model.Ptr("/var/opt/mssql/data/ReplData")}}
	c, err := Run(context.Background(), Conns{Publisher: db, Publication: db, Distributor: db}, fakeDesired(), current)
	if err != nil {
		t.Fatal(err)
	}
	if len(c.Folders) != 1 || c.Folders[0].Path != "/var/opt/mssql/data/ReplData" || c.Folders[0].Server != "repllab" ||
		!c.Folders[0].Checked || !c.Folders[0].Exists {
		t.Errorf("folders %+v, want the current working directory checked", c.Folders)
	}
	// Without the current configuration, nothing names a folder.
	c, err = Run(context.Background(), Conns{Publisher: db, Publication: db, Distributor: db}, fakeDesired(), nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(c.Folders) != 0 {
		t.Errorf("folders %+v without a current configuration", c.Folders)
	}
}
