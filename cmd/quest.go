package cmd

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/spf13/cobra"

	"github.com/alexivison/questmaster/internal/quests/board"
	"github.com/alexivison/questmaster/internal/quests/gate"
	"github.com/alexivison/questmaster/internal/quests/quest"
	"github.com/alexivison/questmaster/internal/state"
)

// questOpts holds the injectable side-effecting bits of the quest command
// group so the interactive editor and the browser opener can be stubbed in
// tests. The store itself is resolved from $QUESTMASTER_HOME on each use.
type questOpts struct {
	editBuffer  func(name string, initial []byte) ([]byte, error)
	openBrowser func(path string) error
	now         func() time.Time
}

type questOption func(*questOpts)

func withQuestEditor(fn func(name string, initial []byte) ([]byte, error)) questOption {
	return func(o *questOpts) { o.editBuffer = fn }
}

func withQuestOpener(fn func(path string) error) questOption {
	return func(o *questOpts) { o.openBrowser = fn }
}

func withQuestNow(fn func() time.Time) questOption {
	return func(o *questOpts) { o.now = fn }
}

// newQuestCmd builds the `questmaster quest ...` command group: authoring,
// validation, and viewing. The quest store is the dotfile store under the
// questmaster home (~/.questmaster/quests), resolved fresh on each invocation
// so $QUESTMASTER_HOME overrides (and tests) take effect.
func newQuestCmd(options ...questOption) *cobra.Command {
	o := questOpts{
		editBuffer:  launchEditor,
		openBrowser: launchBrowser,
		now:         time.Now,
	}
	for _, apply := range options {
		apply(&o)
	}

	cmd := &cobra.Command{
		Use:   "quest",
		Short: "Author, validate, and inspect quests",
		Long: `Quests are HTML plan files (canonical JSON + generated body) stored under the
questmaster home (~/.questmaster/quests), never in a repo. Status is human-owned:
a quest is born wip, approved to active, and marked done by the Questmaster.`,
	}

	cmd.AddCommand(
		newQuestNewCmd(&o),
		newQuestLsCmd(),
		newQuestViewCmd(),
		newQuestOpenCmd(&o),
		newQuestEditCmd(&o),
		newQuestApproveCmd(),
		newQuestDoneCmd(),
		newQuestWithdrawCmd(),
		newQuestCheckCmd(),
		newQuestBoardCmd(&o),
		newQuestValidateCmd(),
	)

	return cmd
}

// newQuestCheckCmd runs a quest's auto gates in the attached session's worktree
// and records the results in the sidecar. This is the manual dry-run: qm is the
// verifier of auto gates; broken checks are reported as misconfigured, not as a
// real failure, and never injected anywhere (the loop is Stage 2-proper).
func newQuestCheckCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "check <id>",
		Short: "Run a quest's auto gates and record the results",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			id := args[0]
			results, err := runQuestCheck(id)
			if err != nil {
				return err
			}
			w := cmd.OutOrStdout()
			if len(results) == 0 {
				fmt.Fprintf(w, "%s: no auto gates to check\n", id)
				return nil
			}
			for _, r := range results {
				label := string(r.Status)
				if r.Misconfigured() {
					label = "misconfigured"
				}
				fmt.Fprintf(w, "  %-8s %s\n", label, r.Gate)
			}
			return nil
		},
	}
}

// questRuntimeDir is the sidecar root: a sibling of the quest store under qm's
// dotfiles, holding observed auto-gate results. Never a repo.
func questRuntimeDir() string {
	return filepath.Join(quest.Home(), "runtime")
}

// questRuntime gathers a quest's derived render state: the sessions on it (the
// scan) and the observed auto-gate results (the sidecar). Both are injected at
// render time and never stored on the quest. Shared by `quest view` and the
// board.
func questRuntime(id string) quest.Runtime {
	ids, _ := state.SessionsForQuest(id)
	rt := quest.Runtime{Sessions: ids}
	if res, err := gate.NewSidecar(questRuntimeDir()).Load(id); err == nil {
		rt.Gates = res.StatusMap()
	}
	return rt
}

// questWorktree resolves the worktree a quest's checks run in: the cwd of an
// attached session. Checks run in the session's disposable worktree, never the
// main checkout, so an unattached quest has nowhere to run.
func questWorktree(id string) (string, error) {
	ids, err := state.SessionsForQuest(id)
	if err != nil {
		return "", err
	}
	store := state.OpenStore(state.StateRoot())
	for _, sid := range ids {
		if m, err := store.Read(sid); err == nil && m.Cwd != "" {
			return m.Cwd, nil
		}
	}
	return "", fmt.Errorf("quest %q has no attached session with a worktree; attach it to a session first", id)
}

// runQuestCheck runs every auto gate's cmd: check in the quest's worktree and
// writes the results to the sidecar. It never mutates the quest JSON.
func runQuestCheck(id string) ([]gate.Result, error) {
	q, err := quest.DefaultStore().Load(id)
	if err != nil {
		return nil, err
	}
	// Collect the auto gates first: a quest with only toggle gates has nothing
	// to run, so it must not require an attached worktree (the CLI then reports
	// "no auto gates to check").
	var autos []quest.Gate
	for _, g := range q.Gates {
		if g.Type == quest.GateAuto {
			autos = append(autos, g)
		}
	}
	if len(autos) == 0 {
		return nil, nil
	}
	worktree, err := questWorktree(id)
	if err != nil {
		return nil, err
	}
	results := make([]gate.Result, 0, len(autos))
	for _, g := range autos {
		results = append(results, gate.RunCheck(g.Name, g.Check, worktree))
	}
	if err := gate.NewSidecar(questRuntimeDir()).Save(id, results); err != nil {
		return results, err
	}
	return results, nil
}

// newQuestBoardCmd launches the interactive quest board (the quests app),
// meant to run in the rightmost shell pane of the qm layout.
func newQuestBoardCmd(o *questOpts) *cobra.Command {
	return &cobra.Command{
		Use:   "board",
		Short: "Open the interactive quest board",
		Args:  cobra.NoArgs,
		RunE: func(_ *cobra.Command, _ []string) error {
			// runtimeFor merges the session scan (who's on the quest) with the
			// sidecar (observed auto-gate results) — both derived, never stored
			// on the quest.
			runtimeFor := questRuntime
			cmds := board.Commands{
				Open: func(id string) tea.Cmd {
					return func() tea.Msg {
						if err := openQuestFile(id, o.openBrowser); err != nil {
							return board.ErrCmd(err)
						}
						return board.ReloadCmd()
					}
				},
				Edit: func(id string) tea.Cmd {
					self, err := os.Executable()
					if err != nil {
						return func() tea.Msg { return board.ReloadCmd() }
					}
					// Hand the terminal to a child `quest edit`, which runs
					// $EDITOR on the canonical JSON and validates + rebuilds.
					return tea.ExecProcess(exec.Command(self, "quest", "edit", id), func(error) tea.Msg {
						return board.ReloadCmd()
					})
				},
				Check: func(id string) tea.Cmd {
					return func() tea.Msg {
						if _, err := runQuestCheck(id); err != nil {
							return board.ErrCmd(err)
						}
						return board.ReloadCmd()
					}
				},
				OpenURL: func(url string) tea.Cmd {
					return func() tea.Msg {
						_ = o.openBrowser(url)
						return nil
					}
				},
			}
			m := board.NewModel(quest.DefaultStore(), runtimeFor, cmds)
			_, err := tea.NewProgram(m, tea.WithAltScreen()).Run()
			return err
		},
	}
}

// openQuestFile rebuilds a quest's HTML (T3) and opens it in the browser.
func openQuestFile(id string, opener func(string) error) error {
	store := quest.DefaultStore()
	q, err := store.Load(id)
	if err != nil {
		return err
	}
	if err := store.Save(q); err != nil {
		return err
	}
	return opener(store.Path(id))
}

// approve / done / withdraw are the human-only status transitions. They are the
// only mutators of status — there is no agent-facing setter — and movement is
// unrestricted (a quest can return to the board or to draft at any time).
func newQuestApproveCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "approve <id>",
		Short: "Post a quest to the board (active, human-only)",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return transitionStatus(cmd.OutOrStdout(), args[0], quest.Approve, "approved", "active")
		},
	}
}

func newQuestDoneCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "done <id>",
		Short: "Turn a quest in (done, human-only)",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return transitionStatus(cmd.OutOrStdout(), args[0], quest.MarkDone, "marked done", "done")
		},
	}
}

func newQuestWithdrawCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "withdraw <id>",
		Short: "Send a quest back to draft (wip, human-only)",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return transitionStatus(cmd.OutOrStdout(), args[0], quest.Withdraw, "withdrew", "wip")
		},
	}
}

func transitionStatus(w io.Writer, id string, apply func(*quest.Quest) error, verb, to string) error {
	store := quest.DefaultStore()
	q, err := store.Load(id)
	if err != nil {
		return err
	}
	if err := apply(q); err != nil {
		return err
	}
	if err := store.Save(q); err != nil {
		return err
	}
	fmt.Fprintf(w, "%s %s (now %s)\n", verb, id, to)
	return nil
}

func newQuestNewCmd(o *questOpts) *cobra.Command {
	var title, summary string
	cmd := &cobra.Command{
		Use:   "new <id>",
		Short: "Scaffold a new wip quest",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			id := args[0]
			store := quest.DefaultStore()
			if store.Exists(id) {
				return fmt.Errorf("quest %q already exists at %s", id, store.Path(id))
			}
			q := quest.Scaffold(id, title, summary, o.now().Format("2006-01-02"))
			if err := store.Save(q); err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "Created wip quest %q at %s\n", id, store.Path(id))
			fmt.Fprintf(cmd.OutOrStdout(), "Elaborate it with: questmaster quest edit %s\n", id)
			return nil
		},
	}
	cmd.Flags().StringVar(&title, "title", "", "short name (defaults to the id)")
	cmd.Flags().StringVar(&summary, "summary", "", "one-line objective")
	return cmd
}

func newQuestLsCmd() *cobra.Command {
	var width int
	cmd := &cobra.Command{
		Use:   "ls",
		Short: "List quests grouped by status",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			quests, err := quest.DefaultStore().List()
			if err != nil {
				return err
			}
			return runQuestLs(cmd.OutOrStdout(), quests, width)
		},
	}
	cmd.Flags().IntVar(&width, "width", 72, "render width")
	return cmd
}

// runQuestLs groups quests the way the board does (on the board / drafts /
// turned in) and renders each row with the terminal renderer.
func runQuestLs(w io.Writer, quests []quest.Quest, width int) error {
	if len(quests) == 0 {
		fmt.Fprintln(w, "No quests.")
		return nil
	}
	groups := []struct {
		label  string
		status quest.Status
	}{
		{"On the board", quest.StatusActive},
		{"Drafts", quest.StatusWIP},
		{"Turned in", quest.StatusDone},
	}
	for _, g := range groups {
		var rows []quest.Quest
		for _, q := range quests {
			if q.Status == g.status {
				rows = append(rows, q)
			}
		}
		if len(rows) == 0 {
			continue
		}
		fmt.Fprintf(w, "%s (%d)\n", g.label, len(rows))
		for i := range rows {
			fmt.Fprintf(w, "  %s\n", quest.RenderListRow(&rows[i], quest.Runtime{}, width))
		}
	}
	return nil
}

func newQuestViewCmd() *cobra.Command {
	var width int
	cmd := &cobra.Command{
		Use:   "view <id>",
		Short: "Print the terminal detail render of a quest",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			q, err := quest.DefaultStore().Load(args[0])
			if err != nil {
				return err
			}
			fmt.Fprintln(cmd.OutOrStdout(), quest.RenderDetail(q, questRuntime(args[0]), width))
			return nil
		},
	}
	cmd.Flags().IntVar(&width, "width", 72, "render width")
	return cmd
}

func newQuestOpenCmd(o *questOpts) *cobra.Command {
	return &cobra.Command{
		Use:   "open <id>",
		Short: "Rebuild and open a quest in the browser",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			id := args[0]
			store := quest.DefaultStore()
			q, err := store.Load(id)
			if err != nil {
				return err
			}
			// Rebuild (run T3) so the on-disk HTML reflects the current JSON.
			if err := store.Save(q); err != nil {
				return err
			}
			path := store.Path(id)
			if err := o.openBrowser(path); err != nil {
				return fmt.Errorf("open %s: %w", path, err)
			}
			fmt.Fprintf(cmd.OutOrStdout(), "Opened %s\n", path)
			return nil
		},
	}
}

func newQuestEditCmd(o *questOpts) *cobra.Command {
	return &cobra.Command{
		Use:   "edit <id>",
		Short: "Edit a quest's JSON in $EDITOR (validated and rebuilt on save)",
		Long: `Opens the quest's canonical JSON in $EDITOR. On save the JSON is validated and
the HTML body rebuilt; a malformed edit is refused with the validator error and
the quest is left unchanged. Status is not editable here — use 'quest approve'
and 'quest done'.`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			id := args[0]
			store := quest.DefaultStore()
			cur, err := store.Load(id)
			if err != nil {
				return err
			}
			initial, err := quest.Marshal(cur)
			if err != nil {
				return err
			}
			edited, err := o.editBuffer("quest-"+id+".json", initial)
			if err != nil {
				return err
			}
			next, err := quest.ParseJSON(edited)
			if err != nil {
				return fmt.Errorf("edit refused: %w", err)
			}
			if next.ID != id {
				return fmt.Errorf("edit refused: id changed from %q to %q (the id is the filename)", id, next.ID)
			}
			// Status is human-only, set via approve/done — never through edit.
			next.Status = cur.Status
			if err := store.Save(next); err != nil {
				return fmt.Errorf("edit refused: %w", err)
			}
			fmt.Fprintf(cmd.OutOrStdout(), "Saved quest %q\n", id)
			return nil
		},
	}
}

func newQuestValidateCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "validate <id>",
		Short: "Validate a quest against the schema",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			id := args[0]
			q, err := quest.DefaultStore().Load(id)
			if err != nil {
				return err
			}
			if err := quest.Validate(q); err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "%s: valid\n", id)
			return nil
		},
	}
}

// launchEditor writes initial to a temp file, opens it in $EDITOR (or vi), and
// returns the edited bytes. This is the production editBuffer; tests inject a
// stub.
func launchEditor(name string, initial []byte) ([]byte, error) {
	dir, err := os.MkdirTemp("", "qm-quest")
	if err != nil {
		return nil, fmt.Errorf("editor temp dir: %w", err)
	}
	defer os.RemoveAll(dir)
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, initial, 0o644); err != nil {
		return nil, fmt.Errorf("editor temp file: %w", err)
	}
	editor := os.Getenv("EDITOR")
	if editor == "" {
		editor = "vi"
	}
	parts := strings.Fields(editor)
	args := append(parts[1:], path)
	c := exec.Command(parts[0], args...)
	c.Stdin = os.Stdin
	c.Stdout = os.Stdout
	c.Stderr = os.Stderr
	if err := c.Run(); err != nil {
		return nil, fmt.Errorf("editor exited: %w", err)
	}
	return os.ReadFile(path)
}

// launchBrowser opens path with the OS opener, detached.
func launchBrowser(path string) error {
	opener := "xdg-open"
	if runtime.GOOS == "darwin" {
		opener = "open"
	}
	return exec.Command(opener, path).Start()
}
