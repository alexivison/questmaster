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
	var clockInterval time.Duration

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
				SocketPath:           socketPath,
				Snapshotter:          serve.NewSnapshotter(store, client, nil),
				ClockInterval:        clockInterval,
				EnableLoopSupervisor: true,
			}
			return srv.Serve(ctx)
		},
	}
	cmd.Flags().StringVar(&socketPath, "socket", "", "Unix socket path (default: <state-root>/serve.sock)")
	cmd.Flags().DurationVar(&clockInterval, "clock-interval", time.Second, "clock-driven push interval for elapsed/runtime fields")
	cmd.Flags().DurationVar(&clockInterval, "interval", time.Second, "deprecated alias for --clock-interval")
	_ = cmd.Flags().MarkDeprecated("interval", "use --clock-interval")
	return cmd
}
