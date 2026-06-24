package focus

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"

	"github.com/alexivison/questmaster/internal/state"
)

const (
	// SocketEnv overrides the app focus handoff socket path.
	SocketEnv = "QUESTMASTER_FOCUS_SOCKET"
)

// Direction is a ctrl+hjkl navigation direction.
type Direction string

const (
	Left  Direction = "left"
	Down  Direction = "down"
	Up    Direction = "up"
	Right Direction = "right"
)

type request struct {
	Direction Direction `json:"direction"`
}

type response struct {
	OK    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
}

// ParseDirection accepts both tmux/vim keys and canonical direction names.
func ParseDirection(input string) (Direction, error) {
	switch strings.ToLower(strings.TrimSpace(input)) {
	case "h", "left":
		return Left, nil
	case "j", "down":
		return Down, nil
	case "k", "up":
		return Up, nil
	case "l", "right":
		return Right, nil
	default:
		return "", fmt.Errorf("direction must be one of h/j/k/l or left/down/up/right")
	}
}

// DefaultSocketPath returns the local socket path used by the app focus bridge.
func DefaultSocketPath() string {
	if socket := os.Getenv(SocketEnv); socket != "" {
		return socket
	}
	if root := state.StateRoot(); root != "" {
		return filepath.Join(root, "app-focus.sock")
	}
	return filepath.Join(os.TempDir(), "questmaster-app-focus.sock")
}

// Send delivers a focus handoff to the running native app and waits for an ack.
func Send(ctx context.Context, socketPath string, direction Direction) error {
	if socketPath == "" {
		socketPath = DefaultSocketPath()
	}
	if socketPath == "" {
		return fmt.Errorf("focus socket path is required")
	}

	var dialer net.Dialer
	conn, err := dialer.DialContext(ctx, "unix", socketPath)
	if err != nil {
		return fmt.Errorf("connect %s: %w", socketPath, err)
	}
	defer conn.Close() //nolint:errcheck

	if deadline, ok := ctx.Deadline(); ok {
		if err := conn.SetDeadline(deadline); err != nil {
			return fmt.Errorf("set focus socket deadline: %w", err)
		}
	}

	if err := json.NewEncoder(conn).Encode(request{Direction: direction}); err != nil {
		return fmt.Errorf("send focus request: %w", err)
	}

	var reply response
	if err := json.NewDecoder(conn).Decode(&reply); err != nil {
		return fmt.Errorf("read focus acknowledgement: %w", err)
	}
	if !reply.OK {
		if reply.Error == "" {
			reply.Error = "app rejected focus handoff"
		}
		return fmt.Errorf("%s", reply.Error)
	}
	return nil
}
