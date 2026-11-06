package modelsuggest

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/agent"
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
	seedCalls := 0

	if _, err := LoadCatalog(context.Background(), CatalogOptions{Root: root, Fetch: fixtureFetcher(t, &seedCalls), Now: now}); err != nil {
		t.Fatalf("seed load: %v", err)
	}

	// Exactly catalogTTL old is not fresh: the cache is served at once and a
	// refresh starts in the background.
	fetch := newBlockingFetcher(t)
	boundary := now.Add(catalogTTL)
	loadCatalogWithin(t, asyncDeadline, CatalogOptions{Root: root, Fetch: fetch.fetch, Now: boundary, Background: true})
	fetch.awaitStarted(t)
	if calls := fetch.calls.Load(); calls != 1 {
		t.Errorf("fetch calls at exactly the TTL = %d, want 1 (a cache this old must not read as fresh)", calls)
	}
	fetch.release()
	awaitCachedAt(t, root, boundary)
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

// Bounds the background-refresh tests check. coldCacheWaitLimit is the spec
// (a request with no cached catalog answers within about 2 s), not the
// production constant, so the test fails if the production wait grows.
const (
	staleServeLimit    = 100 * time.Millisecond
	coldCacheWaitLimit = 2 * time.Second
	coldCacheSlack     = 500 * time.Millisecond
	asyncDeadline      = 5 * time.Second
	catalogPollEvery   = 5 * time.Millisecond
)

// blockingFetcher stands in for a slow network. Each call counts itself and
// signals started, then waits until release opens the gate.
type blockingFetcher struct {
	calls   atomic.Int32
	started chan struct{}
	gate    chan struct{}
	once    sync.Once
}

func newBlockingFetcher(t *testing.T) *blockingFetcher {
	t.Helper()
	fetcher := &blockingFetcher{started: make(chan struct{}, 1), gate: make(chan struct{})}
	t.Cleanup(fetcher.release)
	return fetcher
}

func (f *blockingFetcher) fetch(_ context.Context, _ string) ([]byte, error) {
	f.calls.Add(1)
	select {
	case f.started <- struct{}{}:
	default:
	}
	<-f.gate
	return []byte(upstreamFixture), nil
}

func (f *blockingFetcher) release() {
	f.once.Do(func() { close(f.gate) })
}

// awaitStarted waits for the first fetch call, which is how a test knows the
// background refresh has begun.
func (f *blockingFetcher) awaitStarted(t *testing.T) {
	t.Helper()
	select {
	case <-f.started:
	case <-time.After(asyncDeadline):
		t.Fatalf("no catalog fetch started within %s", asyncDeadline)
	}
}

type loadResult struct {
	catalog Catalog
	err     error
	elapsed time.Duration
}

// loadCatalogWithin runs LoadCatalog on its own goroutine and fails the test
// if it has not returned within limit, so a blocking regression fails instead
// of hanging the suite.
func loadCatalogWithin(t *testing.T, limit time.Duration, opts CatalogOptions) loadResult {
	t.Helper()
	done := make(chan loadResult, 1)
	start := time.Now()
	go func() {
		catalog, err := LoadCatalog(context.Background(), opts)
		done <- loadResult{catalog: catalog, err: err, elapsed: time.Since(start)}
	}()
	select {
	case result := <-done:
		return result
	case <-time.After(limit):
		t.Fatalf("LoadCatalog did not return within %s", limit)
		return loadResult{}
	}
}

// awaitCachedAt waits until the cache under root holds a catalog fetched at
// fetchedAt, which is how a finished refresh shows itself on disk.
func awaitCachedAt(t *testing.T, root string, fetchedAt time.Time) {
	t.Helper()
	deadline := time.Now().Add(asyncDeadline)
	for {
		if cached, _ := readCatalogCache(root); cached.FetchedAt.Equal(fetchedAt) {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("cache under %s was not refreshed to %s within %s", root, fetchedAt, asyncDeadline)
		}
		time.Sleep(catalogPollEvery)
	}
}

func TestCatalogURLOverrideMustBeHTTPS(t *testing.T) {
	cases := []struct {
		name      string
		value     string
		wantFetch bool
	}{
		{name: "plain http", value: "http://mirror.example.test/api.json"},
		{name: "upper-case http", value: "HTTP://mirror.example.test/api.json"},
		{name: "no scheme", value: "mirror.example.test/api.json"},
		{name: "ftp", value: "ftp://mirror.example.test/api.json"},
		{name: "https", value: "https://mirror.example.test/api.json", wantFetch: true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv(CatalogURLEnv, tc.value)

			requested := make(chan string, 1)
			fetch := func(_ context.Context, endpoint string) ([]byte, error) {
				requested <- endpoint
				return []byte(upstreamFixture), nil
			}
			catalog, err := LoadCatalog(context.Background(), CatalogOptions{Root: t.TempDir(), Fetch: fetch})

			select {
			case endpoint := <-requested:
				if !tc.wantFetch {
					t.Fatalf("fetched %q; a non-https override must never be fetched", endpoint)
				}
				if endpoint != tc.value {
					t.Errorf("fetched %q, want the override %q", endpoint, tc.value)
				}
				if err != nil {
					t.Errorf("load with an https override: %v", err)
				}
			default:
				if tc.wantFetch {
					t.Fatalf("no fetch for the https override %q", tc.value)
				}
				if err == nil || !strings.Contains(err.Error(), "https") {
					t.Errorf("load error = %v, want one saying the override must be https", err)
				}
				if !catalog.Empty() {
					t.Errorf("catalog = %+v, want empty", catalog)
				}
			}
		})
	}
}

func TestHTTPFetcherRefusesPlainHTTP(t *testing.T) {
	t.Parallel()

	// Loopback only: the server counts requests, so a fetch that reaches it
	// is caught without any real network access.
	var hits atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits.Add(1)
		_, _ = w.Write([]byte(upstreamFixture))
	}))
	t.Cleanup(server.Close)

	if _, err := HTTPFetcher(context.Background(), server.URL+"/api.json"); err == nil {
		t.Errorf("HTTPFetcher fetched a plain http:// URL, want an error")
	}
	if n := hits.Load(); n != 0 {
		t.Errorf("plain http:// request reached the server %d times, want 0", n)
	}
}

// TestLoadCatalogServesStaleCacheAtOnceAndRefreshesOnce: a stale cache answers
// under staleServeLimit while one background refresh runs, and repeated calls
// during that refresh start no second one.
func TestLoadCatalogServesStaleCacheAtOnceAndRefreshesOnce(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	now := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	stale := Catalog{
		FetchedAt: now.Add(-48 * time.Hour),
		Providers: map[string][]CatalogModel{"example": {{ID: "example-model-stale"}}},
	}
	if err := writeCatalogCache(root, stale); err != nil {
		t.Fatalf("seed stale cache: %v", err)
	}

	fetch := newBlockingFetcher(t)
	opts := CatalogOptions{Root: root, Fetch: fetch.fetch, Now: now, Background: true}

	first := loadCatalogWithin(t, asyncDeadline, opts)
	if first.err != nil {
		t.Errorf("stale load: %v", first.err)
	}
	if first.elapsed >= staleServeLimit {
		t.Errorf("stale cache answered after %s, want under %s while the refresh runs", first.elapsed, staleServeLimit)
	}
	if models := first.catalog.Models("example"); len(models) != 1 || models[0].ID != "example-model-stale" {
		t.Fatalf("stale load = %+v, want the cached catalog", first.catalog)
	}

	fetch.awaitStarted(t)
	for range 3 {
		loadCatalogWithin(t, asyncDeadline, opts)
	}
	if calls := fetch.calls.Load(); calls != 1 {
		t.Errorf("refresh starts = %d, want exactly 1 while one refresh is in flight", calls)
	}

	fetch.release()
	awaitCachedAt(t, root, now)

	refreshed := loadCatalogWithin(t, asyncDeadline, opts)
	if n := len(refreshed.catalog.Models("anthropic")); n != 3 {
		t.Errorf("anthropic models after the refresh = %d, want 3", n)
	}
	if calls := fetch.calls.Load(); calls != 1 {
		t.Errorf("fetch calls after the cache was refreshed = %d, want still 1", calls)
	}
}

// TestLoadCatalogColdCacheAnswersWithinBound: with nothing cached, a request
// waits at most about coldCacheWaitLimit, answers without a catalog, and the
// fetch it started fills the cache for the next request.
func TestLoadCatalogColdCacheAnswersWithinBound(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	now := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	fetch := newBlockingFetcher(t)
	opts := CatalogOptions{Root: root, Fetch: fetch.fetch, Now: now, Background: true}

	cold := loadCatalogWithin(t, asyncDeadline, opts)
	if limit := coldCacheWaitLimit + coldCacheSlack; cold.elapsed > limit {
		t.Errorf("cold cache answered after %s, want within %s", cold.elapsed, limit)
	}
	if !cold.catalog.Empty() {
		t.Errorf("cold load = %+v, want no catalog while the fetch is still running", cold.catalog)
	}
	if cold.err == nil {
		t.Errorf("cold load returned no error, want one saying the catalog is still loading")
	}

	fetch.awaitStarted(t)
	fetch.release()
	awaitCachedAt(t, root, now)

	next := loadCatalogWithin(t, asyncDeadline, opts)
	if next.err != nil || next.catalog.Empty() {
		t.Errorf("load after the cache was filled = %+v, err %v, want the catalog", next.catalog, next.err)
	}
	if calls := fetch.calls.Load(); calls != 1 {
		t.Errorf("fetch calls = %d, want 1 (the next request reads the cache)", calls)
	}
}

// TestLoadCatalogWithoutBackgroundWaitsForFreshCatalog: a one-shot process
// exits before a background refresh could finish, so without Background a
// stale cache is not answered at once. The call waits for the fetch and
// returns the fresh catalog.
func TestLoadCatalogWithoutBackgroundWaitsForFreshCatalog(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	now := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	stale := Catalog{
		FetchedAt: now.Add(-48 * time.Hour),
		Providers: map[string][]CatalogModel{"example": {{ID: "example-model-stale"}}},
	}
	if err := writeCatalogCache(root, stale); err != nil {
		t.Fatalf("seed stale cache: %v", err)
	}

	const fetchDelay = 50 * time.Millisecond
	slow := func(_ context.Context, _ string) ([]byte, error) {
		time.Sleep(fetchDelay)
		return []byte(upstreamFixture), nil
	}
	result := loadCatalogWithin(t, asyncDeadline, CatalogOptions{Root: root, Fetch: slow, Now: now})
	if result.err != nil {
		t.Fatalf("load: %v", result.err)
	}
	if !result.catalog.FetchedAt.Equal(now) {
		t.Errorf("load returned the catalog fetched at %s, want the fresh one fetched at %s", result.catalog.FetchedAt, now)
	}
	if n := len(result.catalog.Models("anthropic")); n != 3 {
		t.Errorf("anthropic models = %d, want 3 from the fresh fetch", n)
	}
	if result.elapsed < fetchDelay {
		t.Errorf("load answered after %s, before its fetch could finish (%s)", result.elapsed, fetchDelay)
	}
}

// TestCatalogClientRefusesRedirectToPlainHTTP: an https endpoint that
// redirects to plain http is not followed, so the plain server never sees a
// request. A redirect to https is still followed, which shows the client works.
func TestCatalogClientRefusesRedirectToPlainHTTP(t *testing.T) {
	t.Parallel()

	var plainHits atomic.Int32
	plain := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		plainHits.Add(1)
		_, _ = w.Write([]byte(upstreamFixture))
	}))
	t.Cleanup(plain.Close)

	var secure *httptest.Server
	secure = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/downgrade":
			http.Redirect(w, r, plain.URL+"/api.json", http.StatusFound)
		case "/secure":
			http.Redirect(w, r, secure.URL+"/api.json", http.StatusFound)
		default:
			_, _ = w.Write([]byte(upstreamFixture))
		}
	}))
	t.Cleanup(secure.Close)
	client := newCatalogClient(secure.Client())

	if _, err := getCatalog(context.Background(), client, secure.URL+"/downgrade"); err == nil {
		t.Errorf("redirect to plain http was followed, want an error")
	}
	if n := plainHits.Load(); n != 0 {
		t.Errorf("plain http target reached %d times, want 0", n)
	}

	body, err := getCatalog(context.Background(), client, secure.URL+"/secure")
	if err != nil {
		t.Fatalf("redirect to https: %v", err)
	}
	if string(body) != upstreamFixture {
		t.Errorf("redirect to https returned %d bytes, want the fixture", len(body))
	}
}

// TestResolveBackgroundServesStaleCatalogAtOnce: the daemon sets Background
// through ResolveOptions, and Resolve must pass it on. With a stale cache and
// a fetch that has not finished, Resolve answers at once.
func TestResolveBackgroundServesStaleCatalogAtOnce(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	now := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	stale := Catalog{
		FetchedAt: now.Add(-48 * time.Hour),
		Providers: map[string][]CatalogModel{"anthropic": {{ID: "example-model-stale"}}},
	}
	if err := writeCatalogCache(root, stale); err != nil {
		t.Fatalf("seed stale cache: %v", err)
	}
	fetch := newBlockingFetcher(t)

	answered := make(chan time.Duration, 1)
	go func() {
		start := time.Now()
		Resolve(context.Background(), ResolveOptions{
			Agent:      "claude",
			Role:       agent.RoleMaster,
			Root:       root,
			Fetch:      fetch.fetch,
			Now:        now,
			NoProbe:    true,
			Background: true,
		})
		answered <- time.Since(start)
	}()
	select {
	case elapsed := <-answered:
		if elapsed >= staleServeLimit {
			t.Errorf("Resolve answered after %s, want under %s while the refresh runs", elapsed, staleServeLimit)
		}
	case <-time.After(asyncDeadline):
		t.Fatalf("Resolve did not return within %s", asyncDeadline)
	}

	fetch.awaitStarted(t)
	fetch.release()
	awaitCachedAt(t, root, now)
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
