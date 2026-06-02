package cmd

import (
	"fmt"

	"github.com/alexivison/questmaster/internal/quests/quest"
	"github.com/spf13/cobra"
)

// newQuestCmd builds the `questmaster quest ...` command group: authoring,
// validation, and (in later slices) status transitions and viewing. The quest
// store is the dotfile store under the questmaster home, resolved fresh on each
// invocation so $QUESTMASTER_HOME overrides (and tests) take effect.
func newQuestCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "quest",
		Short: "Author, validate, and inspect quests",
		Long: `Quests are HTML plan files (canonical JSON + generated body) stored under the
questmaster home (~/.questmaster/quests), never in a repo. Status is human-owned:
a quest is born wip, approved to active, and marked done by the Questmaster.`,
	}

	cmd.AddCommand(newQuestValidateCmd())

	return cmd
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
