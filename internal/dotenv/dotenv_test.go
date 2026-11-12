package dotenv

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParse(t *testing.T) {
	input := `# comment
export FOO=bar

KEY="quoted value"
OTHER='single'
PLAIN=val
`
	got, err := Parse(strings.NewReader(input))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	cases := map[string]string{
		"FOO":   "bar",
		"KEY":   "quoted value",
		"OTHER": "single",
		"PLAIN": "val",
	}
	for k, want := range cases {
		if got[k] != want {
			t.Errorf("got[%q] = %q, want %q", k, got[k], want)
		}
	}
	if len(got) != len(cases) {
		t.Errorf("got %d entries, want %d: %v", len(got), len(cases), got)
	}
}

func TestParseErrorNoEquals(t *testing.T) {
	_, err := Parse(strings.NewReader("NOEQUALS\n"))
	if err == nil {
		t.Fatal("want an error for a line without '='")
	}
}

func TestLoadDoesNotOverride(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "test.env")
	if err := os.WriteFile(path, []byte("SQLREPL_DOTENV_TEST=fromfile\nSQLREPL_DOTENV_NEW=created\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	// The real environment variable must win.
	t.Setenv("SQLREPL_DOTENV_TEST", "fromenv")
	// Registered so that t.Setenv restores (unsets) it after the test.
	t.Setenv("SQLREPL_DOTENV_NEW", "")
	os.Unsetenv("SQLREPL_DOTENV_NEW")

	if err := Load(path); err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got := os.Getenv("SQLREPL_DOTENV_TEST"); got != "fromenv" {
		t.Errorf("SQLREPL_DOTENV_TEST = %q, want %q (the environment must win over .env)", got, "fromenv")
	}
	if got := os.Getenv("SQLREPL_DOTENV_NEW"); got != "created" {
		t.Errorf("SQLREPL_DOTENV_NEW = %q, want %q (a new key must be set)", got, "created")
	}
}

func TestLoadMissingFileNoError(t *testing.T) {
	err := Load(filepath.Join(t.TempDir(), "nope.env"))
	if err != nil {
		t.Fatalf("Load on a missing file: want nil, got %v", err)
	}
}

func TestLoadFilesPriority(t *testing.T) {
	d := t.TempDir()
	a := filepath.Join(d, "a.env")
	b := filepath.Join(d, "b.env")
	if err := os.WriteFile(a, []byte("SQLREPL_DOTENV_A=one\nSQLREPL_DOTENV_B=first\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(b, []byte("SQLREPL_DOTENV_B=second\nSQLREPL_DOTENV_C=three\n"), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SQLREPL_DOTENV_A", "real")
	for _, k := range []string{"SQLREPL_DOTENV_B", "SQLREPL_DOTENV_C"} {
		t.Setenv(k, "")
		os.Unsetenv(k)
	}
	if err := LoadFiles(a, b); err != nil {
		t.Fatal(err)
	}
	for k, want := range map[string]string{"SQLREPL_DOTENV_A": "real", "SQLREPL_DOTENV_B": "second", "SQLREPL_DOTENV_C": "three"} {
		if got := os.Getenv(k); got != want {
			t.Errorf("%s=%q, want %q", k, got, want)
		}
	}
	bad := filepath.Join(d, "bad.env")
	if err := os.WriteFile(bad, []byte("NO_EQUALS_SIGN\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := LoadFiles(a, bad); err == nil || !strings.Contains(err.Error(), "bad.env") {
		t.Fatalf("parse error not returned: %v", err)
	}
}
