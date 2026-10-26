//go:build linux || darwin

package daemon

import (
	"context"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/modelsuggest"
	"github.com/alexivison/questmaster/internal/serve"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

type runtimeTmuxRunner struct{}

func (runtimeTmuxRunner) Run(context.Context, ...string) (string, error) { return "qm-demo", nil }

type runtimeChangeSource struct{ changes chan serve.Change }

func (s *runtimeChangeSource) Subscribe(context.Context) (<-chan serve.Change, func()) {
	return s.changes, func() {}
}
func (*runtimeChangeSource) Close() error { return nil }

func TestDaemonSocketSharesServeRequestsAndSubscriptions(t *testing.T) {
	root := t.TempDir()
	t.Setenv(state.StateRootEnv, root)
	t.Setenv(modelsuggest.CatalogURLEnv, "off")
	t.Setenv("CODEX_BIN", filepath.Join(root, "missing-codex"))
	t.Setenv("QUESTMASTER_SESSION", "")
	store, err := state.NewStore(root)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Create(state.Manifest{SessionID: "qm-demo", Title: "first", Cwd: root, SessionType: "master", Agents: []state.AgentManifest{{Name: "codex", Role: "agent"}}}); err != nil {
		t.Fatal(err)
	}
	artifactPath := filepath.Join(root, "report.html")
	if err := state.UpsertArtifactGlobal(root, state.Artifact{Path: artifactPath}); err != nil {
		t.Fatal(err)
	}
	changes := &runtimeChangeSource{changes: make(chan serve.Change, 4)}
	var mutations atomic.Int32
	runtime := &serve.Server{
		Snapshotter:      serve.NewSnapshotter(store, tmux.NewClient(runtimeTmuxRunner{}), func() time.Time { return time.Unix(100, 0) }),
		ChangeSource:     changes,
		DirQuerier:       func(string) ([]string, error) { return []string{root}, nil },
		ReasoningEfforts: func(context.Context, string, string) []string { return []string{"high"} },
		MutationRunner: mutationRunnerFunc(func(context.Context, []string, []byte) ([]byte, error) {
			mutations.Add(1)
			return []byte(`{"started":true}`), nil
		}),
	}
	s := &server{
		config:  Config{Root: root, PollInterval: time.Millisecond, ReadIdleTimeout: time.Hour, WriteTimeout: time.Second},
		runtime: runtime, id: "canonical", record: Record{Root: root, Identity: "canonical", Accepting: true, Generation: 1},
	}
	serverConn, clientConn := net.Pipe()
	defer clientConn.Close()
	go s.handle(serverConn)
	dec, enc := json.NewDecoder(clientConn), json.NewEncoder(clientConn)
	var greeting hello
	if err := dec.Decode(&greeting); err != nil || greeting.Generation != 1 {
		t.Fatalf("handshake: %+v %v", greeting, err)
	}
	request := func(id, method string, data any, version int) serve.Envelope {
		t.Helper()
		if err := enc.Encode(map[string]any{"id": id, "method": method, "data": data, "protocol_version": version}); err != nil {
			t.Fatal(err)
		}
		var reply serve.Envelope
		if err := dec.Decode(&reply); err != nil {
			t.Fatal(err)
		}
		if reply.ProtocolVersion != ProtocolVersion || string(reply.ID) != `"`+id+`"` || reply.Type != "response" {
			t.Fatalf("%s envelope=%+v", method, reply)
		}
		return reply
	}
	for _, tc := range []struct {
		method string
		data   any
		topic  string
	}{
		{"status", nil, "status"},
		{"tracker", nil, "tracker"},
		{"dir_suggest", map[string]any{"query": filepath.Base(root)}, "dir_suggest"},
		{"reasoning_efforts", map[string]any{"agent": "codex", "model": "test"}, "reasoning_efforts"},
		{"worker_feed", map[string]any{"master_id": "qm-demo"}, "worker_feed"},
		{"models", map[string]any{"agent": "codex", "role": "master"}, "models"},
		{"mutation.delete", map[string]any{"session_id": "qm-demo"}, "mutation.delete"},
		{"continue", map[string]any{"session_id": "qm-demo"}, "continue"},
		{"spawn", map[string]any{"master_id": "qm-demo", "title": "worker"}, "spawn"},
		{"start", map[string]any{"title": "test"}, "start"},
		{"rename", map[string]any{"session_id": "qm-demo", "title": "renamed"}, "rename"},
		{"recolor", map[string]any{"scope": "session", "session_id": "qm-demo", "color": "violet"}, "recolor"},
		{"role_default.set", map[string]any{"agent": "codex", "role": "master", "model": "gpt-test"}, "role_default.set"},
		{"quest.add", map[string]any{"quest_id": "qst-demo", "content": "first quest"}, "quest.add"},
		{"quest.edit", map[string]any{"quest_id": "qst-demo", "content": "edited quest"}, "quest.edit"},
		{"quest.delete", map[string]any{"quest_id": "qst-demo"}, "quest.delete"},
		{"artifact.delete", map[string]any{"path": artifactPath}, "artifact.delete"},
	} {
		reply := request(tc.method, tc.method, tc.data, ProtocolVersion)
		if reply.OK == nil || !*reply.OK || reply.Topic != tc.topic {
			t.Fatalf("%s reply=%+v", tc.method, reply)
		}
	}
	if mutations.Load() != 4 {
		t.Fatalf("mutation runner called %d times", mutations.Load())
	}
	for _, method := range []string{"unknown"} {
		reply := request(method, method, nil, ProtocolVersion)
		if reply.OK == nil || *reply.OK || reply.Error == "" {
			t.Fatalf("%s should return serve error envelope: %+v", method, reply)
		}
	}
	if reply := request("wrong-version", "status", nil, ProtocolVersion+1); reply.OK == nil || *reply.OK || reply.Error != "incompatible protocol" {
		t.Fatalf("version gate=%+v", reply)
	}
	if reply := request("upgrade", "check-upgrade", nil, ProtocolVersion+1); reply.OK == nil || !*reply.OK {
		t.Fatalf("check-upgrade did not bypass version gate: %+v", reply)
	}
	if err := enc.Encode(map[string]any{"id": "sub", "method": "subscribe", "topics": []string{"invalid", "tracker", "tracker"}}); err != nil {
		t.Fatal(err)
	}
	var subscribed serve.Envelope
	if err := dec.Decode(&subscribed); err != nil || subscribed.OK == nil || !*subscribed.OK || subscribed.Topic != "subscribe" {
		t.Fatalf("subscribe response: %+v %v", subscribed, err)
	}
	var initial serve.Envelope
	if err := dec.Decode(&initial); err != nil || initial.Type != "event" || initial.Topic != "tracker" {
		t.Fatalf("initial event: %+v %v", initial, err)
	}
	if err := store.Update("qm-demo", func(m *state.Manifest) { m.Title = "second" }); err != nil {
		t.Fatal(err)
	}
	changes.changes <- serve.Change{Topics: []string{"tracker"}, BroadTracker: true}
	var changed serve.Envelope
	if err := dec.Decode(&changed); err != nil || changed.Type != "event" || changed.Topic != "tracker" {
		t.Fatalf("changed event: %+v %v", changed, err)
	}
	if !strings.Contains(string(mustJSON(t, changed.Data)), "second") {
		t.Fatalf("change did not include new title: %+v", changed)
	}
	changes.changes <- serve.Change{Topics: []string{"tracker"}, Clock: true}
	_ = clientConn.SetReadDeadline(time.Now().Add(150 * time.Millisecond))
	var duplicate serve.Envelope
	if err := dec.Decode(&duplicate); err == nil {
		t.Fatalf("unchanged snapshot emitted duplicate: %+v", duplicate)
	}
	clientConn.Close()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if s.clients() == 0 {
			break
		}
		time.Sleep(time.Millisecond)
	}
	if s.clients() != 0 {
		t.Fatal("closed subscription remained a daemon client")
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

func TestDaemonStopsWatcherWithoutSubscriber(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	s := &server{runtime: &serve.Server{Snapshotter: serve.NewSnapshotter(state.OpenStore(root), tmux.NewClient(runtimeTmuxRunner{}), nil)}}
	if s.source != nil {
		t.Fatal("watcher started without a subscriber")
	}
	_, release, err := s.subscribeSource()
	if err != nil {
		t.Fatal(err)
	}
	if s.source == nil || s.sourceClients != 1 {
		t.Fatalf("watcher did not start: source=%v clients=%d", s.source, s.sourceClients)
	}
	release()
	if s.source != nil || s.sourceClients != 0 {
		t.Fatalf("watcher did not stop: source=%v clients=%d", s.source, s.sourceClients)
	}
}

func TestDaemonAndServeSessionMutationsShareRunnerEnvironment(t *testing.T) {
	for key, value := range map[string]string{
		"QUESTMASTER_APP": "1", "QUESTMASTER_STATE_ROOT": t.TempDir(),
		"QUESTMASTER_BIN": "/app/shim/qm", "QUESTMASTER_PATH_PREFIX": "/app/shim",
		"PATH": "/app/shim:/usr/bin", "SSH_AUTH_SOCK": "/tmp/agent.sock",
	} {
		t.Setenv(key, value)
	}
	runner := mutationRunnerFunc(func(_ context.Context, args []string, _ []byte) ([]byte, error) {
		data := map[string]any{"args": args, "environment": map[string]string{}}
		env := data["environment"].(map[string]string)
		for _, key := range []string{"QUESTMASTER_APP", "QUESTMASTER_STATE_ROOT", "QUESTMASTER_BIN", "QUESTMASTER_PATH_PREFIX", "PATH", "SSH_AUTH_SOCK"} {
			env[key] = os.Getenv(key)
		}
		return json.Marshal(data)
	})
	shared := &serve.Server{MutationRunner: runner}
	daemon := &server{runtime: shared}
	for _, tc := range []struct {
		method string
		data   string
	}{
		{"start", `{"title":"master"}`},
		{"spawn", `{"master_id":"qm-master","title":"worker"}`},
	} {
		req := serve.Request{Method: tc.method, Data: json.RawMessage(tc.data)}
		legacy := shared.HandleRequest(t.Context(), req)
		fromDaemon, _ := daemon.dispatch(req)
		if legacy.OK == nil || !*legacy.OK || fromDaemon.OK == nil || !*fromDaemon.OK || !reflect.DeepEqual(legacy.Data, fromDaemon.Data) {
			t.Fatalf("%s mutation differs: serve=%+v daemon=%+v", tc.method, legacy, fromDaemon)
		}
		env := fromDaemon.Data.(map[string]any)["environment"].(map[string]any)
		if env["SSH_AUTH_SOCK"] != "/tmp/agent.sock" || env["QUESTMASTER_PATH_PREFIX"] != "/app/shim" {
			t.Fatalf("%s runner lost child environment: %+v", tc.method, env)
		}
	}
}
