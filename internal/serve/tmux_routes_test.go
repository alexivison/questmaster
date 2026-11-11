package serve

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxroute"
)

type routeRunner func(context.Context, ...string) (string, error)

func (f routeRunner) Run(ctx context.Context, args ...string) (string, error) { return f(ctx, args...) }

func TestServeTmuxRoutesDedicatedOwnership(t *testing.T) {
	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Create(state.Manifest{SessionID: "qm-example", TmuxServer: "dev_previous", CreatedAt: "2026-01-01T00:00:00Z"}); err != nil {
		t.Fatal(err)
	}
	router := tmuxroute.New(store, map[string]*tmux.Client{
		"dev_previous": tmux.NewClient(routeRunner(func(context.Context, ...string) (string, error) { return "qm-example", nil })),
		"questmaster": tmux.NewClient(routeRunner(func(context.Context, ...string) (string, error) {
			return "", &tmux.ExitError{Code: 1, Stderr: "no server running"}
		})),
	}, func() string { return "dev_previous" }, []string{"/tmp/example/user.conf", "/tmp/example/enforced.conf"})
	srv := &Server{TmuxRouter: router}
	response := srv.HandleRequest(context.Background(), Request{ID: json.RawMessage(`"tmux-routes-request"`), Method: "tmux.routes", Data: json.RawMessage(`{"session_ids":["qm-example"]}`)})
	if response.OK == nil || !*response.OK {
		t.Fatalf("response = %+v", response)
	}
	response.ProtocolVersion = ServeProtocolVersion
	data, err := json.Marshal(response.Data)
	if err != nil {
		t.Fatal(err)
	}
	var routes []tmuxroute.RouteRecord
	if err := json.Unmarshal(data, &routes); err != nil {
		t.Fatal(err)
	}
	if len(routes) != 1 || routes[0].Server != "dev_previous" || !routes[0].Live || len(routes[0].ConfigFiles) != 2 {
		t.Fatalf("routes=%+v", routes)
	}
}
