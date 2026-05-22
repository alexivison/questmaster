package cmd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/spf13/cobra"
)

func newStateCmd(store *state.Store) *cobra.Command {
	cmd := &cobra.Command{
		Use:   "state",
		Short: "Inspect hook state files",
	}
	cmd.AddCommand(newStateLogCmd(store))
	return cmd
}

func newStateLogCmd(store *state.Store) *cobra.Command {
	var follow bool

	cmd := &cobra.Command{
		Use:   "log <session-id>",
		Short: "Print a session's hook state event log",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return runStateLog(cmd.Context(), cmd.OutOrStdout(), store, args[0], follow)
		},
	}
	cmd.Flags().BoolVarP(&follow, "follow", "f", false, "follow appended state events")
	return cmd
}

func runStateLog(ctx context.Context, w io.Writer, store *state.Store, sessionArg string, follow bool) error {
	sessionID, err := resolveStateSessionID(store, sessionArg)
	if err != nil {
		return err
	}

	path := state.SessionStateLogPath(store.Root(), sessionID)
	f, err := os.Open(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("state log for %s not found at %s", sessionID, path)
		}
		return fmt.Errorf("open state log for %s: %w", sessionID, err)
	}
	defer f.Close()

	info, err := f.Stat()
	if err != nil {
		return fmt.Errorf("stat state log for %s: %w", sessionID, err)
	}
	if info.IsDir() {
		return fmt.Errorf("state log for %s is a directory: %s", sessionID, path)
	}

	if !follow {
		_, err = io.Copy(w, f)
		return err
	}
	return followStateLog(ctx, w, f)
}

func followStateLog(ctx context.Context, w io.Writer, f *os.File) error {
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()

	for {
		if _, err := io.Copy(w, f); err != nil {
			return err
		}
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
		}
	}
}

func resolveStateSessionID(store *state.Store, raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", errors.New("session id is required")
	}

	ids, err := discoverStateSessionIDs(store)
	if err != nil {
		return "", err
	}
	idSet := make(map[string]struct{}, len(ids))
	for _, id := range ids {
		idSet[id] = struct{}{}
	}

	if _, ok := idSet[raw]; ok {
		return raw, nil
	}
	if !strings.HasPrefix(raw, "party-") {
		full := "party-" + raw
		if _, ok := idSet[full]; ok {
			return full, nil
		}
	}

	matches := make([]string, 0, 1)
	for _, id := range ids {
		if strings.HasPrefix(id, raw) || (!strings.HasPrefix(raw, "party-") && strings.HasPrefix(strings.TrimPrefix(id, "party-"), raw)) {
			matches = append(matches, id)
		}
	}
	sort.Strings(matches)

	switch len(matches) {
	case 0:
		return "", fmt.Errorf("session %q not found", raw)
	case 1:
		return matches[0], nil
	default:
		return "", fmt.Errorf("session %q is ambiguous: %s", raw, strings.Join(matches, ", "))
	}
}

func discoverStateSessionIDs(store *state.Store) ([]string, error) {
	seen := map[string]struct{}{}
	manifests, err := store.DiscoverSessions()
	if err != nil {
		return nil, fmt.Errorf("discover sessions: %w", err)
	}
	for _, manifest := range manifests {
		if state.IsValidPartyID(manifest.PartyID) {
			seen[manifest.PartyID] = struct{}{}
		}
	}

	entries, err := os.ReadDir(store.Root())
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return sortedSessionIDs(seen), nil
		}
		return nil, fmt.Errorf("read state root: %w", err)
	}
	for _, entry := range entries {
		name := entry.Name()
		switch {
		case entry.IsDir() && state.IsValidPartyID(name):
			seen[name] = struct{}{}
		case !entry.IsDir() && strings.HasSuffix(name, ".json"):
			id := strings.TrimSuffix(name, ".json")
			if state.IsValidPartyID(id) {
				seen[id] = struct{}{}
			}
		}
	}
	return sortedSessionIDs(seen), nil
}

func sortedSessionIDs(seen map[string]struct{}) []string {
	ids := make([]string, 0, len(seen))
	for id := range seen {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return ids
}
