package modelsuggest

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"

	"github.com/alexivison/questmaster/internal/agent"
)

// EffortProbe lets tests supply harness-source fixtures.
type EffortProbe func(context.Context, agent.EffortSource) ([]byte, error)

type EffortResolver struct {
	probe EffortProbe
	mu    sync.Mutex
	cache map[agent.EffortSource]map[string][]string
}

// NewEffortResolver creates a resolver with an optional harness-source probe.
func NewEffortResolver(probe EffortProbe) *EffortResolver {
	if probe == nil {
		probe = probeReasoningEfforts
	}
	return &EffortResolver{
		probe: probe,
		cache: make(map[agent.EffortSource]map[string][]string),
	}
}

func (r *EffortResolver) Resolve(ctx context.Context, agentName, model string) []string {
	source := agent.SpecOf(strings.ToLower(strings.TrimSpace(agentName))).Efforts
	if source == agent.EffortSourceNone {
		return nil
	}
	if source != agent.EffortSourceCodexCache {
		r.mu.Lock()
		defer r.mu.Unlock()
		if cached, ok := r.cache[source]; ok {
			if levels, ok := cached[strings.TrimSpace(model)]; ok {
				return levels
			}
			return cached[""]
		}
	}
	data, err := r.probe(ctx, source)
	if err != nil {
		return nil
	}
	efforts, err := parseEffortSource(source, data)
	if err != nil {
		return nil
	}
	if source != agent.EffortSourceCodexCache && ctx.Err() == nil {
		r.cache[source] = efforts
	}
	if levels, ok := efforts[strings.TrimSpace(model)]; ok {
		return levels
	}
	return efforts[""]
}

var defaultEffortResolver = NewEffortResolver(nil)

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
		}
		return os.ReadFile(filepath.Join(root, "models_cache.json"))
	}
	var name string
	var args []string
	switch source {
	case agent.EffortSourceClaudeHelp:
		name, args = "claude", []string{"--help"}
	case agent.EffortSourcePiHelp:
		name, args = "pi", []string{"--help"}
	case agent.EffortSourceOpenCodeModels:
		name, args = "opencode", []string{"models", "--verbose"}
	}
	if name == "" {
		return nil, fmt.Errorf("unknown reasoning-effort source %q", source)
	}
	binary, ok := probeBinary(name)
	if !ok {
		return nil, fmt.Errorf("%s binary not found", name)
	}
	ctx, cancel := context.WithTimeout(ctx, probeTimeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, binary, args...).CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("run %s %s: %w", binary, strings.Join(args, " "), err)
	}
	return out, nil
}

func parseEffortSource(source agent.EffortSource, data []byte) (map[string][]string, error) {
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
			return nil, err
		}
		models := make(map[string][]string, len(cache.Models))
		for _, entry := range cache.Models {
			if entry.Slug == "" {
				continue
			}
			for _, supported := range entry.Supported {
				if effort := strings.TrimSpace(supported.Effort); effort != "" {
					models[entry.Slug] = append(models[entry.Slug], effort)
				}
			}
		}
		return models, nil
	case agent.EffortSourceClaudeHelp:
		return map[string][]string{"": helpList(data)}, nil
	case agent.EffortSourcePiHelp:
		return map[string][]string{"": piThinkingList(data)}, nil
	case agent.EffortSourceOpenCodeModels:
		return openCodeEffortMap(data), nil
	default:
		return nil, fmt.Errorf("unknown reasoning-effort source %q", source)
	}
}

func helpList(data []byte) []string {
	text := string(data)
	start := strings.Index(text, "--effort")
	if start < 0 {
		return nil
	}
	start += len("--effort")
	openOffset := strings.IndexByte(text[start:], '(')
	if openOffset < 0 {
		return nil
	}
	start += openOffset + 1
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
		lineEnd := bytes.IndexByte(data[offset:], '\n')
		if lineEnd < 0 {
			break
		}
		lineEnd += offset
		model := strings.TrimSpace(string(data[offset:lineEnd]))
		nextLine := lineEnd + 1
		offset = nextLine
		if model == "" || probeModelID(model) != model {
			continue
		}
		decoder := json.NewDecoder(bytes.NewReader(data[nextLine:]))
		var modelInfo struct {
			Variants json.RawMessage `json:"variants"`
		}
		if err := decoder.Decode(&modelInfo); err != nil {
			continue
		}
		if efforts := openCodeVariantNames(modelInfo.Variants); len(efforts) > 0 {
			models[model] = efforts
		}
		if consumed := int(decoder.InputOffset()); consumed > 0 {
			offset = nextLine + consumed
		}
	}
	return models
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
