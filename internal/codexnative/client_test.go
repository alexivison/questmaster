package codexnative

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
)

func runtimeFixture(t *testing.T) string {
	t.Helper()
	// Keep Unix paths below macOS's limit even when testing.T's parent is long.
	dir, err := os.MkdirTemp("/tmp", "qm-codex-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	if err := os.WriteFile(filepath.Join(dir, MarkerName), []byte("1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return dir
}

type peerOptions struct {
	status, rejection string
	drop              bool
	alias             bool
}

func mockPeer(t *testing.T, dir string, opts peerOptions) <-chan map[string]any {
	t.Helper()
	physical := filepath.Join(dir, SocketName)
	if opts.alias {
		physical = filepath.Join(runtimeFixture(t), SocketName)
	}
	listener, err := net.Listen("unix", physical)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(physical, 0o600); err != nil {
		t.Fatal(err)
	}
	if opts.alias {
		if err := os.Symlink(physical, filepath.Join(dir, SocketName)); err != nil {
			t.Fatal(err)
		}
	}
	submissions := make(chan map[string]any, 1)
	server := &http.Server{ReadHeaderTimeout: time.Second}
	server.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer conn.CloseNow()
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		defer cancel()
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				return
			}
			var req struct {
				ID     int            `json:"id"`
				Method string         `json:"method"`
				Params map[string]any `json:"params"`
			}
			if json.Unmarshal(data, &req) != nil {
				return
			}
			if req.Method == "initialized" {
				continue
			}
			var result any = map[string]any{}
			switch req.Method {
			case "initialize":
				capabilities := req.Params["capabilities"].(map[string]any)
				if capabilities["requiredHumanApproval"] != false {
					t.Error("relay claimed human approval capability")
				}
			case "thread/read":
				if req.Params["includeTurns"] != false {
					t.Error("thread read requested history")
				}
				result = map[string]any{"thread": map[string]any{"id": "example-thread", "status": map[string]string{"type": opts.status}}}
			case "thread/resume":
				if req.Params["excludeTurns"] != true {
					t.Error("resume requested unbounded history")
				}
			case "turn/start":
				submissions <- map[string]any{"method": req.Method, "params": req.Params}
				if opts.drop {
					return
				}
				if opts.rejection != "" {
					response, _ := json.Marshal(map[string]any{"id": req.ID, "error": map[string]any{"code": -32600, "message": opts.rejection}})
					_ = conn.Write(ctx, websocket.MessageText, response)
					return
				}
				// A server request (including a string ID) must be left to the TUI.
				_ = conn.Write(ctx, websocket.MessageText, []byte(`{"id":"approval","method":"item/commandExecution/requestApproval","params":{}}`))
				result = map[string]any{"turn": map[string]string{"id": "example-turn"}}
			default:
				t.Errorf("unexpected RPC %s", req.Method)
				return
			}
			response, _ := json.Marshal(map[string]any{"id": req.ID, "result": result})
			if err := conn.Write(ctx, websocket.MessageText, response); err != nil {
				return
			}
		}
	})
	go server.Serve(listener)
	t.Cleanup(func() { server.Close(); listener.Close() })
	return submissions
}

func TestSend(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name            string
		opts            peerOptions
		method, wantErr string
	}{
		{"busy", peerOptions{status: "active"}, "turn/start", ""},
		{"guarded alias", peerOptions{status: "active", alias: true}, "turn/start", ""},
		{"idle", peerOptions{status: "idle"}, "turn/start", ""},
		{"unloaded", peerOptions{status: "notLoaded"}, "", "refusing background resume"},
		{"rejected", peerOptions{status: "active", rejection: "turn changed"}, "turn/start", "rejected: turn changed"},
		{"lost receipt", peerOptions{status: "idle", drop: true}, "turn/start", "delivery uncertain"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			dir := runtimeFixture(t)
			submissions := mockPeer(t, dir, tc.opts)
			err := Send(t.Context(), dir, "example-thread", "[MASTER:example] change course")
			if tc.wantErr == "" && err != nil {
				t.Fatal(err)
			}
			if tc.wantErr != "" && (err == nil || !strings.Contains(err.Error(), tc.wantErr)) {
				t.Fatalf("error = %v, want %q", err, tc.wantErr)
			}
			if tc.method == "" {
				select {
				case msg := <-submissions:
					t.Fatalf("unloaded thread received %v", msg)
				default:
				}
				return
			}
			select {
			case msg := <-submissions:
				if msg["method"] != tc.method {
					t.Fatalf("submission = %v", msg)
				}
				params := msg["params"].(map[string]any)
				if !strings.Contains(string(mustJSON(t, params["input"])), "change course") {
					t.Fatalf("input = %v", params)
				}
			case <-time.After(time.Second):
				t.Fatal("no submission")
			}
			select {
			case extra := <-submissions:
				t.Fatalf("duplicate submission: %v", extra)
			default:
			}
		})
	}
}

func mustJSON(t *testing.T, value any) []byte {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func TestRuntimeValidation(t *testing.T) {
	t.Parallel()
	dir := runtimeFixture(t)
	if enabled, err := Enabled(dir); err != nil || !enabled {
		t.Fatalf("enabled=%v error=%v", enabled, err)
	}
	if err := os.Chmod(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := Enabled(dir); err == nil {
		t.Fatal("public runtime accepted")
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(dir, MarkerName)
	if err := os.Remove(marker); err != nil {
		t.Fatal(err)
	}
	if enabled, err := Enabled(dir); err != nil || enabled {
		t.Fatalf("legacy: %v %v", enabled, err)
	}
	if err := os.Symlink(filepath.Join(dir, "missing"), marker); err != nil {
		t.Fatal(err)
	}
	if _, err := Enabled(dir); err == nil {
		t.Fatal("symlink marker accepted")
	}
	if err := Send(t.Context(), dir, "example-thread", strings.Repeat("x", maxMessage+1)); err == nil {
		t.Fatal("oversize message accepted")
	}
}

func TestSocketAliasRequiresPrivateTarget(t *testing.T) {
	t.Parallel()
	dir, physicalDir := runtimeFixture(t), runtimeFixture(t)
	path := filepath.Join(physicalDir, SocketName)
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	if err := os.Chmod(path, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(path, filepath.Join(dir, SocketName)); err != nil {
		t.Fatal(err)
	}
	if _, err := resolveSocket(dir); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(physicalDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := resolveSocket(dir); err == nil {
		t.Fatal("public target directory accepted")
	}
	if err := os.Chmod(physicalDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0o666); err != nil {
		t.Fatal(err)
	}
	if _, err := resolveSocket(dir); err == nil {
		t.Fatal("public target socket accepted")
	}
}
