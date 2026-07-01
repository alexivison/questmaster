package agent

import (
	"fmt"

	"github.com/alexivison/questmaster/internal/config"
)

// piWorkerModel / piMasterModel route pi off its default google provider onto an
// openai tier per role: worker = cheap, non-worker (master AND standalone) =
// gpt-5.5 to match codex master. Canonical provider/id form: pi resolves both
// "openai/..." and "openai-codex/...", but the canonical id keeps pi consistent
// with omp (which accepts only the canonical form). Every role requests
// `--thinking xhigh`. (openai-codex routing needs openai creds configured for pi.)
const (
	piWorkerModel = "openai-codex/gpt-5.4"
	piMasterModel = "openai-codex/gpt-5.5"
)

var piSpec = Spec{
	Name:           "pi",
	DisplayName:    "Pi",
	Description:    "lightweight and fast; good for small, well-scoped tasks",
	DefaultCLI:     "pi",
	ResumeKey:      "pi_session_id",
	ResumeFileName: "pi-session-id",
	EnvVar:         "PI_SESSION_ID",
	BinaryEnvVar:   "PI_BIN",
	FallbackPath:   "/opt/homebrew/bin/pi",
	State:          StateSidecar,
}

// Pi implements the built-in Pi provider.
//
// Structured Pi read output is handled by internal/message via hook state;
// FilterPaneLines remains the generic fallback for other callers.
type Pi struct {
	base
}

// NewPi constructs a Pi provider from config.
func NewPi(cfg AgentConfig) *Pi {
	return &Pi{base: newBase(piSpec, cfg)}
}

func (p *Pi) BuildCmd(opts CmdOpts) string {
	binary := opts.Binary
	if binary == "" {
		binary = p.Binary()
	}

	cmd := fmt.Sprintf("export PATH=%s; exec %s",
		config.ShellQuote(opts.AgentPath), config.ShellQuote(binary))
	systemPrompt := systemPromptForRole(opts.Role, p.MasterPrompt(), p.StandalonePrompt(), p.WorkerPrompt(), opts.SystemBrief)
	if systemPrompt != "" {
		cmd += " --append-system-prompt " + config.ShellQuote(systemPrompt)
	}
	if opts.Role == RoleMaster && opts.SystemBrief != "" {
		cmd += " --append-system-prompt " + config.ShellQuote(opts.SystemBrief)
	}
	if model := resolveModel(opts, piWorkerModel, piMasterModel); model != "" {
		cmd += " --model " + config.ShellQuote(model)
	}
	// All roles now run at xhigh (worker/master/standalone all pinned above).
	cmd += " --thinking xhigh"
	if opts.ResumeID != "" {
		cmd += " --session " + config.ShellQuote(opts.ResumeID)
	}
	if opts.Prompt != "" {
		cmd += " " + config.ShellQuote(opts.Prompt)
	}
	return cmd
}
