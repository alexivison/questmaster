//go:build linux || darwin

package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"
)

// probeUpgrade is version-independent and runs only on an explicit nudge.
func (s *server) probeUpgrade() {
	s.mu.Lock()
	active := s.active
	currentBuild := s.record.Build
	s.record.UpgradeAvailable = false
	s.mu.Unlock()
	if active > 1 {
		return
	} // this check-upgrade request is the one active request
	path := s.config.Executable
	if s.id == "canonical" {
		var err error
		path, err = filepath.EvalSymlinks(filepath.Join(s.config.Home, ".local", "bin", "questmaster"))
		if err != nil {
			return
		}
	}
	first, err := os.Stat(path)
	if err != nil || !first.Mode().IsRegular() || first.Mode().Perm()&0o111 == 0 {
		return
	}
	second, err := os.Stat(path)
	if err != nil || !os.SameFile(first, second) || first.Size() != second.Size() || !first.ModTime().Equal(second.ModTime()) {
		return
	}
	build, err := fileHash(path)
	if err != nil || build == currentBuild {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, path, "version", "--json")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.WaitDelay = time.Second
	var out bytes.Buffer
	cmd.Stdout = &out
	if err := cmd.Start(); err != nil {
		return
	}
	done := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		case <-done:
		}
	}()
	err = cmd.Wait()
	close(done)
	if err != nil {
		return
	}
	var version struct {
		ProtocolVersion int `json:"protocol_version"`
	}
	if json.Unmarshal(out.Bytes(), &version) != nil || version.ProtocolVersion < 1 {
		return
	}
	third, err := os.Stat(path)
	if err != nil || !os.SameFile(second, third) || third.Size() != second.Size() || !third.ModTime().Equal(second.ModTime()) {
		return
	}
	if s.id == "canonical" {
		current, err := filepath.EvalSymlinks(filepath.Join(s.config.Home, ".local", "bin", "questmaster"))
		if err != nil || current != path {
			return
		}
	}
	s.mu.Lock()
	s.record.UpgradeAvailable = true
	s.mu.Unlock()
	// D1b re-exec adopts the listener and lifetime locks after this gate.
}
