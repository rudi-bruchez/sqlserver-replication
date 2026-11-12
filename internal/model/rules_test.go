package model

import (
	"strings"
	"testing"
)

func TestPublicationSubsetAllowed(t *testing.T) {
	pub := func(method string, immediate bool) *Publication {
		return &Publication{SyncMethod: Ptr(method), ImmediateSync: Ptr(immediate)}
	}
	if pub("native", true).SubsetAllowed() {
		t.Error("immediate_sync: a subset cannot exist")
	}
	for _, m := range []string{"concurrent", "concurrent_c"} {
		if pub(m, false).SubsetAllowed() {
			t.Errorf("%s: a subset cannot exist", m)
		}
	}
	for _, m := range []string{"native", "character", "database_snapshot", "database_snapshot_character"} {
		if !pub(m, false).SubsetAllowed() {
			t.Errorf("%s: a subset can exist", m)
		}
	}
}

// TestScheduleEnabledPointer checks that an omitted enabled stays omitted
// through a load and a marshal, and that false is kept, not dropped.
func TestScheduleEnabledPointer(t *testing.T) {
	load := func(schedule string) (*Config, string) {
		t.Helper()
		in := `version: 2
publisher:
  server: S
  database: D
  log_reader_agent:
    schedules:
      - ` + schedule + `
`
		c, err := Load(strings.NewReader(in))
		if err != nil {
			t.Fatalf("Load: %v", err)
		}
		out, err := Marshal(c)
		if err != nil {
			t.Fatalf("Marshal: %v", err)
		}
		return c, string(out)
	}

	c, out := load("{name: s, frequency: autostart}")
	if s := (*c.Publisher.LogReaderAgent.Schedules)[0]; s.Enabled != nil {
		t.Errorf("omitted enabled loads %v, want nil", *s.Enabled)
	}
	if strings.Contains(out, "enabled") {
		t.Errorf("omitted enabled marshals with the key:\n%s", out)
	}

	c, out = load("{name: s, enabled: false, frequency: autostart}")
	if s := (*c.Publisher.LogReaderAgent.Schedules)[0]; s.Enabled == nil || *s.Enabled {
		t.Errorf("enabled: false loads %v, want a pointer to false", s.Enabled)
	}
	if !strings.Contains(out, "enabled: false") {
		t.Errorf("enabled: false does not marshal back:\n%s", out)
	}
}
