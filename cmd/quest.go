package cmd

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"github.com/alexivison/questmaster/internal/repo"
	"github.com/alexivison/questmaster/internal/session"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/spf13/cobra"
)

func newQuestCmd(store *state.Store, client *tmux.Client, repoRoot string) *cobra.Command {
	var sessionFlag string
	cmd := &cobra.Command{
		Use:   "quest",
		Short: "Manage project quests",
	}
	cmd.PersistentFlags().StringVar(&sessionFlag, "session", "", "session ID for provenance/default project")
	cmd.AddCommand(
		newQuestAddCmd(store, client, &sessionFlag),
		newQuestListCmd(store),
		newQuestEditCmd(store),
		newQuestRemoveCmd(store),
		newQuestStartCmd(store, client, repoRoot),
	)
	return cmd
}

func newQuestAddCmd(store *state.Store, client *tmux.Client, sessionFlag *string) *cobra.Command {
	var project string
	var file string
	cmd := &cobra.Command{
		Use:   "add [content]",
		Short: "Add a quest",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			content, err := questContent(cmd, args, file)
			if err != nil {
				return err
			}
			sessionID, err := questSession(cmd.Context(), client, *sessionFlag)
			if err != nil {
				return err
			}
			projectMeta, err := questProject(cmd, store, sessionID, project)
			if err != nil {
				return err
			}
			quest, err := state.UpsertQuestAt(questStateRoot(store), state.Quest{
				Content:     content,
				ProjectID:   projectMeta.id,
				ProjectPath: projectMeta.path,
				ProjectName: projectMeta.name,
				SessionID:   sessionID,
			})
			if err != nil {
				return err
			}
			return writeJSON(cmd.OutOrStdout(), quest)
		},
	}
	cmd.Flags().StringVar(&project, "project", "", "project path (defaults to session cwd/current repo)")
	cmd.Flags().StringVar(&file, "file", "", "read content from a file, or '-' for stdin")
	return cmd
}

func newQuestListCmd(store *state.Store) *cobra.Command {
	var project string
	var query string
	cmd := &cobra.Command{
		Use:     "ls",
		Aliases: []string{"list"},
		Short:   "List quests",
		RunE: func(cmd *cobra.Command, _ []string) error {
			projectID := ""
			if cmd.Flags().Changed("project") {
				meta, err := questProjectFromPath(project, true)
				if err != nil {
					return err
				}
				projectID = meta.id
			}
			quests, err := state.LoadQuestsAt(questStateRoot(store))
			if err != nil {
				return err
			}
			query = strings.ToLower(strings.TrimSpace(query))
			if projectID != "" || query != "" {
				quests = slices.DeleteFunc(quests, func(quest state.Quest) bool {
					return projectID != "" && quest.ProjectID != projectID ||
						query != "" && !strings.Contains(strings.ToLower(quest.Content), query)
				})
			}
			return writeJSON(cmd.OutOrStdout(), struct {
				Quests []state.Quest `json:"quests"`
			}{Quests: quests})
		},
	}
	cmd.Flags().StringVar(&project, "project", "", "filter by project path")
	cmd.Flags().StringVar(&query, "search", "", "case-insensitive content search")
	return cmd
}

func newQuestEditCmd(store *state.Store) *cobra.Command {
	var content string
	var file string
	var project string
	cmd := &cobra.Command{
		Use:   "edit <id>",
		Short: "Edit a quest",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			quests, err := state.LoadQuestsAt(questStateRoot(store))
			if err != nil {
				return err
			}
			quest, ok := findQuest(quests, args[0])
			if !ok {
				return fmt.Errorf("quest %q not found", args[0])
			}
			contentChanged := cmd.Flags().Changed("content")
			fileChanged := cmd.Flags().Changed("file")
			if contentChanged && fileChanged {
				return fmt.Errorf("quest content accepts only one of --content or --file")
			}
			if fileChanged {
				body, err := readFileOrStdin(cmd, file, "quest")
				if err != nil {
					return err
				}
				quest.Content = body
			} else if contentChanged {
				quest.Content = content
			}
			if cmd.Flags().Changed("project") {
				if strings.TrimSpace(project) == "" {
					quest.ProjectID, quest.ProjectPath, quest.ProjectName = "", "", ""
				} else {
					meta, err := questProjectFromPath(project, true)
					if err != nil {
						return err
					}
					quest.ProjectID, quest.ProjectPath, quest.ProjectName = meta.id, meta.path, meta.name
				}
			}
			saved, err := state.UpsertQuestAt(questStateRoot(store), quest)
			if err != nil {
				return err
			}
			return writeJSON(cmd.OutOrStdout(), saved)
		},
	}
	cmd.Flags().StringVar(&content, "content", "", "replacement content")
	cmd.Flags().StringVar(&file, "file", "", "read replacement content from a file, or '-' for stdin")
	cmd.Flags().StringVar(&project, "project", "", "replacement project path, or empty to clear")
	return cmd
}

func newQuestRemoveCmd(store *state.Store) *cobra.Command {
	return &cobra.Command{
		Use:     "rm <id>...",
		Aliases: []string{"remove", "delete"},
		Short:   "Remove quests",
		Args:    cobra.MinimumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			for _, id := range args {
				removed, err := state.RemoveQuestAt(questStateRoot(store), id)
				if err != nil {
					return err
				}
				if !removed {
					return fmt.Errorf("quest %q not found", id)
				}
			}
			return writeJSON(cmd.OutOrStdout(), map[string]any{"removed": args})
		},
	}
}

func newQuestStartCmd(store *state.Store, client *tmux.Client, repoRoot string) *cobra.Command {
	var title string
	var agentFlags sessionAgentFlags
	cmd := &cobra.Command{
		Use:   "start <id>...",
		Short: "Start a session from quests",
		Args:  cobra.MinimumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			quests, err := questsByID(store, args)
			if err != nil {
				return err
			}
			cwd, prompt, err := questStartPayload(quests)
			if err != nil {
				return err
			}
			registry, err := loadSessionRegistryWithOverrides(agentFlags.ConfigOverrides())
			if err != nil {
				return err
			}
			resumeIDs, err := agentFlags.ResolveResumeIDs(registry)
			if err != nil {
				return err
			}
			result, err := session.NewService(store, client, repoRoot, registry).Start(cmd.Context(), session.StartOpts{
				Title:     title,
				Cwd:       cwd,
				Prompt:    prompt,
				ResumeIDs: resumeIDs,
				Detached:  true,
			})
			if err != nil {
				return err
			}
			return writeJSON(cmd.OutOrStdout(), struct {
				SessionID string   `json:"session_id"`
				Cwd       string   `json:"cwd"`
				QuestIDs  []string `json:"quest_ids"`
			}{SessionID: result.SessionID, Cwd: result.Cwd, QuestIDs: args})
		},
	}
	cmd.Flags().StringVar(&title, "title", "", "session title")
	agentFlags.AddFlags(cmd)
	return cmd
}

type questProjectMeta struct {
	id   string
	path string
	name string
}

func questContent(cmd *cobra.Command, args []string, file string) (string, error) {
	fileSet := cmd.Flags().Changed("file")
	switch {
	case fileSet && len(args) > 0:
		return "", fmt.Errorf("quest content accepts only one of content or --file")
	case fileSet:
		return readFileOrStdin(cmd, file, "quest")
	case len(args) == 1:
		return args[0], nil
	default:
		return "", fmt.Errorf("quest content is required")
	}
}

func questSession(ctx context.Context, client *tmux.Client, sessionFlag string) (string, error) {
	if sessionFlag != "" {
		if state.IsValidSessionID(sessionFlag) {
			return sessionFlag, nil
		}
		return "", fmt.Errorf("invalid session id %q (expected qm-*)", sessionFlag)
	}
	if sessionID := state.SessionIDFromEnv(); state.IsValidSessionID(sessionID) {
		return sessionID, nil
	}
	sessionID, err := discoverSession(ctx, client)
	if err != nil {
		return "", nil
	}
	return sessionID, nil
}

func questProject(cmd *cobra.Command, store *state.Store, sessionID, project string) (questProjectMeta, error) {
	if cmd.Flags().Changed("project") {
		return questProjectFromPath(project, true)
	}
	if store != nil && sessionID != "" {
		if m, err := store.Read(sessionID); err == nil {
			if meta, err := questProjectFromPath(m.Cwd, false); err == nil && meta.id != "" {
				return meta, nil
			}
		}
	}
	cwd, err := os.Getwd()
	if err != nil {
		return questProjectMeta{}, nil
	}
	return questProjectFromPath(cwd, false)
}

func questProjectFromPath(path string, strict bool) (questProjectMeta, error) {
	path = strings.TrimSpace(path)
	if path == "" {
		return questProjectMeta{}, nil
	}
	expanded := path
	if strings.HasPrefix(expanded, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			expanded = filepath.Join(home, expanded[2:])
		}
	}
	abs, err := filepath.Abs(expanded)
	if err != nil {
		return questProjectMeta{}, err
	}
	r, ok := repo.Resolve(abs)
	if !ok {
		if strict {
			return questProjectMeta{}, fmt.Errorf("project path is not in a git repo: %s", path)
		}
		return questProjectMeta{}, nil
	}
	return questProjectMeta{id: r.Identity, path: filepath.Clean(abs), name: r.Name}, nil
}

func questStateRoot(store *state.Store) string {
	if store != nil {
		return store.Root()
	}
	return state.StateRoot()
}

func findQuest(quests []state.Quest, id string) (state.Quest, bool) {
	for _, quest := range quests {
		if quest.ID == id {
			return quest, true
		}
	}
	return state.Quest{}, false
}

func questsByID(store *state.Store, ids []string) ([]state.Quest, error) {
	all, err := state.LoadQuestsAt(questStateRoot(store))
	if err != nil {
		return nil, err
	}
	out := make([]state.Quest, 0, len(ids))
	for _, id := range ids {
		quest, ok := findQuest(all, id)
		if !ok {
			return nil, fmt.Errorf("quest %q not found", id)
		}
		out = append(out, quest)
	}
	return out, nil
}

func questStartPayload(quests []state.Quest) (string, string, error) {
	if len(quests) == 0 {
		return "", "", fmt.Errorf("quest id is required")
	}
	projectID := quests[0].ProjectID
	projectPath := quests[0].ProjectPath
	if projectID == "" || projectPath == "" {
		return "", "", fmt.Errorf("quest %q has no startable project", quests[0].ID)
	}
	var bodies []string
	for _, quest := range quests {
		if quest.ProjectID != projectID || quest.ProjectPath == "" {
			return "", "", fmt.Errorf("selected quests must share one project")
		}
		bodies = append(bodies, "- "+strings.ReplaceAll(quest.Content, "\n", "\n  "))
	}
	return projectPath, strings.Join(bodies, "\n"), nil
}
