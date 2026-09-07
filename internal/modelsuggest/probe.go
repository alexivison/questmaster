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
// discards anything else it prints (headers, hints, blank lines). Only the
// first whitespace-separated field is inspected, so an annotated line (a
// trailing "(current)"/"(default)" marker, a description column) still
// yields its id instead of being dropped outright.
func probeModelID(line string) string {
	fields := strings.Fields(line)
	if len(fields) == 0 {
		return ""
	}
	field := fields[0]
	provider, model, ok := strings.Cut(field, "/")
	if !ok || provider == "" || model == "" {
		return ""
	}
	return field
}

// probeBinary resolves a harness binary well enough to ask it a question:
// the explicit env override, then an augmented PATH, then the declared
// fallback path. It intentionally stops short of the full launch-time
// resolution in internal/session (which also spawns an interactive login
// shell to pick up shell-manager shims) — a probe is best-effort, and falling
// back to the catalog is an acceptable degradation when only that heavier
// lookup would have found the binary.
func probeBinary(agentName string) (string, bool) {
	spec := agent.SpecOf(agentName)
	if env := strings.TrimSpace(os.Getenv(spec.BinaryEnvVar)); env != "" {
		return env, true
	}
	if spec.DefaultCLI == "" {
		return "", false
	}
	if path, ok := lookPathAugmented(spec.DefaultCLI); ok {
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

// lookPathAugmented searches PATH the same way a real launch would before
// falling back further: QUESTMASTER_PATH_PREFIX, ~/.local/bin and
// /opt/homebrew/bin ahead of the process's own PATH (see
// internal/session/agent_resolution.go's defaultAgentPath, which this
// mirrors). A GUI-launched questmaster process often has a thinner PATH than
// an interactive shell, which is exactly the case that would otherwise make
// an installed harness look "not found" here even though it launches fine.
func lookPathAugmented(name string) (string, bool) {
	if path, err := exec.LookPath(name); err == nil {
		return path, true
	}
	home, _ := os.UserHomeDir()
	augmented := mergePathLists(
		os.Getenv("QUESTMASTER_PATH_PREFIX"),
		filepath.Join(home, ".local/bin"),
		"/opt/homebrew/bin",
		os.Getenv("PATH"),
	)
	for _, dir := range filepath.SplitList(augmented) {
		if dir == "" {
			continue
		}
		candidate := filepath.Join(dir, name)
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() && info.Mode()&0o111 != 0 {
			return candidate, true
		}
	}
	return "", false
}

// mergePathLists concatenates PATH-style lists, dropping empty entries and
// de-duplicating while preserving first-seen order.
func mergePathLists(paths ...string) string {
	merged := make([]string, 0, 8)
	seen := make(map[string]struct{}, 8)
	for _, path := range paths {
		for _, dir := range filepath.SplitList(path) {
			if dir == "" {
				continue
			}
			if _, ok := seen[dir]; ok {
				continue
			}
			seen[dir] = struct{}{}
			merged = append(merged, dir)
		}
	}
	return strings.Join(merged, string(os.PathListSeparator))
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
