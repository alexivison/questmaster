package cmd

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/spf13/cobra"
)

func newArtifactCmd(client *tmux.Client) *cobra.Command {
	var sessionFlag string
	cmd := &cobra.Command{
		Use:   "artifact",
		Short: "Manage session runtime artifacts",
	}
	cmd.PersistentFlags().StringVar(&sessionFlag, "session", "", "session ID (defaults to current session)")
	cmd.AddCommand(
		newArtifactAddCmd(client, &sessionFlag),
		newArtifactListCmd(client, &sessionFlag),
		newArtifactRemoveCmd(client, &sessionFlag),
	)
	return cmd
}

func newArtifactAddCmd(client *tmux.Client, sessionFlag *string) *cobra.Command {
	var label string
	var kind string
	cmd := &cobra.Command{
		Use:   "add <path>",
		Short: "Register an artifact file for the current session",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			sessionID, err := resolveArtifactSession(cmd.Context(), client, *sessionFlag)
			if err != nil {
				return err
			}
			path, err := resolveArtifactPath(args[0])
			if err != nil {
				return err
			}
			artifact := state.Artifact{
				Kind:    kind,
				Path:    path,
				Label:   label,
				AddedAt: time.Now().UTC().Format(time.RFC3339Nano),
			}
			if err := state.UpsertArtifact(sessionID, artifact); err != nil {
				return err
			}
			if state.ArtifactMissing(path) {
				fmt.Fprintf(cmd.ErrOrStderr(), "warning: artifact file does not exist yet: %s\n", path)
			}
			fmt.Fprintf(cmd.OutOrStdout(), "session\t%s\npath\t%s\n", sessionID, path)
			return nil
		},
	}
	cmd.Flags().StringVar(&label, "label", "", "display label (defaults to file name)")
	cmd.Flags().StringVar(&kind, "kind", "", "artifact kind override (defaults from file extension)")
	return cmd
}

func newArtifactListCmd(client *tmux.Client, sessionFlag *string) *cobra.Command {
	return &cobra.Command{
		Use:     "ls",
		Aliases: []string{"list"},
		Short:   "List session runtime artifacts",
		RunE: func(cmd *cobra.Command, _ []string) error {
			sessionID, err := resolveArtifactSession(cmd.Context(), client, *sessionFlag)
			if err != nil {
				return err
			}
			artifacts, err := state.LoadArtifacts(sessionID)
			if err != nil {
				return err
			}
			for i, artifact := range artifacts {
				status := "ok"
				if state.ArtifactMissing(artifact.Path) {
					status = "missing"
				}
				fmt.Fprintf(cmd.OutOrStdout(), "%d\t%s\t%s\t%s\t%s\t%s\n", i+1, status, artifact.Kind, artifact.Label, artifact.Path, artifact.AddedAt)
			}
			return nil
		},
	}
}

func newArtifactRemoveCmd(client *tmux.Client, sessionFlag *string) *cobra.Command {
	return &cobra.Command{
		Use:     "rm <path|index>",
		Aliases: []string{"remove"},
		Short:   "Remove a session runtime artifact",
		Args:    cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			sessionID, err := resolveArtifactSession(cmd.Context(), client, *sessionFlag)
			if err != nil {
				return err
			}
			path, err := resolveArtifactRemoveTarget(sessionID, args[0])
			if err != nil {
				return err
			}
			removed, err := state.RemoveArtifact(sessionID, path)
			if err != nil {
				return err
			}
			if !removed {
				return fmt.Errorf("artifact %q not found in session %s", args[0], sessionID)
			}
			fmt.Fprintf(cmd.OutOrStdout(), "session\t%s\nremoved\t%s\n", sessionID, path)
			return nil
		},
	}
}

func resolveArtifactSession(ctx context.Context, client *tmux.Client, sessionFlag string) (string, error) {
	if sessionFlag != "" {
		if !state.IsValidSessionID(sessionFlag) {
			return "", fmt.Errorf("invalid session id %q (expected qm-*)", sessionFlag)
		}
		return sessionFlag, nil
	}
	return discoverSession(ctx, client)
}

func resolveArtifactPath(raw string) (string, error) {
	if raw == "" {
		return "", fmt.Errorf("artifact path is required")
	}
	path := raw
	if !filepath.IsAbs(path) {
		cwd, err := os.Getwd()
		if err != nil {
			return "", fmt.Errorf("resolve cwd: %w", err)
		}
		path = filepath.Join(cwd, path)
	}
	return filepath.Clean(path), nil
}

func resolveArtifactRemoveTarget(sessionID, raw string) (string, error) {
	if idx, ok := parseArtifactIndex(raw); ok {
		artifacts, err := state.LoadArtifacts(sessionID)
		if err != nil {
			return "", err
		}
		if idx < 1 || idx > len(artifacts) {
			return "", fmt.Errorf("artifact index %d out of range for session %s", idx, sessionID)
		}
		return artifacts[idx-1].Path, nil
	}
	return resolveArtifactPath(raw)
}

func parseArtifactIndex(raw string) (int, bool) {
	if raw == "" {
		return 0, false
	}
	for _, r := range raw {
		if r < '0' || r > '9' {
			return 0, false
		}
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n < 1 {
		return 0, false
	}
	return n, true
}
