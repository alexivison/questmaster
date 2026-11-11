package serve

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmux/tmuxtest"
	"github.com/alexivison/questmaster/internal/tmuxconfig"
	"github.com/alexivison/questmaster/internal/tmuxroute"
)

func TestServeTmuxConfigGoldens(t *testing.T) {
	root := t.TempDir()
	t.Setenv("HOME", t.TempDir())
	t.Setenv("QUESTMASTER_STATE_ROOT", root)
	t.Setenv("QUESTMASTER_TMUX_LABEL", "dev_1")
	tmuxtest.StubQuestmaster(t)
	if err := tmuxconfig.Prepare(root); err != nil {
		t.Fatal(err)
	}
	store := state.OpenStore(root)
	runner := routeRunner(func(_ context.Context, args ...string) (string, error) {
		switch args[0] {
		case "display-message":
			return "100|1", nil
		case "show-options":
			if args[len(args)-1] == "@questmaster_root" {
				return tmuxconfig.RootMarker(root, "dev_1"), nil
			}
			return "1", nil
		case "if-shell":
			return "1", nil
		case "source-file":
			return "", nil
		default:
			t.Fatalf("unexpected tmux call: %v", args)
			return "", nil
		}
	})
	router := tmuxroute.New(store, map[string]*tmux.Client{"dev_1": tmux.NewClient(runner)}, func() string { return "dev_1" }, nil)
	srv := &Server{Snapshotter: &Snapshotter{store: store}, TmuxRouter: router}
	for _, tc := range []struct{ method, id, golden string }{
		{"tmux.config", "tmux-config-request", "tmux_config_response_envelope.json"},
		{"tmux.config.reload", "tmux-config-reload-request", "tmux_config_reload_response_envelope.json"},
		{"tmux.server.restart", "tmux-server-restart-request", "tmux_server_restart_response_envelope.json"},
	} {
		response := srv.HandleRequest(t.Context(), Request{ID: json.RawMessage(`"` + tc.id + `"`), Method: tc.method})
		if response.OK == nil || !*response.OK || response.Topic != tc.method {
			t.Fatalf("%s response: %+v", tc.method, response)
		}
		if status, ok := response.Data.(tmuxconfig.StatusResult); ok {
			if status.Config != filepath.Join(root, "tmux", "questmaster.conf") || status.Enforced != filepath.Join(root, "tmux", "enforced.dev_1.conf") || status.EffectiveLabel != "dev_1" {
				t.Fatalf("wrong config route: %+v", status)
			}
			status.Config = "/tmp/example/tmux/questmaster.conf"
			status.Enforced = "/tmp/example/tmux/enforced.questmaster.conf"
			status.EffectiveLabel = "questmaster"
			response.Data = status
		}
		response.ProtocolVersion = ServeProtocolVersion
		assertContractGolden(t, tc.golden, marshalContractFixture(t, response))
	}
	for _, name := range []string{
		"tmux_config_request.json", "tmux_config_response_envelope.json",
		"tmux_config_check_request.json", "tmux_config_check_response_envelope.json",
		"tmux_config_reload_request.json", "tmux_config_reload_response_envelope.json",
		"tmux_server_restart_request.json", "tmux_server_restart_response_envelope.json",
	} {
		found := false
		for _, fixture := range serveContractFixtures() {
			if fixture.name == name {
				assertContractGolden(t, name, marshalContractFixture(t, fixture.value))
				found = true
				break
			}
		}
		if !found {
			t.Fatalf("missing contract fixture %s", name)
		}
	}
}

func TestIntegrationServeTmuxConfigCheck(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	root := t.TempDir()
	t.Setenv("HOME", t.TempDir())
	t.Setenv("QUESTMASTER_STATE_ROOT", root)
	t.Setenv("QUESTMASTER_TMUX_LABEL", "dev_1")
	tmuxtest.StubQuestmaster(t)
	if err := tmuxconfig.Prepare(root); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(tmuxconfig.Paths(root).Config, []byte("invalid-tmux-command\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	srv := &Server{Snapshotter: &Snapshotter{store: state.OpenStore(root)}}
	response := srv.HandleRequest(t.Context(), Request{Method: "tmux.config.check"})
	if response.OK == nil || !*response.OK {
		t.Fatalf("check response: %+v", response)
	}
	result, ok := response.Data.(tmuxconfig.CheckResult)
	if !ok || result.OK || len(result.Errors) == 0 || result.EffectiveLabel != "dev_1" {
		t.Fatalf("check result: %+v", response.Data)
	}
}
