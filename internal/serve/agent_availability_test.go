//go:build linux || darwin

package serve

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/modelsuggest"
	"github.com/alexivison/questmaster/internal/state"
)

func TestAgentAvailabilityReadReturnsOrderedSettingsAndToleratesCorruptRoleDefaults(t *testing.T) {
	env := seedServeFixture(t)
	availability := state.NewAgentAvailabilityStore(env.store.Root())
	if err := availability.Set("codex", false); err != nil {
		t.Fatalf("disable codex: %v", err)
	}
	roleDefaults := state.NewRoleDefaultsStore(env.store.Root())
	if err := roleDefaults.Set("claude", "master", state.RoleDefault{Model: "opus", ReasoningEffort: "high"}); err != nil {
		t.Fatalf("set Claude master default: %v", err)
	}
	if err := roleDefaults.Set("pi", "worker", state.RoleDefault{Model: "anthropic/sonnet", ReasoningEffort: "medium"}); err != nil {
		t.Fatalf("set Pi worker default: %v", err)
	}
	srv := &Server{Snapshotter: testSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now })}

	response := srv.HandleRequest(context.Background(), Request{Method: "agent_availability"})
	if response.OK == nil || !*response.OK {
		t.Fatalf("agent_availability response = %+v", response)
	}
	var got struct {
		Agents []struct {
			Name     string `json:"name"`
			Enabled  bool   `json:"enabled"`
			Defaults map[string]struct {
				Model           string `json:"model"`
				ReasoningEffort string `json:"reasoning_effort"`
			} `json:"defaults"`
		} `json:"agents"`
	}
	if data, err := json.Marshal(response.Data); err != nil {
		t.Fatalf("marshal availability response: %v", err)
	} else if err := json.Unmarshal(data, &got); err != nil {
		t.Fatalf("decode availability response: %v", err)
	}
	if len(got.Agents) != len(agent.Names()) {
		t.Fatalf("agent count = %d, want %d", len(got.Agents), len(agent.Names()))
	}
	names := make([]string, 0, len(got.Agents))
	for _, entry := range got.Agents {
		names = append(names, entry.Name)
		if entry.Name == "codex" && entry.Enabled {
			t.Fatal("codex enabled = true, want saved false")
		}
		if entry.Name != "codex" && !entry.Enabled {
			t.Fatalf("%s enabled = false, want default true", entry.Name)
		}
		if entry.Defaults == nil {
			t.Fatalf("%s defaults = nil, want an object", entry.Name)
		}
	}
	if !slices.Equal(names, agent.Names()) {
		t.Fatalf("agent order = %v, want %v", names, agent.Names())
	}
	if got.Agents[0].Defaults["master"].Model != "opus" || got.Agents[0].Defaults["master"].ReasoningEffort != "high" {
		t.Fatalf("claude defaults = %+v, want opus/high", got.Agents[0].Defaults)
	}
	if got.Agents[3].Defaults["worker"].Model != "anthropic/sonnet" || got.Agents[3].Defaults["worker"].ReasoningEffort != "medium" {
		t.Fatalf("Pi defaults = %+v, want anthropic/sonnet/medium", got.Agents[3].Defaults)
	}
	if len(got.Agents[1].Defaults) != 0 {
		t.Fatalf("codex defaults = %+v, want empty object", got.Agents[1].Defaults)
	}

	if err := os.WriteFile(filepath.Join(env.store.Root(), state.RoleDefaultsFile), []byte("not json"), 0o600); err != nil {
		t.Fatalf("corrupt role defaults: %v", err)
	}
	response = srv.HandleRequest(context.Background(), Request{Method: "agent_availability"})
	if response.OK == nil || !*response.OK {
		t.Fatalf("agent_availability with corrupt role defaults = %+v", response)
	}
}

func TestAgentAvailabilitySetRequiresStringValueAndPreservesRoleDefaults(t *testing.T) {
	env := seedServeFixture(t)
	defaults := state.NewRoleDefaultsStore(env.store.Root())
	if err := defaults.Set("claude", "master", state.RoleDefault{Model: "opus", ReasoningEffort: "high"}); err != nil {
		t.Fatalf("set role default: %v", err)
	}
	srv := &Server{Snapshotter: testSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now })}

	for _, name := range agent.Names() {
		reply := sendAgentAvailabilityMutation(t, srv, map[string]any{"agent": name, "enabled": "false"})
		if reply.OK == nil || !*reply.OK {
			t.Fatalf("disable %s: %+v", name, reply)
		}
	}
	response := sendAgentAvailabilityMutation(t, srv, map[string]any{"agent": "claude", "enabled": "true"})
	if response.OK == nil || !*response.OK {
		t.Fatalf("re-enable claude: %+v", response)
	}
	encoded, err := json.Marshal(response.Data)
	if err != nil {
		t.Fatalf("marshal mutation data: %v", err)
	}
	var mutation map[string]any
	if err := json.Unmarshal(encoded, &mutation); err != nil {
		t.Fatalf("decode mutation data: %v", err)
	}
	if mutation["agent"] != "claude" || mutation["enabled"] != true {
		t.Fatalf("agent_availability.set data = %#v, want claude/true", mutation)
	}

	settings, err := state.NewAgentAvailabilityStore(env.store.Root()).Load()
	if err != nil {
		t.Fatalf("load availability: %v", err)
	}
	if settings["claude"] != true || settings["codex"] || settings["opencode"] || settings["pi"] {
		t.Fatalf("availability settings = %v, want only claude enabled", settings)
	}
	def, ok, err := defaults.Get("claude", "master")
	if err != nil || !ok || def.Model != "opus" || def.ReasoningEffort != "high" {
		t.Fatalf("role default after toggle = %+v ok=%v err=%v", def, ok, err)
	}

	for _, data := range []map[string]any{
		{"agent": "claude"},
		{"agent": "claude", "enabled": "TRUE"},
		{"agent": "claude", "enabled": true},
		{"agent": "stub", "enabled": "false"},
	} {
		bad := sendAgentAvailabilityMutation(t, srv, data)
		if bad.OK == nil || *bad.OK || strings.TrimSpace(bad.Error) == "" {
			t.Errorf("invalid agent_availability.set data %#v = %+v, want validation error", data, bad)
		}
	}
}

func TestDisabledSuggestionsAndRoleDefaultEditsStopBeforeProbes(t *testing.T) {
	env := seedServeFixture(t)
	if err := state.NewAgentAvailabilityStore(env.store.Root()).Set("opencode", false); err != nil {
		t.Fatalf("disable opencode: %v", err)
	}
	if err := state.NewAgentAvailabilityStore(env.store.Root()).Set("claude", false); err != nil {
		t.Fatalf("disable claude: %v", err)
	}
	t.Setenv(modelsuggest.CatalogURLEnv, "off")
	marker := filepath.Join(t.TempDir(), "opencode-probed")
	binary := filepath.Join(t.TempDir(), "opencode")
	script := "#!/bin/sh\nprintf called > " + shellQuote(marker) + "\n"
	if err := os.WriteFile(binary, []byte(script), 0o700); err != nil {
		t.Fatalf("write OpenCode probe fixture: %v", err)
	}
	t.Setenv("OPENCODE_BIN", binary)
	reasoningCalls := 0
	srv := &Server{
		Snapshotter: testSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now }),
		ReasoningEfforts: func(context.Context, string, string) []string {
			reasoningCalls++
			return []string{"low"}
		},
	}

	models := srv.HandleRequest(context.Background(), Request{
		Method: "models",
		Data:   rawJSON(t, map[string]any{"agent": "opencode", "role": "master"}),
	})
	if models.OK == nil || *models.OK || !strings.Contains(models.Error, "disabled") {
		t.Fatalf("disabled models response = %+v, want disabled error", models)
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatalf("OpenCode model probe marker stat = %v, want no probe", err)
	}

	efforts := srv.HandleRequest(context.Background(), Request{
		Method: "reasoning_efforts",
		Data:   rawJSON(t, map[string]any{"agent": "claude", "role": "master", "model": "opus"}),
	})
	if efforts.OK == nil || *efforts.OK || !strings.Contains(efforts.Error, "disabled") {
		t.Fatalf("disabled reasoning_efforts response = %+v, want disabled error", efforts)
	}

	roleDefault := srv.HandleRequest(context.Background(), Request{
		Method: "role_default.set",
		Data:   rawJSON(t, map[string]any{"agent": "claude", "role": "master", "model": "opus", "reasoning_effort": "low"}),
	})
	if roleDefault.OK == nil || *roleDefault.OK || !strings.Contains(roleDefault.Error, "disabled") {
		t.Fatalf("disabled role_default.set response = %+v, want disabled error", roleDefault)
	}
	if reasoningCalls != 0 {
		t.Fatalf("reasoning probe calls = %d, want none", reasoningCalls)
	}
}

func sendAgentAvailabilityMutation(t *testing.T, srv *Server, data map[string]any) Envelope {
	t.Helper()
	return srv.HandleRequest(context.Background(), Request{Method: "agent_availability.set", Data: rawJSON(t, data)})
}

func rawJSON(t *testing.T, value any) json.RawMessage {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatalf("marshal request data: %v", err)
	}
	return data
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}
