package modelsuggest

import (
	"context"
	"errors"
	"reflect"
	"sync"
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
			name:   "pi parses thinking help list",
			source: agent.EffortSourcePiHelp,
			data:   "  --thinking <level>  Set thinking level: off, minimal, low, medium, high, xhigh, max\n",
			want:   []string{"off", "minimal", "low", "medium", "high", "xhigh", "max"},
		},
		{
			name:   "opencode selects variants for exact model",
			source: agent.EffortSourceOpenCodeModels,
			model:  "openai/gpt-5.6",
			data:   "openai/gpt-5.6\n{\"providerID\":\"openai\",\"modelID\":\"gpt-5.6\",\"variants\":{\"none\":{},\"low\":{},\"medium\":{},\"high\":{},\"xhigh\":{}}}\nanthropic/claude-sonnet-4-5\n{\"providerID\":\"anthropic\",\"modelID\":\"claude-sonnet-4-5\",\"variants\":{\"high\":{},\"max\":{}}}",
			want:   []string{"none", "low", "medium", "high", "xhigh"},
		},
		{
			name:   "opencode unknown model has no levels",
			source: agent.EffortSourceOpenCodeModels,
			model:  "ollama/local-model",
			data:   `{"providerID":"openai","modelID":"gpt-5.6","variants":{"none":{},"low":{}}}`,
		},
	} {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got, err := parseReasoningEfforts(tt.source, tt.model, []byte(tt.data))
			if err != nil {
				t.Fatalf("parseReasoningEfforts(): %v", err)
			}
			if !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("parseReasoningEfforts() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestEffortCommand(t *testing.T) {
	t.Parallel()

	for _, tt := range []struct {
		source agent.EffortSource
		name   string
		args   []string
	}{
		{source: agent.EffortSourceClaudeHelp, name: "claude", args: []string{"--help"}},
		{source: agent.EffortSourcePiHelp, name: "pi", args: []string{"--help"}},
		{source: agent.EffortSourceOpenCodeModels, name: "opencode", args: []string{"models", "--verbose"}},
	} {
		t.Run(string(tt.source), func(t *testing.T) {
			t.Parallel()
			name, args := effortCommand(tt.source)
			if name != tt.name || !reflect.DeepEqual(args, tt.args) {
				t.Fatalf("effortCommand(%q) = %q, %v, want %q, %v", tt.source, name, args, tt.name, tt.args)
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

func TestEffortResolverProbesDifferentSourcesConcurrently(t *testing.T) {
	t.Parallel()

	started := make(chan agent.EffortSource, 2)
	release := make(chan struct{})
	resolver := NewEffortResolver(func(_ context.Context, source agent.EffortSource) ([]byte, error) {
		started <- source
		<-release
		return nil, nil
	})
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		resolver.Resolve(context.Background(), "claude", "")
	}()
	go func() {
		defer wg.Done()
		resolver.Resolve(context.Background(), "pi", "")
	}()

	for range 2 {
		select {
		case <-started:
		case <-time.After(time.Second):
			close(release)
			wg.Wait()
			t.Fatal("different effort sources were probed serially")
		}
	}
	close(release)
	wg.Wait()
}
