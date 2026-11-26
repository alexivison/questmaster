package modelsuggest

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/session"
)

const (
	probeTimeout       = 4 * time.Second
	maxModelProbeBytes = 1 << 20
	maxProbedModels    = 4096
)

// Master/worker settings can ask together; bound child processes across callers.
var modelProbeSlots = make(chan struct{}, 2)

// Prober enumerates the model ids a harness itself reports. It is the most
// truthful source available — it reflects the providers the user has actually
// configured — but only some harnesses can do it.
type Prober func(ctx context.Context) ([]string, error)

// HarnessProber returns the prober for an agent, or nil when the harness
// cannot enumerate its own models. Each harness declares the command source
// in its model policy.
func HarnessProber(agentName string) Prober {
	agentName = strings.ToLower(strings.TrimSpace(agentName))
	source := agent.ModelPolicyOf(agentName).Native
	if source == "" {
		return nil
	}
	return func(ctx context.Context) ([]string, error) {
		binary, ok := probeBinary(agentName)
		if !ok {
			return nil, fmt.Errorf("%s binary not found", agentName)
		}
		switch source {
		case agent.ModelListPi:
			// Keep provider extensions: they can supply authorized custom models.
			out, err := modelProbeOutput(ctx, binary, "--list-models", "--offline")
			if err != nil {
				return nil, err
			}
			return parsePiModels(out)
		default:
			return nil, fmt.Errorf("unknown model listing source %q", source)
		}
	}
}

type modelProbeBuffer struct {
	buffer   bytes.Buffer
	overflow bool
}

func (b *modelProbeBuffer) Write(p []byte) (int, error) {
	if b.buffer.Len()+len(p) > maxModelProbeBytes {
		b.overflow = true
		return 0, fmt.Errorf("model listing exceeds 1 MiB")
	}
	return b.buffer.Write(p)
}

func modelProbeOutput(ctx context.Context, binary string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, probeTimeout)
	defer cancel()
	select {
	case modelProbeSlots <- struct{}{}:
		defer func() { <-modelProbeSlots }()
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	cmd := exec.CommandContext(ctx, binary, args...)
	var out modelProbeBuffer
	cmd.Stdout, cmd.Stderr = &out, io.Discard
	cmd.WaitDelay = 100 * time.Millisecond
	err := cmd.Run()
	if out.overflow {
		return nil, fmt.Errorf("model listing exceeds 1 MiB")
	}
	if err != nil {
		return nil, fmt.Errorf("run %s %s: %w", binary, strings.Join(args, " "), err)
	}
	return out.buffer.Bytes(), nil
}

// Pi prints provider and model in separate columns, followed by capabilities.
// Only rows after its table header are model ids; login guidance is not a row.
func parsePiModels(out []byte) ([]string, error) {
	var ids []string
	seen := map[string]bool{}
	table := false
	scanner := bufio.NewScanner(bytes.NewReader(out))
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) >= 2 && fields[0] == "provider" && fields[1] == "model" {
			table = true
			continue
		}
		if !table || len(fields) != 6 || (fields[4] != "yes" && fields[4] != "no") ||
			(fields[5] != "yes" && fields[5] != "no") {
			continue
		}
		id := fields[0] + "/" + fields[1]
		if seen[id] {
			continue
		}
		seen[id] = true
		ids = append(ids, id)
		if len(ids) > maxProbedModels {
			return nil, fmt.Errorf("model listing exceeds %d models", maxProbedModels)
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("read Pi model listing: %w", err)
	}
	return ids, nil
}

// probeBinary resolves a harness binary well enough to ask it a question:
// the explicit env override, then an augmented PATH, then the declared
// fallback path. It intentionally stops short of the full launch-time
// resolution in internal/session (which also spawns an interactive login
// shell to pick up shell-manager shims). A missing binary leaves the
// native inventory empty.
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
	fallback := session.ExpandUserPath(spec.FallbackPath)
	if fallback == "" {
		return "", false
	}
	if info, err := os.Stat(fallback); err == nil && !info.IsDir() {
		return fallback, true
	}
	return "", false
}

// lookPathAugmented searches PATH the same way a real launch would before
// falling back further: internal/session's DefaultAgentPath prepends
// QUESTMASTER_PATH_PREFIX, ~/.local/bin and /opt/homebrew/bin ahead of the
// process's own PATH. A GUI-launched questmaster process often has a thinner
// PATH than an interactive shell, which is exactly the case that would
// otherwise make an installed harness look "not found" here even though it
// launches fine.
func lookPathAugmented(name string) (string, bool) {
	if path, err := exec.LookPath(name); err == nil {
		return path, true
	}
	for _, dir := range filepath.SplitList(session.DefaultAgentPath()) {
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
