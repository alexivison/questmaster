package agent

import (
	"context"
	"os"
	"time"
)

// ActivityWindow is how recently an agent's session transcript must have
// been written for IsActive to return true. Each transcript-appended JSON
// event (message delta, tool call, tool result) bumps the file's mtime,
// so the window captures "agent produced output in the last N seconds".
const ActivityWindow = 5 * time.Second

// transcriptActive is a helper for agent implementations: returns true
// when path is non-empty and its mtime is within ActivityWindow of now.
// Missing files and stat errors are swallowed and return false — a
// nonexistent transcript means the agent hasn't started writing yet.
func transcriptActive(path string) (bool, error) {
	if path == "" {
		return false, nil
	}
	info, err := os.Stat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, err
	}
	return time.Since(info.ModTime()) < ActivityWindow, nil
}

// TmuxClient is the subset of tmux.Client used by agent providers.
type TmuxClient interface {
	UnsetEnvironment(ctx context.Context, session, key string) error
}

// Agent represents any CLI coding agent that can run in a tmux pane.
type Agent interface {
	Name() string
	DisplayName() string
	Binary() string

	BuildCmd(opts CmdOpts) string
	ResumeKey() string
	ResumeFileName() string
	EnvVar() string
	MasterPrompt() string

	FilterPaneLines(raw string, max int) []string

	// IsActive reports whether the agent identified by (cwd, resumeID) is
	// currently producing output. Each implementation owns the heuristic
	// — typically an mtime check on a live session transcript the agent
	// itself appends to. Returns false (no error) when the agent exposes
	// no observable signal or has not yet written anything.
	IsActive(cwd, resumeID string) (bool, error)

	PreLaunchSetup(ctx context.Context, client TmuxClient, session string) error
	BinaryEnvVar() string
	FallbackPath() string
}

// CmdOpts controls agent launch command construction.
type CmdOpts struct {
	Binary    string
	AgentPath string
	ResumeID  string
	Prompt    string
	Title     string
	Master    bool
}
