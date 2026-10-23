//go:build linux || darwin

package cmd

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"syscall"
	"time"

	"github.com/alexivison/questmaster/internal/daemon"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/spf13/cobra"
)

func newDaemonCmd(store *state.Store) *cobra.Command {
	parent := &cobra.Command{Use: "daemon", Short: "Manage the on-demand backend", Args: cobra.NoArgs}
	config := func() daemon.Config { return daemon.Config{Root: store.Root()} }
	encode := func(cmd *cobra.Command, value any) error { return json.NewEncoder(cmd.OutOrStdout()).Encode(value) }
	report := func(cmd *cobra.Command, record daemon.Record, err error) error {
		if err != nil {
			if !errors.Is(err, os.ErrNotExist) && !errors.Is(err, syscall.ECONNREFUSED) && !errors.Is(err, io.EOF) {
				return err
			}
			record = daemon.Record{Running: false}
		}
		return encode(cmd, record)
	}
	var jobs bool
	var idleGrace time.Duration
	run := &cobra.Command{Use: "run", Short: "Run the daemon in the foreground", Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, _ []string) error {
		ctx, cancel := daemon.SignalContext(cmd.Context())
		defer cancel()
		c := config()
		c.IdleGrace = idleGrace
		if err := daemon.Run(ctx, c, jobs); err != nil {
			return err
		}
		return encode(cmd, daemon.Record{Running: false})
	}}
	run.Flags().BoolVar(&jobs, "jobs", false, "allow this development daemon to run background jobs")
	run.Flags().DurationVar(&idleGrace, "idle-grace", 10*time.Minute, "exit after this period without clients or work")
	parent.AddCommand(run)
	parent.AddCommand(&cobra.Command{Use: "start", Short: "Start the daemon if needed", Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, _ []string) error {
		record, err := daemon.Ensure(cmd.Context(), config())
		if err != nil {
			return err
		}
		return encode(cmd, record)
	}})
	parent.AddCommand(&cobra.Command{Use: "status", Short: "Report daemon status", Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, _ []string) error {
		record, err := daemon.Status(config())
		return report(cmd, record, err)
	}})
	parent.AddCommand(&cobra.Command{Use: "stop", Short: "Stop the daemon", Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, _ []string) error {
		record, err := daemon.Stop(cmd.Context(), config())
		return report(cmd, record, err)
	}})
	parent.AddCommand(&cobra.Command{Use: "check-upgrade", Short: "Check for a verified replacement binary", Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, _ []string) error {
		record, err := daemon.CheckUpgrade(config())
		return report(cmd, record, err)
	}})
	return parent
}
