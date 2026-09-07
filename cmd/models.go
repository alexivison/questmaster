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

			suggestions := modelsuggest.Resolve(cmd.Context(), modelsuggest.ResolveOptions{
				Agent:   agentName,
				Role:    modelsuggest.ParseRole(opts.role),
				Query:   opts.query,
				Limit:   opts.limit,
				Refresh: opts.refresh,
				Root:    store.Root(),
				Store:   store,
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
