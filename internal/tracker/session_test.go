package tracker

import (
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
