//go:build linux || darwin

// Package codexnative runs a session-owned Codex app-server and submits messages
// to the same thread used by its interactive TUI.
package codexnative

import (
	"context"
	"crypto/rand"
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

// SocketPath validates the private directory. Codex publishes a filesystem alias
// here and binds its actual socket in a short, private per-user directory.
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
	return filepath.Join(dir, SocketName), nil
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
	return SendWithCheck(ctx, dir, threadID, text, nil)
}

// SendWithCheck runs beforeSend after the thread handshake, immediately before
// each submit attempt. A check error leaves the pending input untouched.
func SendWithCheck(ctx context.Context, dir, threadID, text string, beforeSend func() error) error {
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
	// The owner atomically starts or steers through turn/start. Reading a turn
	// summary first replays the entire rollout for older JSONL conversations.
	params := map[string]any{"threadId": threadID, "input": []map[string]string{{"type": "text", "text": text}}}
	var reply struct {
		Turn struct {
			ID string `json:"id"`
		} `json:"turn"`
	}
	if beforeSend != nil {
		if err := beforeSend(); err != nil {
			return err
		}
	}
	if err := rpc.call(ctx, "turn/start", params, &reply); err != nil {
		var rejection *rpcRejection
		if !errors.As(err, &rejection) || rejection.code != -32603 ||
			rejection.message != "failed to submit turn input: ActiveTurnNotSteerable { turn_kind: Compact }" {
			return err
		}
		// A manual compaction explicitly refuses input. Queue it on the same
		// owner instead; never enqueue after an uncertain turn/start receipt.
		params["clientUserMessageId"] = "questmaster-" + rand.Text()
		var queued struct {
			QueuedSubmission struct {
				ID string `json:"id"`
			} `json:"queuedSubmission"`
		}
		if beforeSend != nil {
			if err := beforeSend(); err != nil {
				return err
			}
		}
		if err := rpc.call(ctx, "thread/queue/add", params, &queued); err != nil {
			return err
		}
		if queued.QueuedSubmission.ID == "" {
			return errors.New("Codex queue returned no submission identity (delivery uncertain)")
		}
		return nil
	}
	if reply.Turn.ID == "" {
		return errors.New("Codex input returned no turn identity (delivery uncertain)")
	}
	return nil
}

type rpcClient struct {
	conn *websocket.Conn
	id   int
}

type rpcRejection struct {
	method, message string
	code            int
}

func (e *rpcRejection) Error() string {
	return fmt.Sprintf("Codex %s rejected: %s", e.method, e.message)
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
				Code    int    `json:"code"`
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
			return &rpcRejection{method: method, code: frame.Error.Code, message: frame.Error.Message}
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
