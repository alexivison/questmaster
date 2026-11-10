package cmd

import (
	"context"
	"fmt"
	"os"
	"strings"

	"github.com/alexivison/questmaster/internal/modelsuggest"
	"github.com/alexivison/questmaster/internal/session"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxroute"
	"github.com/spf13/cobra"
)

func newQuestCmd(store *state.Store, client *tmux.Client, repoRoot string, routers ...*tmuxroute.Router) *cobra.Command {
	var router *tmuxroute.Router
	if len(routers) > 0 {
		router = routers[0]
	}
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
		newQuestStartCmd(store, client, repoRoot, router),
	)
	return cmd
}

func newQuestAddCmd(store *state.Store, client *tmux.Client, sessionFlag *string) *cobra.Command {
	var project string
	var file string
	var types []string
	var size string
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
				Types:       questTagFlagValues(types),
				Size:        size,
			})
			if err != nil {
				return err
			}
			return writeJSON(cmd.OutOrStdout(), quest)
		},
	}
	cmd.Flags().StringVar(&project, "project", "", "project path (defaults to session cwd/current repo)")
	cmd.Flags().StringVar(&file, "file", "", "read content from a file, or '-' for stdin")
	cmd.Flags().StringArrayVar(&types, "type", nil, "quest type tags (repeatable or comma-separated)")
	cmd.Flags().StringVar(&size, "size", "", "quest size: S, M, or L")
	return cmd
}

func newQuestListCmd(store *state.Store) *cobra.Command {
	var project string
	var query string
	var types []string
	var sizes []string
	cmd := &cobra.Command{
		Use:     "ls [id...]",
		Aliases: []string{"list"},
		Short:   "List quests",
		Args:    cobra.ArbitraryArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			projectID := ""
			if cmd.Flags().Changed("project") {
				meta, err := questProjectFromPath(questStateRoot(store), project, true)
				if err != nil {
					return err
				}
				projectID = meta.id
			}
			var quests []state.Quest
			var err error
			if len(args) > 0 {
				quests, err = questsByID(store, args)
			} else {
				quests, err = state.LoadQuestsAt(questStateRoot(store))
			}
			if err != nil {
				return err
			}
			typeFilters, err := state.NormalizeQuestTypes(questTagFlagValues(types))
			if err != nil {
				return err
			}
			sizeFilters, err := state.NormalizeQuestSizes(questTagFlagValues(sizes))
			if err != nil {
				return err
			}
			return writeJSON(cmd.OutOrStdout(), struct {
				Quests []state.Quest `json:"quests"`
			}{Quests: state.FilterQuests(quests, projectID, query, typeFilters, sizeFilters)})
		},
	}
	cmd.Flags().StringVar(&project, "project", "", "filter by project path")
	cmd.Flags().StringVar(&query, "search", "", "case-insensitive content search")
	cmd.Flags().StringArrayVar(&types, "type", nil, "filter by type (repeatable or comma-separated; OR within types)")
	cmd.Flags().StringArrayVar(&sizes, "size", nil, "filter by size (repeatable or comma-separated; OR within sizes)")
	return cmd
}

func newQuestEditCmd(store *state.Store) *cobra.Command {
	var content string
	var file string
	var project string
	var types []string
	var size string
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
					meta, err := questProjectFromPath(questStateRoot(store), project, true)
					if err != nil {
						return err
					}
					quest.ProjectID, quest.ProjectPath, quest.ProjectName = meta.id, meta.path, meta.name
				}
			}
			if cmd.Flags().Changed("type") {
				quest.Types = questTagFlagValues(types)
			}
			if cmd.Flags().Changed("size") {
				quest.Size = size
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
	cmd.Flags().StringArrayVar(&types, "type", nil, "replacement type tags (repeatable or comma-separated; empty clears)")
	cmd.Flags().StringVar(&size, "size", "", "replacement size S, M, or L; empty clears")
	return cmd
}

func questTagFlagValues(values []string) []string {
	var parsed []string
	for _, value := range values {
		parsed = append(parsed, strings.Split(value, ",")...)
	}
	if len(parsed) == 1 && strings.TrimSpace(parsed[0]) == "" {
		return nil
	}
	return parsed
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

func newQuestStartCmd(store *state.Store, client *tmux.Client, repoRoot string, router *tmuxroute.Router) *cobra.Command {
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
			resumeIDs, err := agentFlags.ResolveResumeIDs(registry, cmd.Flags().Changed("resume-agent"))
			if err != nil {
				return err
			}
			svc := session.NewService(store, client, repoRoot, registry)
			if router != nil {
				svc.Router = router
			}
			svc.ReasoningEfforts = modelsuggest.ResolveReasoningEfforts
			result, err := svc.Start(cmd.Context(), session.StartOpts{
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
		return questProjectFromPath(questStateRoot(store), project, true)
	}
	if store != nil && sessionID != "" {
		if m, err := store.Read(sessionID); err == nil {
			if meta, err := questProjectFromPath(questStateRoot(store), m.Cwd, false); err == nil && meta.id != "" {
				return meta, nil
			}
		}
	}
	cwd, err := os.Getwd()
	if err != nil {
		return questProjectMeta{}, nil
	}
	return questProjectFromPath(questStateRoot(store), cwd, false)
}

func questProjectFromPath(stateRoot, path string, strict bool) (questProjectMeta, error) {
	id, abs, name, err := state.ResolveQuestProject(stateRoot, path, strict)
	return questProjectMeta{id: id, path: abs, name: name}, err
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
	byID := make(map[string]state.Quest, len(all))
	for _, quest := range all {
		byID[quest.ID] = quest
	}
	selected := make([]state.Quest, 0, len(ids))
	for _, id := range ids {
		quest, ok := byID[id]
		if !ok {
			return nil, fmt.Errorf("quest %q not found", id)
		}
		selected = append(selected, quest)
	}
	return selected, nil
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
	ids := make([]string, 0, len(quests))
	for _, quest := range quests {
		if quest.ProjectID != projectID || quest.ProjectPath == "" {
			return "", "", fmt.Errorf("selected quests must share one project")
		}
		ids = append(ids, shellArgument(quest.ID))
	}
	joinedIDs := strings.Join(ids, " ")
	return projectPath, fmt.Sprintf("Quest IDs: %s\nRead them with: questmaster quest ls -- %s", joinedIDs, joinedIDs), nil
}

func shellArgument(value string) string {
	if value == "" {
		return "''"
	}
	for _, char := range value {
		if (char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z') ||
			(char >= '0' && char <= '9') || char == '-' || char == '_' || char == '.' {
			continue
		}
		return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
	}
	return value
}
