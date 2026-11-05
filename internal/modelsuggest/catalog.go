package modelsuggest

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexivison/questmaster/internal/state"
)

const (
	// CatalogURL is the models.dev index: one JSON document describing every
	// known provider and its models. It is the same catalog OpenCode reads,
	// and it is the reason a newly released model needs no Questmaster change.
	CatalogURL = "https://models.dev/api.json"

	// CatalogURLEnv overrides CatalogURL. Set it to "off" (or an empty value)
	// to never reach the network: suggestions then come from the cache,
	// harness enumeration, recent launches, and the built-in role defaults.
	CatalogURLEnv = "QUESTMASTER_MODEL_CATALOG_URL"

	// CatalogFileName is the distilled catalog cached under the state root.
	// Only the fields Questmaster renders are kept, so the cache is a few
	// hundred KB rather than the multi-MB upstream document.
	CatalogFileName = "model-catalog.json"

	catalogTTL = 24 * time.Hour
	// catalogColdWait bounds how long a request with no cached catalog waits
	// for the first fetch. The fetch keeps running and fills the cache, so the
	// next request reads it.
	catalogColdWait = 2 * time.Second
	// catalogFetchTimeout bounds one fetch, background or not, so a hung
	// network cannot keep a refresh open forever.
	catalogFetchTimeout = 15 * time.Second
	catalogMaxBytes     = 64 << 20
)

// CatalogModel is one model as Questmaster needs it: the id a harness is
// launched with, a label, and just enough metadata to order and annotate the
// list.
type CatalogModel struct {
	ID          string   `json:"id"`
	Name        string   `json:"name,omitempty"`
	Family      string   `json:"family,omitempty"`
	ReleaseDate string   `json:"release_date,omitempty"`
	Reasoning   bool     `json:"reasoning,omitempty"`
	Efforts     []string `json:"efforts,omitempty"`
}

// Catalog is the distilled model catalog, indexed by provider id.
type Catalog struct {
	FetchedAt time.Time                 `json:"fetched_at"`
	Providers map[string][]CatalogModel `json:"providers"`
}

// Empty reports whether the catalog carries no models at all.
func (c Catalog) Empty() bool {
	return len(c.Providers) == 0
}

// Models returns one provider's models, newest first.
func (c Catalog) Models(provider string) []CatalogModel {
	return c.Providers[strings.TrimSpace(provider)]
}

func (c Catalog) fresh(now time.Time) bool {
	if c.Empty() || c.FetchedAt.IsZero() {
		return false
	}
	return now.Sub(c.FetchedAt) < catalogTTL
}

// Fetcher retrieves the raw catalog document. It is injected so tests never
// touch the network.
type Fetcher func(ctx context.Context, endpoint string) ([]byte, error)

// CatalogOptions configures a catalog load.
type CatalogOptions struct {
	// Root is the state root that holds the cache. An empty root disables
	// caching: the catalog is never read from or written to disk, so a call
	// waits on a fetch as it would for a cold cache.
	Root string
	// Fetch retrieves the raw document. Nil uses HTTPFetcher.
	Fetch Fetcher
	// Now is the reference time for cache freshness. Zero means time.Now().
	Now time.Time
	// Refresh forces a fetch even when the cache is still fresh.
	Refresh bool
}

// LoadCatalog resolves the model catalog without holding a request on the
// network. A fresh cache is returned as is. A stale cache is returned at once
// while one background refresh runs. With no cache, the call waits up to
// catalogColdWait and then answers empty, and the fetch it started fills the
// cache for the next request. Refresh waits for the fetch. Callers degrade to
// harness enumeration, recent launches, and the built-in role defaults, and a
// model the user types is never gated on the catalog.
func LoadCatalog(ctx context.Context, opts CatalogOptions) (Catalog, error) {
	now := opts.Now
	if now.IsZero() {
		now = time.Now()
	}
	// A missing or corrupt cache is just an empty one: the fetch below is the
	// real source, and the cache exists to spare it.
	cached, _ := readCatalogCache(opts.Root)
	if !opts.Refresh && cached.fresh(now) {
		return cached, nil
	}

	endpoint, err := catalogURL()
	if err != nil {
		return cached, err
	}
	if endpoint == "" {
		if cached.Empty() {
			return cached, fmt.Errorf("model catalog fetch disabled by %s and no cache present", CatalogURLEnv)
		}
		return cached, nil
	}

	fetch := opts.Fetch
	if fetch == nil {
		fetch = HTTPFetcher
	}
	flight := startCatalogFlight(opts.Root, endpoint, fetch, now)
	switch {
	case opts.Refresh:
		return awaitCatalog(ctx, flight, catalogFetchTimeout, cached)
	case cached.Empty():
		return awaitCatalog(ctx, flight, catalogColdWait, cached)
	default:
		// Stale but usable: answer now, and the flight refreshes the cache for
		// the next request.
		return cached, nil
	}
}

// catalogFlight is one catalog fetch. Once done closes, catalog or err holds
// its result.
type catalogFlight struct {
	done    chan struct{}
	catalog Catalog
	err     error
}

// catalogFlights holds the fetch in progress for each cache root, so requests
// that arrive during a refresh share it instead of starting another.
var (
	catalogFlightsMu     sync.Mutex
	catalogFlightsByRoot = map[string]*catalogFlight{}
)

// startCatalogFlight returns the fetch already running for root, or starts one.
// The fetch runs on its own goroutine and does not inherit the request's
// context: a request that gives up must not cancel a refresh other requests
// are waiting on. Its own timeout bounds its life, so it never outlives
// catalogFetchTimeout.
func startCatalogFlight(root, endpoint string, fetch Fetcher, now time.Time) *catalogFlight {
	catalogFlightsMu.Lock()
	defer catalogFlightsMu.Unlock()
	if flight, running := catalogFlightsByRoot[root]; running {
		return flight
	}
	flight := &catalogFlight{done: make(chan struct{})}
	catalogFlightsByRoot[root] = flight
	go flight.run(root, endpoint, fetch, now)
	return flight
}

func (f *catalogFlight) run(root, endpoint string, fetch Fetcher, now time.Time) {
	ctx, cancel := context.WithTimeout(context.Background(), catalogFetchTimeout)
	defer cancel()
	f.catalog, f.err = fetchCatalog(ctx, fetch, endpoint, root, now)

	catalogFlightsMu.Lock()
	delete(catalogFlightsByRoot, root)
	catalogFlightsMu.Unlock()
	close(f.done)
}

// awaitCatalog waits up to limit for flight, or until ctx ends. When it stops
// waiting first it returns fallback. The flight keeps running and fills the
// cache either way.
func awaitCatalog(ctx context.Context, flight *catalogFlight, limit time.Duration, fallback Catalog) (Catalog, error) {
	timer := time.NewTimer(limit)
	defer timer.Stop()
	select {
	case <-flight.done:
		if flight.err != nil {
			return fallback, flight.err
		}
		return flight.catalog, nil
	case <-timer.C:
		return fallback, fmt.Errorf("model catalog still loading after %s; the next request will have it", limit)
	case <-ctx.Done():
		return fallback, ctx.Err()
	}
}

// fetchCatalog fetches, distills and caches one catalog. A cache we cannot
// write is not a reason to drop a catalog we just fetched successfully.
func fetchCatalog(ctx context.Context, fetch Fetcher, endpoint, root string, now time.Time) (Catalog, error) {
	raw, err := fetch(ctx, endpoint)
	if err != nil {
		return Catalog{}, fmt.Errorf("fetch model catalog: %w", err)
	}
	fresh, err := distillCatalog(raw, now)
	if err != nil {
		return Catalog{}, err
	}
	if fresh.Empty() {
		return Catalog{}, fmt.Errorf("model catalog from %s carried no usable models", endpoint)
	}
	_ = writeCatalogCache(root, fresh)
	return fresh, nil
}

// HTTPFetcher is the default catalog fetcher. It refuses any endpoint that is
// not https, and ctx bounds the request.
func HTTPFetcher(ctx context.Context, endpoint string) ([]byte, error) {
	if err := requireHTTPS(endpoint); err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close() //nolint:errcheck
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s returned HTTP %d", endpoint, resp.StatusCode)
	}
	return io.ReadAll(io.LimitReader(resp.Body, catalogMaxBytes))
}

// catalogURL returns the endpoint to fetch, or "" when fetching is off. An
// override that is not https is an error, so nothing is fetched from it.
func catalogURL() (string, error) {
	value, ok := os.LookupEnv(CatalogURLEnv)
	if !ok {
		return CatalogURL, nil
	}
	value = strings.TrimSpace(value)
	if value == "" || strings.EqualFold(value, "off") {
		return "", nil
	}
	if err := requireHTTPS(value); err != nil {
		return "", fmt.Errorf("%s: %w", CatalogURLEnv, err)
	}
	return value, nil
}

// requireHTTPS rejects a catalog endpoint that would not be fetched over TLS.
func requireHTTPS(endpoint string) error {
	parsed, err := url.Parse(endpoint)
	if err != nil {
		return fmt.Errorf("parse model catalog URL: %w", err)
	}
	if parsed.Scheme != "https" || parsed.Host == "" {
		return fmt.Errorf("model catalog URL must be https://, got %q", endpoint)
	}
	return nil
}

// upstreamProvider mirrors just the parts of the models.dev document
// Questmaster reads. Unknown fields (and whole unknown providers) are ignored,
// so an upstream addition never breaks the parse.
type upstreamProvider struct {
	Models map[string]upstreamModel `json:"models"`
}

type upstreamModel struct {
	ID               string `json:"id"`
	Name             string `json:"name"`
	Family           string `json:"family"`
	ReleaseDate      string `json:"release_date"`
	ToolCall         bool   `json:"tool_call"`
	Reasoning        bool   `json:"reasoning"`
	ReasoningOptions []struct {
		Type   string   `json:"type"`
		Values []string `json:"values"`
	} `json:"reasoning_options"`
	Modalities struct {
		Output []string `json:"output"`
	} `json:"modalities"`
}

// distillCatalog keeps the models a coding harness can actually be driven
// with — text out, tool calls in — and drops everything else (image and
// embedding models) along with every field Questmaster does not render.
func distillCatalog(raw []byte, fetchedAt time.Time) (Catalog, error) {
	var upstream map[string]upstreamProvider
	if err := json.Unmarshal(raw, &upstream); err != nil {
		return Catalog{}, fmt.Errorf("parse model catalog: %w", err)
	}

	providers := make(map[string][]CatalogModel, len(upstream))
	for providerID, provider := range upstream {
		models := make([]CatalogModel, 0, len(provider.Models))
		for modelID, model := range provider.Models {
			if !model.ToolCall || !outputsText(model.Modalities.Output) {
				continue
			}
			id := strings.TrimSpace(model.ID)
			if id == "" {
				id = strings.TrimSpace(modelID)
			}
			if id == "" {
				continue
			}
			models = append(models, CatalogModel{
				ID:          id,
				Name:        strings.TrimSpace(model.Name),
				Family:      strings.TrimSpace(model.Family),
				ReleaseDate: strings.TrimSpace(model.ReleaseDate),
				Reasoning:   model.Reasoning,
				Efforts:     effortValues(model),
			})
		}
		if len(models) == 0 {
			continue
		}
		sortCatalogModels(models)
		providers[providerID] = models
	}
	if len(providers) == 0 {
		return Catalog{}, nil
	}
	return Catalog{FetchedAt: fetchedAt, Providers: providers}, nil
}

func outputsText(output []string) bool {
	for _, value := range output {
		if strings.EqualFold(strings.TrimSpace(value), "text") {
			return true
		}
	}
	return false
}

func effortValues(model upstreamModel) []string {
	for _, option := range model.ReasoningOptions {
		if !strings.EqualFold(option.Type, "effort") {
			continue
		}
		values := make([]string, 0, len(option.Values))
		for _, value := range option.Values {
			if value = strings.TrimSpace(value); value != "" {
				values = append(values, value)
			}
		}
		if len(values) > 0 {
			return values
		}
	}
	return nil
}

// sortCatalogModels orders a provider's models newest first, with a stable
// alphabetical tiebreak so undated models keep a deterministic order.
func sortCatalogModels(models []CatalogModel) {
	sort.SliceStable(models, func(i, j int) bool {
		if models[i].ReleaseDate != models[j].ReleaseDate {
			return models[i].ReleaseDate > models[j].ReleaseDate
		}
		return models[i].ID < models[j].ID
	})
}

func catalogCachePath(root string) string {
	root = strings.TrimSpace(root)
	if root == "" {
		return ""
	}
	return filepath.Join(root, CatalogFileName)
}

func readCatalogCache(root string) (Catalog, error) {
	path := catalogCachePath(root)
	if path == "" {
		return Catalog{}, nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return Catalog{}, nil
		}
		return Catalog{}, fmt.Errorf("read model catalog cache: %w", err)
	}
	var catalog Catalog
	if err := json.Unmarshal(data, &catalog); err != nil {
		return Catalog{}, fmt.Errorf("parse model catalog cache: %w", err)
	}
	return catalog, nil
}

func writeCatalogCache(root string, catalog Catalog) error {
	path := catalogCachePath(root)
	if path == "" {
		return nil
	}
	if err := state.EnsurePrivateStateRoot(filepath.Dir(path)); err != nil {
		return fmt.Errorf("create state root: %w", err)
	}
	data, err := json.Marshal(catalog)
	if err != nil {
		return fmt.Errorf("marshal model catalog cache: %w", err)
	}
	data = append(data, '\n')

	// A uniquely-named temp file (rather than a fixed "path+.tmp") keeps two
	// concurrent writers — e.g. the daemon and a `questmaster models` CLI call
	// racing a cache refresh — from interleaving writes to the same file
	// before either renames; os.Rename itself is atomic, but two writers
	// sharing one temp path could otherwise corrupt each other's content
	// first.
	tmp, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".*.tmp")
	if err != nil {
		return fmt.Errorf("create temp model catalog cache: %w", err)
	}
	tmpPath := tmp.Name()
	// os.CreateTemp defaults to 0600; match the 0644 the rest of this
	// package's cache files use.
	if err := tmp.Chmod(0o644); err != nil {
		tmp.Close()        //nolint:errcheck
		os.Remove(tmpPath) //nolint:errcheck
		return fmt.Errorf("chmod temp model catalog cache: %w", err)
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()        //nolint:errcheck
		os.Remove(tmpPath) //nolint:errcheck
		return fmt.Errorf("write temp model catalog cache: %w", err)
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpPath) //nolint:errcheck
		return fmt.Errorf("close temp model catalog cache: %w", err)
	}
	if err := os.Rename(tmpPath, path); err != nil {
		os.Remove(tmpPath) //nolint:errcheck
		return fmt.Errorf("rename model catalog cache: %w", err)
	}
	return nil
}
