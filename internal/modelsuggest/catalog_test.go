package modelsuggest

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
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

// TestLoadCatalogTTLBoundaryIsStrictlyLessThan locks in the exact freshness
// semantics: a cache exactly catalogTTL old is no longer fresh (Catalog.fresh
// uses strict "<", not "<="), so a regression to "<=" would make a
// once-a-day-on-the-dot refetch silently stop happening.
func TestLoadCatalogTTLBoundaryIsStrictlyLessThan(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	now := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	calls := 0
	fetch := fixtureFetcher(t, &calls)

	if _, err := LoadCatalog(context.Background(), CatalogOptions{Root: root, Fetch: fetch, Now: now}); err != nil {
		t.Fatalf("seed load: %v", err)
	}
	if _, err := LoadCatalog(context.Background(), CatalogOptions{Root: root, Fetch: fetch, Now: now.Add(catalogTTL)}); err != nil {
		t.Fatalf("boundary load: %v", err)
	}
	if calls != 2 {
		t.Errorf("fetch calls at exactly the TTL = %d, want 2 (a cache this old must not read as fresh)", calls)
	}
}

// TestLoadCatalogSurvivesCorruptCacheFile guards readCatalogCache's error
// path: LoadCatalog deliberately discards a cache read error and treats it as
// "no cache", so a corrupt file on disk must degrade to a fresh fetch (or, if
// the fetch also fails, to an empty catalog plus an error) rather than
// panicking or looping.
func TestLoadCatalogSurvivesCorruptCacheFile(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, CatalogFileName), []byte("{not valid json"), 0o644); err != nil {
		t.Fatalf("seed corrupt cache: %v", err)
	}

	calls := 0
	fresh, err := LoadCatalog(context.Background(), CatalogOptions{Root: root, Fetch: fixtureFetcher(t, &calls)})
	if err != nil {
		t.Fatalf("load with corrupt cache and a working fetch: %v", err)
	}
	if calls != 1 || len(fresh.Models("anthropic")) != 3 {
		t.Fatalf("fetch calls = %d, anthropic models = %d, want one fetch to replace the corrupt cache",
			calls, len(fresh.Models("anthropic")))
	}

	// A corrupt cache with no working fetch to fall back on has nothing to
	// recover from; it must still return cleanly (empty catalog, a
	// descriptive error), not panic or loop.
	unrecoverableRoot := t.TempDir()
	if err := os.WriteFile(filepath.Join(unrecoverableRoot, CatalogFileName), []byte("{not valid json"), 0o644); err != nil {
		t.Fatalf("seed corrupt cache: %v", err)
	}
	empty, err := LoadCatalog(context.Background(), CatalogOptions{Root: unrecoverableRoot, Fetch: failingFetcher(t)})
	if err == nil {
		t.Errorf("expected an error when both the cache is corrupt and the fetch fails")
	}
	if !empty.Empty() {
		t.Errorf("catalog = %+v, want empty", empty)
	}
}

// TestWriteCatalogCacheConcurrentWritersNeverCorruptTheFile guards the unique
// temp-file fix: two writers racing writeCatalogCache for the same path must
// each still produce a complete, parseable cache file — never an interleaved
// mix of both writers' bytes — regardless of which one's rename wins.
func TestWriteCatalogCacheConcurrentWritersNeverCorruptTheFile(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	a := Catalog{FetchedAt: time.Unix(1, 0), Providers: map[string][]CatalogModel{"a": {{ID: "model-a"}}}}
	b := Catalog{FetchedAt: time.Unix(2, 0), Providers: map[string][]CatalogModel{"b": {{ID: "model-b"}}}}

	var wg sync.WaitGroup
	wg.Add(2)
	for _, catalog := range []Catalog{a, b} {
		catalog := catalog
		go func() {
			defer wg.Done()
			if err := writeCatalogCache(root, catalog); err != nil {
				t.Errorf("concurrent writeCatalogCache: %v", err)
			}
		}()
	}
	wg.Wait()

	data, err := os.ReadFile(filepath.Join(root, CatalogFileName))
	if err != nil {
		t.Fatalf("read cache after concurrent writes: %v", err)
	}
	var got Catalog
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatalf("cache after concurrent writes is not valid JSON (corrupted): %v\n%s", err, data)
	}
	if len(got.Providers) != 1 || (!got.FetchedAt.Equal(a.FetchedAt) && !got.FetchedAt.Equal(b.FetchedAt)) {
		t.Fatalf("cache after concurrent writes = %+v, want a clean copy of one writer's catalog", got)
	}

	// No leftover temp files: each writer's unique tmp path was renamed away
	// (the winner) or removed on error, never left behind.
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Fatalf("read cache dir: %v", err)
	}
	for _, entry := range entries {
		if entry.Name() != CatalogFileName {
			t.Errorf("leftover file in cache dir: %s", entry.Name())
		}
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
		{name: "annotated current", line: "anthropic/claude-opus-5  (current)", want: "anthropic/claude-opus-5"},
		{name: "annotated tab-separated", line: "opencode/big-pickle\tReasoning model", want: "opencode/big-pickle"},
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
