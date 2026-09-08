package modelsuggest

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
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

	catalogTTL          = 24 * time.Hour
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
type Fetcher func(ctx context.Context, url string) ([]byte, error)

// CatalogOptions configures a catalog load.
type CatalogOptions struct {
	// Root is the state root that holds the cache. An empty root disables
	// caching (the catalog is fetched and used in memory).
	Root string
	// Fetch retrieves the raw document. Nil uses HTTPFetcher.
	Fetch Fetcher
	// Now is the reference time for cache freshness. Zero means time.Now().
	Now time.Time
	// Refresh forces a fetch even when the cache is still fresh.
	Refresh bool
}

// LoadCatalog resolves the model catalog, preferring the freshest source that
// works: a fresh cache, then a fetch, then a stale cache. It returns an empty
// catalog rather than failing hard — callers degrade to harness enumeration,
// recent launches, and the built-in role defaults, and a model the user types
// is never gated on the catalog.
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

	url := catalogURL()
	if url == "" {
		if cached.Empty() {
			return cached, fmt.Errorf("model catalog fetch disabled by %s and no cache present", CatalogURLEnv)
		}
		return cached, nil
	}

	fetch := opts.Fetch
	if fetch == nil {
		fetch = HTTPFetcher
	}
	raw, err := fetch(ctx, url)
	if err != nil {
		return cached, fmt.Errorf("fetch model catalog: %w", err)
	}
	fresh, err := distillCatalog(raw, now)
	if err != nil {
		return cached, err
	}
	if fresh.Empty() {
		return cached, fmt.Errorf("model catalog from %s carried no usable models", url)
	}
	// Caching is best effort: a cache we cannot write is not a reason to drop
	// a catalog we just fetched successfully.
	_ = writeCatalogCache(opts.Root, fresh)
	return fresh, nil
}

// HTTPFetcher is the default catalog fetcher.
func HTTPFetcher(ctx context.Context, url string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, catalogFetchTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close() //nolint:errcheck
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s returned HTTP %d", url, resp.StatusCode)
	}
	return io.ReadAll(io.LimitReader(resp.Body, catalogMaxBytes))
}

func catalogURL() string {
	value, ok := os.LookupEnv(CatalogURLEnv)
	if !ok {
		return CatalogURL
	}
	value = strings.TrimSpace(value)
	if value == "" || strings.EqualFold(value, "off") {
		return ""
	}
	return value
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
	// concurrent writers — e.g. `qm serve` and a `questmaster models` CLI call
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
