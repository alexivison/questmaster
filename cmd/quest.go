package cmd

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/alexivison/questmaster/internal/quests/gate"
	qlifecycle "github.com/alexivison/questmaster/internal/quests/lifecycle"
	"github.com/alexivison/questmaster/internal/quests/quest"
	qruntime "github.com/alexivison/questmaster/internal/quests/runtime"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

// questOpts holds the injectable side-effecting bits of the quest command
// group so the interactive editor and the browser opener can be stubbed in
// tests. The store itself is resolved from $QUESTMASTER_HOME on each use.
type questOpts struct {
	editBuffer  func(name string, initial []byte) ([]byte, error)
	openBrowser func(path string) error
	now         func() time.Time
	authorName  func() string
	projectName func() string
	store       *state.Store
	client      *tmux.Client
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

func withQuestAuthor(fn func() string) questOption {
	return func(o *questOpts) { o.authorName = fn }
}

func withQuestProject(fn func() string) questOption {
	return func(o *questOpts) { o.projectName = fn }
}

func withQuestDeps(store *state.Store, client *tmux.Client) questOption {
	return func(o *questOpts) {
		o.store = store
		o.client = client
	}
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
		authorName:  detectAuthorName,
		projectName: detectProjectName,
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
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			return cmd.Help()
		},
	}

	cmd.AddCommand(
		newQuestNewCmd(&o),
		newQuestLsCmd(),
		newQuestViewCmd(),
		newQuestDeleteCmd(),
		newQuestOpenCmd(&o),
		newQuestEditCmd(&o),
		newQuestApplyCmd(),
		newQuestApproveCmd(),
		newQuestDoneCmd(),
		newQuestWithdrawCmd(),
		newQuestGateToggleCmd(),
		newQuestCheckCmd(),
		newQuestCommentCmd(&o),
		newQuestLoopCmd(&o),
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
			results, err := runQuestCheck(cmd.Context(), id)
			if err != nil {
				return err
			}
			if results == nil {
				results = []gate.Result{}
			}
			return writeJSON(cmd.OutOrStdout(), struct {
				QuestID string        `json:"quest_id"`
				Results []gate.Result `json:"results"`
			}{QuestID: id, Results: results})
		},
	}
}

// questRuntimeDir is the sidecar root: a sibling of the quest store under qm's
// dotfiles, holding observed auto-gate results. Never a repo.
func questRuntimeDir() string {
	return filepath.Join(quest.Home(), "runtime")
}

// questRuntime gathers one quest's derived render state via the shared runtime
// scan: the sessions on it (with live activity), the armed loop marker, and
// the observed auto-gate results (the sidecar). All injected at render time
// and never stored on the quest. Shared by `quest view`; the board uses the
// bulk questRuntimes so its poll stays one scan pass.
func questRuntime(id string) quest.Runtime {
	return questRuntimes([]string{id})[id]
}

// questRuntimes is the bulk form: one state-root pass for every requested
// quest. The board reloads through this on its poll tick.
func questRuntimes(ids []string) map[string]quest.Runtime {
	return qruntime.Snapshot(gate.NewSidecar(questRuntimeDir()), ids, time.Now().UTC())
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
func runQuestCheck(ctx context.Context, id string) ([]gate.Result, error) {
	q, err := quest.DefaultStore().Load(id)
	if err != nil {
		return nil, err
	}
	// Collect the auto gates first: a quest with only toggle gates has nothing
	// to run, so it must not require an attached worktree (the CLI then reports
	// "no auto gates to check").
	autos := questAutoGates(q)
	if len(autos) == 0 {
		return nil, nil
	}
	worktree, err := questWorktree(id)
	if err != nil {
		return nil, err
	}
	return runQuestAutoChecks(ctx, id, autos, worktree)
}

// Per-gate deadlines bound a single check so one wedged process can't hang the
// quest loop. cmd: checks may be real builds/tests (generous); github: checks
// are network round-trips that should be quick.
const (
	cmdGateTimeout    = 10 * time.Minute
	githubGateTimeout = 45 * time.Second
)

func runQuestAutoChecks(ctx context.Context, id string, autos []quest.Gate, worktree string) ([]gate.Result, error) {
	results := make([]gate.Result, 0, len(autos))
	for _, g := range autos {
		results = append(results, runGateWithTimeout(ctx, g, worktree))
	}
	if err := gate.NewSidecar(questRuntimeDir()).Save(id, results); err != nil {
		return results, err
	}
	return results, nil
}

// runGateWithTimeout runs one gate under its own deadline derived from ctx, so a
// stalled gate fails as a (misconfigured) error rather than blocking the loop,
// while a parent cancellation (Ctrl-C, loop stop) still interrupts it promptly.
func runGateWithTimeout(ctx context.Context, g quest.Gate, worktree string) gate.Result {
	timeout := cmdGateTimeout
	if strings.HasPrefix(strings.TrimSpace(g.Check), "github:") {
		timeout = githubGateTimeout
	}
	cctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	return gate.RunCheck(cctx, g.Name, g.Check, worktree)
}

func questAutoGates(q *quest.Quest) []quest.Gate {
	var autos []quest.Gate
	for _, g := range q.Gates {
		if g.Type == quest.GateAuto {
			autos = append(autos, g)
		}
	}
	return autos
}

// rebuildQuestFile rebuilds a quest's HTML (T3) and returns its path.
func rebuildQuestFile(id string) (string, error) {
	store := quest.DefaultStore()
	q, err := store.Load(id)
	if err != nil {
		return "", err
	}
	if err := store.Save(q); err != nil {
		return "", err
	}
	return store.Path(id), nil
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
			return transitionStatus(cmd.Context(), cmd.OutOrStdout(), args[0], quest.StatusActive)
		},
	}
}

func newQuestDoneCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "done <id>",
		Short: "Turn a quest in (done, human-only)",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return transitionStatus(cmd.Context(), cmd.OutOrStdout(), args[0], quest.StatusDone)
		},
	}
}

func newQuestWithdrawCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "withdraw <id>",
		Short: "Send a quest back to draft (wip, human-only)",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return transitionStatus(cmd.Context(), cmd.OutOrStdout(), args[0], quest.StatusWIP)
		},
	}
}

func transitionStatus(ctx context.Context, w io.Writer, id string, target quest.Status) error {
	result, err := qlifecycle.SetStatus(ctx, quest.DefaultStore(), state.OpenStore(state.StateRoot()), id, target)
	if err != nil {
		return err
	}
	return writeJSON(w, result)
}

func newQuestGateToggleCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "gate-toggle <id> <gate-name>",
		Short: "Toggle a manual quest gate",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			result, err := qlifecycle.ToggleGate(quest.DefaultStore(), args[0], args[1])
			if err != nil {
				return err
			}
			return writeJSON(cmd.OutOrStdout(), result)
		},
	}
}

func newQuestNewCmd(o *questOpts) *cobra.Command {
	var title, summary string
	cmd := &cobra.Command{
		Use:   "new",
		Short: "Scaffold a new wip quest",
		Long: `Scaffold a new wip quest. Questmaster always auto-generates a
quest-specific id such as quest-1780539999.`,
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			store := quest.DefaultStore()
			now := o.now()
			id := nextQuestID(store, now.Unix())
			if store.Exists(id) {
				return fmt.Errorf("quest %q already exists at %s", id, store.Path(id))
			}
			q := quest.Scaffold(id, title, summary, now.Format("2006-01-02"))
			q.Project = o.projectName()
			if err := store.Save(q); err != nil {
				return err
			}
			return writeJSON(cmd.OutOrStdout(), struct {
				QuestID string       `json:"quest_id"`
				Path    string       `json:"path"`
				Status  quest.Status `json:"status"`
				Title   string       `json:"title"`
				Project string       `json:"project,omitempty"`
			}{
				QuestID: q.ID,
				Path:    store.Path(q.ID),
				Status:  q.Status,
				Title:   q.Title,
				Project: q.Project,
			})
		},
	}
	cmd.Flags().StringVar(&title, "title", "", "short name (defaults to the id)")
	cmd.Flags().StringVar(&summary, "summary", "", "one-line objective")
	return cmd
}

// detectProjectName stamps a new quest with the current repo's name: the
// basename of the git toplevel, evaluated in the working directory where
// `quest new` runs. Outside a git repo it returns "", so the quest lands in the
// board's "Unsorted" section. Existing quests are never backfilled.
func detectProjectName() string {
	out, err := exec.Command("git", "rev-parse", "--show-toplevel").Output()
	if err != nil {
		return ""
	}
	top := strings.TrimSpace(string(out))
	if top == "" {
		return ""
	}
	return filepath.Base(top)
}

func detectAuthorName() string {
	for _, key := range []string{"QUESTMASTER_AUTHOR", "GIT_AUTHOR_NAME", "USER"} {
		if v := strings.TrimSpace(os.Getenv(key)); v != "" {
			return v
		}
	}
	return ""
}

func nextQuestID(store *quest.FileStore, timestamp int64) string {
	id := quest.NewID(timestamp)
	if !store.Exists(id) {
		return id
	}
	for suffix := 1; ; suffix++ {
		id = quest.NewIDWithSuffix(timestamp, suffix)
		if !store.Exists(id) {
			return id
		}
	}
}

func newQuestLsCmd() *cobra.Command {
	var width int
	var textOut bool
	cmd := &cobra.Command{
		Use:   "ls",
		Short: "List quests",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			quests, err := quest.DefaultStore().List()
			if err != nil {
				return err
			}
			if textOut {
				return runQuestLs(cmd.OutOrStdout(), quests, width)
			}
			if quests == nil {
				quests = []quest.Quest{}
			}
			return writeJSON(cmd.OutOrStdout(), struct {
				Quests []quest.Quest `json:"quests"`
			}{Quests: quests})
		},
	}
	cmd.Flags().BoolVar(&textOut, "text", false, "render a terminal list")
	cmd.Flags().IntVar(&width, "width", 72, "render width with --text")
	return cmd
}

// runQuestLs groups quests the way the board does — project sections, each row
// carrying its own status — and renders each row with the terminal renderer.
func runQuestLs(w io.Writer, quests []quest.Quest, width int) error {
	if len(quests) == 0 {
		fmt.Fprintln(w, "No quests.")
		return nil
	}
	for _, g := range quest.GroupByProject(quests) {
		fmt.Fprintf(w, "%s\n", g.Project)
		for i := range g.Quests {
			fmt.Fprintf(w, "  %s\n", quest.RenderListRow(&g.Quests[i], quest.Runtime{}, width, quest.TagStatus))
		}
	}
	return nil
}

func newQuestViewCmd() *cobra.Command {
	var width int
	var textOut bool
	cmd := &cobra.Command{
		Use:   "view <id>",
		Short: "Show a quest with derived runtime",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			q, err := quest.DefaultStore().Load(args[0])
			if err != nil {
				return err
			}
			rt := questRuntime(args[0])
			if textOut {
				fmt.Fprintln(cmd.OutOrStdout(), quest.RenderDetail(q, rt, width))
				return nil
			}
			return writeJSON(cmd.OutOrStdout(), struct {
				Quest   *quest.Quest  `json:"quest"`
				Runtime quest.Runtime `json:"runtime"`
			}{Quest: q, Runtime: rt})
		},
	}
	cmd.Flags().BoolVar(&textOut, "text", false, "render the terminal detail view")
	cmd.Flags().IntVar(&width, "width", 72, "render width with --text")
	return cmd
}

func newQuestDeleteCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "delete <id>",
		Short: "Delete a quest from the store",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			id := args[0]
			if err := quest.DefaultStore().Delete(id); err != nil {
				return err
			}
			return writeJSON(cmd.OutOrStdout(), struct {
				QuestID string `json:"quest_id"`
				Deleted bool   `json:"deleted"`
			}{QuestID: id, Deleted: true})
		},
	}
}

func newQuestOpenCmd(o *questOpts) *cobra.Command {
	var browser bool
	cmd := &cobra.Command{
		Use:   "open <id>",
		Short: "Rebuild a quest HTML file and print its path",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			id := args[0]
			path, err := rebuildQuestFile(id)
			if err != nil {
				return err
			}
			if browser {
				if err := o.openBrowser(path); err != nil {
					return fmt.Errorf("open %s: %w", path, err)
				}
			}
			fmt.Fprintln(cmd.OutOrStdout(), path)
			return nil
		},
	}
	cmd.Flags().BoolVar(&browser, "browser", false, "open the rebuilt HTML in a browser")
	return cmd
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

func newQuestApplyCmd() *cobra.Command {
	var filePath string
	cmd := &cobra.Command{
		Use:   "apply <id> --file <path|->",
		Short: "Apply canonical quest JSON from a file or stdin",
		Long: `Apply bare canonical quest JSON from a file or stdin. The JSON is parsed,
validated, and rebuilt through the quest store. Status remains human-owned:
use 'quest approve', 'quest done', or 'quest withdraw' for lifecycle changes.`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			if !cmd.Flags().Changed("file") {
				return fmt.Errorf("quest apply requires --file")
			}
			id := args[0]
			raw, err := readFileOrStdin(cmd, filePath, "quest JSON")
			if err != nil {
				return err
			}
			path, err := applyQuestJSON(id, []byte(raw))
			if err != nil {
				return err
			}
			return writeJSON(cmd.OutOrStdout(), struct {
				QuestID string `json:"quest_id"`
				Path    string `json:"path"`
			}{QuestID: id, Path: path})
		},
	}
	cmd.Flags().StringVar(&filePath, "file", "", "read canonical quest JSON from a file, or '-' for stdin")
	return cmd
}

func applyQuestJSON(id string, raw []byte) (string, error) {
	store := quest.DefaultStore()
	cur, err := store.Load(id)
	if err != nil {
		return "", err
	}
	next, err := quest.ParseJSON(raw)
	if err != nil {
		return "", fmt.Errorf("apply refused: %w", err)
	}
	if next.ID != id {
		return "", fmt.Errorf("apply refused: id changed from %q to %q (the id is the filename)", id, next.ID)
	}
	next.Status = cur.Status
	if err := store.Save(next); err != nil {
		return "", fmt.Errorf("apply refused: %w", err)
	}
	return store.Path(id), nil
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
			return writeJSON(cmd.OutOrStdout(), struct {
				QuestID string `json:"quest_id"`
				Valid   bool   `json:"valid"`
			}{QuestID: id, Valid: true})
		},
	}
}

func newQuestCommentCmd(o *questOpts) *cobra.Command {
	cmd := &cobra.Command{
		Use:   "comment",
		Short: "List, add, edit, delete, and resolve quest comments",
		Args:  cobra.NoArgs,
	}
	cmd.AddCommand(
		newQuestCommentListCmd(),
		newQuestCommentAddCmd(o),
		newQuestCommentEditCmd(),
		newQuestCommentDeleteCmd(),
		newQuestCommentResolveCmd(o),
	)
	return cmd
}

func newQuestCommentListCmd() *cobra.Command {
	var onlyOpen bool
	var textOut bool
	cmd := &cobra.Command{
		Use:   "list <id>",
		Short: "List comments on a quest",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			q, err := quest.DefaultStore().Load(args[0])
			if err != nil {
				return err
			}
			if textOut {
				return printQuestComments(cmd.OutOrStdout(), q, onlyOpen)
			}
			comments := make([]quest.QuestComment, 0, len(q.Comments))
			for _, c := range q.Comments {
				if onlyOpen && c.Status != quest.CommentOpen {
					continue
				}
				comments = append(comments, c)
			}
			return writeJSON(cmd.OutOrStdout(), struct {
				QuestID  string               `json:"quest_id"`
				Comments []quest.QuestComment `json:"comments"`
			}{QuestID: q.ID, Comments: comments})
		},
	}
	cmd.Flags().BoolVar(&onlyOpen, "open", false, "show only open comments")
	cmd.Flags().BoolVar(&textOut, "text", false, "render comments as text")
	return cmd
}

func newQuestCommentAddCmd(o *questOpts) *cobra.Command {
	var anchorRaw, bodyRaw, bodyFile string
	cmd := &cobra.Command{
		Use:   "add <id>",
		Short: "Add a comment to a quest anchor",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			if strings.TrimSpace(anchorRaw) == "" {
				return fmt.Errorf("comment add requires --anchor")
			}
			anchor, err := quest.ParseCommentAnchor(anchorRaw)
			if err != nil {
				return err
			}

			id := args[0]
			q, err := quest.DefaultStore().Load(id)
			if err != nil {
				return err
			}
			if err := quest.ValidateCommentAnchor(q, anchor); err != nil {
				return err
			}
			bodyText, err := commentBodyFromFlags(cmd, bodyRaw, bodyFile)
			if err != nil {
				return err
			}

			result, err := qlifecycle.AddComment(quest.DefaultStore(), id, anchor, o.authorName(), bodyText, o.now().UTC())
			if err != nil {
				return err
			}
			return writeJSON(cmd.OutOrStdout(), result)
		},
	}
	cmd.Flags().StringVar(&anchorRaw, "anchor", "", "comment anchor (quest, gate:<name>, related:<id>, block:<id>, block:<id>#item:<zero-based-index>)")
	cmd.Flags().StringVar(&bodyRaw, "body", "", "comment body")
	cmd.Flags().StringVar(&bodyFile, "body-file", "", "read comment body from a file, or '-' for stdin")
	return cmd
}

func newQuestCommentEditCmd() *cobra.Command {
	var bodyRaw, bodyFile string
	cmd := &cobra.Command{
		Use:   "edit <id> <comment-id>",
		Short: "Edit a quest comment body",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			id, commentID := args[0], args[1]
			store := quest.DefaultStore()
			q, err := store.Load(id)
			if err != nil {
				return err
			}
			c, ok := quest.CommentByID(q, commentID)
			if !ok {
				return fmt.Errorf("comment %q not found on quest %s", commentID, id)
			}
			body, err := commentBodyFromFlags(cmd, bodyRaw, bodyFile)
			if err != nil {
				return err
			}
			if err := quest.UpdateCommentBody(q, c.ID, body); err != nil {
				return fmt.Errorf("comment edit refused: %w", err)
			}
			if err := store.Save(q); err != nil {
				return err
			}
			next, _ := quest.CommentByID(q, commentID)
			return writeJSON(cmd.OutOrStdout(), struct {
				QuestID   string              `json:"quest_id"`
				CommentID string              `json:"comment_id"`
				Status    quest.CommentStatus `json:"status"`
				Comment   quest.QuestComment  `json:"comment"`
			}{
				QuestID:   id,
				CommentID: next.ID,
				Status:    next.Status,
				Comment:   next,
			})
		},
	}
	cmd.Flags().StringVar(&bodyRaw, "body", "", "replacement comment body")
	cmd.Flags().StringVar(&bodyFile, "body-file", "", "read replacement comment body from a file, or '-' for stdin")
	return cmd
}

func commentBodyFromFlags(cmd *cobra.Command, bodyRaw, bodyFile string) (string, error) {
	bodySet := cmd.Flags().Changed("body")
	fileSet := cmd.Flags().Changed("body-file")
	switch {
	case bodySet && fileSet:
		return "", fmt.Errorf("comment body accepts only one of --body or --body-file")
	case !bodySet && !fileSet:
		return "", fmt.Errorf("comment body requires exactly one of --body or --body-file")
	case bodySet:
		return bodyRaw, nil
	case bodyFile == "-":
		raw, err := io.ReadAll(cmd.InOrStdin())
		if err != nil {
			return "", fmt.Errorf("read comment body from stdin: %w", err)
		}
		return string(raw), nil
	default:
		raw, err := os.ReadFile(bodyFile)
		if err != nil {
			return "", fmt.Errorf("read comment body file: %w", err)
		}
		return string(raw), nil
	}
}

func newQuestCommentDeleteCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "delete <id> <comment-id>",
		Short: "Delete a quest comment",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			id, commentID := args[0], args[1]
			if err := deleteQuestComment(id, commentID); err != nil {
				return err
			}
			return writeJSON(cmd.OutOrStdout(), struct {
				QuestID   string `json:"quest_id"`
				CommentID string `json:"comment_id"`
				Deleted   bool   `json:"deleted"`
			}{QuestID: id, CommentID: commentID, Deleted: true})
		},
	}
}

func deleteQuestComment(id, commentID string) error {
	store := quest.DefaultStore()
	q, err := store.Load(id)
	if err != nil {
		return err
	}
	if err := quest.DeleteComment(q, commentID); err != nil {
		return err
	}
	return store.Save(q)
}

func newQuestCommentResolveCmd(o *questOpts) *cobra.Command {
	return &cobra.Command{
		Use:   "resolve <id> <comment-id>",
		Short: "Resolve a quest comment",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			id, commentID := args[0], args[1]
			c, err := resolveQuestComment(id, commentID, o.now().UTC())
			if err != nil {
				return err
			}
			return writeJSON(cmd.OutOrStdout(), struct {
				QuestID   string              `json:"quest_id"`
				CommentID string              `json:"comment_id"`
				Status    quest.CommentStatus `json:"status"`
				Comment   quest.QuestComment  `json:"comment"`
			}{
				QuestID:   id,
				CommentID: c.ID,
				Status:    c.Status,
				Comment:   c,
			})
		},
	}
}

func resolveQuestComment(id, commentID string, now time.Time) (quest.QuestComment, error) {
	result, err := qlifecycle.ResolveComment(quest.DefaultStore(), id, commentID, now)
	if err != nil {
		return quest.QuestComment{}, err
	}
	return result.Comment, nil
}

func printQuestComments(w io.Writer, q *quest.Quest, onlyOpen bool) error {
	count := 0
	for _, c := range q.Comments {
		if onlyOpen && c.Status != quest.CommentOpen {
			continue
		}
		count++
		meta := string(c.Status)
		if c.Author != "" {
			meta += " by " + c.Author
		}
		if c.CreatedAt != "" {
			meta += " at " + c.CreatedAt
		}
		fmt.Fprintf(w, "%s  %s  %s\n", c.ID, c.Anchor.String(), meta)
		for _, ln := range strings.Split(strings.TrimSpace(c.Body), "\n") {
			fmt.Fprintf(w, "  %s\n", ln)
		}
	}
	if count == 0 {
		fmt.Fprintln(w, "No comments.")
	}
	return nil
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
