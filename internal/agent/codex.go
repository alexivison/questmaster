package agent

import (
	"fmt"
	"strconv"

	"github.com/alexivison/questmaster/internal/config"
	"github.com/alexivison/questmaster/internal/state"
)

var codexSpec = Spec{
	Name:           "codex",
	DisplayName:    "Codex",
	Description:    "reliable general-purpose coding with strong codebase navigation",
	DefaultCLI:     "codex",
	ResumeKey:      "codex_thread_id",
	ResumeFileName: "codex-thread-id",
	EnvVar:         "CODEX_THREAD_ID",
	BinaryEnvVar:   "CODEX_BIN",
	FallbackPath:   "/opt/homebrew/bin/codex",
	Filter:         filterCodex,
	Models: ModelPolicy{
		Sources: []ModelSource{{Catalog: "openai"}},
	},
}

// Codex implements the built-in Codex provider.
type Codex struct {
	base
}

// NewCodex constructs a Codex provider from config.
func NewCodex(cfg AgentConfig) *Codex {
	return &Codex{base: newBase(codexSpec, cfg)}
}

func (c *Codex) BuildCmd(opts CmdOpts) string {
	binary := opts.Binary
	if binary == "" {
		binary = c.Binary()
	}

	args := "--dangerously-bypass-approvals-and-sandbox"
	if opts.Model != "" {
		args += " --model " + config.ShellQuote(opts.Model)
	}
	if opts.ReasoningEffort != "" {
		args += " -c " + config.ShellQuote("model_reasoning_effort="+strconv.Quote(opts.ReasoningEffort))
	}
	systemPrompt := systemPromptForRole(opts.Role, c.MasterPrompt(), c.StandalonePrompt(), c.WorkerPrompt(), opts.SystemBrief)
	if systemPrompt != "" {
		args += " -c " + config.ShellQuote("developer_instructions="+strconv.Quote(systemPrompt))
	}
	if opts.ResumeID != "" {
		args += " resume " + config.ShellQuote(opts.ResumeID)
	}
	if opts.Prompt != "" {
		args += " -- " + config.ShellQuote(opts.Prompt)
	}
	quotedBinary := config.ShellQuote(binary)
	return fmt.Sprintf(`export PATH=%s
%s app-server daemon start >/dev/null 2>&1 || true
set -- %s
socket_path=""
server_pid=""
cleanup() {
	if [ -n "$server_pid" ]; then
		kill "$server_pid" 2>/dev/null
		wait "$server_pid" 2>/dev/null
	fi
	if [ -n "$socket_path" ]; then /bin/rm -f "$socket_path"; fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
if [ -n "${QUESTMASTER_SESSION:-}" ]; then
	socket_path="/tmp/${QUESTMASTER_SESSION}/%s"
	/bin/rm -f "$socket_path"
	%s app-server --listen "unix://$socket_path" >/dev/null 2>&1 &
	server_pid=$!
	attempt=0
	while [ ! -e "$socket_path" ] && kill -0 "$server_pid" 2>/dev/null && [ "$attempt" -lt 50 ]; do
		/bin/sleep 0.1
		attempt=$((attempt + 1))
	done
fi
if [ -n "$server_pid" ] && [ -e "$socket_path" ] && kill -0 "$server_pid" 2>/dev/null; then
	%s --remote "unix://$socket_path" "$@"
else
	if [ -n "$server_pid" ]; then
		kill "$server_pid" 2>/dev/null
		wait "$server_pid" 2>/dev/null
		server_pid=""
	fi
	%s "$@"
fi
status=$?
exit "$status"`,
		config.ShellQuote(opts.AgentPath), quotedBinary, args, state.CodexAppServerSocketName, quotedBinary, quotedBinary, quotedBinary)
}
