package cmd

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/anthropics/ai-party/tools/party-cli/internal/agent"
	"github.com/anthropics/ai-party/tools/party-cli/internal/picker"
	"github.com/anthropics/ai-party/tools/party-cli/internal/session"
	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
	"github.com/spf13/cobra"
)

func newPickerCmd(store *state.Store, client *tmux.Client, repoRoot string) *cobra.Command {
	cmd := &cobra.Command{
		Use:   "picker",
		Short: "Interactive session picker",
		Long: `Launch an interactive session picker.

Select a session with Enter to resume/attach, or press Ctrl-D to delete.
Navigate with j/k or arrow keys. Press n for a new session, or m (N alias) for a master session.`,
		RunE: func(cmd *cobra.Command, _ []string) error {
			return runPicker(cmd, store, client, repoRoot)
		},
	}

	return cmd
}

func runPicker(cmd *cobra.Command, store *state.Store, client *tmux.Client, repoRoot string) error {
	ctx := cmd.Context()
	entries, err := picker.BuildEntries(ctx, store, client)
	if err != nil {
		return err
	}
	currentSession, _ := client.CurrentSessionName(ctx)
	tmuxEntries, err := picker.BuildTmuxEntries(ctx, client, currentSession)
	if err != nil {
		return err
	}
	cfg, err := agent.LoadConfig(nil)
	if err != nil {
		return err
	}
	registry, err := agent.NewRegistry(cfg)
	if err != nil {
		return err
	}
	agentOpts := picker.AgentOptions{
		Available:      registry.Names(),
		DefaultPrimary: cfg.Roles.Primary.Agent,
	}
	if cfg.Roles.Companion != nil {
		agentOpts.DefaultCompanion = cfg.Roles.Companion.Agent
	}

	svc := session.NewService(store, client, repoRoot, registry)
	deleteFn := func(ctx context.Context, sessionID string) error {
		if strings.HasPrefix(sessionID, "party-") {
			return svc.Delete(ctx, sessionID)
		}
		return client.KillSession(ctx, sessionID)
	}
	startFn := func(ctx context.Context, title, cwd string, opts picker.CreateStartOptions) (string, error) {
		overrides := &agent.ConfigOverrides{Primary: opts.Primary}
		if opts.NoCompanion {
			overrides.NoCompanion = true
		} else if opts.Companion != "" {
			overrides.Companion = opts.Companion
		}
		if overrides.Primary == "" && overrides.Companion == "" && !overrides.NoCompanion {
			overrides = nil
		}

		startRegistry, err := loadSessionRegistryWithOverrides(overrides)
		if err != nil {
			return "", err
		}

		startSvc := session.NewService(store, client, repoRoot, startRegistry)
		res, err := startSvc.Start(ctx, session.StartOpts{
			Title:            title,
			Cwd:              cwd,
			Master:           opts.Master,
			IncludeCompanion: opts.Master && !opts.NoCompanion,
		})
		if err != nil {
			return "", err
		}
		return res.SessionID, nil
	}
	tmuxStartFn := func(ctx context.Context, name, cwd string) (string, error) {
		if name == "" {
			name = fmt.Sprintf("s%d", os.Getpid())
		}
		if cwd == "" {
			cwd, _ = os.Getwd()
		}
		err := client.NewSession(ctx, name, "main", cwd)
		if err != nil {
			return "", err
		}
		return name, nil
	}
	m := picker.NewModel(ctx, entries, tmuxEntries, store, client, deleteFn, startFn, tmuxStartFn, agentOpts)

	p := tea.NewProgram(m, tea.WithAltScreen())
	result, err := p.Run()
	if err != nil {
		return fmt.Errorf("picker: %w", err)
	}

	target := result.(picker.Model).Selected()
	if target == "" {
		return nil
	}

	alive, _ := client.HasSession(ctx, target)
	w := cmd.OutOrStdout()

	if alive {
		fmt.Fprintf(w, "Attaching to %s...\n", target)
		return attachSession(ctx, client, target)
	}

	// Only party sessions can be resumed from a stale state.
	if !strings.HasPrefix(target, "party-") {
		return nil
	}

	res, err := svc.Continue(ctx, target)
	if err != nil {
		return fmt.Errorf("continue %s: %w", target, err)
	}
	if res.Reattach {
		fmt.Fprintf(w, "Attaching to %s...\n", target)
	} else {
		fmt.Fprintf(w, "Resumed %s.\n", target)
	}
	return attachSession(ctx, client, target)
}

// attachSession switches to the named tmux session.
func attachSession(ctx context.Context, client *tmux.Client, sessionID string) error {
	if os.Getenv("TMUX") != "" {
		return client.SwitchClientWithFallback(ctx, sessionID)
	}
	cmd := exec.Command("tmux", "attach-session", "-t", sessionID)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}
