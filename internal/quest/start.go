package quest

import (
	"fmt"
	"strings"

	"github.com/alexivison/questmaster/internal/state"
)

func LoadByID(root string, ids []string) ([]state.Quest, error) {
	quests, err := state.LoadQuestsAt(root)
	if err != nil {
		return nil, err
	}
	byID := make(map[string]state.Quest, len(quests))
	for _, quest := range quests {
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

func StartPayload(quests []state.Quest) (string, string, error) {
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
		ids = append(ids, quest.ID)
	}
	joinedIDs := strings.Join(ids, " ")
	return projectPath, fmt.Sprintf("Quest IDs: %s\nRead them with: questmaster quest ls %s", joinedIDs, joinedIDs), nil
}
