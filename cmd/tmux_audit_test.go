package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxroute"
)

type auditRunner func(context.Context, ...string) (string, error)

func (f auditRunner) Run(ctx context.Context, args ...string) (string, error) { return f(ctx, args...) }

func TestTmuxAuditGateUnknownWhenServerUnavailable(t *testing.T) {
	store := state.OpenStore(t.TempDir())
	router := tmuxroute.New(store, map[string]*tmux.Client{
		"default": tmux.NewClient(auditRunner(func(context.Context, ...string) (string, error) {
			return "", &tmux.ExitError{Code: 1, Stderr: "no server running"}
		})),
		"questmaster": tmux.NewClient(auditRunner(func(context.Context, ...string) (string, error) { return "", context.DeadlineExceeded })),
	}, func() string { return "default" }, nil)
	audit, err := router.Audit(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if audit.Gate != "unknown" {
		t.Fatalf("gate = %q", audit.Gate)
	}
	var output bytes.Buffer
	cmd := NewRootCmd(WithDeps(store, tmux.NewClient(auditRunner(func(context.Context, ...string) (string, error) { return "", nil }))), WithTmuxRouter(router))
	cmd.SetOut(&output)
	cmd.SetArgs([]string{"tmux", "audit"})
	if err := cmd.Execute(); err != nil {
		t.Fatal(err)
	}
	var result struct {
		Gate string `json:"gate"`
	}
	if err := json.Unmarshal(output.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if result.Gate != "unknown" {
		t.Fatalf("CLI gate = %q", result.Gate)
	}
	want, err := os.ReadFile(filepath.Join("testdata", "tmux-audit-unavailable.json"))
	if err != nil {
		t.Fatal(err)
	}
	var got bytes.Buffer
	if err := json.Indent(&got, bytes.TrimSpace(output.Bytes()), "", "  "); err != nil {
		t.Fatal(err)
	}
	got.WriteByte('\n')
	if !bytes.Equal(got.Bytes(), want) {
		t.Fatalf("audit JSON =\n%s\nwant:\n%s", got.Bytes(), want)
	}
}

func TestTmuxRoutesCLI(t *testing.T) {
	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Create(state.Manifest{TmuxServer: "dev_previous", SessionID: "qm-example", CreatedAt: "2026-01-01T00:00:00Z"}); err != nil {
		t.Fatal(err)
	}
	defaultClient := tmux.NewClient(auditRunner(func(context.Context, ...string) (string, error) { return "qm-example", nil }))
	router := tmuxroute.New(store, map[string]*tmux.Client{"dev_previous": defaultClient, "questmaster": tmux.NewClient(auditRunner(func(context.Context, ...string) (string, error) {
		return "", &tmux.ExitError{Code: 1, Stderr: "no server running"}
	}))}, func() string { return "dev_previous" }, nil)
	var output bytes.Buffer
	cmd := NewRootCmd(WithDeps(store, defaultClient), WithTmuxRouter(router))
	cmd.SetOut(&output)
	cmd.SetArgs([]string{"tmux", "routes", "--live"})
	if err := cmd.Execute(); err != nil {
		t.Fatal(err)
	}
	var routes []tmuxroute.RouteRecord
	if err := json.Unmarshal(output.Bytes(), &routes); err != nil {
		t.Fatal(err)
	}
	if len(routes) != 1 || routes[0].SessionID != "qm-example" || routes[0].Server != "dev_previous" || !routes[0].Live {
		t.Fatalf("routes = %+v", routes)
	}
}
