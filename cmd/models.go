package cmd

import (
	"fmt"
	"strings"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/modelsuggest"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/spf13/cobra"
)

type modelsOptions struct {
	role    string
	query   string
	limit   int
	refresh bool
	text    bool
}

// modelsCatalogFetch overrides the catalog fetcher `questmaster models` uses.
// Nil (the default) leaves modelsuggest to use its own HTTPFetcher. Tests set
// this so --refresh's cache-bypass behavior can be proven at the CLI layer
// without ever reaching the network.
var modelsCatalogFetch modelsuggest.Fetcher

// newModelsCmd lists the models an agent can be launched with, resolved at
// runtime from the harness itself, the models.dev catalog, and models this
// agent has run here before. It is what a master reads before passing
// `spawn --model <id>`, and what the native app's picker shows.
func newModelsCmd(store *state.Store) *cobra.Command {
	var opts modelsOptions

	cmd := &cobra.Command{
		Use:   "models [agent]",
		Short: "List the models an agent can be launched with",
		Long: `List the models an agent can be launched with.

The list is resolved at runtime — from the harness itself where it can
enumerate its models, from the models.dev catalog (cached under the state
root), and from models this agent has already run here — so a newly released
model appears without a questmaster update. It is advisory: start --model and
spawn --model accept any id the harness understands, listed or not.`,
		Args: cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			agentName := ""
			if len(args) == 1 {
				agentName = strings.TrimSpace(args[0])
			}
			if agentName == "" {
				return fmt.Errorf("agent is required (one of: %s)", strings.Join(agent.Names(), ", "))
			}
			role, err := parseModelsRoleFlag(opts.role)
			if err != nil {
				return err
			}

			suggestions := modelsuggest.Resolve(cmd.Context(), modelsuggest.ResolveOptions{
				Agent:   agentName,
				Role:    role,
				Query:   opts.query,
				Limit:   opts.limit,
				Refresh: opts.refresh,
				Root:    store.Root(),
				Store:   store,
				Fetch:   modelsCatalogFetch,
			})
			if opts.text {
				writeModelsText(cmd, suggestions)
				return nil
			}
			return writeJSON(cmd.OutOrStdout(), suggestions)
		},
	}

	cmd.Flags().StringVar(&opts.role, "role", "standalone", "role the model would launch in (standalone, master, worker)")
	cmd.Flags().StringVar(&opts.query, "query", "", "filter models by substring")
	cmd.Flags().IntVar(&opts.limit, "limit", 0, "maximum models to list (0 uses the default)")
	cmd.Flags().BoolVar(&opts.refresh, "refresh", false, "refetch the model catalog instead of using the cache")
	cmd.Flags().BoolVar(&opts.text, "text", false, "print human-readable text instead of JSON")
	return cmd
}

// parseModelsRoleFlag validates --role against the values modelsuggest.ParseRole
// treats meaningfully. ParseRole itself defaults anything unrecognized to
// standalone with no error, which would otherwise let a typo like "wrker"
// silently change semantics instead of failing loudly.
func parseModelsRoleFlag(value string) (agent.SessionRole, error) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "", "standalone":
		return agent.RoleStandalone, nil
	case "master", "primary":
		return agent.RoleMaster, nil
	case "worker":
		return agent.RoleWorker, nil
	default:
		return agent.RoleStandalone, fmt.Errorf("invalid --role %q (want standalone, master, or worker)", value)
	}
}

func writeModelsText(cmd *cobra.Command, suggestions modelsuggest.Suggestions) {
	out := cmd.OutOrStdout()
	fmt.Fprintf(out, "%s (%s) · default: %s · source: %s\n",
		suggestions.Agent, suggestions.Role, defaultLabel(suggestions.Default), suggestions.Source)
	if len(suggestions.Models) == 0 {
		fmt.Fprintln(out, "  no models resolved — pass any id the harness understands")
		return
	}
	for _, model := range suggestions.Models {
		if model.Note == "" {
			fmt.Fprintf(out, "  %s\n", model.ID)
			continue
		}
		fmt.Fprintf(out, "  %-32s %s\n", model.ID, model.Note)
	}
}

func defaultLabel(value string) string {
	if strings.TrimSpace(value) == "" {
		return "harness default"
	}
	return value
}
