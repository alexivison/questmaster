package main

import (
	"context"
	"fmt"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/picker"
	"github.com/alexivison/questmaster/internal/session"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/spf13/cobra"
)

// newPickerCmd is the Quests session picker — the questmaster picker reused
// under the Quests namespace. Bind it to `prefix+p` in tmux for a fast
// spawn/jump that matches questmaster's muscle memory.
func newPickerCmd(e *env) *cobra.Command {
	return &cobra.Command{
		Use:   "picker",
		Short: "Interactive session picker (spawn / resume / jump)",
		Long: `Launch the interactive session picker under the Quests namespace.

Enter resumes/attaches a session; n creates a new one (m/N for a master);
Ctrl-D deletes. Bind to prefix+p in your tmux.conf for questmaster-style spawn.`,
		RunE: func(cmd *cobra.Command, _ []string) error {
			return e.runPicker(cmd)
		},
	}
}

// runPickerProgram is overridable in tests.
var runPickerProgram = func(m picker.Model) (picker.Model, error) {
	p := tea.NewProgram(m, tea.WithAltScreen())
	result, err := p.Run()
	if err != nil {
		return picker.Model{}, err
	}
	return result.(picker.Model), nil
}

func (e *env) runPicker(cmd *cobra.Command) error {
	ctx := cmd.Context()
	store, err := state.NewStore(e.paths.StateRoot())
	if err != nil {
		return err
	}
	client := tmux.NewExecClient()

	entries, err := picker.BuildEntries(ctx, store, client)
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

	svc := newQuestsService(store, client, registry)
	deleteFn := func(ctx context.Context, sessionID string) error {
		return svc.Delete(ctx, sessionID)
	}
	startFn := func(ctx context.Context, title, cwd string, opts picker.CreateStartOptions) (string, error) {
		var overrides *agent.ConfigOverrides
		if opts.Primary != "" {
			overrides = &agent.ConfigOverrides{Primary: opts.Primary}
		}
		startCfg, cerr := agent.LoadConfig(overrides)
		if cerr != nil {
			return "", cerr
		}
		startRegistry, cerr := agent.NewRegistry(startCfg)
		if cerr != nil {
			return "", cerr
		}
		startSvc := newQuestsService(store, client, startRegistry)
		res, serr := startSvc.Start(ctx, session.StartOpts{
			Title:        title,
			Cwd:          cwd,
			Master:       opts.Master,
			DisplayColor: opts.DisplayColor,
			Prompt:       opts.Prompt,
		})
		if serr != nil {
			return "", serr
		}
		return res.SessionID, nil
	}

	m := picker.NewModel(ctx, entries, store, client, deleteFn, startFn, agentOpts)
	result, err := runPickerProgram(m)
	if err != nil {
		return fmt.Errorf("picker: %w", err)
	}

	target := result.Selected()
	if target == "" {
		return nil
	}

	w := cmd.OutOrStdout()
	if alive, _ := client.HasSession(ctx, target); alive {
		fmt.Fprintf(w, "Attaching to %s...\n", target)
		return attachTo(target)
	}
	if !state.IsValidSessionID(target) {
		return nil
	}
	if _, err := svc.Continue(ctx, target); err != nil {
		return fmt.Errorf("continue %s: %w", target, err)
	}
	fmt.Fprintf(w, "Attaching to %s...\n", target)
	return attachTo(target)
}

// newQuestsService builds a session.Service whose sidebar pane launches the
// `quests` binary (not questmaster).
func newQuestsService(store *state.Store, client *tmux.Client, registry *agent.Registry) *session.Service {
	svc := session.NewService(store, client, repoRoot(), registry)
	svc.CLIResolver = resolveQuestsCmd
	return svc
}
