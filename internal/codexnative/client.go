//go:build linux || darwin

// Package codexnative runs a session-owned Codex app-server and submits messages
// to the same thread used by its interactive TUI.
package codexnative

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"syscall"
	"time"

	"github.com/coder/websocket"
)

const (
	MarkerName = "codex-native"
	SocketName = "cx.sock"
	maxFrame   = 2 << 20
	maxMessage = 1 << 20
)

// Enabled distinguishes managed sessions from older, tmux-only Codex sessions.
// An invalid marker is an error: it must not cause a second send through tmux.
func Enabled(dir string) (bool, error) {
	path := filepath.Join(dir, MarkerName)
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if err := privateFile(info, false); err != nil {
		return false, err
	}
	if info.Size() != 2 {
		return false, errors.New("invalid Codex native marker")
	}
	if _, err := SocketPath(dir); err != nil {
		return false, err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return false, err
	}
	if string(data) != "1\n" {
		return false, errors.New("unsupported Codex native marker")
	}
	return true, nil
}

// SocketPath validates the private directory and the macOS Unix path limit.
func SocketPath(dir string) (string, error) {
	if !filepath.IsAbs(dir) || filepath.Clean(dir) != dir {
		return "", errors.New("Codex runtime directory must be an absolute clean path")
	}
	info, err := os.Lstat(dir)
	if err != nil {
		return "", err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return "", errors.New("Codex runtime path is not a directory")
	}
	if err := privateFile(info, true); err != nil {
		return "", err
	}
	path := filepath.Join(dir, SocketName)
	if len(path) > 103 {
		return "", errors.New("Codex socket path exceeds 103 bytes; use a shorter Questmaster state root")
	}
	return path, nil
}

func privateFile(info os.FileInfo, directory bool) error {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || int(stat.Uid) != os.Getuid() || info.Mode().Perm()&0o077 != 0 {
		return errors.New("Codex runtime files must be owned by this user and owner-only")
	}
	if !directory && !info.Mode().IsRegular() {
		return errors.New("Codex native marker is not a regular file")
	}
	return nil
}

// Codex publishes a rendezvous symlink to a socket in its protected per-user
// directory. Validate both ends and dial the resolved path, so changing the
// advertised alias cannot redirect a connection after validation.
func resolveSocket(dir string) (string, error) {
	path, err := SocketPath(dir)
	if err != nil {
		return "", err
	}
	info, err := os.Lstat(path)
	if err != nil {
		return "", err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		stat, ok := info.Sys().(*syscall.Stat_t)
		if !ok || int(stat.Uid) != os.Getuid() {
			return "", errors.New("Codex socket alias is owned by another user")
		}
		path, err = filepath.EvalSymlinks(path)
		if err != nil {
			return "", err
		}
		parent, err := os.Lstat(filepath.Dir(path))
		if err != nil {
			return "", err
		}
		if !parent.IsDir() {
			return "", errors.New("Codex socket target parent is not a directory")
		}
		if err := privateFile(parent, true); err != nil {
			return "", err
		}
		info, err = os.Lstat(path)
		if err != nil {
			return "", err
		}
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if info.Mode()&os.ModeSocket == 0 || !ok || int(stat.Uid) != os.Getuid() || info.Mode().Perm()&0o077 != 0 {
		return "", errors.New("Codex app-server socket must be owner-only and owned by this user")
	}
	return path, nil
}

// Send starts an idle turn or steers the active one. Success acknowledges server
// acceptance, not model consumption. All errors are final for this attempt;
// callers must not fall back to tmux after a possibly accepted RPC.
func Send(ctx context.Context, dir, threadID, text string) error {
	if threadID == "" || len(threadID) > 128 {
		return errors.New("Codex thread identity is not ready")
	}
	if len(text) > maxMessage {
		return errors.New("Codex message exceeds 1 MiB")
	}
	path, err := resolveSocket(dir)
	if err != nil {
		return fmt.Errorf("Codex app-server is unavailable: %w", err)
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	transport := &http.Transport{MaxResponseHeaderBytes: 8192, DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", path)
	}}
	defer transport.CloseIdleConnections()
	conn, _, err := websocket.Dial(ctx, "ws://localhost/", &websocket.DialOptions{HTTPClient: &http.Client{Transport: transport}})
	if err != nil {
		return fmt.Errorf("connect Codex app-server: %w", err)
	}
	defer conn.CloseNow()
	conn.SetReadLimit(maxFrame)
	rpc := rpcClient{conn: conn}
	if err := rpc.call(ctx, "initialize", map[string]any{
		"clientInfo":   map[string]string{"name": "questmaster_relay", "version": "1"},
		"capabilities": map[string]any{"experimentalApi": true, "requiredHumanApproval": false},
	}, nil); err != nil {
		return err
	}
	if err := rpc.write(ctx, map[string]string{"method": "initialized"}); err != nil {
		return err
	}
	var read struct {
		Thread struct {
			ID     string `json:"id"`
			Status struct {
				Type string `json:"type"`
			} `json:"status"`
		} `json:"thread"`
	}
	if err := rpc.call(ctx, "thread/read", map[string]any{"threadId": threadID, "includeTurns": false}, &read); err != nil {
		return err
	}
	if read.Thread.ID != threadID || (read.Thread.Status.Type != "active" && read.Thread.Status.Type != "idle") {
		return errors.New("Codex TUI thread is not loaded; refusing background resume")
	}
	if err := rpc.call(ctx, "thread/resume", map[string]any{"threadId": threadID, "excludeTurns": true}, nil); err != nil {
		return err
	}
	var turns struct {
		Data []struct {
			ID     string `json:"id"`
			Status string `json:"status"`
		} `json:"data"`
	}
	if err := rpc.call(ctx, "thread/turns/list", map[string]any{"threadId": threadID, "limit": 1, "sortDirection": "desc", "itemsView": "summary"}, &turns); err != nil {
		return err
	}
	params := map[string]any{"threadId": threadID, "input": []map[string]string{{"type": "text", "text": text}}}
	method := "turn/start"
	if len(turns.Data) > 0 && turns.Data[0].Status == "inProgress" {
		method = "turn/steer"
		params["expectedTurnId"] = turns.Data[0].ID
	}
	var reply struct {
		TurnID string `json:"turnId"`
		Turn   struct {
			ID string `json:"id"`
		} `json:"turn"`
	}
	if err := rpc.call(ctx, method, params, &reply); err != nil {
		return err
	}
	if method == "turn/steer" && reply.TurnID != turns.Data[0].ID {
		return errors.New("Codex steer returned an unexpected turn (delivery uncertain)")
	}
	if method == "turn/start" && reply.Turn.ID == "" {
		return errors.New("Codex start returned no turn identity (delivery uncertain)")
	}
	return nil
}

type rpcClient struct {
	conn *websocket.Conn
	id   int
}

func (c *rpcClient) write(ctx context.Context, value any) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	return c.conn.Write(ctx, websocket.MessageText, data)
}

func (c *rpcClient) call(ctx context.Context, method string, params, result any) error {
	c.id++
	if err := c.write(ctx, map[string]any{"id": c.id, "method": method, "params": params}); err != nil {
		return fmt.Errorf("Codex %s write (delivery uncertain): %w", method, err)
	}
	for {
		_, data, err := c.conn.Read(ctx)
		if err != nil {
			return fmt.Errorf("Codex %s response (delivery uncertain): %w", method, err)
		}
		var frame struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
			Result json.RawMessage `json:"result"`
			Error  *struct {
				Message string `json:"message"`
			} `json:"error"`
		}
		if err := json.Unmarshal(data, &frame); err != nil {
			return fmt.Errorf("decode Codex response: %w", err)
		}
		// Notifications and server requests belong to the interactive TUI. This
		// connection never answers permission or user-input requests.
		if frame.Method != "" || string(frame.ID) != strconv.Itoa(c.id) {
			continue
		}
		if frame.Error != nil {
			return fmt.Errorf("Codex %s rejected: %s", method, frame.Error.Message)
		}
		if len(frame.Result) == 0 {
			return fmt.Errorf("Codex %s returned no result (delivery uncertain)", method)
		}
		if result != nil {
			return json.Unmarshal(frame.Result, result)
		}
		return nil
	}
}
