package plan

import (
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// TestPurePackages: the planner packages import neither database/sql nor the
// reader nor the precheck package (spec "Engine as a library").
func TestPurePackages(t *testing.T) {
	forbidden := map[string]bool{
		"database/sql": true,
		"github.com/rudi-bruchez/sqlserver-replication/internal/reader":   true,
		"github.com/rudi-bruchez/sqlserver-replication/internal/precheck": true,
	}
	files := 0
	for _, dir := range []string{"../normalize", "../cost", "."} {
		entries, err := os.ReadDir(dir)
		if err != nil {
			t.Fatal(err)
		}
		for _, e := range entries {
			name := e.Name()
			if e.IsDir() || !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
				continue
			}
			path := filepath.Join(dir, name)
			f, err := parser.ParseFile(token.NewFileSet(), path, nil, parser.ImportsOnly)
			if err != nil {
				t.Fatal(err)
			}
			files++
			for _, imp := range f.Imports {
				p, err := strconv.Unquote(imp.Path.Value)
				if err != nil {
					t.Fatal(err)
				}
				if forbidden[p] {
					t.Errorf("%s imports %s", path, p)
				}
			}
		}
	}
	if files < 3 {
		t.Fatalf("parsed %d files: the directories were not found", files)
	}
}
