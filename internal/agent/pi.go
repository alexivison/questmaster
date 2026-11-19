package agent

import (
	"fmt"
	"strings"

	"github.com/alexivison/questmaster/internal/config"
)

var piSpec = Spec{
	Name:           "pi",
	DisplayName:    "Pi",
	DefaultCLI:     "pi",
	ResumeKey:      "pi_session_id",
	ResumeFileName: "pi-session-id",
	EnvVar:         "PI_SESSION_ID",
	BinaryEnvVar:   "PI_BIN",
	FallbackPath:   "/opt/homebrew/bin/pi",
	State:          StateSidecar,
	Efforts:        EffortSourcePiHelp,
	Models: ModelPolicy{
		// Pi owns provider authorization and its model inventory.
		Native: ModelListPi,
	},
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

// BuildCmd launches Pi with the Questmaster extension (-e), the session identity
// the extension reads from its environment, and the session name (--name).
func (p *Pi) BuildCmd(opts CmdOpts) string {
	binary := opts.Binary
	if binary == "" {
		binary = p.Binary()
	}

	cmd := fmt.Sprintf("export PATH=%s; %s; exec %s",
		config.ShellQuote(opts.AgentPath), piIdentityExports(opts), config.ShellQuote(binary))
	if opts.PiExtension != "" {
		cmd += " -e " + config.ShellQuote(opts.PiExtension)
	}
	if opts.Title != "" {
		cmd += " --name " + config.ShellQuote(opts.Title)
	}
	systemPrompt := systemPromptForRole(opts.Role, opts.Class, p.MasterPrompt(), p.WorkerPrompt(), opts.SystemBrief)
	if systemPrompt != "" {
		cmd += " --append-system-prompt " + config.ShellQuote(systemPrompt)
	}
	if opts.Role == RoleMaster && opts.SystemBrief != "" {
		cmd += " --append-system-prompt " + config.ShellQuote(opts.SystemBrief)
	}
	if opts.Model != "" {
		cmd += " --model " + config.ShellQuote(opts.Model)
	}
	if opts.ReasoningEffort != "" {
		cmd += " --thinking " + config.ShellQuote(opts.ReasoningEffort)
	}
	if opts.ResumeID != "" {
		cmd += " --session " + config.ShellQuote(opts.ResumeID)
	}
	if opts.Prompt != "" {
		cmd += " " + config.ShellQuote(opts.Prompt)
	}
	return cmd
}

// piIdentityExports returns one export statement with the session identity for
// the Pi extension. The variable names are the contract the extension reads at
// startup. QUESTMASTER_ROLE is always set; the others only when known.
func piIdentityExports(opts CmdOpts) string {
	role := "master"
	if opts.Role == RoleWorker {
		role = "worker"
	}
	assignments := []string{"QUESTMASTER_ROLE=" + config.ShellQuote(role)}
	if opts.Title != "" {
		assignments = append(assignments, "QUESTMASTER_TITLE="+config.ShellQuote(opts.Title))
	}
	if opts.Class != "" {
		assignments = append(assignments, "QUESTMASTER_CLASS="+config.ShellQuote(opts.Class))
	}
	if opts.MasterClass != "" {
		assignments = append(assignments, "QUESTMASTER_MASTER_CLASS="+config.ShellQuote(opts.MasterClass))
	}
	return "export " + strings.Join(assignments, " ")
}
