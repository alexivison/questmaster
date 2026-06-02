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

	"github.com/alexivison/questmaster/internal/quests/quest"
	"github.com/spf13/cobra"
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
		newQuestValidateCmd(),
	)

	return cmd
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
			fmt.Fprintln(cmd.OutOrStdout(), quest.RenderDetail(q, quest.Runtime{}, width))
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
