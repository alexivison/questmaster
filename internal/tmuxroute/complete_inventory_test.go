package tmuxroute

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

func TestAuditRequiresCompleteInventory(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name, record, ids, wantGate, wantError string
		lateLabel, unavailable                 bool
	}{
		{name: "unreadable record", record: "{", wantGate: "unknown", wantError: "parse tmux server labels"},
		{name: "label recorded later", lateLabel: true, ids: "qm-orphan", wantGate: "blocked"},
		{name: "unavailable server", unavailable: true, wantGate: "unknown", wantError: "unavailable"},
		{name: "complete empty inventory", wantGate: "ready"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			r := testRouter(t, func(context.Context, ...string) (string, error) { return "", nil }, func(context.Context, ...string) (string, error) {
				if tc.unavailable {
					return "", context.DeadlineExceeded
				}
				return "", nil
			})
			if tc.record != "" {
				if err := os.WriteFile(filepath.Join(r.store.Root(), "tmux-servers.json"), []byte(tc.record), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			r.factory = func(label string) (*tmux.Client, error) {
				if label != "dev_later" {
					t.Fatalf("unexpected label %q", label)
				}
				return tmux.NewClient(runnerFunc(func(context.Context, ...string) (string, error) { return tc.ids, nil })), nil
			}
			if tc.lateLabel {
				if err := state.RecordTmuxServerLabel(r.store.Root(), "dev_later"); err != nil {
					t.Fatal(err)
				}
			}
			audit, err := r.Audit(t.Context())
			if err != nil {
				t.Fatal(err)
			}
			if audit.Gate != tc.wantGate {
				t.Errorf("gate = %q, want %q", audit.Gate, tc.wantGate)
			}
			data, err := json.Marshal(audit)
			if err != nil {
				t.Fatal(err)
			}
			var output map[string]json.RawMessage
			if err := json.Unmarshal(data, &output); err != nil {
				t.Fatal(err)
			}
			if tc.wantError != "" && !strings.Contains(string(output["inventory_error"]), tc.wantError) {
				t.Errorf("inventory_error = %s, want %q", output["inventory_error"], tc.wantError)
			}
			if tc.wantError == "" && output["inventory_error"] != nil {
				t.Errorf("unexpected inventory_error: %s", output["inventory_error"])
			}
			if tc.lateLabel && (len(audit.Orphans) != 1 || audit.Orphans[0].Label != "dev_later" || audit.Orphans[0].ID != tc.ids) {
				t.Errorf("orphans = %+v", audit.Orphans)
			}
		})
	}
}
