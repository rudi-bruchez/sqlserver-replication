package decode

import (
	"reflect"
	"testing"
)

func TestSchemaOptionBytesIsBigEndian(t *testing.T) {
	// 0x00000000000030F3 is the documented default for a table article.
	b := []byte{0, 0, 0, 0, 0, 0, 0x30, 0xF3}
	v, err := SchemaOptionBytes(b)
	if err != nil {
		t.Fatal(err)
	}
	if v != 0x30F3 {
		t.Fatalf("got 0x%X, want 0x30F3", v)
	}
	if _, err := SchemaOptionBytes(make([]byte, 9)); err == nil {
		t.Fatal("expected an error for 9 bytes")
	}
}

func TestSchemaOptionNamesDefault(t *testing.T) {
	got := SchemaOptionNames(0x30F3)
	want := []string{
		"object_creation", "custom_procedures", "clustered_index", "udt_to_base_types",
		"nonclustered_indexes", "primary_key", "column_collation", "extended_properties",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestSchemaOptionRoundTrip(t *testing.T) {
	values := []uint64{0, 0x30F3, 0x800000000000, 0x1000000000000 | 0x1, 0xFFFFFFFFFFFFFFFF}
	for _, v := range values {
		names := SchemaOptionNames(v)
		back, err := EncodeSchemaOptions(names)
		if err != nil {
			t.Fatalf("0x%X: %v", v, err)
		}
		if back != v {
			t.Fatalf("0x%X: round trip gave 0x%X (%v)", v, back, names)
		}
	}
}

func TestSchemaOptionUnknownBitIsKept(t *testing.T) {
	got := SchemaOptionNames(0x1000000000000)
	if !reflect.DeepEqual(got, []string{"0x1000000000000"}) {
		t.Fatalf("got %v", got)
	}
	if _, err := EncodeSchemaOptions([]string{"0x3"}); err == nil {
		t.Fatal("0x3 is not a single bit and must be rejected")
	}
	if _, err := EncodeSchemaOptions([]string{"no_such_option"}); err == nil {
		t.Fatal("unknown names must be rejected")
	}
}

func TestSchemaOptionNamesAreUnique(t *testing.T) {
	seen := map[string]bool{}
	var bits uint64
	for _, o := range schemaOptions {
		if seen[o.name] {
			t.Fatalf("duplicate name %s", o.name)
		}
		if o.bit&(o.bit-1) != 0 || bits&o.bit != 0 {
			t.Fatalf("bad or duplicate bit 0x%X", o.bit)
		}
		seen[o.name] = true
		bits |= o.bit
	}
}

func TestParseCommand(t *testing.T) {
	cases := []struct {
		in   string
		want Command
		out  string
	}{
		{"CALL [sp_MSins_dboOrders]", Command{"CALL", "", "sp_MSins_dboOrders"}, "CALL [sp_MSins_dboOrders]"},
		{"SCALL sp_MSupd_dboOrders", Command{"SCALL", "", "sp_MSupd_dboOrders"}, "SCALL [sp_MSupd_dboOrders]"},
		// SQL Server 2022 stores the generated procedures qualified.
		{"CALL [dbo].[sp_MSins_dboCustomer]", Command{"CALL", "dbo", "sp_MSins_dboCustomer"}, "CALL [dbo].[sp_MSins_dboCustomer]"},
		{"xcall dbo.x", Command{"XCALL", "dbo", "x"}, "XCALL [dbo].[x]"},
		{`CALL "s".[a.b]`, Command{"CALL", "s", "a.b"}, "CALL [s].[a.b]"},
		{"CALL [a]]b]", Command{"CALL", "", "a]b"}, "CALL [a]]b]"},
		{"CALL [x].[y].[z]", Command{Mode: "CALL [x].[y].[z]"}, "CALL [x].[y].[z]"},
		{"CALL [unclosed", Command{Mode: "CALL [unclosed"}, "CALL [unclosed"},
		{"", Command{Mode: "SQL"}, "SQL"},
		{"SQL", Command{Mode: "SQL"}, "SQL"},
		{"NONE", Command{Mode: "NONE"}, "NONE"},
		{"INSERT INTO t VALUES (1)", Command{Mode: "INSERT INTO t VALUES (1)"}, "INSERT INTO t VALUES (1)"},
	}
	for _, c := range cases {
		got := ParseCommand(c.in)
		if got != c.want {
			t.Errorf("ParseCommand(%q) = %+v, want %+v", c.in, got, c.want)
		}
		if got.String() != c.out {
			t.Errorf("ParseCommand(%q).String() = %q, want %q", c.in, got.String(), c.out)
		}
	}
}

func TestCodeTablesRoundTrip(t *testing.T) {
	tables := []struct {
		name   string
		table  codeTable
		decode func(int) string
		encode func(string) (int, error)
	}{
		{"articleTypes", articleTypes, ArticleType, ArticleTypeCode},
		{"preCreationCmds", preCreationCmds, PreCreationCmd, PreCreationCmdCode},
		{"syncMethods", syncMethods, SyncMethod, SyncMethodCode},
		{"replFreqs", replFreqs, PublicationType, PublicationTypeCode},
		{"publicationStatuses", publicationStatuses, PublicationStatus, PublicationStatusCode},
		{"freqTypes", freqTypes, FreqType, FreqTypeCode},
		{"freqSubdayTypes", freqSubdayTypes, FreqSubdayType, FreqSubdayTypeCode},
		{"agentTypes", agentTypes, AgentType, AgentTypeCode},
		{"securityModes", securityModes, SecurityMode, SecurityModeCode},
		{"subscriptionTypes", subscriptionTypes, SubscriptionType, SubscriptionTypeCode},
		{"subscriberTypes", subscriberTypes, SubscriberType, SubscriberTypeCode},
	}
	for _, tb := range tables {
		// Distinct names: a duplicate would make the inverse depend on map
		// order, so the check ranges over the table, not over the inverse.
		seen := map[string]int{}
		for code, name := range tb.table {
			if other, dup := seen[name]; dup {
				t.Errorf("%s: name %q used by codes %d and %d", tb.name, name, other, code)
			}
			seen[name] = code
			back, err := tb.encode(tb.decode(code))
			if err != nil || back != code {
				t.Errorf("%s: code %d: got %d, %v", tb.name, code, back, err)
			}
		}
		if got := tb.decode(97); got != "unknown(97)" {
			t.Errorf("%s: decode(97) = %q", tb.name, got)
		}
		if back, err := tb.encode("unknown(97)"); err != nil || back != 97 {
			t.Errorf("%s: unknown(97): got %d, %v", tb.name, back, err)
		}
	}
	if ArticleType(2) != "unknown(2)" {
		t.Fatalf("got %q", ArticleType(2))
	}
}

func TestSyncMethodCodes(t *testing.T) {
	if SyncMethod(5) != "database_snapshot" || SyncMethod(6) != "database_snapshot_character" {
		t.Fatalf("got %q, %q", SyncMethod(5), SyncMethod(6))
	}
	for name, want := range map[string]int{"database_snapshot": 5, "database_snapshot_character": 6} {
		if got, err := SyncMethodCode(name); err != nil || got != want {
			t.Fatalf("%s: got %d, %v", name, got, err)
		}
	}
	if SyncMethod(2) != "unknown(2)" {
		t.Fatalf("sync_method 2 is undocumented, got %q", SyncMethod(2))
	}
}

func TestInitializationCode(t *testing.T) {
	for _, in := range [][2]int{{1, 0}, {2, 0}, {2, 1}, {2, 2}, {2, 3}, {9, 9}} {
		name := Initialization(in[0], in[1])
		s, n, err := InitializationCode(name)
		if err != nil || s != in[0] || n != in[1] {
			t.Errorf("%s: got %d, %d, %v, want %v", name, s, n, err, in)
		}
	}
	if _, _, err := InitializationCode("nonsense"); err == nil {
		t.Error("nonsense must be rejected")
	}
}

func TestPublicationOptionBits(t *testing.T) {
	if got := PublicationOptionUnknownBits(0x20 | 0x40); got != 0 {
		t.Fatalf("got 0x%X", got)
	}
	if got := PublicationOptionUnknownBits(0x200); got != 0x200 {
		t.Fatalf("got 0x%X", got)
	}
}

func TestInitialization(t *testing.T) {
	cases := map[[2]int]string{
		{1, 0}: "snapshot",
		{2, 0}: "none",
		{2, 1}: "replication_support_only",
		{2, 2}: "backup",
		{2, 3}: "lsn",
	}
	for in, want := range cases {
		if got := Initialization(in[0], in[1]); got != want {
			t.Errorf("Initialization(%d, %d) = %q, want %q", in[0], in[1], got, want)
		}
	}
}

func TestUnknownBits(t *testing.T) {
	if got := ArticleStatusUnknownBits(0x1 | 0x10 | 0x40); got != 0x40 {
		t.Fatalf("got 0x%X", got)
	}
	if got := PublicationOptionUnknownBits(0x80 | 0x200); got != 0x200 {
		t.Fatalf("got 0x%X", got)
	}
}
