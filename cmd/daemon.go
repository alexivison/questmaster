//go:build linux || darwin

package cmd

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"

	"github.com/alexivison/questmaster/internal/daemon"
	"github.com/alexivison/questmaster/internal/prstatus"
	"github.com/alexivison/questmaster/internal/session"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/spf13/cobra"
)

func newDaemonCmd(store *state.Store) *cobra.Command {
	parent := &cobra.Command{Use: "daemon", Short: "Manage the on-demand backend", Args: cobra.NoArgs}
	var buildFrom string
	config := func() (daemon.Config, error) {
		c, err := newDaemonConfig(store, tmux.NewExecClient())
		if err != nil {
			return daemon.Config{}, err
		}
		if buildFrom == "" {
			return c, nil
		}
		worktree, err := filepath.EvalSymlinks(buildFrom)
		if err != nil {
			return c, err
		}
		id, err := daemon.DevIdentity(worktree)
		if err != nil {
			return c, err
		}
		c.Executable = filepath.Join(c.Root, "daemon", "bin", id, "exe", "qm")
		return c, nil
	}
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
	var clockInterval time.Duration
	run := &cobra.Command{Use: "run", Short: "Run the daemon in the foreground", Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, _ []string) error {
		ctx, cancel := daemon.SignalContext(cmd.Context())
		defer cancel()
		c, err := config()
		if err != nil {
			return err
		}
		c.IdleGrace = idleGrace
		prTmux := tmux.NewExecClient()
		prTmux.CacheListSessions(time.Second)
		c.Jobs = append(c.Jobs, prstatus.NewJob(store.Root(), prTmux, prstatus.GH))
		if clockInterval > 0 {
			c.ClockInterval = clockInterval
		}
		if err := daemon.Run(ctx, c, jobs); err != nil {
			return err
		}
		return encode(cmd, daemon.Record{Running: false})
	}}
	run.Flags().BoolVar(&jobs, "jobs", false, "allow this development daemon to run background jobs")
	run.Flags().DurationVar(&idleGrace, "idle-grace", 10*time.Minute, "exit after this period without clients or work")
	run.Flags().DurationVar(&clockInterval, "clock-interval", time.Second, "clock-driven push interval")
	parent.AddCommand(run)
	start := &cobra.Command{Use: "start", Short: "Start the daemon if needed", Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, _ []string) error {
		c, err := config()
		if err != nil {
			return err
		}
		if buildFrom != "" {
			binDir := filepath.Dir(c.Executable)
			if err := os.MkdirAll(binDir, 0o700); err != nil {
				return err
			}
			file, err := os.CreateTemp(binDir, "qm-*.tmp")
			if err != nil {
				return err
			}
			tmp := file.Name()
			if err := file.Chmod(0o700); err != nil {
				file.Close()
				return err
			}
			if err := file.Close(); err != nil {
				return err
			}
			defer os.Remove(tmp)
			build := exec.CommandContext(cmd.Context(), "go", "build", "-buildvcs=false", "-o", tmp, ".")
			build.Dir = buildFrom
			build.Stderr = cmd.ErrOrStderr()
			if err := build.Run(); err != nil {
				return err
			}
			if err := os.Rename(tmp, c.Executable); err != nil {
				return err
			}
		}
		record, err := daemon.Ensure(cmd.Context(), c)
		if err != nil {
			return err
		}
		if record.Identity == "canonical" {
			home, err := os.UserHomeDir()
			if err != nil {
				return err
			}
			if err := daemon.MigrateLegacyShims(home, record.Executable); err != nil {
				return err
			}
		}
		if buildFrom != "" {
			_, _ = daemon.CheckUpgrade(c)
		}
		return encode(cmd, record)
	}}
	parent.PersistentFlags().StringVar(&buildFrom, "build-from", "", "use a stable development daemon from a worktree")
	parent.AddCommand(start)
	parent.AddCommand(&cobra.Command{Use: "status", Short: "Report daemon status", Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, _ []string) error {
		c, err := config()
		if err != nil {
			return err
		}
		record, err := daemon.Status(c)
		return report(cmd, record, err)
	}})
	parent.AddCommand(&cobra.Command{Use: "stop", Short: "Stop the daemon", Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, _ []string) error {
		c, err := config()
		if err != nil {
			return err
		}
		record, err := daemon.Stop(cmd.Context(), c)
		return report(cmd, record, err)
	}})
	parent.AddCommand(&cobra.Command{Use: "check-upgrade", Short: "Probe and start a verified replacement binary", Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, _ []string) error {
		c, err := config()
		if err != nil {
			return err
		}
		record, err := daemon.CheckUpgrade(c)
		return report(cmd, record, err)
	}})
	return parent
}

func newDaemonConfig(store *state.Store, tmuxClient *tmux.Client) (daemon.Config, error) {
	root, err := filepath.Abs(store.Root())
	if err != nil {
		return daemon.Config{}, err
	}
	return daemon.Config{
		Root: root,
		Jobs: []daemon.Job{session.NewClassBackfillJob(state.OpenStore(root), tmuxClient)},
	}, nil
}
