//go:build linux || darwin

package message

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/alexivison/questmaster/internal/state"
)

var codexQueueTimeout = 10 * time.Second
var codexSteerTimeout = 10 * time.Second

const codexRPCFrameLimit = 4 << 20

func (s *Service) deliverCodex(ctx context.Context, m state.Manifest, message string) error {
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
		return fmt.Errorf("%w: Codex thread id missing", errNativeUnavailable)
	}
	if state.SanitizeResumeID(thread) != thread {
		return fmt.Errorf("invalid Codex thread id")
	}
	if binary == "" {
		return fmt.Errorf("%w: Codex binary missing from target manifest", errNativeUnavailable)
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
		return fmt.Errorf("%w: Codex binary unavailable: %v", errNativeUnavailable, err)
	}
	checkCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	version, err := exec.CommandContext(checkCtx, binary, "app-server", "daemon", "version").Output()
	if err != nil {
		return fmt.Errorf("%w: Codex daemon unavailable: %v", errNativeUnavailable, err)
	}
	var daemon struct {
		Status     string `json:"status"`
		SocketPath string `json:"socketPath"`
	}
	if json.Unmarshal(version, &daemon) != nil || daemon.Status != "running" {
		return fmt.Errorf("%w: Codex daemon is not running", errNativeUnavailable)
	}
	if s.Steer && daemon.SocketPath != "" {
		steerCtx, steerCancel := context.WithTimeout(ctx, codexSteerTimeout)
		steered, err := codexSteer(steerCtx, binary, daemon.SocketPath, thread, message)
		steerCancel()
		if err != nil {
			return fmt.Errorf("Codex steer: %w", err)
		}
		if steered {
			return nil
		}
	}
	return queueCodex(ctx, binary, thread, message)
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
	input   io.WriteCloser
	output  *bufio.Scanner
	request int
}

func codexSteer(ctx context.Context, binary, socket, thread, message string) (bool, error) {
	cmd := exec.CommandContext(ctx, binary, "app-server", "proxy", "--sock", socket)
	cmd.Stderr = io.Discard
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return false, nil
	}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return false, nil
	}
	if err := cmd.Start(); err != nil {
		return false, nil
	}
	defer func() {
		_ = stdin.Close()
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	}()

	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 64<<10), codexRPCFrameLimit)
	rpc := codexRPCClient{input: stdin, output: scanner}
	if _, err := rpc.call("initialize", map[string]any{
		"clientInfo":   map[string]any{"name": "questmaster", "title": "Questmaster", "version": "1"},
		"capabilities": map[string]any{"experimentalApi": true, "requestAttestation": false},
	}); err != nil {
		return false, nil
	}
	if err := rpc.notify("initialized"); err != nil {
		return false, nil
	}
	if _, err := rpc.call("thread/resume", map[string]any{"threadId": thread, "excludeTurns": true}); err != nil {
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
	for c.output.Scan() {
		var response struct {
			ID     json.RawMessage `json:"id"`
			Result json.RawMessage `json:"result"`
			Error  *codexRPCError  `json:"error"`
		}
		if err := json.Unmarshal(c.output.Bytes(), &response); err != nil {
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
	if err := c.output.Err(); err != nil {
		return nil, fmt.Errorf("read Codex app-server response: %w", err)
	}
	return nil, io.EOF
}

func (c *codexRPCClient) write(message any) error {
	data, err := json.Marshal(message)
	if err != nil {
		return fmt.Errorf("encode Codex app-server request: %w", err)
	}
	data = append(data, '\n')
	if _, err := c.input.Write(data); err != nil {
		return fmt.Errorf("write Codex app-server request: %w", err)
	}
	return nil
}
