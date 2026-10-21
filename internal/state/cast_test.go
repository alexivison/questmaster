//go:build linux || darwin

package state

import (
	"encoding/json"
	"os"
	"reflect"
	"sync"
	"testing"
	"time"
)

func TestRunningToolsFollowLatestStartAndFallBackOnEnd(t *testing.T) {
	t.Parallel()

	started := time.Date(2026, 10, 20, 7, 33, 48, 529000000, time.UTC)
	for _, tc := range []struct {
		name         string
		startTools   []RunningTool
		endTool      string
		endCallID    string
		endAfter     time.Duration
		wantTool     string
		wantCallID   string
		wantDuration time.Duration
	}{
		{
			name: "parallel different tools", startTools: []RunningTool{
				{CallID: "call-1", Tool: "Read", StartedAt: started},
				{CallID: "call-2", Tool: "Bash", StartedAt: started.Add(time.Second)},
			}, endTool: "Bash", endCallID: "call-2", endAfter: 7 * time.Second,
			wantTool: "Read", wantCallID: "call-1", wantDuration: 6 * time.Second,
		},
		{
			name: "parallel same tools use call ID", startTools: []RunningTool{
				{CallID: "call-1", Tool: "Bash", StartedAt: started},
				{CallID: "call-2", Tool: "Bash", StartedAt: started.Add(time.Second)},
			}, endTool: "Bash", endCallID: "call-1", endAfter: 4 * time.Second,
			wantTool: "Bash", wantCallID: "call-2", wantDuration: 4 * time.Second,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			pane := PaneState{}
			for _, running := range tc.startTools {
				StartRunningTool(&pane, running.Tool, running.CallID, running.Command, running.StartedAt)
			}
			if pane.Tool != tc.startTools[len(tc.startTools)-1].Tool {
				t.Fatalf("latest tool = %q, want %q", pane.Tool, tc.startTools[len(tc.startTools)-1].Tool)
			}
			ended, duration, ok := EndRunningTool(&pane, tc.endTool, tc.endCallID, started.Add(tc.endAfter))
			if !ok || duration != tc.wantDuration {
				t.Fatalf("ended tool = (%s, %t), want (%s, true)", duration, ok, tc.wantDuration)
			}
			if ended.Tool != tc.endTool {
				t.Fatalf("ended tool name = %q, want %q", ended.Tool, tc.endTool)
			}
			if pane.Tool != tc.wantTool || len(pane.RunningTools) != 1 || pane.RunningTools[0].CallID != tc.wantCallID {
				t.Fatalf("fallback tool = %+v, want %s/%s", pane.RunningTools, tc.wantTool, tc.wantCallID)
			}
		})
	}
}

func TestRunningToolsMatchByNameWithoutCallIDAndClear(t *testing.T) {
	t.Parallel()

	started := time.Date(2026, 10, 20, 7, 0, 0, 0, time.UTC)
	pane := PaneState{}
	StartRunningTool(&pane, "Bash", "", "", started)
	StartRunningTool(&pane, "Bash", "", "", started.Add(time.Second))
	ended, duration, ok := EndRunningTool(&pane, "Bash", "", started.Add(3*time.Second))
	if !ok || duration != 2*time.Second || len(pane.RunningTools) != 1 || !pane.RunningTools[0].StartedAt.Equal(started) {
		t.Fatalf("ended latest same-name tool = (%s, %t), remaining=%+v", duration, ok, pane.RunningTools)
	}
	if ended.Tool != "Bash" {
		t.Fatalf("ended tool name = %q, want Bash", ended.Tool)
	}

	ClearRunningTools(&pane)
	if pane.Tool != "" || len(pane.RunningTools) != 0 {
		t.Fatalf("clear left tools: %+v", pane)
	}
}

func TestRunningToolsKeepOnlyNewestCalls(t *testing.T) {
	t.Parallel()
	started := time.Date(2026, 10, 20, 7, 0, 0, 0, time.UTC)
	pane := PaneState{}
	for i := 0; i < maxRunningTools+4; i++ {
		StartRunningTool(&pane, "Tool", "", "", started.Add(time.Duration(i)*time.Second))
	}
	if len(pane.RunningTools) != maxRunningTools || pane.RunningTools[0].StartedAt != started.Add(4*time.Second) {
		t.Fatalf("running tools = %d, oldest=%s; want %d newest calls", len(pane.RunningTools), pane.RunningTools[0].StartedAt, maxRunningTools)
	}
}

func TestToolDurationMedianNeedsThreeSamplesAndKeepsLastTwenty(t *testing.T) {
	t.Parallel()
	root := t.TempDir()

	for _, sample := range []time.Duration{10, 100} {
		if err := RecordToolDurationAt(root, "claude", "Bash", "", sample*time.Millisecond); err != nil {
			t.Fatalf("record sample: %v", err)
		}
	}
	medians, err := LoadToolTypicalDurationsAt(root)
	if err != nil {
		t.Fatalf("load after two samples: %v", err)
	}
	if _, ok := medians[ToolDurationKey{Agent: "claude", Tool: "Bash"}]; ok {
		t.Fatalf("median available before third sample: %#v", medians)
	}
	if err := RecordToolDurationAt(root, "claude", "Bash", "", 30*time.Millisecond); err != nil {
		t.Fatalf("record third sample: %v", err)
	}
	medians, err = LoadToolTypicalDurationsAt(root)
	if err != nil {
		t.Fatalf("load median: %v", err)
	}
	key := ToolDurationKey{Agent: "claude", Tool: "Bash"}
	if medians[key] != 30 {
		t.Fatalf("median = %dms, want 30ms", medians[key])
	}

	for i := 1; i <= 20; i++ {
		if err := RecordToolDurationAt(root, "claude", "Bash", "", time.Duration(i)*time.Millisecond); err != nil {
			t.Fatalf("record bounded sample %d: %v", i, err)
		}
	}
	samples, err := loadToolDurationSamplesAt(root)
	if err != nil {
		t.Fatalf("load samples: %v", err)
	}
	got := samples[ToolDurationKey{Agent: "claude", Tool: "Bash"}]
	want := make([]int64, 20)
	for i := range want {
		want[i] = int64(i + 1)
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("samples = %v, want last 20 %v", got, want)
	}
	medians, err = LoadToolTypicalDurationsAt(root)
	if err != nil {
		t.Fatalf("load rolling median: %v", err)
	}
	if medians[key] != 10 {
		t.Fatalf("rolling median = %dms, want 10ms", medians[key])
	}
}

func TestToolDurationConcurrentRecordsStayBounded(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	const records = 40
	var wg sync.WaitGroup
	errs := make(chan error, records)
	for i := 0; i < records; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			errs <- RecordToolDurationAt(root, "pi", "bash", "", 250*time.Millisecond)
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatalf("record duration: %v", err)
		}
	}
	samples, err := loadToolDurationSamplesAt(root)
	if err != nil {
		t.Fatalf("load samples: %v", err)
	}
	if got := len(samples[ToolDurationKey{Agent: "pi", Tool: "bash"}]); got != maxToolDurationRuns {
		t.Fatalf("sample count = %d, want %d", got, maxToolDurationRuns)
	}
}

func TestToolDurationWriteRecoversFromCorruptFile(t *testing.T) {
	t.Parallel()
	for _, data := range []struct {
		name string
		file []byte
	}{
		{name: "truncated", file: []byte(`{"entries":[`)},
		{name: "empty"},
	} {
		t.Run(data.name, func(t *testing.T) {
			t.Parallel()
			root := t.TempDir()
			if err := os.WriteFile(toolDurationsPath(root), data.file, 0o600); err != nil {
				t.Fatalf("write corrupt file: %v", err)
			}
			if err := RecordToolDurationAt(root, "claude", "Bash", "go test", 42*time.Millisecond); err != nil {
				t.Fatalf("record after corrupt file: %v", err)
			}
			medians, err := LoadToolTypicalDurationsAt(root)
			if err != nil {
				t.Fatalf("load recovered file: %v", err)
			}
			if len(medians) != 0 {
				t.Fatalf("median after one recovered sample = %#v, want none", medians)
			}
			samples, err := loadToolDurationSamplesAt(root)
			if err != nil {
				t.Fatalf("load recovered samples: %v", err)
			}
			if got := samples[ToolDurationKey{Agent: "claude", Tool: "Bash", Command: "go test"}]; !reflect.DeepEqual(got, []int64{42}) {
				t.Fatalf("recovered samples = %v, want [42]", got)
			}
		})
	}
}

func TestToolDurationRecordsCommandAndToolMedians(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	for _, sample := range []time.Duration{100, 200, 300} {
		if err := RecordToolDurationAt(root, "claude", "Bash", "go test", sample*time.Millisecond); err != nil {
			t.Fatalf("record sample: %v", err)
		}
	}
	medians, err := LoadToolTypicalDurationsAt(root)
	if err != nil {
		t.Fatalf("load medians: %v", err)
	}
	if got := medians[ToolDurationKey{Agent: "claude", Tool: "Bash"}]; got != 200 {
		t.Fatalf("tool median = %dms, want 200", got)
	}
	if got := medians[ToolDurationKey{Agent: "claude", Tool: "Bash", Command: "go test"}]; got != 200 {
		t.Fatalf("command median = %dms, want 200", got)
	}
}

func TestToolDurationEvictsLeastRecentlyUpdatedPair(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	type entry struct {
		Agent     string    `json:"agent"`
		Tool      string    `json:"tool"`
		Command   string    `json:"command,omitempty"`
		Samples   []int64   `json:"samples"`
		UpdatedAt time.Time `json:"updated_at"`
	}
	entries := make([]entry, maxToolDurationPairs)
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	for i := range entries {
		entries[i] = entry{
			Agent:     "agent-" + string(rune('a'+i/26)) + string(rune('a'+i%26)),
			Tool:      "Bash",
			Samples:   []int64{10, 20, 30},
			UpdatedAt: base.Add(time.Duration(i) * time.Minute),
		}
	}
	data, err := json.Marshal(map[string]interface{}{"entries": entries})
	if err != nil {
		t.Fatalf("marshal seeded entries: %v", err)
	}
	if err := os.WriteFile(toolDurationsPath(root), data, 0o600); err != nil {
		t.Fatalf("write seeded entries: %v", err)
	}
	if err := RecordToolDurationAt(root, "new-agent", "bash", "sleep", 500*time.Millisecond); err != nil {
		t.Fatalf("record new command: %v", err)
	}
	samples, err := loadToolDurationSamplesAt(root)
	if err != nil {
		t.Fatalf("load evicted samples: %v", err)
	}
	if len(samples) != maxToolDurationPairs {
		t.Fatalf("duration pairs = %d, want cap %d", len(samples), maxToolDurationPairs)
	}
	if _, ok := samples[ToolDurationKey{Agent: "agent-aa", Tool: "Bash"}]; ok {
		t.Fatal("oldest pair was retained")
	}
	if _, ok := samples[ToolDurationKey{Agent: "agent-ab", Tool: "Bash"}]; ok {
		t.Fatal("second-oldest pair was retained")
	}
	for _, key := range []ToolDurationKey{
		{Agent: "new-agent", Tool: "bash"},
		{Agent: "new-agent", Tool: "bash", Command: "sleep"},
	} {
		if _, ok := samples[key]; !ok {
			t.Fatalf("new pair %+v missing after eviction", key)
		}
	}
}

func TestToolDurationEvictionKeepsToolPairBeingUpdated(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	entries := make([]toolDurationEntry, maxToolDurationPairs)
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	entries[0] = toolDurationEntry{
		Agent: "claude", Tool: "Bash", Samples: []int64{10, 20, 30}, UpdatedAt: base,
	}
	for i := 1; i < len(entries); i++ {
		entries[i] = toolDurationEntry{
			Agent:     "other-" + string(rune('a'+i/26)) + string(rune('a'+i%26)),
			Tool:      "Bash",
			Samples:   []int64{10, 20, 30},
			UpdatedAt: base.Add(time.Duration(i) * time.Minute),
		}
	}
	data, err := json.Marshal(toolDurationFile{Entries: entries})
	if err != nil {
		t.Fatalf("marshal seeded entries: %v", err)
	}
	if err := os.WriteFile(toolDurationsPath(root), data, 0o600); err != nil {
		t.Fatalf("write seeded entries: %v", err)
	}
	if err := RecordToolDurationAt(root, "claude", "Bash", "sleep", 500*time.Millisecond); err != nil {
		t.Fatalf("record command sample: %v", err)
	}
	samples, err := loadToolDurationSamplesAt(root)
	if err != nil {
		t.Fatalf("load samples: %v", err)
	}
	baseKey := ToolDurationKey{Agent: "claude", Tool: "Bash"}
	if got, want := samples[baseKey], []int64{10, 20, 30, 500}; !reflect.DeepEqual(got, want) {
		t.Fatalf("tool-level samples = %v, want %v", got, want)
	}
	if got := samples[ToolDurationKey{Agent: "claude", Tool: "Bash", Command: "sleep"}]; !reflect.DeepEqual(got, []int64{500}) {
		t.Fatalf("command samples = %v, want [500]", got)
	}
}
