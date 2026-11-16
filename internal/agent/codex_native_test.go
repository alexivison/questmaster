package agent

import (
	"strings"
	"testing"
)

func TestCodexNativeCommandKeepsSessionSettings(t *testing.T) {
	t.Parallel()
	provider := NewCodex(AgentConfig{})
	opts := CmdOpts{Binary: "/bin/codex", LauncherBinary: "/bin/qm", AgentPath: "/bin", CodexNative: true, Model: "example-model", ReasoningEffort: "high", Role: RoleWorker, SystemBrief: "stay in this worktree", ResumeID: "example-thread", Prompt: "check the result"}
	got := provider.BuildCmd(opts)
	for _, part := range []string{"exec '/bin/qm' agent codex --binary '/bin/codex'", `--config 'model="example-model"'`, `--config 'model_reasoning_effort="high"'`, `--config 'approval_policy="never"'`, `--config 'sandbox_mode="danger-full-access"'`, " -- resume 'example-thread' -- 'check the result'", "stay in this worktree"} {
		if !strings.Contains(got, part) {
			t.Fatalf("missing %q in %s", part, got)
		}
	}
	if !strings.Contains(got, "--config 'developer_instructions=") {
		t.Fatal("developer prompt absent")
	}
	opts.CodexNative = false
	if legacy := provider.BuildCmd(opts); strings.Contains(legacy, "agent codex") || !strings.Contains(legacy, "--dangerously-bypass-approvals-and-sandbox") {
		t.Fatalf("legacy command changed: %s", legacy)
	}
}
