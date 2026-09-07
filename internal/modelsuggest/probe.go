package modelsuggest

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/alexivison/questmaster/internal/agent"
)

const probeTimeout = 4 * time.Second

// Prober enumerates the model ids a harness itself reports. It is the most
// truthful source available — it reflects the providers the user has actually
// configured — but only some harnesses can do it.
type Prober func(ctx context.Context) ([]string, error)

// HarnessProber returns the prober for an agent, or nil when the harness
// cannot enumerate its own models. Only OpenCode can today, via
// `opencode models`; Claude, Codex and Pi have no listing command, so their
// suggestions come from the catalog.
func HarnessProber(agentName string) Prober {
	if strings.TrimSpace(agentName) != "opencode" {
		return nil
	}
	return func(ctx context.Context) ([]string, error) {
		binary, ok := probeBinary("opencode")
		if !ok {
			return nil, fmt.Errorf("opencode binary not found")
		}
		return runModelProbe(ctx, binary, "models")
	}
}

func runModelProbe(ctx context.Context, binary string, args ...string) ([]string, error) {
	ctx, cancel := context.WithTimeout(ctx, probeTimeout)
	defer cancel()

	out, err := exec.CommandContext(ctx, binary, args...).Output()
	if err != nil {
		return nil, fmt.Errorf("run %s %s: %w", binary, strings.Join(args, " "), err)
	}

	ids := make([]string, 0, 64)
	seen := make(map[string]bool, 64)
	scanner := bufio.NewScanner(strings.NewReader(string(out)))
	for scanner.Scan() {
		id := probeModelID(scanner.Text())
		if id == "" || seen[id] {
			continue
		}
		seen[id] = true
		ids = append(ids, id)
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("read %s output: %w", binary, err)
	}
	return ids, nil
}

// probeModelID keeps the provider-qualified ids out of a harness listing and
// discards anything else it prints (headers, hints, blank lines).
func probeModelID(line string) string {
	field := strings.TrimSpace(line)
	if field == "" || strings.ContainsAny(field, " \t") {
		return ""
	}
	provider, model, ok := strings.Cut(field, "/")
	if !ok || provider == "" || model == "" {
		return ""
	}
	return field
}

// probeBinary resolves a harness binary well enough to ask it a question:
// the explicit env override, then PATH, then the declared fallback path. It is
// deliberately simpler than the launch-time resolution — a probe that cannot
// find the binary just yields no suggestions.
func probeBinary(agentName string) (string, bool) {
	spec := agent.SpecOf(agentName)
	if env := strings.TrimSpace(os.Getenv(spec.BinaryEnvVar)); env != "" {
		return env, true
	}
	if spec.DefaultCLI == "" {
		return "", false
	}
	if path, err := exec.LookPath(spec.DefaultCLI); err == nil {
		return path, true
	}
	fallback := expandHome(spec.FallbackPath)
	if fallback == "" {
		return "", false
	}
	if info, err := os.Stat(fallback); err == nil && !info.IsDir() {
		return fallback, true
	}
	return "", false
}

func expandHome(path string) string {
	path = strings.TrimSpace(path)
	if !strings.HasPrefix(path, "~") {
		return path
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, strings.TrimPrefix(path, "~"))
}
