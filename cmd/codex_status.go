package cmd

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/anthropics/ai-config/tools/party-cli/internal/tmux"
	"github.com/spf13/cobra"
)

func newStatusWriteCmd(client *tmux.Client) *cobra.Command {
	var opts struct {
		session  string
		target   string
		mode     string
		verdict  string
		errMsg   string
	}

	cmd := &cobra.Command{
		Use:   "write <state>",
		Short: "Write codex-status.json atomically",
		Long: `Write codex-status.json to the session's runtime directory.

Matches the write_codex_status() contract from party-lib.sh.
State is one of: working, idle, error.`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx := cmd.Context()
			state := args[0]

			sessionID := opts.session
			if sessionID == "" {
				id, err := discoverSession(ctx, client)
				if err != nil {
					return err
				}
				sessionID = id
			}

			runtimeDir := filepath.Join(os.TempDir(), sessionID)
			if err := os.MkdirAll(runtimeDir, 0o755); err != nil {
				return fmt.Errorf("create runtime dir: %w", err)
			}

			now := time.Now().UTC().Format("2006-01-02T15:04:05Z")

			data := map[string]string{"state": state}
			if opts.target != "" {
				data["target"] = opts.target
			}
			if opts.mode != "" {
				data["mode"] = opts.mode
			}
			if opts.verdict != "" {
				data["verdict"] = opts.verdict
			}
			if state == "working" {
				data["started_at"] = now
			} else {
				data["finished_at"] = now
			}
			if opts.errMsg != "" {
				data["error"] = opts.errMsg
			}

			jsonBytes, err := json.MarshalIndent(data, "", "  ")
			if err != nil {
				return fmt.Errorf("marshal status: %w", err)
			}

			tmpFile := filepath.Join(runtimeDir, "codex-status.json.tmp")
			finalFile := filepath.Join(runtimeDir, "codex-status.json")

			if err := os.WriteFile(tmpFile, append(jsonBytes, '\n'), 0o644); err != nil {
				return fmt.Errorf("write tmp: %w", err)
			}
			if err := os.Rename(tmpFile, finalFile); err != nil {
				return fmt.Errorf("rename: %w", err)
			}
			return nil
		},
	}

	cmd.Flags().StringVar(&opts.session, "session", "", "session ID (default: auto-discover)")
	cmd.Flags().StringVar(&opts.target, "target", "", "review target (base branch, file path, etc.)")
	cmd.Flags().StringVar(&opts.mode, "mode", "", "operation mode (review, plan-review, prompt)")
	cmd.Flags().StringVar(&opts.verdict, "verdict", "", "review verdict (APPROVE, REQUEST_CHANGES, etc.)")
	cmd.Flags().StringVar(&opts.errMsg, "error", "", "error message")

	return cmd
}

// newStatusCmd group is already defined in status.go, so we create a sub-group.
// This function returns the "status write" subcommand to be added to the existing
// status command or as a new "codex-status" top-level command.
func newCodexStatusCmd(client *tmux.Client) *cobra.Command {
	cmd := &cobra.Command{
		Use:   "codex-status",
		Short: "Manage codex-status.json",
	}
	cmd.AddCommand(newStatusWriteCmd(client))
	return cmd
}
