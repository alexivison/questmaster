package main

import (
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/alexivison/questmaster/internal/quests/quest"
	"github.com/alexivison/questmaster/internal/quests/review"
	"github.com/alexivison/questmaster/internal/quests/runtime"
	"github.com/spf13/cobra"
)

// store returns the quest file store rooted under the Quests home.
func (e *env) store() *quest.FileStore {
	return quest.NewStore(e.paths.QuestsDir())
}

// runtimeStore returns the runtime-record store (beside the quests).
func (e *env) runtimeStore() *runtime.Store {
	return runtime.NewStore(e.paths.QuestsDir())
}

func newQuestCmd(e *env) *cobra.Command {
	cmd := &cobra.Command{
		Use:   "quest",
		Short: "Author, inspect, and review quests",
	}
	cmd.AddCommand(
		newQuestNewCmd(e),
		newQuestLsCmd(e),
		newQuestViewCmd(e),
		newQuestOpenCmd(e),
		newQuestEditCmd(e),
		newQuestDiffCmd(e),
	)
	return cmd
}

func newQuestNewCmd(e *env) *cobra.Command {
	var goal, worktree string
	var context, next []string
	var budget int

	cmd := &cobra.Command{
		Use:   "new <id>",
		Short: "Create a new quest scaffold (valid file under the Quests home)",
		Long: `Create a new quest with the given id. The scaffold is a valid quest file;
gates and the rich plan body are added by editing it (quest edit) or by asking
a quest-aware session to elaborate it.`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			id := args[0]
			if goal == "" {
				goal = "(draft) describe the goal of " + id
			}
			q := quest.Quest{
				ID:       id,
				Goal:     goal,
				Next:     next,
				Context:  context,
				Worktree: worktree,
				Budget:   budget,
			}
			body, err := quest.Render(q)
			if err != nil {
				return err
			}
			store := e.store()
			if err := store.Save(&quest.Document{Head: q, Body: body}); err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "created %s\n", store.Path(id))
			return nil
		},
	}
	cmd.Flags().StringVar(&goal, "goal", "", "quest goal (required content; defaults to a draft placeholder)")
	cmd.Flags().StringVar(&worktree, "worktree", "", "worktree path the quest is about")
	cmd.Flags().StringArrayVar(&context, "context", nil, "context ref (repeatable), e.g. linear:ENG-142")
	cmd.Flags().StringArrayVar(&next, "next", nil, "a next step (repeatable)")
	cmd.Flags().IntVar(&budget, "budget", 0, "attempt budget (Stage 2)")
	return cmd
}

func newQuestLsCmd(e *env) *cobra.Command {
	return &cobra.Command{
		Use:   "ls",
		Short: "List quests",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			heads, err := e.store().List()
			if err != nil {
				return err
			}
			rt := e.runtimeStore()
			out := cmd.OutOrStdout()
			if len(heads) == 0 {
				fmt.Fprintln(out, "no quests yet")
				return nil
			}
			for _, h := range heads {
				status := runtime.StatusDraft
				if rec, err := rt.Load(h.ID); err == nil {
					status = rec.Status
				}
				fmt.Fprintf(out, "%-16s %-12s %s\n", h.ID, status, h.Goal)
			}
			return nil
		},
	}
}

func newQuestViewCmd(e *env) *cobra.Command {
	return &cobra.Command{
		Use:   "view <id>",
		Short: "Print a quest's head and runtime summary",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			id := args[0]
			doc, err := e.store().Load(id)
			if err != nil {
				return err
			}
			rec, err := e.runtimeStore().Load(id)
			if err != nil {
				return err
			}
			writeView(cmd.OutOrStdout(), doc.Head, rec)
			return nil
		},
	}
}

func newQuestOpenCmd(e *env) *cobra.Command {
	return &cobra.Command{
		Use:   "open <id>",
		Short: "Open a quest's HTML body in the browser",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			id := args[0]
			store := e.store()
			if _, err := store.Load(id); err != nil {
				return err
			}
			return e.openInBrowser(store.Path(id))
		},
	}
}

func newQuestEditCmd(e *env) *cobra.Command {
	return &cobra.Command{
		Use:   "edit <id>",
		Short: "Edit a quest in $EDITOR; re-validates on save and rejects a corrupted result",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			id := args[0]
			store := e.store()
			orig, err := store.Load(id)
			if err != nil {
				return err
			}

			tmp, err := os.CreateTemp("", "quest-*.html")
			if err != nil {
				return fmt.Errorf("create temp: %w", err)
			}
			tmpPath := tmp.Name()
			defer os.Remove(tmpPath)
			if _, err := tmp.Write(orig.Body); err != nil {
				tmp.Close()
				return fmt.Errorf("write temp: %w", err)
			}
			tmp.Close()

			if err := e.editFile(tmpPath); err != nil {
				return fmt.Errorf("editor: %w", err)
			}

			edited, err := os.ReadFile(tmpPath)
			if err != nil {
				return fmt.Errorf("read edited: %w", err)
			}
			doc, err := quest.Parse(edited)
			if err != nil {
				return fmt.Errorf("edit rejected (not saved): %w", err)
			}
			if err := quest.Validate(doc.Head); err != nil {
				return fmt.Errorf("edit rejected (not saved): %w", err)
			}
			if doc.Head.ID != id {
				return fmt.Errorf("edit rejected (not saved): cannot change quest id from %q to %q via edit", id, doc.Head.ID)
			}
			if err := store.Save(doc); err != nil {
				return fmt.Errorf("edit rejected (not saved): %w", err)
			}
			fmt.Fprintf(cmd.OutOrStdout(), "saved %s\n", store.Path(id))
			return nil
		},
	}
}

func newQuestDiffCmd(e *env) *cobra.Command {
	var viewerFlag, baseRef string
	cmd := &cobra.Command{
		Use:   "diff <id>",
		Short: "Launch a diff viewer on the quest's worktree vs base",
		Args:  cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, args []string) error {
			id := args[0]
			doc, err := e.store().Load(id)
			if err != nil {
				return err
			}
			if doc.Head.Worktree == "" {
				return fmt.Errorf("quest %q has no worktree to diff", id)
			}
			bin := review.ResolveViewer(viewerFlag)
			viewer := e.newViewer(bin)
			return viewer.Open(doc.Head.Worktree, baseRef)
		},
	}
	cmd.Flags().StringVar(&viewerFlag, "viewer", "", "diff viewer binary (default scry; or set QUESTS_DIFF_VIEWER)")
	cmd.Flags().StringVar(&baseRef, "base", "main", "base ref to diff the worktree against")
	return cmd
}

// writeView renders a terminal summary of a quest's head + runtime record.
func writeView(out io.Writer, q quest.Quest, rec *runtime.RuntimeRecord) {
	fmt.Fprintf(out, "Quest %s\n", q.ID)
	fmt.Fprintf(out, "  goal:     %s\n", q.Goal)
	fmt.Fprintf(out, "  status:   %s\n", rec.Status)
	if q.Worktree != "" {
		fmt.Fprintf(out, "  worktree: %s\n", q.Worktree)
	}
	if len(q.Context) > 0 {
		fmt.Fprintf(out, "  context:  %s\n", strings.Join(q.Context, ", "))
	}
	if len(q.Gates) > 0 {
		fmt.Fprintln(out, "  gates:")
		for _, g := range q.Gates {
			result := rec.GateResults[g.Name]
			if result == "" {
				result = "unset"
			}
			line := fmt.Sprintf("    [%s] %s", g.Type, g.Name)
			if g.Check != "" {
				line += " (" + g.Check + ")"
			}
			if g.Before != "" {
				line += " before:" + g.Before
			}
			fmt.Fprintf(out, "%s — %s\n", line, result)
		}
	}
	if len(q.Next) > 0 {
		fmt.Fprintln(out, "  next:")
		for _, n := range q.Next {
			fmt.Fprintf(out, "    - %s\n", n)
		}
	}
	if len(rec.Sessions) > 0 {
		fmt.Fprintln(out, "  sessions:")
		for _, s := range rec.Sessions {
			fmt.Fprintf(out, "    %s %s/%s %s\n", s.ID, s.Role, s.Agent, s.State)
		}
	}
	if rec.PR != nil {
		fmt.Fprintf(out, "  pr:       #%d ci:%s review:%s %s\n", rec.PR.Number, rec.PR.CI, rec.PR.Review, rec.PR.URL)
	}
}
