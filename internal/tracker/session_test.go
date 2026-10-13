package tracker

import (
	"encoding/json"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
)

func TestManifestToSessionRowKeepsRawPrimaryAgentName(t *testing.T) {
	t.Parallel()

	row := ManifestToSessionRow("qm-raw-agent", state.Manifest{
		SessionID: "qm-raw-agent",
		Title:     "Raw agent",
		Agents: []state.AgentManifest{{
			Name: "future-agent",
			Role: "primary",
		}},
	}, true)

	if row.PrimaryAgent != "future-agent" {
		t.Fatalf("PrimaryAgent = %q, want raw manifest agent", row.PrimaryAgent)
	}
}

func TestManifestToSessionRowKeepsOpenCodePrimaryAgentName(t *testing.T) {
	t.Parallel()

	row := ManifestToSessionRow("qm-opencode-agent", state.Manifest{
		SessionID: "qm-opencode-agent",
		Title:     "OpenCode",
		Agents: []state.AgentManifest{{
			Name: "opencode",
			Role: "primary",
		}},
	}, true)

	if row.PrimaryAgent != "opencode" {
		t.Fatalf("PrimaryAgent = %q, want opencode", row.PrimaryAgent)
	}
}

func TestSessionTypeForManifestDerivesRoleFromAgentsAndParent(t *testing.T) {
	t.Parallel()

	agent := []state.AgentManifest{{Name: "codex", Role: "primary"}}
	tests := []struct {
		name string
		m    state.Manifest
		want string
	}{
		{name: "new master", m: state.Manifest{SessionType: "master", Agents: agent}, want: "master"},
		{name: "old master", m: state.Manifest{Agents: agent}, want: "master"},
		{name: "worker", m: state.Manifest{Agents: agent, Extra: map[string]json.RawMessage{"parent_session": json.RawMessage(`"qm-master"`)}}, want: "worker"},
		{name: "parent without agent metadata", m: state.Manifest{Extra: map[string]json.RawMessage{"parent_session": json.RawMessage(`"qm-master"`)}}, want: "worker"},
		{name: "parent wins over stale type", m: state.Manifest{SessionType: "master", Agents: agent, Extra: map[string]json.RawMessage{"parent_session": json.RawMessage(`"qm-master"`)}}, want: "worker"},
		{name: "plain shell", m: state.Manifest{}, want: "shell"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			if got := SessionTypeForManifest(tt.m); got != tt.want {
				t.Fatalf("SessionTypeForManifest() = %q, want %q", got, tt.want)
			}
		})
	}
}
