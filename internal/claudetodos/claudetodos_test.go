package claudetodos

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestParse(t *testing.T) {
	t.Parallel()

	cases := map[string]struct {
		input      string
		wantErr    bool
		wantTotal  int
		wantCounts Counts
	}{
		"empty list":     {input: "[]", wantTotal: 0},
		"all completed":  {input: `[{"content":"a","status":"completed"},{"content":"b","status":"completed"}]`, wantTotal: 2, wantCounts: Counts{Completed: 2}},
		"single active":  {input: `[{"content":"a","status":"in_progress"}]`, wantTotal: 1, wantCounts: Counts{InProgress: 1}},
		"multi active":   {input: `[{"content":"a","status":"in_progress"},{"content":"b","status":"in_progress"},{"content":"c","status":"pending"}]`, wantTotal: 3, wantCounts: Counts{InProgress: 2, Pending: 1}},
		"pending only":   {input: `[{"content":"a","status":"pending"},{"content":"b","status":"pending"}]`, wantTotal: 2, wantCounts: Counts{Pending: 2}},
		"unknown status": {input: `[{"content":"a","status":"frobnicated"}]`, wantTotal: 1},
		"extra fields":   {input: `[{"content":"a","status":"pending","activeForm":"Working","id":"x"}]`, wantTotal: 1, wantCounts: Counts{Pending: 1}},
		"malformed":      {input: `{"not":"an array"}`, wantErr: true},
		"broken json":    {input: `[`, wantErr: true},
	}

	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()

			state, err := Parse([]byte(tc.input))
			if tc.wantErr {
				if err == nil {
					t.Fatalf("expected error, got state=%+v", state)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if state.Total() != tc.wantTotal {
				t.Errorf("total: got %d want %d", state.Total(), tc.wantTotal)
			}
			if state.Counts != tc.wantCounts {
				t.Errorf("counts: got %+v want %+v", state.Counts, tc.wantCounts)
			}
		})
	}
}

func TestBuildOverlay(t *testing.T) {
	t.Parallel()

	cases := map[string]struct {
		items       []Item
		wantOK      bool
		wantText    string
		wantActive  int
		wantComplete int
		wantTotal   int
	}{
		"empty": {wantOK: false},
		"single in_progress": {
			items:      []Item{{"write tests", "in_progress"}},
			wantOK:     true,
			wantText:   "write tests",
			wantActive: 1,
			wantTotal:  1,
		},
		"prefer first in_progress over pending": {
			items: []Item{
				{"old pending", "pending"},
				{"active task", "in_progress"},
				{"also active", "in_progress"},
			},
			wantOK:     true,
			wantText:   "active task",
			wantActive: 2,
			wantTotal:  3,
		},
		"first pending when no in_progress": {
			items: []Item{
				{"done", "completed"},
				{"next up", "pending"},
				{"later", "pending"},
			},
			wantOK:       true,
			wantText:     "next up",
			wantComplete: 1,
			wantTotal:    3,
		},
		"last completed when all completed": {
			items: []Item{
				{"first", "completed"},
				{"middle", "completed"},
				{"final", "completed"},
			},
			wantOK:       true,
			wantText:     "final",
			wantComplete: 3,
			wantTotal:    3,
		},
	}

	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()

			// Drive the state through Parse so the test exercises the
			// same counting path production uses.
			payload, err := json.Marshal(tc.items)
			if err != nil {
				t.Fatalf("marshal items: %v", err)
			}
			state, err := Parse(payload)
			if err != nil {
				t.Fatalf("parse: %v", err)
			}

			ov, ok := BuildOverlay(state)
			if ok != tc.wantOK {
				t.Fatalf("ok: got %v want %v", ok, tc.wantOK)
			}
			if !tc.wantOK {
				return
			}
			if ov.Text != tc.wantText {
				t.Errorf("text: got %q want %q", ov.Text, tc.wantText)
			}
			if ov.ActiveCount != tc.wantActive {
				t.Errorf("active: got %d want %d", ov.ActiveCount, tc.wantActive)
			}
			if ov.Completed != tc.wantComplete {
				t.Errorf("completed: got %d want %d", ov.Completed, tc.wantComplete)
			}
			if ov.Total != tc.wantTotal {
				t.Errorf("total: got %d want %d", ov.Total, tc.wantTotal)
			}
		})
	}
}

func TestOverlayFormatLine(t *testing.T) {
	t.Parallel()

	cases := map[string]struct {
		ov   Overlay
		want string
	}{
		"single":      {ov: Overlay{Completed: 1, Total: 3, ActiveCount: 1, Text: "run tests"}, want: "1/3: run tests"},
		"no active":   {ov: Overlay{Completed: 2, Total: 3, ActiveCount: 0, Text: "next task"}, want: "2/3: next task"},
		"two active":  {ov: Overlay{Completed: 0, Total: 5, ActiveCount: 2, Text: "primary"}, want: "0/5(+1): primary"},
		"many active": {ov: Overlay{Completed: 1, Total: 6, ActiveCount: 4, Text: "primary"}, want: "1/6(+3): primary"},
	}

	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()

			if got := tc.ov.FormatLine(); got != tc.want {
				t.Errorf("got %q want %q", got, tc.want)
			}
		})
	}
}

func TestResolveSessionID(t *testing.T) {
	t.Parallel()

	validUUID := "01bd389f-134f-4c3f-827a-fe88c00e485a"
	otherUUID := "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
	thirdUUID := "11111111-2222-3333-4444-555555555555"

	cases := map[string]struct {
		fileContent string // if non-empty, written to resumeFilePath
		omitFile    bool   // true = pass resumeFilePath="" to skip file lookup
		manifestID  string
		resumeID    string
		want        string
	}{
		"runtime file wins":       {fileContent: validUUID + "\n", manifestID: otherUUID, resumeID: thirdUUID, want: validUUID},
		"falls back to manifest":  {manifestID: otherUUID, resumeID: thirdUUID, want: otherUUID},
		"falls back to resumeID":  {resumeID: thirdUUID, want: thirdUUID},
		"all empty":               {want: ""},
		"runtime unsafe skipped":  {fileContent: "../../etc/passwd", manifestID: otherUUID, want: otherUUID},
		"manifest unsafe skipped": {manifestID: "../foo", resumeID: thirdUUID, want: thirdUUID},
		"resumeID unsafe":         {resumeID: "bad*glob", want: ""},
		"path skipped":            {omitFile: true, fileContent: validUUID, manifestID: otherUUID, want: otherUUID},
	}

	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()

			path := filepath.Join(t.TempDir(), "claude-session-id")
			if tc.fileContent != "" && !tc.omitFile {
				if err := os.WriteFile(path, []byte(tc.fileContent), 0o644); err != nil {
					t.Fatalf("write runtime file: %v", err)
				}
			}
			arg := path
			if tc.omitFile {
				arg = ""
			}

			got := ResolveSessionID(arg, tc.manifestID, tc.resumeID)
			if got != tc.want {
				t.Errorf("got %q want %q", got, tc.want)
			}
		})
	}
}

func TestPath(t *testing.T) {
	t.Parallel()

	want := "/todos/abc-agent-abc.json"
	if got := Path("/todos", "abc"); got != want {
		t.Errorf("got %q want %q", got, want)
	}
}
