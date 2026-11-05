//go:build linux || darwin

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/alexivison/questmaster/internal/daemon"
	"github.com/alexivison/questmaster/internal/serve"
)

type drainJob struct{ root string }

func (j drainJob) Name() string { return "drain" }
func (j drainJob) HasWork() bool {
	_, err := os.Stat(filepath.Join(j.root, "daemon", "work"))
	return err == nil
}
func (j drainJob) Run(ctx context.Context) error {
	started, err := os.OpenFile(filepath.Join(j.root, "daemon", "job-starts"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	_, err = started.WriteString("x")
	started.Close()
	if err != nil {
		return err
	}
	<-ctx.Done()
	_ = os.WriteFile(filepath.Join(j.root, "daemon", "draining"), nil, 0o600)
	for {
		if _, err := os.Stat(filepath.Join(j.root, "daemon", "release-drain")); err == nil {
			return nil
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func handle(ctx context.Context, root, method string) error {
	switch method {
	case "hold":
		if err := os.WriteFile(filepath.Join(root, "daemon", "hold-started"), nil, 0o600); err != nil {
			return err
		}
		for {
			if _, err := os.Stat(filepath.Join(root, "daemon", "hold-release")); err == nil {
				return nil
			}
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(10 * time.Millisecond):
			}
		}
	case "spawn-child":
		child := exec.Command("sleep", "60")
		if err := child.Start(); err != nil {
			return err
		}
		go child.Wait()
		return os.WriteFile(filepath.Join(root, "daemon", "child-pid"), []byte(fmt.Sprint(child.Process.Pid)), 0o600)
	default:
		return fmt.Errorf("unknown method %s", method)
	}
}

type mutationRunner struct{ root string }

func (r mutationRunner) RunMutationCommand(ctx context.Context, args []string, _ []byte) ([]byte, error) {
	if len(args) == 0 || args[0] != "start" && args[0] != "spawn" || len(args) < 2 {
		return nil, fmt.Errorf("unsupported test mutation %v", args)
	}
	if args[len(args)-1] == "environment" {
		env := map[string]string{}
		for _, key := range []string{"HOME", "SHELL", "LANG", "PATH", "SSH_AUTH_SOCK", "CODEX_HOME", "CLAUDECODE", "TMUX", "TERM", "QUESTMASTER_SESSION", "QUESTMASTER_HOME", "QUESTMASTER_QM", "QUESTMASTER_STATE_ROOT", "QUESTMASTER_APP", "QUESTMASTER_BIN", "QUESTMASTER_PATH_PREFIX", "XDG_CONFIG_HOME"} {
			env[key] = os.Getenv(key)
		}
		env["zoxide"], _ = exec.LookPath("zoxide")
		env["codex"], _ = exec.LookPath("codex")
		return json.Marshal(env)
	}
	if err := handle(ctx, r.root, args[len(args)-1]); err != nil {
		return nil, err
	}
	return []byte("{}"), nil
}

func main() {
	if len(os.Args) == 3 && os.Args[1] == "version" && os.Args[2] == "--json" {
		_ = json.NewEncoder(os.Stdout).Encode(map[string]int{"protocol_version": daemon.ProtocolVersion})
		return
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	root := os.Getenv("QUESTMASTER_STATE_ROOT")
	if err := daemon.Run(ctx, daemon.Config{Root: root, Home: os.Getenv("HOME"), IdleGrace: 500 * time.Millisecond, PollInterval: 10 * time.Millisecond, Jobs: []daemon.Job{drainJob{root}}, Runtime: &serve.Server{MutationRunner: mutationRunner{root}}}, false); err != nil {
		os.Exit(1)
	}
}
