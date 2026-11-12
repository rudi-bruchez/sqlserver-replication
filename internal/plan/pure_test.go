package plan

import (
	"os/exec"
	"strings"
	"testing"
)

// TestPurePackages: the planner packages import neither database/sql nor the
// reader nor the precheck package, directly or through another package
// (spec "Engine as a library"). go list -deps lists the transitive closure
// of the non-test files.
func TestPurePackages(t *testing.T) {
	forbidden := map[string]bool{
		"database/sql": true,
		"github.com/rudi-bruchez/sqlserver-replication/internal/reader":   true,
		"github.com/rudi-bruchez/sqlserver-replication/internal/precheck": true,
	}
	for _, pkg := range []string{"../normalize", "../cost", "."} {
		out, err := exec.Command("go", "list", "-deps", pkg).CombinedOutput()
		if err != nil {
			t.Fatalf("go list -deps %s: %v\n%s", pkg, err, out)
		}
		deps := strings.Fields(string(out))
		if len(deps) < 2 {
			t.Fatalf("go list -deps %s listed %d packages", pkg, len(deps))
		}
		for _, d := range deps {
			if forbidden[d] {
				t.Errorf("%s depends on %s", pkg, d)
			}
		}
	}
}
