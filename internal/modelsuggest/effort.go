package modelsuggest

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"

	"github.com/alexivison/questmaster/internal/agent"
)

// EffortProbe reads the harness-owned source for effort levels. Tests inject
// fixture bytes here so they never inspect a real home directory or CLI.
type EffortProbe func(context.Context, agent.EffortSource) ([]byte, error)

type EffortResolver struct {
	probe EffortProbe
	mu    sync.Mutex
	locks map[agent.EffortSource]*sync.Mutex
	cache map[agent.EffortSource]effortProbeResult
}

type effortProbeResult struct {
	levels []string
	models map[string][]string
	err    error
}

func (r effortProbeResult) forModel(model string) []string {
	if r.models != nil {
		return r.models[model]
	}
	return r.levels
}

// NewEffortResolver creates a resolver with an optional harness-source probe.
// A nil probe uses the declared source for each built-in harness.
func NewEffortResolver(probe EffortProbe) *EffortResolver {
	if probe == nil {
		probe = probeReasoningEfforts
	}
	return &EffortResolver{
		probe: probe,
		locks: make(map[agent.EffortSource]*sync.Mutex),
		cache: make(map[agent.EffortSource]effortProbeResult),
	}
}

// Resolve returns only levels reported for this agent and model. Missing
// sources, unknown models and probe failures return no data so callers pass
// the requested effort through to the harness.
func (r *EffortResolver) Resolve(ctx context.Context, agentName, model string) []string {
	source := agent.SpecOf(strings.ToLower(strings.TrimSpace(agentName))).Efforts
	if source == agent.EffortSourceNone {
		return nil
	}
	result := r.source(ctx, source)
	if result.err != nil {
		return nil
	}
	return result.forModel(strings.TrimSpace(model))
}

func (r *EffortResolver) source(ctx context.Context, source agent.EffortSource) effortProbeResult {
	if source == agent.EffortSourceCodexCache {
		return r.probeAndParse(ctx, source)
	}
	r.mu.Lock()
	if result, ok := r.cache[source]; ok {
		r.mu.Unlock()
		return result
	}
	lock := r.locks[source]
	if lock == nil {
		lock = &sync.Mutex{}
		r.locks[source] = lock
	}
	r.mu.Unlock()
	lock.Lock()
	defer lock.Unlock()

	r.mu.Lock()
	if result, ok := r.cache[source]; ok {
		r.mu.Unlock()
		return result
	}
	r.mu.Unlock()
	result := r.probeAndParse(ctx, source)
	err := result.err
	if ctx.Err() == nil && err == nil {
		r.mu.Lock()
		r.cache[source] = result
		r.mu.Unlock()
	}
	return result
}

func (r *EffortResolver) probeAndParse(ctx context.Context, source agent.EffortSource) effortProbeResult {
	data, err := r.probe(ctx, source)
	if err != nil {
		return effortProbeResult{err: err}
	}
	result, err := parseEffortSource(source, data)
	result.err = err
	return result
}

var defaultEffortResolver = NewEffortResolver(nil)

// ResolveReasoningEfforts uses the process-wide source cache used by serve
// and session launch commands.
func ResolveReasoningEfforts(ctx context.Context, agentName, model string) []string {
	return defaultEffortResolver.Resolve(ctx, agentName, model)
}

func probeReasoningEfforts(ctx context.Context, source agent.EffortSource) ([]byte, error) {
	switch source {
	case agent.EffortSourceCodexCache:
		root := strings.TrimSpace(os.Getenv("CODEX_HOME"))
		if root == "" {
			home, err := os.UserHomeDir()
			if err != nil {
				return nil, err
			}
			root = filepath.Join(home, ".codex")
		} else if root == "~" || strings.HasPrefix(root, "~/") {
			home, err := os.UserHomeDir()
			if err != nil {
				return nil, err
			}
			root = filepath.Join(home, strings.TrimPrefix(strings.TrimPrefix(root, "~"), string(filepath.Separator)))
		}
		return os.ReadFile(filepath.Join(root, "models_cache.json"))
	case agent.EffortSourceClaudeHelp, agent.EffortSourcePiHelp, agent.EffortSourceOpenCodeModels:
		name, args := effortCommand(source)
		binary, ok := probeBinary(name)
		if !ok {
			return nil, fmt.Errorf("%s binary not found", name)
		}
		return runEffortProbe(ctx, binary, args...)
	default:
		return nil, fmt.Errorf("unknown reasoning-effort source %q", source)
	}
}

func effortCommand(source agent.EffortSource) (string, []string) {
	switch source {
	case agent.EffortSourceClaudeHelp:
		return "claude", []string{"--help"}
	case agent.EffortSourcePiHelp:
		return "pi", []string{"--help"}
	case agent.EffortSourceOpenCodeModels:
		return "opencode", []string{"models", "--verbose"}
	default:
		return "", nil
	}
}

func runEffortProbe(ctx context.Context, binary string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, probeTimeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, binary, args...).CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("run %s %s: %w", binary, strings.Join(args, " "), err)
	}
	return out, nil
}

func parseEffortSource(source agent.EffortSource, data []byte) (effortProbeResult, error) {
	switch source {
	case agent.EffortSourceCodexCache:
		var cache struct {
			Models []struct {
				Slug      string `json:"slug"`
				Supported []struct {
					Effort string `json:"effort"`
				} `json:"supported_reasoning_levels"`
			} `json:"models"`
		}
		if err := json.Unmarshal(data, &cache); err != nil {
			return effortProbeResult{}, err
		}
		models := make(map[string][]string, len(cache.Models))
		for _, entry := range cache.Models {
			if entry.Slug == "" {
				continue
			}
			models[entry.Slug] = nonEmptyEffortValues(len(entry.Supported), func(i int) string { return entry.Supported[i].Effort })
		}
		return effortProbeResult{models: models}, nil
	case agent.EffortSourceClaudeHelp:
		return effortProbeResult{levels: helpList(data, "--effort", "(")}, nil
	case agent.EffortSourcePiHelp:
		return effortProbeResult{levels: piThinkingList(data)}, nil
	case agent.EffortSourceOpenCodeModels:
		return effortProbeResult{models: openCodeEffortMap(data)}, nil
	default:
		return effortProbeResult{}, fmt.Errorf("unknown reasoning-effort source %q", source)
	}
}

func parseReasoningEfforts(source agent.EffortSource, model string, data []byte) ([]string, error) {
	result, err := parseEffortSource(source, data)
	if err != nil {
		return nil, err
	}
	return result.forModel(model), nil
}

func nonEmptyEffortValues(count int, value func(int) string) []string {
	values := make([]string, 0, count)
	for i := 0; i < count; i++ {
		if v := strings.TrimSpace(value(i)); v != "" {
			values = append(values, v)
		}
	}
	return values
}

func helpList(data []byte, flag, opener string) []string {
	text := string(data)
	start := strings.Index(text, flag)
	if start < 0 {
		return nil
	}
	start += len(flag)
	openOffset := strings.Index(text[start:], opener)
	if openOffset < 0 {
		return nil
	}
	start += openOffset + len(opener)
	end := strings.IndexByte(text[start:], ')')
	if end < 0 {
		return nil
	}
	return splitEffortValues(text[start : start+end])
}

func piThinkingList(data []byte) []string {
	text := string(data)
	start := strings.Index(text, "--thinking")
	if start < 0 {
		return nil
	}
	const label = "Set thinking level:"
	labelStart := strings.Index(text[start:], label)
	if labelStart < 0 {
		return nil
	}
	start += labelStart + len(label)
	end := strings.IndexByte(text[start:], '\n')
	if end < 0 {
		end = len(text) - start
	}
	return splitEffortValues(text[start : start+end])
}

func splitEffortValues(value string) []string {
	parts := strings.Split(value, ",")
	values := make([]string, 0, len(parts))
	for _, part := range parts {
		part = strings.TrimSpace(strings.TrimRight(strings.TrimSpace(part), "."))
		if part != "" && part != "..." {
			values = append(values, part)
		}
	}
	return values
}

func openCodeEffortMap(data []byte) map[string][]string {
	models := make(map[string][]string)
	for offset := 0; offset < len(data); {
		start := bytes.IndexAny(data[offset:], "{[")
		if start < 0 {
			return models
		}
		start += offset
		decoder := json.NewDecoder(bytes.NewReader(data[start:]))
		var value json.RawMessage
		if err := decoder.Decode(&value); err != nil {
			offset = start + 1
			continue
		}
		collectOpenCodeEfforts(value, "", models)
		offset = start + int(decoder.InputOffset())
	}
	return models
}

func collectOpenCodeEfforts(raw json.RawMessage, inheritedID string, models map[string][]string) {
	var object map[string]json.RawMessage
	if json.Unmarshal(raw, &object) == nil && object != nil {
		if variants, ok := object["variants"]; ok {
			provider := jsonString(object, "providerID", "provider")
			modelID := jsonString(object, "modelID", "model", "id")
			if modelID == "" {
				modelID = inheritedID
			}
			qualified := modelID
			if !strings.Contains(qualified, "/") && provider != "" {
				qualified = provider + "/" + qualified
			}
			if qualified != "" {
				models[qualified] = openCodeVariantNames(variants)
			}
		}
		keys := make([]string, 0, len(object))
		for key := range object {
			if key != "variants" {
				keys = append(keys, key)
			}
		}
		sort.Strings(keys)
		for _, key := range keys {
			collectOpenCodeEfforts(object[key], key, models)
		}
		return
	}
	var values []json.RawMessage
	if json.Unmarshal(raw, &values) == nil {
		for _, value := range values {
			collectOpenCodeEfforts(value, inheritedID, models)
		}
	}
}

func jsonString(object map[string]json.RawMessage, names ...string) string {
	for _, name := range names {
		var value string
		if json.Unmarshal(object[name], &value) == nil && value != "" {
			return value
		}
	}
	return ""
}

func openCodeVariantNames(raw json.RawMessage) []string {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	if _, err := decoder.Token(); err != nil {
		return nil
	}
	var values []string
	for decoder.More() {
		key, err := decoder.Token()
		if err != nil {
			return nil
		}
		var ignored json.RawMessage
		if err := decoder.Decode(&ignored); err != nil {
			return nil
		}
		if name, ok := key.(string); ok {
			values = append(values, name)
		}
	}
	if len(values) == 0 {
		return nil
	}
	return values
}
