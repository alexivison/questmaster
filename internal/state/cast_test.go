//go:build linux || darwin

package state

import (
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
				StartRunningTool(&pane, running.Tool, running.CallID, running.StartedAt)
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
	StartRunningTool(&pane, "Bash", "", started)
	StartRunningTool(&pane, "Bash", "", started.Add(time.Second))
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
		StartRunningTool(&pane, "Tool", "", started.Add(time.Duration(i)*time.Second))
	}
	if len(pane.RunningTools) != maxRunningTools || pane.RunningTools[0].StartedAt != started.Add(4*time.Second) {
		t.Fatalf("running tools = %d, oldest=%s; want %d newest calls", len(pane.RunningTools), pane.RunningTools[0].StartedAt, maxRunningTools)
	}
}

func TestToolDurationMedianNeedsThreeSamplesAndKeepsLastTwenty(t *testing.T) {
	t.Parallel()
	root := t.TempDir()

	for _, sample := range []time.Duration{10, 100} {
		if err := RecordToolDurationAt(root, "claude", "Bash", sample*time.Millisecond); err != nil {
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
	if err := RecordToolDurationAt(root, "claude", "Bash", 30*time.Millisecond); err != nil {
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
		if err := RecordToolDurationAt(root, "claude", "Bash", time.Duration(i)*time.Millisecond); err != nil {
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
			errs <- RecordToolDurationAt(root, "pi", "bash", 250*time.Millisecond)
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
