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
	"net/url"
	"os"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/alexivison/questmaster/internal/state"
)

const (
	openCodeNativeTimeout  = time.Second
	openCodeMaxPromptBytes = 1 << 20
)

type openCodePrompt struct {
	Agent string               `json:"agent"`
	Parts []openCodePromptPart `json:"parts"`
}

type openCodePromptPart struct {
	Type string `json:"type"`
	Text string `json:"text"`
}

func (s *Service) deliverOpenCode(ctx context.Context, sessionID string, m state.Manifest, target, message string) error {
	ss, err := state.LoadSessionStateAt(s.store.Root(), sessionID)
	if err != nil {
		return fmt.Errorf("read OpenCode hook state: %w", err)
	}
	if ss == nil || ss.Version != state.SchemaVersion {
		return fmt.Errorf("%w: OpenCode hook state missing", errNativeUnavailable)
	}
	pane, ok := ss.Panes[primaryRole]
	if !ok || pane.OpenCodeServerURL == "" || pane.OpenCodeSessionID == "" || pane.OpenCodeAgent == "" || pane.OpenCodePID <= 0 {
		return fmt.Errorf("%w: OpenCode native state incomplete", errNativeUnavailable)
	}
	endpoint, err := openCodePromptEndpoint(pane.OpenCodeServerURL, pane.OpenCodeSessionID)
	if err != nil {
		return err
	}
	if len(message) > openCodeMaxPromptBytes {
		return fmt.Errorf("OpenCode message exceeds %d byte limit", openCodeMaxPromptBytes)
	}

	pid, _, err := s.client.PaneIdentity(ctx, target)
	if err != nil {
		return fmt.Errorf("resolve OpenCode pane identity: %w", err)
	}
	if pid != pane.OpenCodePID {
		return fmt.Errorf("%w: OpenCode pane pid %d does not match hook pid %d", errNativeUnavailable, pid, pane.OpenCodePID)
	}

	body, err := json.Marshal(openCodePrompt{
		Agent: pane.OpenCodeAgent,
		Parts: []openCodePromptPart{{Type: "text", Text: message}},
	})
	if err != nil {
		return fmt.Errorf("encode OpenCode prompt: %w", err)
	}

	request, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint.String(), bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("build OpenCode prompt request: %w", err)
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("x-opencode-directory", openCodeDirectoryHeader(m.Cwd))
	if password := os.Getenv("OPENCODE_SERVER_PASSWORD"); password != "" {
		username := os.Getenv("OPENCODE_SERVER_USERNAME")
		if username == "" {
			username = "opencode"
		}
		request.SetBasicAuth(username, password)
	}
	return s.postOpenCodePrompt(ctx, request)
}

func openCodePromptEndpoint(raw, sessionID string) (*url.URL, error) {
	if state.SanitizeResumeID(sessionID) != sessionID {
		return nil, fmt.Errorf("%w: invalid OpenCode session id", errNativeUnavailable)
	}
	endpoint, err := url.Parse(raw)
	if err != nil || endpoint.Scheme != "http" || endpoint.Hostname() != "127.0.0.1" || endpoint.User != nil || endpoint.RawQuery != "" || endpoint.ForceQuery || endpoint.Fragment != "" {
		return nil, fmt.Errorf("%w: invalid OpenCode server URL", errNativeUnavailable)
	}
	port, err := strconv.Atoi(endpoint.Port())
	if endpoint.Port() == "" || err != nil || port < 1 || port > 65535 {
		return nil, fmt.Errorf("%w: invalid OpenCode server URL", errNativeUnavailable)
	}
	endpoint.Path = "/session/" + url.PathEscape(sessionID) + "/prompt_async"
	endpoint.RawPath = ""
	endpoint.ForceQuery = false
	return endpoint, nil
}

func openCodeDirectoryHeader(cwd string) string {
	return strings.ReplaceAll(url.QueryEscape(cwd), "+", "%20")
}

func (s *Service) postOpenCodePrompt(ctx context.Context, request *http.Request) error {
	ctx, cancel := context.WithTimeout(ctx, openCodeNativeTimeout)
	defer cancel()

	connected := false
	dial := s.dial
	transport := &http.Transport{
		Proxy: nil,
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			if dial == nil {
				var dialer net.Dialer
				dial = dialer.DialContext
			}
			conn, err := dial(ctx, network, address)
			if err == nil && conn != nil {
				connected = true
			}
			return conn, err
		},
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{
		Transport: transport,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	response, err := client.Do(request.WithContext(ctx))
	if err != nil {
		if !connected && errors.Is(err, syscall.ECONNREFUSED) {
			return fmt.Errorf("%w: OpenCode server refused connection", errNativeUnavailable)
		}
		return fmt.Errorf("send OpenCode prompt: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		return fmt.Errorf("OpenCode prompt response status %s", response.Status)
	}
	return nil
}
