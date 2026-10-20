package modelsuggest

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/BurntSushi/toml"
	"github.com/alexivison/questmaster/internal/agent"
)

// EffortProbe lets tests supply harness-source fixtures.
type EffortProbe func(context.Context, agent.EffortSource, string) ([]byte, error)

type effortProbeResult struct {
	data      []byte
	err       error
	expiresAt time.Time
}

type effortProbeKey struct {
	source agent.EffortSource
	binary string
}

const effortProbeTTL = 5 * time.Minute

type EffortResolver struct {
	probe EffortProbe
	mu    sync.Mutex
	cache map[effortProbeKey]effortProbeResult
	now   func() time.Time
}

// NewEffortResolver creates a resolver with an optional harness-source probe.
func NewEffortResolver(probe EffortProbe) *EffortResolver {
	if probe == nil {
		probe = probeReasoningEfforts
	}
	return &EffortResolver{
		probe: probe,
		cache: make(map[effortProbeKey]effortProbeResult),
		now:   time.Now,
	}
}

func (r *EffortResolver) Resolve(ctx context.Context, agentName, model string, binary ...string) []string {
	spec := agent.SpecOf(strings.ToLower(strings.TrimSpace(agentName)))
	source := spec.Efforts
	if source == agent.EffortSourceNone {
		return nil
	}
	preferredBinary := ""
	if len(binary) > 0 {
		preferredBinary = binary[0]
	}
	model = strings.TrimSpace(model)
	if model == "" {
		model = r.defaultModel(ctx, spec.EffortModel, preferredBinary)
	}
	return effortForModel(r.efforts(ctx, source, preferredBinary), model)
}

func (r *EffortResolver) efforts(ctx context.Context, source agent.EffortSource, binary string) map[string][]string {
	data, err := r.sourceData(ctx, source, binary)
	if err != nil {
		return nil
	}
	efforts, err := parseEffortSource(source, data)
	if err != nil {
		return nil
	}
	return efforts
}

func (r *EffortResolver) defaultModel(ctx context.Context, source agent.EffortSource, binary string) string {
	if source == agent.EffortSourceNone {
		return ""
	}
	data, err := r.sourceData(ctx, source, binary)
	if err != nil {
		return ""
	}
	model, err := parseDefaultEffortModel(source, data)
	if err != nil {
		return ""
	}
	return model
}

func (r *EffortResolver) sourceData(ctx context.Context, source agent.EffortSource, binary string) ([]byte, error) {
	if source == agent.EffortSourceCodexCache || source == agent.EffortSourceCodexConfig {
		return r.probe(ctx, source, binary)
	}
	key := effortProbeKey{source: source, binary: binary}
	now := r.now()
	r.mu.Lock()
	cached, ok := r.cache[key]
	r.mu.Unlock()
	if ok && now.Before(cached.expiresAt) {
		return cached.data, cached.err
	}
	data, err := r.probe(ctx, source, binary)
	now = r.now()
	r.mu.Lock()
	for cachedKey, result := range r.cache {
		if !now.Before(result.expiresAt) {
			delete(r.cache, cachedKey)
		}
	}
	r.cache[key] = effortProbeResult{data: data, err: err, expiresAt: now.Add(effortProbeTTL)}
	r.mu.Unlock()
	return data, err
}

func effortForModel(efforts map[string][]string, model string) []string {
	if levels, ok := efforts[model]; ok {
		return levels
	}
	return efforts[""]
}

var defaultEffortResolver = NewEffortResolver(nil)

func ResolveReasoningEfforts(ctx context.Context, agentName, model string, binary ...string) []string {
	return defaultEffortResolver.Resolve(ctx, agentName, model, binary...)
}

func probeReasoningEfforts(ctx context.Context, source agent.EffortSource, configuredBinary string) ([]byte, error) {
	switch source {
	case agent.EffortSourceCodexCache:
		root := codexHome()
		if root == "" {
			return nil, fmt.Errorf("Codex home not found")
		}
		return os.ReadFile(filepath.Join(root, "models_cache.json"))
	case agent.EffortSourceCodexConfig:
		root := codexHome()
		if root == "" {
			return nil, fmt.Errorf("Codex home not found")
		}
		return os.ReadFile(filepath.Join(root, "config.toml"))
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
	case agent.EffortSourceOpenCodeConfig:
		name, args = "opencode", []string{"debug", "config"}
	}
	if name == "" {
		return nil, fmt.Errorf("unknown reasoning-effort source %q", source)
	}
	binary := strings.TrimSpace(configuredBinary)
	if binary == "" {
		var ok bool
		binary, ok = probeBinary(name)
		if !ok {
			return nil, fmt.Errorf("%s binary not found", name)
		}
	}
	ctx, cancel := context.WithTimeout(ctx, probeTimeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, binary, args...).Output()
	if err != nil {
		return nil, fmt.Errorf("run %s %s: %w", binary, strings.Join(args, " "), err)
	}
	return out, nil
}

func codexHome() string {
	if root := strings.TrimSpace(os.Getenv("CODEX_HOME")); root != "" {
		return root
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".codex")
}

func parseDefaultEffortModel(source agent.EffortSource, data []byte) (string, error) {
	switch source {
	case agent.EffortSourceCodexConfig:
		var config struct {
			Model string `toml:"model"`
		}
		if _, err := toml.Decode(string(data), &config); err != nil {
			return "", err
		}
		return strings.TrimSpace(config.Model), nil
	case agent.EffortSourceOpenCodeConfig:
		var config struct {
			Model string `json:"model"`
		}
		if err := json.Unmarshal(data, &config); err != nil {
			return "", err
		}
		return strings.TrimSpace(config.Model), nil
	default:
		return "", fmt.Errorf("unknown default-model source %q", source)
	}
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

var effortTokenPattern = regexp.MustCompile(`^[a-z]+$`)

func helpList(data []byte) []string {
	description := optionDescription(string(data), "--effort")
	openOffset := strings.IndexByte(description, '(')
	if openOffset < 0 {
		return nil
	}
	start := openOffset + 1
	end := strings.IndexByte(description[start:], ')')
	if end < 0 {
		return nil
	}
	return splitEffortValues(description[start : start+end])
}

func piThinkingList(data []byte) []string {
	description := optionDescription(string(data), "--thinking")
	const label = "Set thinking level:"
	labelStart := strings.Index(description, label)
	if labelStart < 0 {
		return nil
	}
	start := labelStart + len(label)
	end := strings.IndexByte(description[start:], '\n')
	if end < 0 {
		end = len(description) - start
	}
	return splitEffortValues(description[start : start+end])
}

func optionDescription(text, flag string) string {
	lines := strings.Split(text, "\n")
	for index, line := range lines {
		line = strings.TrimLeft(line, " \t")
		if !strings.HasPrefix(line, flag) || len(line) > len(flag) && !strings.ContainsRune(" \t<=", rune(line[len(flag)])) {
			continue
		}
		description := []string{line}
		for _, next := range lines[index+1:] {
			next = strings.TrimLeft(next, " \t")
			if strings.HasPrefix(next, "-") {
				break
			}
			description = append(description, next)
		}
		return strings.Join(description, "\n")
	}
	return ""
}

func splitEffortValues(value string) []string {
	parts := strings.Split(value, ",")
	values := make([]string, 0, len(parts))
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if !effortTokenPattern.MatchString(part) {
			return nil
		}
		values = append(values, part)
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
