package state

import (
	"encoding/json"
	"testing"
)

func TestManifestTmuxServerRoundTrip(t *testing.T) {
	for _, tc := range []struct {
		name, input, want string
	}{
		{"absent", `{"session_id":"qm-example","note":{"keep":true}}`, ""},
		{"default", `{"session_id":"qm-example","tmux_server":"default","note":{"keep":true}}`, "default"},
		{"questmaster", `{"session_id":"qm-example","tmux_server":"questmaster","note":{"keep":true}}`, "questmaster"},
		{"unknown", `{"session_id":"qm-example","tmux_server":"dev_1","note":{"keep":true}}`, "dev_1"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var m Manifest
			if err := json.Unmarshal([]byte(tc.input), &m); err != nil {
				t.Fatal(err)
			}
			if string(m.TmuxServer) != tc.want {
				t.Fatalf("server = %q", m.TmuxServer)
			}
			if _, ok := m.Extra["tmux_server"]; ok {
				t.Fatal("typed field retained in Extra")
			}
			if string(m.Extra["note"]) != `{"keep":true}` {
				t.Fatalf("Extra = %s", m.Extra["note"])
			}
			data, err := json.Marshal(m)
			if err != nil {
				t.Fatal(err)
			}
			var round Manifest
			if err := json.Unmarshal(data, &round); err != nil {
				t.Fatal(err)
			}
			if round.TmuxServer != m.TmuxServer || string(round.Extra["note"]) != `{"keep":true}` {
				t.Fatalf("round trip = %+v", round)
			}
		})
	}
}
