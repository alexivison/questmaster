package cmd

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/picker"
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

const (
	pickerPopupEnv       = "QUESTMASTER_PICKER_POPUP"
	pickerPopupWidthPct  = 60
	pickerPopupHeightPct = 80
)

type pickerPopupPlanInput struct {
	TMUX       string
	PopupEnv   string
	Target     string
	Executable string
	RepoRoot   string
	StateRoot  string
}

type pickerPopupPlan struct {
	Launch bool
	Args   []string
}

func runPicker(cmd *cobra.Command, store *state.Store, client *tmux.Client, repoRoot string) error {
	ctx := cmd.Context()
	plan, err := currentPickerPopupPlan(ctx, store, client, repoRoot)
	if err != nil {
		return err
	}
	if plan.Launch {
		if _, err := client.RunBatch(ctx, plan.Args); err != nil {
			return fmt.Errorf("picker popup: %w", err)
		}
		return nil
	}

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

		startSvc := session.NewService(store, client, repoRoot, startRegistry)
		res, err := startSvc.Start(ctx, session.StartOpts{
			Title:        title,
			Cwd:          cwd,
			Master:       opts.Master,
			DisplayColor: opts.DisplayColor,
			Prompt:       opts.Prompt,
		})
		if err != nil {
			return "", err
		}
		return res.SessionID, nil
	}
	m := picker.NewModel(ctx, entries, store, client, deleteFn, startFn, agentOpts)

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

func currentPickerPopupPlan(ctx context.Context, store *state.Store, client *tmux.Client, repoRoot string) (pickerPopupPlan, error) {
	input := pickerPopupPlanInput{
		TMUX:     os.Getenv("TMUX"),
		PopupEnv: os.Getenv(pickerPopupEnv),
		Target:   os.Getenv("TMUX_PANE"),
		RepoRoot: repoRoot,
	}
	if store != nil {
		input.StateRoot = store.Root()
	}
	if input.TMUX != "" && input.PopupEnv == "" {
		if input.Target == "" {
			target, err := client.CurrentSessionName(ctx)
			if err != nil {
				return pickerPopupPlan{}, fmt.Errorf("picker popup target: %w", err)
			}
			input.Target = strings.TrimSpace(target)
		}
		exe, err := os.Executable()
		if err != nil {
			return pickerPopupPlan{}, fmt.Errorf("questmaster executable: %w", err)
		}
		input.Executable = exe
	}
	return buildPickerPopupPlan(input)
}

func buildPickerPopupPlan(input pickerPopupPlanInput) (pickerPopupPlan, error) {
	if input.TMUX == "" || input.PopupEnv != "" {
		return pickerPopupPlan{}, nil
	}
	if input.Target == "" {
		return pickerPopupPlan{}, fmt.Errorf("picker popup target is empty")
	}
	if input.Executable == "" {
		return pickerPopupPlan{}, fmt.Errorf("questmaster executable is empty")
	}
	return pickerPopupPlan{
		Launch: true,
		Args: tmux.PopupArgs(
			input.Target,
			pickerPopupWidthPct,
			pickerPopupHeightPct,
			buildPickerPopupEnv(input),
			input.Executable,
			"picker",
		),
	}, nil
}

func buildPickerPopupEnv(input pickerPopupPlanInput) []string {
	env := []string{pickerPopupEnv + "=1"}
	if input.StateRoot != "" {
		env = append(env, state.StateRootEnv+"="+input.StateRoot)
	}
	env = append(env, "PARTY_REPO_ROOT="+input.RepoRoot)
	return env
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
