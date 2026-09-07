package modelsuggest

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// upstreamFixture mirrors the shape of the models.dev document, including the
// records Questmaster must drop (an embedding model with no tool calls, an
// image-only model) and fields it ignores.
const upstreamFixture = `{
  "anthropic": {
    "id": "anthropic",
    "models": {
      "claude-opus-5": {
        "id": "claude-opus-5",
        "name": "Claude Opus 5",
        "family": "claude-opus",
        "release_date": "2026-06-01",
        "tool_call": true,
        "reasoning": true,
        "cost": {"input": 5},
        "reasoning_options": [
          {"type": "effort", "values": ["low", "high", "max"]},
          {"type": "budget_tokens", "min": 1024}
        ],
        "modalities": {"input": ["text"], "output": ["text"]}
      },
      "claude-sonnet-4-6": {
        "id": "claude-sonnet-4-6",
        "name": "Claude Sonnet 4.6",
        "family": "claude-sonnet",
        "release_date": "2026-02-17",
        "tool_call": true,
        "modalities": {"output": ["text"]}
      },
      "claude-opus-4-8": {
        "id": "claude-opus-4-8",
        "name": "Claude Opus 4.8",
        "family": "claude-opus",
        "release_date": "2026-04-02",
        "tool_call": true,
        "modalities": {"output": ["text"]}
      },
      "text-embedding-x": {
        "id": "text-embedding-x",
        "name": "Embeddings",
        "family": "text-embedding",
        "tool_call": false,
        "modalities": {"output": ["text"]}
      }
    }
  },
  "openai": {
    "id": "openai",
    "models": {
      "gpt-5.6-terra": {
        "id": "gpt-5.6-terra",
        "name": "GPT-5.6 Terra",
        "family": "gpt-terra",
        "release_date": "2026-07-09",
        "tool_call": true,
        "modalities": {"output": ["text"]}
      },
      "gpt-image-2": {
        "id": "gpt-image-2",
        "name": "GPT Image 2",
        "family": "gpt-image",
        "tool_call": true,
        "modalities": {"output": ["image"]}
      }
    }
  },
  "opencode": {
    "id": "opencode",
    "models": {
      "big-pickle": {
        "id": "big-pickle",
        "name": "Big Pickle",
        "family": "big-pickle",
        "release_date": "2025-10-17",
        "tool_call": true,
        "modalities": {"output": ["text"]}
      }
    }
  }
}`

func fixtureFetcher(t *testing.T, calls *int) Fetcher {
	t.Helper()
	return func(_ context.Context, _ string) ([]byte, error) {
		*calls++
		return []byte(upstreamFixture), nil
	}
}

func failingFetcher(t *testing.T) Fetcher {
	t.Helper()
	return func(_ context.Context, _ string) ([]byte, error) {
		return nil, fmt.Errorf("network down")
	}
}

func TestDistillCatalogKeepsLaunchableModels(t *testing.T) {
	t.Parallel()

	catalog, err := distillCatalog([]byte(upstreamFixture), time.Unix(0, 0))
	if err != nil {
		t.Fatalf("distill catalog: %v", err)
	}

	anthropic := catalog.Models("anthropic")
	if len(anthropic) != 3 {
		t.Fatalf("anthropic models = %d, want 3 (embeddings dropped): %+v", len(anthropic), anthropic)
	}
	// Newest first, so the ordering never needs a hardcoded model list.
	if anthropic[0].ID != "claude-opus-5" {
		t.Errorf("first anthropic model = %q, want claude-opus-5", anthropic[0].ID)
	}
	if got := anthropic[0].Efforts; len(got) != 3 || got[0] != "low" || got[2] != "max" {
		t.Errorf("effort values = %v, want [low high max]", got)
	}
	if openai := catalog.Models("openai"); len(openai) != 1 || openai[0].ID != "gpt-5.6-terra" {
		t.Errorf("openai models = %+v, want only gpt-5.6-terra (image model dropped)", openai)
	}
}

func TestLoadCatalogCachesAndSurvivesFetchFailure(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	now := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	calls := 0

	first, err := LoadCatalog(context.Background(), CatalogOptions{Root: root, Fetch: fixtureFetcher(t, &calls), Now: now})
	if err != nil {
		t.Fatalf("first load: %v", err)
	}
	if first.Empty() || calls != 1 {
		t.Fatalf("first load fetched %d times, catalog empty = %v", calls, first.Empty())
	}
	if _, err := os.Stat(filepath.Join(root, CatalogFileName)); err != nil {
		t.Fatalf("catalog cache not written: %v", err)
	}

	// A fresh cache is served without touching the network at all.
	cached, err := LoadCatalog(context.Background(), CatalogOptions{Root: root, Fetch: failingFetcher(t), Now: now.Add(time.Hour)})
	if err != nil {
		t.Fatalf("cached load: %v", err)
	}
	if len(cached.Models("anthropic")) != 3 {
		t.Errorf("cached anthropic models = %d, want 3", len(cached.Models("anthropic")))
	}

	// An expired cache plus a failed fetch still yields the stale catalog,
	// so an offline picker keeps working.
	stale, err := LoadCatalog(context.Background(), CatalogOptions{Root: root, Fetch: failingFetcher(t), Now: now.Add(48 * time.Hour)})
	if err == nil {
		t.Errorf("expected an error describing the failed fetch")
	}
	if len(stale.Models("anthropic")) != 3 {
		t.Errorf("stale anthropic models = %d, want the cached 3", len(stale.Models("anthropic")))
	}
}

func TestLoadCatalogRefreshForcesFetch(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	now := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	calls := 0
	fetch := fixtureFetcher(t, &calls)

	if _, err := LoadCatalog(context.Background(), CatalogOptions{Root: root, Fetch: fetch, Now: now}); err != nil {
		t.Fatalf("seed load: %v", err)
	}
	if _, err := LoadCatalog(context.Background(), CatalogOptions{Root: root, Fetch: fetch, Now: now, Refresh: true}); err != nil {
		t.Fatalf("refresh load: %v", err)
	}
	if calls != 2 {
		t.Errorf("fetch calls = %d, want 2 (refresh bypasses the fresh cache)", calls)
	}
}

func TestCatalogURLEnvDisablesFetch(t *testing.T) {
	t.Setenv(CatalogURLEnv, "off")

	root := t.TempDir()
	calls := 0
	catalog, err := LoadCatalog(context.Background(), CatalogOptions{Root: root, Fetch: fixtureFetcher(t, &calls)})
	if calls != 0 {
		t.Errorf("fetch calls = %d, want 0 when %s is off", calls, CatalogURLEnv)
	}
	if err == nil {
		t.Errorf("expected an error explaining that fetching is disabled with no cache")
	}
	if !catalog.Empty() {
		t.Errorf("catalog = %+v, want empty", catalog)
	}
}

func TestProbeModelIDKeepsQualifiedIDsOnly(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name string
		line string
		want string
	}{
		{name: "qualified", line: "anthropic/claude-opus-5", want: "anthropic/claude-opus-5"},
		{name: "padded", line: "  opencode/big-pickle  ", want: "opencode/big-pickle"},
		{name: "bare", line: "claude-opus-5", want: ""},
		{name: "header", line: "Available models:", want: ""},
		{name: "blank", line: "   ", want: ""},
		{name: "trailing slash", line: "anthropic/", want: ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			if got := probeModelID(tc.line); got != tc.want {
				t.Errorf("probeModelID(%q) = %q, want %q", tc.line, got, tc.want)
			}
		})
	}
}
