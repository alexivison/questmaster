package cmd

import (
	"context"
	"fmt"
	"os"
	"os/exec"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/picker"
	"github.com/alexivison/questmaster/internal/quests/quest"
	"github.com/alexivison/questmaster/internal/session"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
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

var runPickerProgram = func(m picker.Model) (picker.Model, error) {
	p := tea.NewProgram(m, tea.WithAltScreen())
	result, err := p.Run()
	if err != nil {
		return picker.Model{}, err
	}
	return result.(picker.Model), nil
}

func runPicker(cmd *cobra.Command, store *state.Store, client *tmux.Client, repoRoot string) error {
	ctx := cmd.Context()
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

	svc := session.NewService(store, client, repoRoot, registry)
	deleteFn := func(ctx context.Context, sessionID string) error {
		return svc.Delete(ctx, sessionID)
	}
	startFn := func(ctx context.Context, title, cwd string, opts picker.CreateStartOptions) (string, error) {
		overrides := &agent.ConfigOverrides{Primary: opts.Primary}
		if overrides.Primary == "" {
			overrides = nil
		}

		startRegistry, err := loadSessionRegistryWithOverrides(overrides)
		if err != nil {
			return "", err
		}

		// A chosen quest (active-only) seeds the opening prompt and is stamped
		// after the session is created — the same attach-and-inject as
		// `qm session new --quest`.
		prompt := opts.Prompt
		if opts.QuestID != "" {
			q, err := resolveAttachableQuest(opts.QuestID)
			if err != nil {
				return "", err
			}
			prompt = seededQuestPrompt(q, prompt)
		}

		startSvc := session.NewService(store, client, repoRoot, startRegistry)
		res, err := startSvc.Start(ctx, session.StartOpts{
			Title:        title,
			Cwd:          cwd,
			Master:       opts.Master,
			DisplayColor: opts.DisplayColor,
			Prompt:       prompt,
		})
		if err != nil {
			return "", err
		}
		if opts.QuestID != "" {
			if err := state.StampQuest(res.SessionID, opts.QuestID); err != nil {
				return "", fmt.Errorf("stamp quest on %s: %w", res.SessionID, err)
			}
		}
		return res.SessionID, nil
	}
	m := picker.NewModel(ctx, entries, store, client, deleteFn, startFn, agentOpts, activeQuestChoices())

	result, err := runPickerProgram(m)
	if err != nil {
		return fmt.Errorf("picker: %w", err)
	}

	target := result.Selected()
	if target == "" {
		return nil
	}

	alive, _ := client.HasSession(ctx, target)
	w := cmd.OutOrStdout()

	if alive {
		fmt.Fprintf(w, "Attaching to %s...\n", target)
		return attachSession(ctx, client, target)
	}

	// Only questmaster sessions can be resumed from persisted state.
	if !state.IsValidSessionID(target) {
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

// activeQuestChoices lists the attachable (active) quests for the picker's
// quest-attach step. wip and done are excluded, as everywhere.
func activeQuestChoices() []picker.QuestChoice {
	quests, err := quest.DefaultStore().List()
	if err != nil {
		return nil
	}
	var out []picker.QuestChoice
	for _, q := range quests {
		if q.Status == quest.StatusActive {
			out = append(out, picker.QuestChoice{ID: q.ID, Title: q.Title})
		}
	}
	return out
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
