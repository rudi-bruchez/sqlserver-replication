package state

import (
	"encoding/json"
	"sort"
	"strings"
	"testing"
)

// keys collects the object keys of a decoded JSON value, each with the path
// of its parent, so that a key placed in the wrong object is seen.
func keys(prefix string, v any, out map[string]bool) {
	switch x := v.(type) {
	case map[string]any:
		for k, c := range x {
			out[prefix+"."+k] = true
			keys(prefix+"."+k, c, out)
		}
	case []any:
		for _, c := range x {
			keys(prefix+"[]", c, out)
		}
	}
}

func TestFactsJSONKeys(t *testing.T) {
	hist := &HistoryRow{Time: "2026-11-11T10:00:00", RunStatus: 6, Comments: "c", ErrorText: "e"}
	f := Facts{
		ReadAt: "2026-11-11T10:00:00",
		Publications: []PublicationFacts{{Name: "P", ImmediateSyncReady: true, LastGeneration: "2026-11-11T09:00:00",
			Articles: []ArticleFacts{{Name: "A", Active: true}}}},
		Subscriptions: []SubscriptionFacts{{Publication: "P", Subscriber: "S", Database: "D",
			Rows: []SubscriptionRow{{Article: "A", PublisherStatus: 2}}}},
		Agents: []AgentFacts{{Kind: "distribution", Publication: "P", Subscriber: "S", Database: "D", AgentID: 3,
			Job: &JobState{Exists: true, Enabled: true, Running: true}, LastHistory: hist, LastFailure: hist}},
		ProfileUses: []ProfileUse{{Profile: "p", AgentType: "distribution", DistributionDB: "distribution",
			PublisherDB: "Sales", Publication: "P", Subscriber: "S", Database: "D"}},
	}
	b, err := json.Marshal(f)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), `"distributor_status":null`) {
		t.Errorf("distributor_status not written as null: %s", b)
	}
	var v any
	if err := json.Unmarshal(b, &v); err != nil {
		t.Fatal(err)
	}
	got := map[string]bool{}
	keys("", v, got)
	want := []string{
		".read_at", ".publications", ".subscriptions", ".agents", ".profile_uses",
		".publications[].name", ".publications[].immediate_sync_ready", ".publications[].last_generation",
		".publications[].articles", ".publications[].articles[].name", ".publications[].articles[].active",
		".subscriptions[].publication", ".subscriptions[].subscriber", ".subscriptions[].database",
		".subscriptions[].rows", ".subscriptions[].rows[].article", ".subscriptions[].rows[].publisher_status",
		".subscriptions[].rows[].distributor_status",
		".agents[].kind", ".agents[].publication", ".agents[].subscriber", ".agents[].database",
		".agents[].agent_id", ".agents[].job", ".agents[].job.exists", ".agents[].job.enabled",
		".agents[].job.running", ".agents[].last_history", ".agents[].last_failure",
		".agents[].last_history.time", ".agents[].last_history.runstatus", ".agents[].last_history.comments",
		".agents[].last_history.error_text",
		".agents[].last_failure.time", ".agents[].last_failure.runstatus", ".agents[].last_failure.comments",
		".agents[].last_failure.error_text",
		".profile_uses[].profile", ".profile_uses[].agent_type", ".profile_uses[].distribution_db",
		".profile_uses[].publisher_db", ".profile_uses[].publication", ".profile_uses[].subscriber",
		".profile_uses[].database",
	}
	wantSet := map[string]bool{}
	for _, k := range want {
		wantSet[k] = true
	}
	var missing, extra []string
	for k := range wantSet {
		if !got[k] {
			missing = append(missing, k)
		}
	}
	for k := range got {
		if !wantSet[k] {
			extra = append(extra, k)
		}
	}
	sort.Strings(missing)
	sort.Strings(extra)
	if len(missing) > 0 || len(extra) > 0 {
		t.Errorf("missing keys %v, unexpected keys %v", missing, extra)
	}
}
