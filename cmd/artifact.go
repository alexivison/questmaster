package cmd

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"github.com/alexivison/questmaster/internal/repo"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/spf13/cobra"
)

func newArtifactCmd(store *state.Store, client *tmux.Client) *cobra.Command {
	var sessionFlag string
	cmd := &cobra.Command{
		Use:   "artifact",
		Short: "Manage session runtime artifacts",
	}
	cmd.PersistentFlags().StringVar(&sessionFlag, "session", "", "session ID (defaults to current session)")
	cmd.AddCommand(
		newArtifactAddCmd(store, client, &sessionFlag),
		newArtifactListCmd(store, client, &sessionFlag),
		newArtifactRemoveCmd(store, client, &sessionFlag),
	)
	return cmd
}

func newArtifactAddCmd(store *state.Store, client *tmux.Client, sessionFlag *string) *cobra.Command {
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
			projectID := resolveArtifactProjectID(store, sessionID)
			artifact := state.Artifact{
				Kind:      kind,
				Path:      path,
				Label:     label,
				SessionID: sessionID,
				ProjectID: projectID,
				AddedAt:   time.Now().UTC().Format(time.RFC3339Nano),
			}
			if err := state.UpsertArtifactAt(artifactStateRoot(store), sessionID, artifact); err != nil {
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

func newArtifactListCmd(store *state.Store, client *tmux.Client, sessionFlag *string) *cobra.Command {
	var scope string
	cmd := &cobra.Command{
		Use:     "ls",
		Aliases: []string{"list"},
		Short:   "List session runtime artifacts",
		RunE: func(cmd *cobra.Command, _ []string) error {
			scope, err := normalizeArtifactScope(scope)
			if err != nil {
				return err
			}
			sessionID, projectID, err := resolveArtifactScopeContext(cmd.Context(), client, store, *sessionFlag, scope)
			if err != nil {
				return err
			}
			artifacts, err := loadScopedArtifacts(store, scope, sessionID, projectID)
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
	cmd.Flags().StringVar(&scope, "scope", state.ArtifactScopeSession, "artifact scope (session, project, all)")
	return cmd
}

func newArtifactRemoveCmd(store *state.Store, client *tmux.Client, sessionFlag *string) *cobra.Command {
	var scope string
	cmd := &cobra.Command{
		Use:     "rm <path|index>",
		Aliases: []string{"remove"},
		Short:   "Remove a session runtime artifact",
		Args:    cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			scope, err := normalizeArtifactScope(scope)
			if err != nil {
				return err
			}
			sessionID, projectID, err := resolveArtifactScopeContext(cmd.Context(), client, store, *sessionFlag, scope)
			if err != nil {
				return err
			}
			target, err := resolveArtifactRemoveTarget(store, scope, sessionID, projectID, args[0])
			if err != nil {
				return err
			}
			removed := false
			root := artifactStateRoot(store)
			if target.SessionID != "" {
				removed, err = state.RemoveArtifactAt(root, target.SessionID, target.Path)
			} else {
				removed, err = state.RemoveArtifactGlobal(root, target.Path)
			}
			if err != nil {
				return err
			}
			if !removed {
				return artifactNotFoundError(args[0], scope, sessionID)
			}
			if target.SessionID != "" {
				sessionID = target.SessionID
			}
			fmt.Fprintf(cmd.OutOrStdout(), "session\t%s\nremoved\t%s\n", sessionID, target.Path)
			return nil
		},
	}
	cmd.Flags().StringVar(&scope, "scope", state.ArtifactScopeSession, "artifact scope (session, project, all)")
	return cmd
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

func resolveArtifactScopeContext(ctx context.Context, client *tmux.Client, store *state.Store, sessionFlag, scope string) (string, string, error) {
	if scope == state.ArtifactScopeAll && sessionFlag == "" {
		sessionID := state.SessionIDFromEnv()
		return sessionID, resolveArtifactProjectID(store, sessionID), nil
	}
	sessionID, err := resolveArtifactSession(ctx, client, sessionFlag)
	if err != nil {
		return "", "", err
	}
	return sessionID, resolveArtifactProjectID(store, sessionID), nil
}

func resolveArtifactProjectID(store *state.Store, sessionID string) string {
	if store == nil || sessionID == "" {
		return ""
	}
	m, err := store.Read(sessionID)
	if err != nil {
		return ""
	}
	r, ok := repo.Resolve(m.Cwd)
	if !ok {
		return ""
	}
	return r.Identity
}

func artifactStateRoot(store *state.Store) string {
	if store != nil {
		return store.Root()
	}
	return state.StateRoot()
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

func loadScopedArtifacts(store *state.Store, scope, sessionID, projectID string) ([]state.Artifact, error) {
	artifacts, err := state.LoadArtifactsGlobal(artifactStateRoot(store))
	if err != nil {
		return nil, err
	}
	return state.FilterArtifacts(artifacts, scope, sessionID, projectID), nil
}

func resolveArtifactRemoveTarget(store *state.Store, scope, sessionID, projectID, raw string) (state.Artifact, error) {
	artifacts, err := loadScopedArtifacts(store, scope, sessionID, projectID)
	if err != nil {
		return state.Artifact{}, err
	}
	if idx, ok := parseArtifactIndex(raw); ok {
		if idx < 1 || idx > len(artifacts) {
			if scope == state.ArtifactScopeSession {
				return state.Artifact{}, fmt.Errorf("artifact index %d out of range for session %s", idx, sessionID)
			}
			return state.Artifact{}, fmt.Errorf("artifact index %d out of range for %s scope", idx, scope)
		}
		return artifacts[idx-1], nil
	}
	path, err := resolveArtifactPath(raw)
	if err != nil {
		return state.Artifact{}, err
	}
	for _, artifact := range artifacts {
		if artifact.Path == path {
			return artifact, nil
		}
	}
	if scope == state.ArtifactScopeSession {
		return state.Artifact{Path: path, SessionID: sessionID}, nil
	}
	return state.Artifact{Path: path}, artifactNotFoundError(raw, scope, sessionID)
}

func normalizeArtifactScope(scope string) (string, error) {
	switch scope {
	case "", state.ArtifactScopeSession:
		return state.ArtifactScopeSession, nil
	case state.ArtifactScopeProject, state.ArtifactScopeAll:
		return scope, nil
	default:
		return "", fmt.Errorf("invalid artifact scope %q (expected session, project, or all)", scope)
	}
}

func artifactNotFoundError(raw, scope, sessionID string) error {
	if scope == state.ArtifactScopeSession {
		return fmt.Errorf("artifact %q not found in session %s", raw, sessionID)
	}
	return fmt.Errorf("artifact %q not found in %s scope", raw, scope)
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
