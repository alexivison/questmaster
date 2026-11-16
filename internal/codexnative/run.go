//go:build linux || darwin

package codexnative

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"sync"
	"syscall"
	"time"
)

// Options carries the session's existing configuration and terminal into the
// app-server owner and the TUI attached to it.
type Options struct {
	Binary, RuntimeDir string
	Config, Args       []string
	In                 io.Reader
	Out, Err           io.Writer
	command            func(string, ...string) *exec.Cmd
}

// Run supervises exactly one app-server for the foreground TUI. It does not
// start or modify Codex's shared daemon. Either child exiting stops the other.
func Run(ctx context.Context, opts Options) error {
	enabled, err := Enabled(opts.RuntimeDir)
	if err != nil {
		return err
	}
	if !enabled || opts.Binary == "" {
		return errors.New("managed Codex requires a prepared native runtime and binary")
	}
	path, err := SocketPath(opts.RuntimeDir)
	if err != nil {
		return err
	}
	if _, err := os.Lstat(path); !errors.Is(err, os.ErrNotExist) {
		return errors.New("Codex app-server socket already exists; refusing a second owner")
	}
	logFile, err := os.OpenFile(filepath.Join(opts.RuntimeDir, "codex-server.log"), os.O_CREATE|os.O_TRUNC|os.O_WRONLY|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return err
	}
	defer logFile.Close()
	if err := logFile.Chmod(0o600); err != nil {
		return err
	}
	log := &boundedLog{out: logFile, remaining: 1 << 20}
	if opts.command == nil {
		opts.command = exec.Command
	}
	ctx, cancel := signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	defer cancel()
	var configArgs []string
	for _, setting := range opts.Config {
		configArgs = append(configArgs, "-c", setting)
	}
	serverArgs := append([]string{"app-server", "--listen", "unix://" + path}, configArgs...)
	serverCmd := opts.command(opts.Binary, serverArgs...)
	serverCmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	serverCmd.Stdout, serverCmd.Stderr = log, log
	server, err := startChild(serverCmd)
	if err != nil {
		return fmt.Errorf("start Codex app-server: %w", err)
	}
	defer os.Remove(path)
	defer server.stop(true)
	readyCtx, readyCancel := context.WithTimeout(ctx, 10*time.Second)
	defer readyCancel()
	if err := waitSocket(readyCtx, opts.RuntimeDir, server); err != nil {
		return fmt.Errorf("Codex app-server startup: %w; see codex-server.log in the session runtime", err)
	}
	tuiArgs := append(append([]string{}, configArgs...), "--remote", "unix://"+path)
	tuiArgs = append(tuiArgs, opts.Args...)
	tuiCmd := opts.command(opts.Binary, tuiArgs...)
	tuiCmd.Stdin, tuiCmd.Stdout, tuiCmd.Stderr = opts.In, opts.Out, opts.Err
	tui, err := startChild(tuiCmd)
	if err != nil {
		return fmt.Errorf("start Codex TUI: %w", err)
	}
	defer tui.stop(false)
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-tui.done:
		return tui.err
	case <-server.done:
		return fmt.Errorf("Codex app-server exited while the TUI was running: %v; see codex-server.log", server.err)
	}
}

type child struct {
	cmd  *exec.Cmd
	done chan struct{}
	err  error
}

func startChild(cmd *exec.Cmd) (*child, error) {
	cmd.WaitDelay = 2 * time.Second
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	c := &child{cmd: cmd, done: make(chan struct{})}
	go func() { c.err = cmd.Wait(); close(c.done) }()
	return c, nil
}

func (c *child) stop(group bool) {
	select {
	case <-c.done:
		return
	default:
	}
	stop := func(sig syscall.Signal) {
		if group {
			_ = syscall.Kill(-c.cmd.Process.Pid, sig)
		} else {
			_ = c.cmd.Process.Signal(sig)
		}
	}
	stop(syscall.SIGTERM)
	timer := time.NewTimer(2 * time.Second)
	defer timer.Stop()
	select {
	case <-c.done:
	case <-timer.C:
		stop(syscall.SIGKILL)
		<-c.done
	}
}

func waitSocket(ctx context.Context, dir string, server *child) error {
	ticker := time.NewTicker(25 * time.Millisecond)
	defer ticker.Stop()
	for {
		path, err := resolveSocket(dir)
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		if err == nil {
			conn, err := (&net.Dialer{}).DialContext(ctx, "unix", path)
			if err == nil {
				conn.Close()
				return nil
			}
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-server.done:
			return fmt.Errorf("server exited: %v", server.err)
		case <-ticker.C:
		}
	}
}

type boundedLog struct {
	sync.Mutex
	out       io.Writer
	remaining int
}

func (w *boundedLog) Write(p []byte) (int, error) {
	w.Lock()
	defer w.Unlock()
	n := len(p)
	if len(p) > w.remaining {
		p = p[:w.remaining]
	}
	written, err := w.out.Write(p)
	w.remaining -= written
	return n, err
}
