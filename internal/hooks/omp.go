package hooks

import (
	_ "embed"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

// ompSidecarSource is the embedded oh-my-pi activity-sidecar extension. The
// installer writes this verbatim into omp's extensions directory.
//
//go:embed assets/omp-activity-sidecar.ts
var ompSidecarSource string

// ompSidecarFileName is the on-disk name of the installed sidecar extension.
const ompSidecarFileName = "questmaster-omp-sidecar.ts"

// OmpInstaller manages the oh-my-pi activity-sidecar extension.
//
// Unlike the Pi installer — which only tracks a marker for a sidecar published
// out-of-band — questmaster ships the omp sidecar itself and writes it directly
// into omp's auto-discovered extensions directory (~/.omp/agent/extensions).
// Status is therefore content-based: Current iff the on-disk file matches the
// shipped extension byte-for-byte.
type OmpInstaller struct {
	// AgentDir is the resolved omp agent directory ($PI_CODING_AGENT_DIR or
	// ~/.omp/agent). Override only in tests.
	AgentDir string
}

// NewOmpInstaller resolves the omp agent directory. Pass an explicit dir for
// tests; pass "" to honour $PI_CODING_AGENT_DIR / $HOME.
func NewOmpInstaller(agentDir string) *OmpInstaller {
	if agentDir == "" {
		agentDir = os.Getenv("PI_CODING_AGENT_DIR")
	}
	if agentDir == "" {
		if h := os.Getenv("HOME"); h != "" {
			agentDir = filepath.Join(h, ".omp", "agent")
		}
	}
	return &OmpInstaller{AgentDir: agentDir}
}

// Name implements Installer.
func (o *OmpInstaller) Name() string { return "omp" }

func (o *OmpInstaller) sidecarPath() string {
	return filepath.Join(o.AgentDir, "extensions", ompSidecarFileName)
}

// Install implements Installer.
func (o *OmpInstaller) Install() error { return o.InstallWithOptions(InstallOptions{}) }

// InstallWithOptions writes the sidecar extension, optionally as a dry run.
// Idempotent: re-running writes a byte-identical file.
func (o *OmpInstaller) InstallWithOptions(opts InstallOptions) error {
	opts = opts.normalized()
	if o.AgentDir == "" {
		return errors.New("omp agent dir not resolved (set $PI_CODING_AGENT_DIR or $HOME)")
	}
	body := []byte(ompSidecarSource)
	if opts.DryRun {
		if existing, err := os.ReadFile(o.sidecarPath()); err == nil && string(existing) == string(body) {
			return nil
		}
		logf(opts, "questmaster: dry-run: would write omp sidecar %s", o.sidecarPath())
		return nil
	}
	if existing, err := os.ReadFile(o.sidecarPath()); err == nil && string(existing) == string(body) {
		return nil
	}
	return atomicWrite(o.sidecarPath(), body)
}

// Uninstall implements Installer. Removes the installed sidecar; leaves any
// other user-managed omp extensions alone.
func (o *OmpInstaller) Uninstall() error {
	if o.AgentDir == "" {
		return errors.New("omp agent dir not resolved")
	}
	if err := os.Remove(o.sidecarPath()); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("remove omp sidecar: %w", err)
	}
	return nil
}

// Status implements Installer.
func (o *OmpInstaller) Status() Report {
	if o.AgentDir == "" {
		return Report{Agent: "omp", Status: StatusNotInstalled, Detail: "agent dir not resolved"}
	}
	data, err := os.ReadFile(o.sidecarPath())
	if errors.Is(err, os.ErrNotExist) {
		return Report{Agent: "omp", Status: StatusNotInstalled}
	}
	if err != nil {
		return Report{Agent: "omp", Status: StatusOutdated, Detail: fmt.Sprintf("sidecar unreadable: %v", err)}
	}
	if string(data) == ompSidecarSource {
		return Report{Agent: "omp", Status: StatusCurrent}
	}
	return Report{Agent: "omp", Status: StatusModified, Detail: "sidecar body differs from shipped extension"}
}
