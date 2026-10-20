package modelsuggest

import (
	"context"
	"errors"
	"reflect"
	"testing"

	"github.com/alexivison/questmaster/internal/agent"
)

func TestParseReasoningEfforts(t *testing.T) {
	t.Parallel()

	for _, tt := range []struct {
		name   string
		source agent.EffortSource
		model  string
		data   string
		want   []string
	}{
		{
			name:   "codex selects levels for exact model",
			source: agent.EffortSourceCodexCache,
			model:  "gpt-6-luna",
			data:   `{"models":[{"slug":"gpt-6-luna","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"}]},{"slug":"gpt-6-sol","supported_reasoning_levels":[{"effort":"minimal"}]}]}`,
			want:   []string{"low", "medium", "high", "xhigh", "max"},
		},
		{
			name:   "codex unknown model has no levels",
			source: agent.EffortSourceCodexCache,
			model:  "future-model",
			data:   `{"models":[{"slug":"gpt-6-luna","supported_reasoning_levels":[{"effort":"low"}]}]}`,
		},
		{
			name:   "claude parses wrapped help list",
			source: agent.EffortSourceClaudeHelp,
			data:   "  --effort <level>  Set effort (low, medium,\n                     high, xhigh, max)\n",
			want:   []string{"low", "medium", "high", "xhigh", "max"},
		},
		{
			name:   "pi parses thinking help list",
			source: agent.EffortSourcePiHelp,
			data:   "  --thinking <level>  Set thinking level: off, minimal, low, medium, high, xhigh, max\n",
			want:   []string{"off", "minimal", "low", "medium", "high", "xhigh", "max"},
		},
		{
			name:   "opencode selects variants for exact model",
			source: agent.EffortSourceOpenCodeModels,
			model:  "openai/gpt-5.6",
			data:   "openai/gpt-5.6\n{\n  \"providerID\": \"openai\",\n  \"modelID\": \"gpt-5.6\",\n  \"variants\": {\"none\": {}, \"low\": {}, \"medium\": {}, \"high\": {}, \"xhigh\": {}}\n}\nanthropic/claude-sonnet-4-5\n{\"variants\":{\"high\":{},\"max\":{}}}",
			want:   []string{"none", "low", "medium", "high", "xhigh"},
		},
		{
			name:   "opencode unknown model has no levels",
			source: agent.EffortSourceOpenCodeModels,
			model:  "ollama/local-model",
			data:   "openai/gpt-5.6\n{\"variants\":{\"none\":{},\"low\":{}}}",
		},
		{
			name:   "opencode empty variants has no levels",
			source: agent.EffortSourceOpenCodeModels,
			model:  "openai/gpt-5.6",
			data:   "openai/gpt-5.6\n{\"variants\":{}}",
		},
	} {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			result, err := parseEffortSource(tt.source, []byte(tt.data))
			if err != nil {
				t.Fatalf("parseEffortSource(): %v", err)
			}
			got := result[tt.model]
			if got == nil {
				got = result[""]
			}
			if !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("forModel() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestParseDefaultEffortModel(t *testing.T) {
	t.Parallel()

	for _, tt := range []struct {
		name    string
		source  agent.EffortSource
		data    string
		want    string
		wantErr bool
	}{
		{name: "Codex top-level model", source: agent.EffortSourceCodexConfig, data: "model = \"gpt-6-luna\"\n[features]\nmodel = \"ignored\"\n", want: "gpt-6-luna"},
		{name: "OpenCode model", source: agent.EffortSourceOpenCodeConfig, data: `{"model":"openai/gpt-5.6"}`, want: "openai/gpt-5.6"},
		{name: "missing default", source: agent.EffortSourceOpenCodeConfig, data: `{"plugin":[]}`},
		{name: "invalid config", source: agent.EffortSourceCodexConfig, data: "model = [", wantErr: true},
	} {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got, err := parseDefaultEffortModel(tt.source, []byte(tt.data))
			if (err != nil) != tt.wantErr {
				t.Fatalf("parseDefaultEffortModel() error = %v, wantErr %v", err, tt.wantErr)
			}
			if tt.wantErr {
				return
			}
			if got != tt.want {
				t.Fatalf("parseDefaultEffortModel() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestEffortResolverCachesSuccessfulSourceAndRetriesFailures(t *testing.T) {
	t.Parallel()

	for _, tt := range []struct {
		name      string
		firstErr  error
		first     []string
		resolved  []string
		wantCalls int
	}{
		{name: "reported levels", first: []string{"low", "high"}, resolved: []string{"low", "high"}, wantCalls: 1},
		{name: "temporary probe failure", firstErr: errors.New("offline"), resolved: []string{"low", "high"}, wantCalls: 2},
	} {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			calls := 0
			resolver := NewEffortResolver(func(context.Context, agent.EffortSource) ([]byte, error) {
				calls++
				if calls == 1 && tt.firstErr != nil {
					return nil, tt.firstErr
				}
				return []byte("--effort <level> (low, high)"), nil
			})
			first := resolver.Resolve(context.Background(), "claude", "")
			if !reflect.DeepEqual(first, tt.first) {
				t.Fatalf("first Resolve() = %v, want %v", first, tt.first)
			}
			got := resolver.Resolve(context.Background(), "claude", "")
			if !reflect.DeepEqual(got, tt.resolved) {
				t.Fatalf("Resolve() = %v, want %v", got, tt.resolved)
			}
			resolver.Resolve(context.Background(), "claude", "")
			if calls != tt.wantCalls {
				t.Fatalf("probe calls = %d, want %d", calls, tt.wantCalls)
			}
		})
	}
}

func TestEffortResolverRereadsCodexCache(t *testing.T) {
	t.Parallel()

	fixtures := [][]byte{
		[]byte(`{"models":[{"slug":"gpt-6-luna","supported_reasoning_levels":[{"effort":"low"}]}]}`),
		[]byte(`{"models":[{"slug":"gpt-6-luna","supported_reasoning_levels":[{"effort":"max"}]}]}`),
	}
	calls := 0
	resolver := NewEffortResolver(func(context.Context, agent.EffortSource) ([]byte, error) {
		data := fixtures[calls]
		calls++
		return data, nil
	})
	for _, want := range [][]string{{"low"}, {"max"}} {
		got := resolver.Resolve(context.Background(), "codex", "gpt-6-luna")
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("Resolve() = %v, want %v", got, want)
		}
	}
	if calls != 2 {
		t.Fatalf("Codex cache reads = %d, want one per resolution", calls)
	}
}

func TestEffortResolverUsesConfiguredDefaultModel(t *testing.T) {
	t.Parallel()

	for _, tt := range []struct {
		name      string
		agentName string
		fixtures  map[agent.EffortSource]string
		want      []string
	}{
		{
			name:      "Codex config model",
			agentName: "codex",
			fixtures: map[agent.EffortSource]string{
				agent.EffortSourceCodexConfig: `model = "gpt-6-luna"`,
				agent.EffortSourceCodexCache:  `{"models":[{"slug":"gpt-6-luna","supported_reasoning_levels":[{"effort":"low"},{"effort":"max"}]}]}`,
			},
			want: []string{"low", "max"},
		},
		{
			name:      "OpenCode resolved config model",
			agentName: "opencode",
			fixtures: map[agent.EffortSource]string{
				agent.EffortSourceOpenCodeConfig: `{"model":"openai/gpt-5.6"}`,
				agent.EffortSourceOpenCodeModels: "openai/gpt-5.6\n{\"variants\":{\"none\":{},\"low\":{},\"high\":{}}}",
			},
			want: []string{"none", "low", "high"},
		},
		{
			name:      "missing configured model remains unknown",
			agentName: "opencode",
			fixtures: map[agent.EffortSource]string{
				agent.EffortSourceOpenCodeConfig: `{"plugin":[]}`,
				agent.EffortSourceOpenCodeModels: "openai/gpt-5.6\n{\"variants\":{\"low\":{}}}",
			},
		},
	} {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			resolver := NewEffortResolver(func(_ context.Context, source agent.EffortSource) ([]byte, error) {
				fixture, ok := tt.fixtures[source]
				if !ok {
					return nil, errors.New("missing fixture")
				}
				return []byte(fixture), nil
			})
			got := resolver.Resolve(context.Background(), tt.agentName, "")
			if !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("Resolve(%q, empty model) = %v, want %v", tt.agentName, got, tt.want)
			}
		})
	}
}

func TestOpenCodeDefaultAndEffortProbesAreCached(t *testing.T) {
	t.Parallel()

	calls := make(map[agent.EffortSource]int)
	resolver := NewEffortResolver(func(_ context.Context, source agent.EffortSource) ([]byte, error) {
		calls[source]++
		switch source {
		case agent.EffortSourceOpenCodeConfig:
			return []byte(`{"model":"openai/gpt-5.6"}`), nil
		case agent.EffortSourceOpenCodeModels:
			return []byte("openai/gpt-5.6\n{\"variants\":{\"low\":{}}}"), nil
		default:
			return nil, errors.New("unexpected source")
		}
	})
	for range 2 {
		if got := resolver.Resolve(context.Background(), "opencode", ""); !reflect.DeepEqual(got, []string{"low"}) {
			t.Fatalf("Resolve(opencode, empty model) = %v, want [low]", got)
		}
	}
	for _, source := range []agent.EffortSource{agent.EffortSourceOpenCodeConfig, agent.EffortSourceOpenCodeModels} {
		if calls[source] != 1 {
			t.Errorf("%s probes = %d, want 1", source, calls[source])
		}
	}
}

func TestPiEffortsIntersectMappedProviderCache(t *testing.T) {
	t.Parallel()

	const piHelp = "--thinking <level> Set thinking level: off, minimal, low, medium, high, xhigh, max\n"
	const piLevels = `{"models":[{"slug":"gpt-5.6-luna","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"}]}]}`

	for _, tt := range []struct {
		name     string
		model    string
		cache    string
		cacheErr error
		want     []string
	}{
		{name: "intersects and preserves Pi order", model: "openai-codex/gpt-5.6-luna", cache: piLevels, want: []string{"low", "medium", "high", "xhigh", "max"}},
		{name: "no cache entry preserves Pi list", model: "openai-codex/unknown", cache: piLevels, want: []string{"off", "minimal", "low", "medium", "high", "xhigh", "max"}},
		{name: "cache failure preserves Pi list", model: "openai-codex/gpt-5.6-luna", cacheErr: errors.New("cache unavailable"), want: []string{"off", "minimal", "low", "medium", "high", "xhigh", "max"}},
		{name: "other provider preserves Pi list", model: "anthropic/claude-sonnet-4-5", cache: piLevels, want: []string{"off", "minimal", "low", "medium", "high", "xhigh", "max"}},
	} {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			resolver := NewEffortResolver(func(_ context.Context, source agent.EffortSource) ([]byte, error) {
				switch source {
				case agent.EffortSourcePiHelp:
					return []byte(piHelp), nil
				case agent.EffortSourceCodexCache:
					return []byte(tt.cache), tt.cacheErr
				default:
					return nil, errors.New("unexpected source")
				}
			})
			got := resolver.Resolve(context.Background(), "pi", tt.model)
			if !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("Resolve(pi, %q) = %v, want %v", tt.model, got, tt.want)
			}
		})
	}
}
