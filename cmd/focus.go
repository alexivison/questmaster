package cmd

import (
	"context"
	"fmt"
	"time"

	"github.com/alexivison/questmaster/internal/focus"
	"github.com/spf13/cobra"
)

func newFocusCmd() *cobra.Command {
	var socketPath string
	var timeout time.Duration

	cmd := &cobra.Command{
		Use:   "focus <h|j|k|l|left|down|up|right>",
		Short: "Hand keyboard focus from tmux to the native app",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			direction, err := focus.ParseDirection(args[0])
			if err != nil {
				return err
			}

			ctx, cancel := context.WithTimeout(cmd.Context(), timeout)
			defer cancel()

			if err := focus.Send(ctx, socketPath, direction); err != nil {
				return fmt.Errorf("focus %s: %w", direction, err)
			}
			return nil
		},
	}
	cmd.Flags().StringVar(&socketPath, "socket", "", "focus socket path (default: $QUESTMASTER_FOCUS_SOCKET or <state-root>/app-focus.sock)")
	cmd.Flags().DurationVar(&timeout, "timeout", time.Second, "focus handoff timeout")
	return cmd
}
