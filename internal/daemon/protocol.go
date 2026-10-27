//go:build linux || darwin

package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"

	"github.com/alexivison/questmaster/internal/prstatus"
	"github.com/alexivison/questmaster/internal/serve"
)

const ProtocolVersion = serve.ServeProtocolVersion

// Config supplies the daemon's durable identity and the testable lifetime settings.
type Config struct {
	Root, Home, Executable                   string
	IdleGrace, PollInterval, JobDrainTimeout time.Duration
	ReadIdleTimeout, WriteTimeout            time.Duration
	Jobs                                     []Job
	Runtime                                  *serve.Server
	ClockInterval                            time.Duration
	LoginEnvironmentRunner                   LoginEnvironmentRunner
	Exec                                     func(string, []string, []string) error
}

func (c Config) resolve() (Config, string, string, error) {
	var err error
	if c.Home == "" {
		c.Home, err = os.UserHomeDir()
		if err != nil {
			return c, "", "", err
		}
	}
	if c.Executable == "" {
		c.Executable, err = os.Executable()
		if err != nil {
			return c, "", "", err
		}
	}
	if c.Root == "" {
		return c, "", "", errors.New("state root is required")
	}
	c.Root, err = filepath.Abs(c.Root)
	if err != nil {
		return c, "", "", err
	}
	id, err := Identity(c.Root, c.Home, c.Executable)
	if err != nil {
		return c, "", "", err
	}
	socket, err := SocketPath(c.Root, id)
	if c.IdleGrace <= 0 {
		c.IdleGrace = 10 * time.Minute
	}
	if c.PollInterval <= 0 {
		c.PollInterval = 100 * time.Millisecond
	}
	if c.ReadIdleTimeout <= 0 {
		c.ReadIdleTimeout = 24 * time.Hour
	}
	if c.WriteTimeout <= 0 {
		c.WriteTimeout = 30 * time.Second
	}
	return c, id, socket, err
}

func (c Config) resolveClient() (Config, string, string, error) {
	resolved, id, socket, err := c.resolve()
	if err == nil {
		return resolved, id, socket, nil
	}
	canonical, linkErr := filepath.EvalSymlinks(filepath.Join(resolved.Home, ".local", "bin", "questmaster"))
	if linkErr != nil {
		return resolved, "", "", err
	}
	resolved.Executable = canonical
	return resolved.resolve()
}

// Record is the atomically published description of the lock holder.
type Record struct {
	Running          bool   `json:"running"`
	PID              int    `json:"pid"`
	Root             string `json:"root"`
	Identity         string `json:"identity"`
	Socket           string `json:"socket"`
	Executable       string `json:"executable"`
	ShimDirectory    string `json:"shim_directory,omitempty"`
	Build            string `json:"build"`
	Generation       int    `json:"generation"`
	Clients          int    `json:"clients"`
	Jobs             bool   `json:"jobs"`
	HasWork          bool   `json:"has_work"`
	UpgradeAvailable bool   `json:"upgrade_available"`
	UpgradeStarted   bool   `json:"upgrade_started"`
	Accepting        bool   `json:"accepting"`
}

type hello struct {
	Root            string `json:"root"`
	Identity        string `json:"identity"`
	ProtocolVersion int    `json:"protocol_version"`
	Generation      int    `json:"generation"`
	Accepting       bool   `json:"accepting"`
}

type request struct {
	Method          string `json:"method"`
	ProtocolVersion int    `json:"protocol_version"`
}
type response struct {
	OK    bool            `json:"ok"`
	Error string          `json:"error,omitempty"`
	Data  json.RawMessage `json:"data,omitempty"`
}

func dial(c Config, requireReady bool) (net.Conn, *json.Decoder, error) {
	c, id, socket, err := c.resolveClient()
	if err != nil {
		return nil, nil, err
	}
	conn, err := net.DialTimeout("unix", socket, 250*time.Millisecond)
	if err != nil {
		return nil, nil, err
	}
	_ = conn.SetReadDeadline(time.Now().Add(time.Second))
	dec := json.NewDecoder(conn)
	var h hello
	if err := dec.Decode(&h); err != nil {
		conn.Close()
		return nil, nil, err
	}
	if h.Root != c.Root || h.Identity != id {
		conn.Close()
		return nil, nil, fmt.Errorf("daemon identity mismatch")
	}
	if requireReady && (!h.Accepting || h.ProtocolVersion != ProtocolVersion) {
		conn.Close()
		return nil, nil, errors.New("daemon is exiting or has an incompatible protocol")
	}
	_ = conn.SetReadDeadline(time.Time{})
	return conn, dec, nil
}

// Ready succeeds only after the lock holder answers the matching handshake.
func Ready(c Config) error {
	conn, _, err := dial(c, true)
	if err == nil {
		err = conn.Close()
	}
	return err
}

// RequestPRRefresh wakes watched PR hosts and optionally waits for the fetch.
func RequestPRRefresh(ctx context.Context, c Config, keys []string, wait bool) (map[string]prstatus.HostResult, error) {
	conn, dec, err := dial(c, true)
	if err != nil {
		return nil, fmt.Errorf("PR refresh needs a running daemon: %w", err)
	}
	defer conn.Close()
	timeout := 5 * time.Second
	if wait {
		timeout = 30 * time.Second
	}
	deadline := time.Now().Add(timeout)
	if requested, ok := ctx.Deadline(); ok && requested.Before(deadline) {
		deadline = requested
	}
	_ = conn.SetDeadline(deadline)
	data, err := json.Marshal(struct {
		Keys []string `json:"keys"`
		Wait bool     `json:"wait"`
	}{keys, wait})
	if err != nil {
		return nil, err
	}
	if err := json.NewEncoder(conn).Encode(serve.Request{Method: "pr.refresh", Data: data, ProtocolVersion: ProtocolVersion}); err != nil {
		return nil, err
	}
	var response struct {
		OK    bool   `json:"ok"`
		Error string `json:"error"`
		Data  struct {
			Hosts map[string]prstatus.HostResult `json:"hosts"`
		} `json:"data"`
	}
	if err := dec.Decode(&response); err != nil {
		return nil, fmt.Errorf("PR refresh: %w", err)
	}
	if !response.OK {
		return nil, errors.New(response.Error)
	}
	return response.Data.Hosts, nil
}

func call(c Config, method string, requireReady bool) (Record, error) {
	conn, dec, err := dial(c, requireReady)
	if err != nil {
		return Record{}, err
	}
	defer conn.Close()
	timeout := 5 * time.Second
	if method == "check-upgrade" {
		timeout = 45 * time.Second
	}
	_ = conn.SetDeadline(time.Now().Add(timeout))
	if err := json.NewEncoder(conn).Encode(request{Method: method, ProtocolVersion: ProtocolVersion}); err != nil {
		return Record{}, err
	}
	var resp response
	if err := dec.Decode(&resp); err != nil {
		return Record{}, err
	}
	if !resp.OK {
		return Record{}, errors.New(resp.Error)
	}
	var record Record
	if len(resp.Data) > 0 {
		err = json.Unmarshal(resp.Data, &record)
	}
	return record, err
}

// Status reports the running daemon without starting one.
func Status(c Config) (Record, error) { return call(c, "status", true) }

// Stop requests a clean shutdown and returns after the lifetime lock is free.
func Stop(ctx context.Context, c Config) (Record, error) {
	record, err := call(c, "stop", true)
	if err != nil {
		return Record{}, err
	}
	c, id, _, err := c.resolveClient()
	if err != nil {
		return Record{}, err
	}
	lock, err := os.OpenFile(filepath.Join(c.Root, "daemon", id+".lock"), os.O_RDWR, 0)
	if err != nil {
		return Record{}, err
	}
	defer lock.Close()
	deadline, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	tick := time.NewTicker(c.PollInterval)
	defer tick.Stop()
	for {
		err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			_ = syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
			record.Running, record.PID, record.Clients, record.Jobs, record.HasWork, record.Accepting = false, 0, 0, false, false, false
			return record, nil
		}
		if err != syscall.EWOULDBLOCK {
			return Record{}, err
		}
		select {
		case <-deadline.Done():
			return Record{}, fmt.Errorf("wait for daemon stop: %w", deadline.Err())
		case <-tick.C:
		}
	}
}

// CheckUpgrade is connect-only and is handled before protocol validation.
func CheckUpgrade(c Config) (Record, error) { return call(c, "check-upgrade", false) }

// Ensure starts a detached run process if necessary and waits for readiness.
func Ensure(ctx context.Context, c Config) (Record, error) {
	c, id, _, err := c.resolveClient()
	if err != nil {
		return Record{}, err
	}
	if record, err := Status(c); err == nil {
		return record, nil
	}
	if old, err := CheckUpgrade(c); err == nil && (old.UpgradeStarted || old.UpgradeAvailable) {
		deadline := time.Now().Add(60 * time.Second)
		for time.Now().Before(deadline) {
			if record, err := Status(c); err == nil {
				return record, nil
			}
			select {
			case <-ctx.Done():
				return Record{}, ctx.Err()
			case <-time.After(c.PollInterval):
			}
		}
		return Record{}, errors.New("timed out waiting for daemon upgrade")
	}
	dir := filepath.Join(c.Root, "daemon")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return Record{}, err
	}
	if err := os.Chmod(c.Root, 0o700); err != nil {
		return Record{}, err
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return Record{}, err
	}
	deadline, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	tick := time.NewTicker(c.PollInterval)
	defer tick.Stop()
	starter, err := os.OpenFile(filepath.Join(dir, id+".start.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return Record{}, err
	}
	defer starter.Close()
	for {
		if err := syscall.Flock(int(starter.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err == nil {
			break
		} else if err != syscall.EWOULDBLOCK {
			return Record{}, err
		}
		if record, err := Status(c); err == nil {
			return record, nil
		}
		select {
		case <-deadline.Done():
			return Record{}, fmt.Errorf("wait for daemon starter: %w", deadline.Err())
		case <-tick.C:
		}
	}
	if record, err := Status(c); err == nil {
		return record, nil
	}
	log, err := os.OpenFile(filepath.Join(dir, id+".log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return Record{}, err
	}
	defer log.Close()
	cmd := exec.Command(c.Executable, "daemon", "run")
	cmd.Env = append(os.Environ(), "QUESTMASTER_STATE_ROOT="+c.Root, "HOME="+c.Home)
	cmd.Dir = c.Home
	cmd.Stdin, cmd.Stdout, cmd.Stderr = nil, log, log
	setDetached(cmd)
	if err := cmd.Start(); err != nil {
		return Record{}, err
	}
	_ = cmd.Process.Release()
	for {
		if record, err := Status(c); err == nil {
			return record, nil
		}
		select {
		case <-deadline.Done():
			return Record{}, fmt.Errorf("wait for daemon readiness: %w", deadline.Err())
		case <-tick.C:
		}
	}
}
