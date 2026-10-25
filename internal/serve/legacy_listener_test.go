//go:build linux || darwin

package serve

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"syscall"
	"time"

	"github.com/alexivison/questmaster/internal/state"
)

// DefaultSocketPath supplies the former socket path for transport tests.
func DefaultSocketPath() string {
	if root := state.StateRoot(); root != "" {
		return filepath.Join(root, "serve.sock")
	}
	return filepath.Join(os.TempDir(), "questmaster-serve.sock")
}

// Serve starts the local socket server and runs until ctx is canceled.
func (s *Server) Serve(ctx context.Context) error {
	path := s.SocketPath
	if path == "" {
		path = DefaultSocketPath()
	}
	if s.Snapshotter == nil {
		// Transport tests can exercise the zero-value server.
		s.Snapshotter = NewSnapshotter(nil, nil, nil)
	}
	if root := s.Snapshotter.StateRoot(); root != "" {
		if err := state.EnsurePrivateStateRoot(root); err != nil {
			return fmt.Errorf("secure state root: %w", err)
		}
	}
	clockInterval := s.ClockInterval
	if clockInterval <= 0 {
		clockInterval = time.Second
	}
	if err := prepareSocket(path); err != nil {
		return err
	}
	changeSource := s.ChangeSource
	if changeSource == nil {
		source, err := NewFileChangeSource(ctx, s.Snapshotter, clockInterval)
		if err != nil {
			return err
		}
		changeSource = source
		defer changeSource.Close() //nolint:errcheck
	}
	ln, err := net.Listen("unix", path)
	if err != nil {
		return fmt.Errorf("listen %s: %w", path, err)
	}
	if err := os.Chmod(path, 0o600); err != nil {
		ln.Close()      //nolint:errcheck
		os.Remove(path) //nolint:errcheck
		return fmt.Errorf("restrict socket permissions: %w", err)
	}
	defer os.Remove(path) //nolint:errcheck
	defer ln.Close()      //nolint:errcheck

	go func() {
		<-ctx.Done()
		_ = ln.Close()
	}()

	for {
		conn, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				return nil
			}
			return fmt.Errorf("accept: %w", err)
		}
		go s.handleConn(ctx, conn, changeSource)
	}
}

func prepareSocket(path string) error {
	if path == "" {
		return fmt.Errorf("socket path is required")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return fmt.Errorf("create socket directory: %w", err)
	}
	info, err := os.Stat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("stat socket: %w", err)
	}
	if info.Mode()&os.ModeSocket == 0 {
		return fmt.Errorf("socket path exists and is not a socket: %s", path)
	}
	conn, err := net.DialTimeout("unix", path, 100*time.Millisecond)
	if err == nil {
		conn.Close() //nolint:errcheck
		return fmt.Errorf("serve socket already active at %s", path)
	}
	if !ownedByCurrentUID(info) {
		return fmt.Errorf("refusing to remove stale socket not owned by current user: %s", path)
	}
	if err := os.Remove(path); err != nil {
		return fmt.Errorf("remove stale socket: %w", err)
	}
	return nil
}

func ownedByCurrentUID(info os.FileInfo) bool {
	stat, ok := info.Sys().(*syscall.Stat_t)
	return ok && int(stat.Uid) == os.Getuid()
}

func (s *Server) handleConn(ctx context.Context, conn net.Conn, changeSource ChangeSource) {
	defer conn.Close() //nolint:errcheck

	dec := json.NewDecoder(conn)
	enc := json.NewEncoder(conn)
	for {
		var req Request
		if err := dec.Decode(&req); err != nil {
			return
		}
		if req.Method == "subscribe" {
			if err := WriteEnvelope(enc, s.HandleRequest(ctx, req)); err != nil {
				return
			}
			_ = s.Subscribe(ctx, enc, req, changeSource)
			return
		}
		if err := WriteEnvelope(enc, s.HandleRequest(ctx, req)); err != nil {
			return
		}
	}
}
