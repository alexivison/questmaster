package modelsuggest

import (
	"context"
	"errors"
	"reflect"
	"testing"
	"time"

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
			name:   "claude list removed fails closed",
			source: agent.EffortSourceClaudeHelp,
			data:   "  --effort <level>  Set effort based on the selected model\n  --verbose  Enable verbose output (always, never)\n",
		},
		{
			name:   "claude model-specific default fails closed",
			source: agent.EffortSourceClaudeHelp,
			data:   "  --effort <level>  Set effort (default: model-specific)\n",
		},
		{
			name:   "pi model-specific default fails closed",
			source: agent.EffortSourcePiHelp,
			data:   "  --thinking <level>  Set thinking level: (default: model-specific)\n",
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

func TestEffortResolverCachesSuccessesAndFailuresForFiveMinutes(t *testing.T) {
	t.Parallel()

	now := time.Now()
	data := []byte("  --effort <level> (low, high)")
	calls := 0
	resolver := NewEffortResolver(func(context.Context, agent.EffortSource, string) ([]byte, error) {
		calls++
		return data, nil
	})
	resolver.now = func() time.Time { return now }
	if got := resolver.Resolve(context.Background(), "claude", ""); !reflect.DeepEqual(got, []string{"low", "high"}) {
		t.Fatalf("Resolve() = %v, want [low high]", got)
	}
	data = []byte("  --effort <level> (high)")
	if got := resolver.Resolve(context.Background(), "claude", ""); !reflect.DeepEqual(got, []string{"low", "high"}) {
		t.Fatalf("cached Resolve() = %v, want [low high]", got)
	}
	if calls != 1 {
		t.Fatalf("cached probe calls = %d, want 1", calls)
	}
	now = now.Add(effortProbeTTL + time.Nanosecond)
	if got := resolver.Resolve(context.Background(), "claude", ""); !reflect.DeepEqual(got, []string{"high"}) {
		t.Fatalf("expired Resolve() = %v, want [high]", got)
	}
	if calls != 2 {
		t.Fatalf("expired probe calls = %d, want 2", calls)
	}

	failures := 0
	failing := NewEffortResolver(func(context.Context, agent.EffortSource, string) ([]byte, error) {
		failures++
		if failures == 1 {
			return nil, errors.New("offline")
		}
		return []byte("  --effort <level> (low, high)"), nil
	})
	failing.now = func() time.Time { return now }
	for range 2 {
		if got := failing.Resolve(context.Background(), "claude", ""); got != nil {
			t.Fatalf("failed probe Resolve() = %v, want nil", got)
		}
	}
	if failures != 1 {
		t.Fatalf("cached failure probes = %d, want 1", failures)
	}
	now = now.Add(effortProbeTTL + time.Nanosecond)
	if got := failing.Resolve(context.Background(), "claude", ""); !reflect.DeepEqual(got, []string{"low", "high"}) {
		t.Fatalf("expired failure Resolve() = %v, want [low high]", got)
	}
	if failures != 2 {
		t.Fatalf("expired failure probes = %d, want 2", failures)
	}
}

func TestEffortResolverRereadsCodexCache(t *testing.T) {
	t.Parallel()

	fixtures := [][]byte{
		[]byte(`{"models":[{"slug":"gpt-6-luna","supported_reasoning_levels":[{"effort":"low"}]}]}`),
		[]byte(`{"models":[{"slug":"gpt-6-luna","supported_reasoning_levels":[{"effort":"max"}]}]}`),
	}
	calls := 0
	resolver := NewEffortResolver(func(context.Context, agent.EffortSource, string) ([]byte, error) {
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

func TestEffortResolverUsesConfiguredBinary(t *testing.T) {
	t.Parallel()

	var gotBinary string
	resolver := NewEffortResolver(func(_ context.Context, source agent.EffortSource, binary string) ([]byte, error) {
		if source != agent.EffortSourceClaudeHelp {
			t.Fatalf("probe source = %q, want Claude help", source)
		}
		gotBinary = binary
		return []byte("  --effort <level> (low, high)"), nil
	})
	if got := resolver.Resolve(context.Background(), "claude", "sonnet", "/custom/bin/claude"); !reflect.DeepEqual(got, []string{"low", "high"}) {
		t.Fatalf("Resolve() = %v, want [low high]", got)
	}
	if gotBinary != "/custom/bin/claude" {
		t.Fatalf("probed binary = %q, want configured path", gotBinary)
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
			resolver := NewEffortResolver(func(_ context.Context, source agent.EffortSource, _ string) ([]byte, error) {
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
	resolver := NewEffortResolver(func(_ context.Context, source agent.EffortSource, _ string) ([]byte, error) {
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
