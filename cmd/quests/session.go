package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/config"
	"github.com/alexivison/questmaster/internal/session"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/spf13/cobra"
)

func newSessionCmd(e *env) *cobra.Command {
	cmd := &cobra.Command{
		Use:   "session",
		Short: "Spawn and list sessions (the substrate)",
	}
	cmd.AddCommand(newSessionNewCmd(e), newSessionLsCmd(e))
	return cmd
}

func newSessionNewCmd(e *env) *cobra.Command {
	var agentName, role, questID, cwd string
	var attach bool

	cmd := &cobra.Command{
		Use:   "new [title]",
		Short: "Spawn an interactive session (a free session, or one wearing a quest hat)",
		Long: `Spawn an interactive tmux session via the reused spine, under the Quests
namespace. With no --quest it is a free session and behaves exactly as
questmaster today.`,
		Args: cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			var title string
			if len(args) > 0 {
				title = args[0]
			}
			master, err := masterFromRole(role)
			if err != nil {
				return err
			}
			res, err := e.spawnSession(cmd.Context(), session.StartOpts{
				Title:    title,
				Cwd:      cwd,
				Master:   master,
				Detached: true, // parity with questmaster: detached spawn
			}, agentName)
			if err != nil {
				return err
			}

			// Attach the quest hat (Stage 1: metadata only; no loop yet).
			if questID != "" {
				if err := e.attachQuest(res.SessionID, questID); err != nil {
					return err
				}
			}

			out := cmd.OutOrStdout()
			fmt.Fprintf(out, "session %s started\n", res.SessionID)
			if questID != "" {
				fmt.Fprintf(out, "  quest: %s\n", questID)
			}
			if attach {
				return attachTo(res.SessionID)
			}
			return nil
		},
	}
	cmd.Flags().StringVar(&agentName, "agent", "", "primary agent (claude|codex|pi; default from config)")
	cmd.Flags().StringVar(&role, "role", "solo", "session role: solo|master")
	cmd.Flags().StringVar(&questID, "quest", "", "attach a quest hat by id")
	cmd.Flags().StringVar(&cwd, "cwd", "", "working directory (default: current)")
	cmd.Flags().BoolVar(&attach, "attach", false, "attach to the session after spawning (switch-client in tmux)")
	return cmd
}

// attachTo switches to (in tmux) or attaches (outside) the named session,
// inheriting the terminal.
func attachTo(sessionID string) error {
	c := attachExecCmd(sessionID)
	c.Stdin, c.Stdout, c.Stderr = os.Stdin, os.Stdout, os.Stderr
	return c.Run()
}

func newSessionLsCmd(e *env) *cobra.Command {
	return &cobra.Command{
		Use:   "ls",
		Short: "List sessions in the Quests namespace",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			store := state.OpenStore(e.paths.StateRoot())
			manifests, err := store.DiscoverSessions()
			if err != nil {
				return err
			}
			state.SortByMtime(manifests, store.Root())
			out := cmd.OutOrStdout()
			if len(manifests) == 0 {
				fmt.Fprintln(out, "no sessions")
				return nil
			}
			for _, m := range manifests {
				hat := ""
				if m.QuestID != "" {
					hat = "  quest:" + m.QuestID
				}
				fmt.Fprintf(out, "%-18s %-8s %-16s %s%s\n",
					m.SessionID, sessionRole(m), filepath.Base(m.Cwd), m.Title, hat)
			}
			return nil
		},
	}
}

// attachQuest records the quest hat (and interactive mode) on a session.
func (e *env) attachQuest(sessionID, questID string) error {
	store := state.OpenStore(e.paths.StateRoot())
	return store.Update(sessionID, func(m *state.Manifest) {
		m.QuestID = questID
		m.Mode = state.ModeInteractive
	})
}

func masterFromRole(role string) (bool, error) {
	switch role {
	case "", "solo":
		return false, nil
	case "master":
		return true, nil
	case "worker":
		return false, fmt.Errorf("worker sessions are spawned from a master (Stage 2)")
	default:
		return false, fmt.Errorf("unknown role %q (want solo|master)", role)
	}
}

// defaultSpawnSession builds the reused session.Service under the Quests
// namespace and starts an interactive session. The session's sidebar/cockpit
// pane launches the `quests` binary (not questmaster), and state is written to
// the Quests state root — so a free session is fully isolated yet behaves
// exactly as questmaster's.
func (e *env) defaultSpawnSession(ctx context.Context, opts session.StartOpts, agentName string) (session.StartResult, error) {
	store, err := state.NewStore(e.paths.StateRoot())
	if err != nil {
		return session.StartResult{}, err
	}
	var overrides *agent.ConfigOverrides
	if agentName != "" {
		overrides = &agent.ConfigOverrides{Primary: agentName}
	}
	cfg, err := agent.LoadConfig(overrides)
	if err != nil {
		return session.StartResult{}, err
	}
	registry, err := agent.NewRegistry(cfg)
	if err != nil {
		return session.StartResult{}, err
	}

	svc := newQuestsService(store, tmux.NewExecClient(), registry)
	return svc.Start(ctx, opts)
}

// resolveQuestsCmd resolves the shell command that launches the quests cockpit
// inside a session's sidebar pane (mirrors config.ResolveQuestmasterCmd).
func resolveQuestsCmd(repo string) (string, error) {
	if bin, err := exec.LookPath("quests"); err == nil {
		return fmt.Sprintf("PARTY_REPO_ROOT=%s %s", config.ShellQuote(repo), config.ShellQuote(bin)), nil
	}
	return "", fmt.Errorf("quests: not found on PATH")
}

func repoRoot() string {
	if r := os.Getenv("PARTY_REPO_ROOT"); r != "" {
		return r
	}
	wd, _ := os.Getwd()
	return wd
}
