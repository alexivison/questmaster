package modelsuggest

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/agent"
)

func TestPiEffortProbeSkipsStartupResources(t *testing.T) {
	t.Parallel()

	binary := filepath.Join(t.TempDir(), "pi")
	stub := `#!/bin/sh
extensions=enabled
network=enabled
help=false
for arg do
  case "$arg" in
    --help) help=true ;;
    --no-extensions) extensions=disabled ;;
    --offline) network=disabled ;;
    *) exit 2 ;;
  esac
done
if [ "$help" != true ] || [ "$extensions" != disabled ] || [ "$network" != disabled ]; then
  echo 'probe would run startup resources' >&2
  exit 1
fi
echo '  --thinking <level>  Set thinking level: off, high, max'
`
	if err := os.WriteFile(binary, []byte(stub), 0o755); err != nil {
		t.Fatal(err)
	}
	resolver := NewEffortResolver(nil)
	got := resolver.Resolve(context.Background(), "pi", "", binary)
	if want := []string{"off", "high", "max"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("Resolve() = %v, want %v", got, want)
	}
}

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
			name:   "claude list removed fails open",
			source: agent.EffortSourceClaudeHelp,
			data:   "  --effort <level>  Set effort based on the selected model\n  --verbose  Enable verbose output (always, never)\n",
		},
		{
			name:   "claude model-specific default fails open",
			source: agent.EffortSourceClaudeHelp,
			data:   "  --effort <level>  Set effort (default: model-specific)\n",
		},
		{
			name:   "pi model-specific default fails open",
			source: agent.EffortSourcePiHelp,
			data:   "  --thinking <level>  Set thinking level: (default: model-specific)\n",
		},
		{
			name:   "pi parses thinking help list",
			source: agent.EffortSourcePiHelp,
			data:   "  --thinking <level>  Set thinking level: off, minimal, low, medium, high, xhigh, max\n",
			want:   []string{"off", "minimal", "low", "medium", "high", "xhigh", "max"},
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
	if got := resolver.Resolve(context.Background(), "claude", "", ""); !reflect.DeepEqual(got, []string{"low", "high"}) {
		t.Fatalf("Resolve() = %v, want [low high]", got)
	}
	data = []byte("  --effort <level> (high)")
	if got := resolver.Resolve(context.Background(), "claude", "", ""); !reflect.DeepEqual(got, []string{"low", "high"}) {
		t.Fatalf("cached Resolve() = %v, want [low high]", got)
	}
	if calls != 1 {
		t.Fatalf("cached probe calls = %d, want 1", calls)
	}
	now = now.Add(effortProbeTTL + time.Nanosecond)
	if got := resolver.Resolve(context.Background(), "claude", "", ""); !reflect.DeepEqual(got, []string{"high"}) {
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
		if got := failing.Resolve(context.Background(), "claude", "", ""); got != nil {
			t.Fatalf("failed probe Resolve() = %v, want nil", got)
		}
	}
	if failures != 1 {
		t.Fatalf("cached failure probes = %d, want 1", failures)
	}
	now = now.Add(effortProbeTTL + time.Nanosecond)
	if got := failing.Resolve(context.Background(), "claude", "", ""); !reflect.DeepEqual(got, []string{"low", "high"}) {
		t.Fatalf("expired failure Resolve() = %v, want [low high]", got)
	}
	if failures != 2 {
		t.Fatalf("expired failure probes = %d, want 2", failures)
	}
}

func TestEffortResolverDoesNotCacheCanceledProbe(t *testing.T) {
	t.Parallel()

	calls := 0
	resolver := NewEffortResolver(func(ctx context.Context, _ agent.EffortSource, _ string) ([]byte, error) {
		calls++
		if calls == 1 {
			return nil, ctx.Err()
		}
		return []byte("  --effort <level> (low, high)"), nil
	})
	canceled, cancel := context.WithCancel(context.Background())
	cancel()
	if got := resolver.Resolve(canceled, "claude", "", ""); got != nil {
		t.Fatalf("canceled Resolve() = %v, want nil", got)
	}
	if got := resolver.Resolve(context.Background(), "claude", "", ""); !reflect.DeepEqual(got, []string{"low", "high"}) {
		t.Fatalf("healthy Resolve() = %v, want [low high]", got)
	}
	if calls != 2 {
		t.Fatalf("probes after cancellation = %d, want 2", calls)
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
		got := resolver.Resolve(context.Background(), "codex", "gpt-6-luna", "")
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
			name:      "missing configured model remains unknown",
			agentName: "codex",
			fixtures: map[agent.EffortSource]string{
				agent.EffortSourceCodexConfig: `model_provider = "openai"`,
				agent.EffortSourceCodexCache:  `{"models":[{"slug":"gpt-6-luna","supported_reasoning_levels":[{"effort":"low"}]}]}`,
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
			got := resolver.Resolve(context.Background(), tt.agentName, "", "")
			if !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("Resolve(%q, empty model) = %v, want %v", tt.agentName, got, tt.want)
			}
		})
	}
}
