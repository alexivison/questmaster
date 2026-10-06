//go:build linux || darwin

package message

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/coder/websocket"
)

var codexQueueTimeout = 10 * time.Second
var codexSteerTimeout = 10 * time.Second

const codexRPCFrameLimit = 4 << 20

func (s *Service) deliverCodexWithMode(ctx context.Context, m state.Manifest, message string) (DeliveryMode, error) {
	thread := m.ExtraString("codex_thread_id")
	binary := ""
	for _, agent := range m.Agents {
		if agent.Role == primaryRole && agent.Name == "codex" {
			binary = agent.CLI
			if thread == "" {
				thread = agent.ResumeID
			}
			break
		}
	}
	if thread == "" {
		return "", fmt.Errorf("%w: Codex thread id missing", errNativeUnavailable)
	}
	if state.SanitizeResumeID(thread) != thread {
		return "", fmt.Errorf("invalid Codex thread id")
	}
	if binary == "" {
		return "", fmt.Errorf("%w: Codex binary missing from target manifest", errNativeUnavailable)
	}
	if !filepath.IsAbs(binary) {
		if strings.ContainsRune(binary, os.PathSeparator) {
			binary = filepath.Join(m.Cwd, binary)
		} else {
			name := binary
			binary = ""
			for _, dir := range filepath.SplitList(m.AgentPath) {
				candidate := filepath.Join(dir, name)
				if !filepath.IsAbs(candidate) {
					candidate = filepath.Join(m.Cwd, candidate)
				}
				if _, err := exec.LookPath(candidate); err == nil {
					binary = candidate
					break
				}
			}
		}
	}
	binary, err := exec.LookPath(binary)
	if err != nil {
		return "", fmt.Errorf("%w: Codex binary unavailable: %v", errNativeUnavailable, err)
	}
	checkCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	version, err := exec.CommandContext(checkCtx, binary, "app-server", "daemon", "version").Output()
	if err != nil {
		return "", fmt.Errorf("%w: Codex daemon unavailable: %v", errNativeUnavailable, err)
	}
	var daemon struct {
		Status     string `json:"status"`
		SocketPath string `json:"socketPath"`
	}
	if json.Unmarshal(version, &daemon) != nil || daemon.Status != "running" {
		return "", fmt.Errorf("%w: Codex daemon is not running", errNativeUnavailable)
	}
	if s.Steer && m.ExtraString(state.CodexRemoteAppServerKey) == state.CodexRemoteAppServer && daemon.SocketPath != "" {
		steerCtx, steerCancel := context.WithTimeout(ctx, codexSteerTimeout)
		steered, err := codexSteer(steerCtx, daemon.SocketPath, thread, message)
		steerCancel()
		if err != nil {
			return "", fmt.Errorf("Codex steer: %w", err)
		}
		if steered {
			return DeliveryCodexSteer, nil
		}
	}
	if err := queueCodex(ctx, binary, thread, message); err != nil {
		return "", err
	}
	return DeliveryCodexQueue, nil
}

func queueCodex(ctx context.Context, binary, thread, message string) error {
	queueCtx, queueCancel := context.WithTimeout(ctx, codexQueueTimeout)
	defer queueCancel()
	output, err := exec.CommandContext(queueCtx, binary, "queue", "--thread", thread, "--message="+message).CombinedOutput()
	if err != nil {
		if queueCtx.Err() != nil {
			return fmt.Errorf("Codex queue: %w", queueCtx.Err())
		}
		return fmt.Errorf("Codex queue failed: %w: %s", err, strings.TrimSpace(string(output)))
	}
	if !strings.HasPrefix(string(output), "Queued message ") {
		return fmt.Errorf("Codex queue returned no acceptance receipt: %s", strings.TrimSpace(string(output)))
	}
	return nil
}

type codexRPCError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func (e *codexRPCError) Error() string { return e.Message }

type codexRPCClient struct {
	ctx     context.Context
	conn    *websocket.Conn
	request int
}

func codexSteer(ctx context.Context, socket, thread, message string) (bool, error) {
	transport := &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "unix", socket)
		},
	}
	defer transport.CloseIdleConnections()
	conn, _, err := websocket.Dial(ctx, "ws://localhost/", &websocket.DialOptions{
		HTTPClient: &http.Client{Transport: transport},
	})
	if err != nil {
		return false, nil
	}
	defer conn.CloseNow()
	conn.SetReadLimit(codexRPCFrameLimit)
	rpc := codexRPCClient{ctx: ctx, conn: conn}
	if _, err := rpc.call("initialize", map[string]any{
		"clientInfo":   map[string]any{"name": "questmaster", "title": "Questmaster", "version": "1"},
		"capabilities": map[string]any{"experimentalApi": true, "requestAttestation": false},
	}); err != nil {
		return false, nil
	}
	if err := rpc.notify("initialized"); err != nil {
		return false, nil
	}
	turns, err := rpc.call("thread/turns/list", map[string]any{
		"threadId":      thread,
		"limit":         1,
		"sortDirection": "desc",
		"itemsView":     "notLoaded",
	})
	if err != nil {
		return false, nil
	}
	var page struct {
		Data []struct {
			ID     string `json:"id"`
			Status string `json:"status"`
		} `json:"data"`
	}
	if err := json.Unmarshal(turns, &page); err != nil || len(page.Data) == 0 || page.Data[0].ID == "" || page.Data[0].Status != "inProgress" {
		return false, nil
	}
	result, err := rpc.call("turn/steer", map[string]any{
		"threadId":       thread,
		"expectedTurnId": page.Data[0].ID,
		"input":          []any{map[string]any{"type": "text", "text": message, "text_elements": []any{}}},
	})
	if err != nil {
		var remoteError *codexRPCError
		if errors.As(err, &remoteError) {
			return false, nil
		}
		return false, err
	}
	var accepted struct {
		TurnID string `json:"turnId"`
	}
	if err := json.Unmarshal(result, &accepted); err != nil || accepted.TurnID == "" {
		return false, errors.New("Codex app-server returned no steer acceptance")
	}
	return true, nil
}

func (c *codexRPCClient) notify(method string) error {
	return c.write(map[string]any{"method": method})
}

func (c *codexRPCClient) call(method string, params any) (json.RawMessage, error) {
	c.request++
	id := c.request
	if err := c.write(map[string]any{"id": id, "method": method, "params": params}); err != nil {
		return nil, err
	}
	for {
		messageType, data, err := c.conn.Read(c.ctx)
		if err != nil {
			return nil, fmt.Errorf("read Codex app-server response: %w", err)
		}
		if messageType != websocket.MessageText {
			continue
		}
		var response struct {
			ID     json.RawMessage `json:"id"`
			Result json.RawMessage `json:"result"`
			Error  *codexRPCError  `json:"error"`
		}
		if err := json.Unmarshal(data, &response); err != nil {
			return nil, fmt.Errorf("decode Codex app-server response: %w", err)
		}
		if !bytes.Equal(bytes.TrimSpace(response.ID), []byte(strconv.Itoa(id))) {
			continue
		}
		if response.Error != nil {
			return nil, response.Error
		}
		return response.Result, nil
	}
}

func (c *codexRPCClient) write(message map[string]any) error {
	message["jsonrpc"] = "2.0"
	data, err := json.Marshal(message)
	if err != nil {
		return fmt.Errorf("encode Codex app-server request: %w", err)
	}
	if err := c.conn.Write(c.ctx, websocket.MessageText, data); err != nil {
		return fmt.Errorf("write Codex app-server request: %w", err)
	}
	return nil
}
