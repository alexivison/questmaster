//go:build linux || darwin

package message

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/alexivison/questmaster/internal/state"
)

const (
	claudeNativeTimeout  = time.Second
	claudeMaxFrameBytes  = 1 << 20
	claudeMaxRecordBytes = 64 << 10
)

var errNativeUnavailable = errors.New("native delivery unavailable")

type claudeSessionRecord struct {
	PID                 int    `json:"pid"`
	PeerProtocol        int    `json:"peerProtocol"`
	Tmux                string `json:"tmux"`
	MessagingSocketPath string `json:"messagingSocketPath"`
}

type claudeMessageFrame struct {
	MsgV    int `json:"msgV"`
	Message struct {
		Role    string `json:"role"`
		Content string `json:"content"`
	} `json:"message"`
	MessageID string `json:"msg_id"`
	Priority  string `json:"priority"`
	Type      string `json:"type"`
}

func (s *Service) nativeDeliver(ctx context.Context, sessionID string, m state.Manifest, target, message string) error {
	switch primaryAgentName(m) {
	case "claude":
		return s.deliverClaude(ctx, target, message)
	case "opencode":
		return s.deliverOpenCode(ctx, sessionID, m, target, message)
	case "pi":
		return s.deliverPi(ctx, sessionID, message)
	default:
		return errNativeUnavailable
	}
}

func (s *Service) deliverClaude(ctx context.Context, target, message string) error {
	pid, canonical, err := s.client.PaneIdentity(ctx, target)
	if err != nil {
		return fmt.Errorf("resolve Claude pane identity: %w", err)
	}
	record, err := claudeRecord(pid, canonical)
	if err != nil {
		return err
	}
	frame, err := claudeFrame(message)
	if err != nil {
		return err
	}

	ctx, cancel := context.WithTimeout(ctx, claudeNativeTimeout)
	defer cancel()
	dial := s.dial
	if dial == nil {
		var dialer net.Dialer
		dial = dialer.DialContext
	}
	conn, err := dial(ctx, "unix", record.MessagingSocketPath)
	if err != nil {
		if errors.Is(err, syscall.ENOENT) || errors.Is(err, syscall.ECONNREFUSED) {
			return fmt.Errorf("%w: Claude socket: %v", errNativeUnavailable, err)
		}
		return fmt.Errorf("dial Claude socket: %w", err)
	}
	defer conn.Close()
	if deadline, ok := ctx.Deadline(); ok {
		if err := conn.SetWriteDeadline(deadline); err != nil {
			return fmt.Errorf("set Claude socket write deadline: %w", err)
		}
	}
	n, err := conn.Write(frame)
	if err != nil {
		return fmt.Errorf("write Claude socket: %w", err)
	}
	if n != len(frame) {
		return fmt.Errorf("write Claude socket: %w", io.ErrShortWrite)
	}
	return nil
}

func claudeRecord(pid int, canonical string) (claudeSessionRecord, error) {
	configDir := claudeConfigDir()
	if configDir == "" {
		return claudeSessionRecord{}, fmt.Errorf("%w: Claude config directory missing", errNativeUnavailable)
	}
	sessionsDir := filepath.Join(configDir, "sessions")
	if err := validateClaudeSessionsDir(sessionsDir); err != nil {
		return claudeSessionRecord{}, err
	}
	recordPath := filepath.Join(sessionsDir, strconv.Itoa(pid)+".json")
	file, err := os.Open(recordPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return claudeSessionRecord{}, fmt.Errorf("%w: Claude session record missing", errNativeUnavailable)
		}
		return claudeSessionRecord{}, fmt.Errorf("read Claude session record: %w", err)
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, claudeMaxRecordBytes+1))
	if err != nil {
		return claudeSessionRecord{}, fmt.Errorf("read Claude session record: %w", err)
	}
	if len(data) > claudeMaxRecordBytes {
		return claudeSessionRecord{}, fmt.Errorf("Claude session record exceeds %d bytes", claudeMaxRecordBytes)
	}
	var record claudeSessionRecord
	if err := json.Unmarshal(data, &record); err != nil {
		return claudeSessionRecord{}, fmt.Errorf("decode Claude session record: %w", err)
	}
	if record.PID != pid {
		return claudeSessionRecord{}, fmt.Errorf("Claude session record pid %d does not match pane pid %d", record.PID, pid)
	}
	if record.PeerProtocol != 1 {
		return claudeSessionRecord{}, fmt.Errorf("%w: Claude peer protocol %d is unsupported", errNativeUnavailable, record.PeerProtocol)
	}
	if record.Tmux != canonical {
		return claudeSessionRecord{}, fmt.Errorf("Claude session record tmux %q does not match pane %q", record.Tmux, canonical)
	}
	if err := claudeProcessAlive(pid); err != nil {
		return claudeSessionRecord{}, err
	}
	if record.MessagingSocketPath == "" {
		return claudeSessionRecord{}, fmt.Errorf("%w: Claude messaging socket missing", errNativeUnavailable)
	}
	if !filepath.IsAbs(record.MessagingSocketPath) {
		return claudeSessionRecord{}, fmt.Errorf("Claude messaging socket is not an absolute path")
	}
	if err := validateClaudeSocket(record.MessagingSocketPath); err != nil {
		return claudeSessionRecord{}, err
	}
	return record, nil
}

func claudeConfigDir() string {
	if dir := os.Getenv("CLAUDE_CONFIG_DIR"); dir != "" {
		return dir
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".claude")
}

func validateClaudeSessionsDir(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("%w: Claude sessions directory missing", errNativeUnavailable)
		}
		return fmt.Errorf("stat Claude sessions directory: %w", err)
	}
	if !info.IsDir() {
		return fmt.Errorf("Claude sessions path is not a directory")
	}
	if err := validateUserOwned(info); err != nil {
		return fmt.Errorf("Claude sessions directory: %w", err)
	}
	if info.Mode().Perm()&0o022 != 0 {
		return fmt.Errorf("Claude sessions directory is group/world writable")
	}
	return nil
}

func validateClaudeSocket(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("%w: Claude messaging socket missing", errNativeUnavailable)
		}
		return fmt.Errorf("stat Claude messaging socket: %w", err)
	}
	if info.Mode()&os.ModeType != os.ModeSocket {
		return fmt.Errorf("Claude messaging socket is not a Unix socket")
	}
	if err := validateUserOwned(info); err != nil {
		return fmt.Errorf("Claude messaging socket: %w", err)
	}
	if info.Mode().Perm() != 0o600 {
		return fmt.Errorf("Claude messaging socket permissions are %04o, want 0600", info.Mode().Perm())
	}
	return nil
}

func validateUserOwned(info os.FileInfo) error {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uint32(os.Getuid()) {
		return errors.New("not owned by current user")
	}
	return nil
}

func claudeProcessAlive(pid int) error {
	process, err := os.FindProcess(pid)
	if err != nil {
		return fmt.Errorf("find Claude pane pid %d: %w", pid, err)
	}
	if err := process.Signal(syscall.Signal(0)); err != nil {
		if errors.Is(err, syscall.ESRCH) || errors.Is(err, os.ErrProcessDone) {
			return fmt.Errorf("%w: Claude pane pid %d is not live", errNativeUnavailable, pid)
		}
		return fmt.Errorf("Claude pane pid %d is not live: %w", pid, err)
	}
	return nil
}

func claudeFrame(message string) ([]byte, error) {
	if len(message) > claudeMaxFrameBytes {
		return nil, fmt.Errorf("Claude message exceeds %d byte frame limit", claudeMaxFrameBytes)
	}
	id, err := newUUID()
	if err != nil {
		return nil, fmt.Errorf("generate Claude message id: %w", err)
	}
	var frame claudeMessageFrame
	frame.MsgV = 1
	frame.MessageID = id
	frame.Type = "user"
	frame.Message.Role = "user"
	frame.Message.Content = `<cross-session-message from-name="Questmaster">` + "\n" +
		strings.ReplaceAll(message, "</cross-session-message>", "&lt;/cross-session-message>") + "\n</cross-session-message>"
	frame.Priority = "next"
	data, err := json.Marshal(frame)
	if err != nil {
		return nil, fmt.Errorf("encode Claude message: %w", err)
	}
	data = append(data, '\n')
	if len(data) > claudeMaxFrameBytes {
		return nil, fmt.Errorf("Claude message exceeds %d byte frame limit", claudeMaxFrameBytes)
	}
	return data, nil
}

func newUUID() (string, error) {
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", err
	}
	raw[6] = raw[6]&0x0f | 0x40
	raw[8] = raw[8]&0x3f | 0x80
	encoded := hex.EncodeToString(raw[:])
	return encoded[:8] + "-" + encoded[8:12] + "-" + encoded[12:16] + "-" + encoded[16:20] + "-" + encoded[20:], nil
}
