package cmd

import (
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/alexivison/questmaster/internal/serve"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/spf13/cobra"
)

func newServeCmd(store *state.Store, client *tmux.Client) *cobra.Command {
	var socketPath string
	var interval time.Duration

	cmd := &cobra.Command{
		Use:   "serve",
		Short: "Serve read-only questmaster runtime JSON over a local socket",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			if socketPath == "" {
				socketPath = serve.DefaultSocketPath()
			}
			ctx, stop := signal.NotifyContext(cmd.Context(), os.Interrupt, syscall.SIGTERM)
			defer stop()

			fmt.Fprintf(cmd.ErrOrStderr(), "qm serve listening on %s\n", socketPath)
			srv := &serve.Server{
				SocketPath:  socketPath,
				Snapshotter: serve.NewSnapshotter(store, client, nil),
				Interval:    interval,
			}
			return srv.Serve(ctx)
		},
	}
	cmd.Flags().StringVar(&socketPath, "socket", "", "Unix socket path (default: <state-root>/serve.sock)")
	cmd.Flags().DurationVar(&interval, "interval", time.Second, "snapshot push interval")
	return cmd
}
