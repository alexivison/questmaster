//go:build linux || darwin

package state

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func BenchmarkDiscoverSessions(b *testing.B) {
	s := newBenchmarkStore(b, 100)

	b.ReportAllocs()
	b.ResetTimer()

	for i := 0; i < b.N; i++ {
		sessions, err := s.DiscoverSessions()
		if err != nil {
			b.Fatalf("DiscoverSessions: %v", err)
		}
		if len(sessions) != 100 {
			b.Fatalf("session count: got %d, want 100", len(sessions))
		}
	}

	b.StopTimer()
}

func newBenchmarkStore(b *testing.B, count int) *Store {
	b.Helper()

	root, err := os.MkdirTemp("", "party-cli-state-bench-*")
	if err != nil {
		b.Fatalf("MkdirTemp: %v", err)
	}
	defer func() {
		if b.Failed() {
			os.RemoveAll(root)
			return
		}
		b.Cleanup(func() {
			os.RemoveAll(root)
		})
	}()

	s, err := NewStore(root)
	if err != nil {
		b.Fatalf("NewStore: %v", err)
	}

	for i := 0; i < count; i++ {
		path := filepath.Join(s.root, fmt.Sprintf("party-%03d.json", i))
		raw := fmt.Sprintf(`{
  "party_id": "party-%03d",
  "created_at": "2026-03-20T10:00:00Z",
  "updated_at": "2026-03-20T10:05:00Z",
  "title": "session-%03d",
  "cwd": "/tmp/party-%03d",
  "window_name": "party-%03d",
  "agents": [
    {"name": "claude", "role": "primary", "cli": "/usr/local/bin/claude", "resume_id": "claude-%03d", "window": 1},
    {"name": "codex", "role": "companion", "cli": "/usr/local/bin/codex", "resume_id": "codex-%03d", "window": 0}
  ],
  "workers": ["party-worker-%03d", "party-worker-%03d"],
  "feature_flag": true,
  "retry_count": %d,
  "metadata": {"index": %d, "labels": ["alpha", "beta"]},
  "initial_prompt": "benchmark payload"
}
`, i, i, i, i, i, i, i, i+1, i%7, i)
		if err := os.WriteFile(path, []byte(raw), 0o644); err != nil {
			b.Fatalf("WriteFile(%s): %v", path, err)
		}
	}

	return s
}
