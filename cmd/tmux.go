package cmd

import (
	"encoding/json"
	"fmt"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxconfig"
	"github.com/alexivison/questmaster/internal/tmuxroute"
	"github.com/spf13/cobra"
)

func newTmuxCmd(store *state.Store, router *tmuxroute.Router, routerErr error) *cobra.Command {
	tmuxCmd := &cobra.Command{Use: "tmux", Short: "Inspect Questmaster tmux configuration"}
	namedClient := func() (*tmux.Client, error) {
		if routerErr != nil {
			return nil, routerErr
		}
		label, err := tmux.EffectiveLabel()
		if err != nil {
			return nil, err
		}
		handle, err := router.Route(state.Manifest{TmuxServer: state.TmuxServer(label)})
		if err != nil {
			return nil, err
		}
		return handle.Client(), nil
	}
	var live bool
	routesCmd := &cobra.Command{Use: "routes [session-id...]", Short: "Report recorded tmux routes", RunE: func(cmd *cobra.Command, ids []string) error {
		if routerErr != nil {
			return routerErr
		}
		routes, err := router.Routes(cmd.Context(), ids, live)
		if err != nil {
			return err
		}
		return json.NewEncoder(cmd.OutOrStdout()).Encode(routes)
	}}
	routesCmd.Flags().BoolVar(&live, "live", false, "include only live sessions")
	tmuxCmd.AddCommand(routesCmd)
	tmuxCmd.AddCommand(&cobra.Command{Use: "audit", Short: "Audit both tmux servers without changing them", Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, _ []string) error {
		if routerErr != nil {
			return routerErr
		}
		audit, err := router.Audit(cmd.Context())
		if err != nil {
			return err
		}
		return json.NewEncoder(cmd.OutOrStdout()).Encode(audit)
	}})
	configCmd := &cobra.Command{Use: "config", Short: "Inspect Questmaster tmux config files"}
	configCmd.AddCommand(&cobra.Command{Use: "status", Short: "Report dedicated server and config status", Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, _ []string) error {
		client, err := namedClient()
		if err != nil {
			return err
		}
		status, err := tmuxconfig.Status(cmd.Context(), client, store.Root())
		if err != nil {
			return err
		}
		return json.NewEncoder(cmd.OutOrStdout()).Encode(status)
	}})
	configCmd.AddCommand(&cobra.Command{Use: "reload", Short: "Source both config files in the running server", Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, _ []string) error {
		client, err := namedClient()
		if err != nil {
			return err
		}
		result, err := tmuxconfig.Reload(cmd.Context(), client, store.Root())
		if err != nil {
			return err
		}
		return json.NewEncoder(cmd.OutOrStdout()).Encode(result)
	}})
	configCmd.AddCommand(&cobra.Command{
		Use: "path", Short: "Print config file paths", Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			label, err := tmux.EffectiveLabel()
			if err != nil {
				return err
			}
			return json.NewEncoder(cmd.OutOrStdout()).Encode(struct {
				tmuxconfig.FilePaths
				EffectiveLabel string `json:"effective_label"`
			}{tmuxconfig.Paths(store.Root()), label})
		},
	})
	configCmd.AddCommand(&cobra.Command{
		Use: "template", Short: "Print the built-in rendered template", Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			_, err := fmt.Fprint(cmd.OutOrStdout(), tmuxconfig.Template(store.Root()))
			return err
		},
	})
	var file string
	checkCmd := &cobra.Command{
		Use: "check", Short: "Validate a config on a private tmux socket", Args: cobra.NoArgs,
		Long: "Parse and execute a config on a throwaway private tmux server. Load-time run-shell and if-shell commands really run.",
		RunE: func(cmd *cobra.Command, _ []string) error {
			label, err := tmux.EffectiveLabel()
			if err != nil {
				return err
			}
			if file == "" {
				file = tmuxconfig.Paths(store.Root()).Config
			}
			errors, err := tmuxconfig.Check(cmd.Context(), file)
			if err != nil {
				return err
			}
			return json.NewEncoder(cmd.OutOrStdout()).Encode(tmuxconfig.CheckResult{OK: len(errors) == 0, Errors: errors, EffectiveLabel: label})
		},
	}
	checkCmd.Flags().StringVar(&file, "file", "", "config file to validate")
	configCmd.AddCommand(checkCmd)
	tmuxCmd.AddCommand(configCmd)
	tmuxCmd.AddCommand(&cobra.Command{Use: "restart", Short: "Restart the dedicated server only while empty", Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, _ []string) error {
		client, err := namedClient()
		if err != nil {
			return err
		}
		result, err := tmuxconfig.RestartIfEmpty(cmd.Context(), client)
		if err != nil {
			return err
		}
		return json.NewEncoder(cmd.OutOrStdout()).Encode(result)
	}})
	return tmuxCmd
}
