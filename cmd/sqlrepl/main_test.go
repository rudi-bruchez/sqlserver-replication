package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

// A facts path that cannot be written fails the export before the YAML is
// written: a new output file is not left behind, an existing one keeps its
// content.
func TestWriteOutputsOpensBothFirst(t *testing.T) {
	dir := t.TempDir()
	out := filepath.Join(dir, "out.yaml")
	badFacts := filepath.Join(dir, "missing", "facts.json")

	if err := writeOutputs(nil, out, []byte("version: 2\n"), badFacts, []byte("{}\n")); err == nil {
		t.Fatal("unwritable facts path: no error")
	}
	if _, err := os.Stat(out); !os.IsNotExist(err) {
		t.Errorf("output written although the facts path cannot be: stat err = %v", err)
	}

	if err := os.WriteFile(out, []byte("old content, longer than the new one\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := writeOutputs(nil, out, []byte("version: 2\n"), badFacts, []byte("{}\n")); err == nil {
		t.Fatal("unwritable facts path, existing output: no error")
	}
	if b, _ := os.ReadFile(out); string(b) != "old content, longer than the new one\n" {
		t.Errorf("existing output = %q, want it untouched", b)
	}

	facts := filepath.Join(dir, "facts.json")
	if err := writeOutputs(nil, out, []byte("version: 2\n"), facts, []byte("{}\n")); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(out); string(b) != "version: 2\n" {
		t.Errorf("output = %q, want the new YAML only", b)
	}
	if b, _ := os.ReadFile(facts); string(b) != "{}\n" {
		t.Errorf("facts = %q", b)
	}

	var stdout bytes.Buffer
	if err := writeOutputs(&stdout, "", []byte("version: 2\n"), "", nil); err != nil || stdout.String() != "version: 2\n" {
		t.Errorf("stdout = %q, err = %v", stdout.String(), err)
	}
}
