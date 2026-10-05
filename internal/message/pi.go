//go:build linux || darwin

package message

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"syscall"
	"time"

	"github.com/alexivison/questmaster/internal/state"
)

const (
	piNativeTimeout  = time.Second
	piMaxFrameBytes  = 1 << 20
	piMaxAckBytes    = 64 << 10
	piSocketFileName = "pi.sock"
)

type piMessageRequest struct {
	ID      string `json:"id"`
	Message string `json:"message"`
}

type piMessageAck struct {
	ID     string `json:"id"`
	Status string `json:"status"`
}

func (s *Service) deliverPi(ctx context.Context, sessionID, message string) error {
	frame, id, err := piFrame(message)
	if err != nil {
		return err
	}
	path, err := piSocketPath(sessionID)
	if err != nil {
		return err
	}
	if err := validatePiSocket(path); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, piNativeTimeout)
	defer cancel()
	dial := s.dial
	if dial == nil {
		var dialer net.Dialer
		dial = dialer.DialContext
	}
	conn, err := dial(ctx, "unix", path)
	if err != nil {
		if errors.Is(err, syscall.ENOENT) || errors.Is(err, syscall.ECONNREFUSED) {
			return fmt.Errorf("%w: Pi socket: %v", errNativeUnavailable, err)
		}
		return fmt.Errorf("dial Pi socket: %w", err)
	}
	defer conn.Close()
	if deadline, ok := ctx.Deadline(); ok {
		if err := conn.SetDeadline(deadline); err != nil {
			return fmt.Errorf("set Pi socket deadline: %w", err)
		}
	}
	n, err := conn.Write(frame)
	if err != nil {
		return fmt.Errorf("write Pi socket: %w", err)
	}
	if n != len(frame) {
		return fmt.Errorf("write Pi socket: %w", io.ErrShortWrite)
	}
	if err := readPiAck(conn, id); err != nil {
		return err
	}
	return nil
}

func piSocketPath(sessionID string) (string, error) {
	if !state.IsValidSessionID(sessionID) {
		return "", fmt.Errorf("%w: invalid Pi session id", errNativeUnavailable)
	}
	return filepath.Join("/tmp", sessionID, piSocketFileName), nil
}

func validatePiSocket(path string) error {
	runtime, err := os.Lstat(filepath.Dir(path))
	if errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("%w: Pi runtime directory missing", errNativeUnavailable)
	}
	if err != nil {
		return fmt.Errorf("stat Pi runtime directory: %w", err)
	}
	if !runtime.IsDir() {
		return errors.New("Pi runtime path is not a directory")
	}
	if err := validateUserOwned(runtime); err != nil {
		return fmt.Errorf("Pi runtime directory: %w", err)
	}
	if runtime.Mode().Perm()&0o022 != 0 {
		return fmt.Errorf("Pi runtime directory permissions are %04o, must not be group or world writable", runtime.Mode().Perm())
	}
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("%w: Pi messaging socket missing", errNativeUnavailable)
	}
	if err != nil {
		return fmt.Errorf("stat Pi messaging socket: %w", err)
	}
	if info.Mode()&os.ModeType != os.ModeSocket {
		return errors.New("Pi messaging socket is not a Unix socket")
	}
	if err := validateUserOwned(info); err != nil {
		return fmt.Errorf("Pi messaging socket: %w", err)
	}
	if info.Mode().Perm() != 0o600 {
		return fmt.Errorf("Pi messaging socket permissions are %04o, want 0600", info.Mode().Perm())
	}
	return nil
}

func piFrame(message string) ([]byte, string, error) {
	if len(message) > piMaxFrameBytes {
		return nil, "", fmt.Errorf("%w: Pi message exceeds %d byte limit", errNativeUnavailable, piMaxFrameBytes)
	}
	id, err := newUUID()
	if err != nil {
		return nil, "", fmt.Errorf("%w: generate Pi message id: %v", errNativeUnavailable, err)
	}
	frame, err := json.Marshal(piMessageRequest{ID: id, Message: message})
	if err != nil {
		return nil, "", fmt.Errorf("%w: encode Pi message: %v", errNativeUnavailable, err)
	}
	frame = append(frame, '\n')
	if len(frame) > piMaxFrameBytes {
		return nil, "", fmt.Errorf("%w: Pi message exceeds %d byte limit", errNativeUnavailable, piMaxFrameBytes)
	}
	return frame, id, nil
}

func readPiAck(conn net.Conn, id string) error {
	data, err := io.ReadAll(io.LimitReader(conn, piMaxAckBytes+1))
	if err != nil {
		return fmt.Errorf("read Pi acknowledgment: %w", err)
	}
	if len(data) > piMaxAckBytes {
		return fmt.Errorf("Pi acknowledgment exceeds %d bytes", piMaxAckBytes)
	}
	if !bytes.HasSuffix(data, []byte{'\n'}) || bytes.Count(data, []byte{'\n'}) != 1 {
		return errors.New("Pi acknowledgment is not one newline-delimited record")
	}
	line := data[:len(data)-1]
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(line, &fields); err != nil {
		return fmt.Errorf("decode Pi acknowledgment: %w", err)
	}
	if len(fields) != 2 || fields["id"] == nil || fields["status"] == nil {
		return errors.New("Pi acknowledgment does not match request")
	}
	var ack piMessageAck
	if err := json.Unmarshal(line, &ack); err != nil {
		return fmt.Errorf("decode Pi acknowledgment: %w", err)
	}
	if ack.ID != id || ack.Status != "unconfirmed" {
		return errors.New("Pi acknowledgment does not match request")
	}
	return nil
}
