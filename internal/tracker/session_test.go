package tracker

import (
	"testing"

	"github.com/alexivison/questmaster/internal/state"
)

func TestManifestToSessionRowKeepsRawAgentName(t *testing.T) {
	t.Parallel()

	row := ManifestToSessionRow("qm-raw-agent", state.Manifest{
		SessionID: "qm-raw-agent",
		Title:     "Raw agent",
		Agents: []state.AgentManifest{{
			Name: "future-agent",
			Role: "agent",
		}},
	}, true)

	if row.Agent != "future-agent" {
		t.Fatalf("Agent = %q, want raw manifest agent", row.Agent)
	}
}
