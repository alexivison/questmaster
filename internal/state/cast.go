//go:build linux || darwin

package state

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

const (
	// shortcut: retain the newest 16 calls; raise this if harnesses allow deeper tool concurrency.
	maxRunningTools = 16
	// shortcut: cap 256 pairs and 256-byte labels/IDs; raise the caps if a harness exceeds them.
	maxToolDurationPairs = 256
	maxToolDurationRuns  = 20
)

type RunningTool struct {
	CallID    string    `json:"call_id,omitempty"`
	Tool      string    `json:"tool"`
	StartedAt time.Time `json:"started_at"`
}

type ToolDurationKey struct {
	Agent string
	Tool  string
}

type toolDurationFile struct {
	Samples map[string]map[string][]int64 `json:"samples"`
}

func StartRunningTool(pane *PaneState, tool, callID string, startedAt time.Time) {
	if pane == nil || tool == "" || startedAt.IsZero() {
		return
	}
	if len(callID) > 256 {
		callID = ""
	}
	if callID != "" {
		for i := len(pane.RunningTools) - 1; i >= 0; i-- {
			if pane.RunningTools[i].CallID == callID {
				pane.RunningTools = append(pane.RunningTools[:i], pane.RunningTools[i+1:]...)
			}
		}
	}
	pane.RunningTools = append(pane.RunningTools, RunningTool{CallID: callID, Tool: tool, StartedAt: startedAt.UTC()})
	if len(pane.RunningTools) > maxRunningTools {
		pane.RunningTools = append([]RunningTool(nil), pane.RunningTools[len(pane.RunningTools)-maxRunningTools:]...)
	}
	pane.Tool = tool
}

func EndRunningTool(pane *PaneState, tool, callID string, endedAt time.Time) (RunningTool, time.Duration, bool) {
	if pane == nil {
		return RunningTool{}, 0, false
	}
	if len(callID) > 256 {
		callID = ""
	}
	index := -1
	if callID == "" && tool == "" && len(pane.RunningTools) > 0 {
		index = len(pane.RunningTools) - 1
	}
	if index < 0 {
		for i := len(pane.RunningTools) - 1; i >= 0; i-- {
			running := pane.RunningTools[i]
			if (callID != "" && running.CallID == callID) || (callID == "" && tool != "" && running.Tool == tool) {
				index = i
				break
			}
		}
	}
	if index < 0 {
		setPaneToolFromRunning(pane)
		return RunningTool{}, 0, false
	}
	ended := pane.RunningTools[index]
	pane.RunningTools = append(pane.RunningTools[:index], pane.RunningTools[index+1:]...)
	setPaneToolFromRunning(pane)
	duration := endedAt.Sub(ended.StartedAt)
	return ended, duration, true
}

func setPaneToolFromRunning(pane *PaneState) {
	if len(pane.RunningTools) == 0 {
		pane.Tool = ""
		return
	}
	pane.Tool = pane.RunningTools[len(pane.RunningTools)-1].Tool
}

func ClearRunningTools(pane *PaneState) {
	if pane == nil {
		return
	}
	pane.RunningTools = nil
	pane.Tool = ""
}

func toolDurationsPath(root string) string {
	return filepath.Join(root, "tool-durations.json")
}

func LoadToolTypicalDurationsAt(root string) (map[ToolDurationKey]int64, error) {
	samples, err := loadToolDurationSamplesAt(root)
	if err != nil {
		return nil, err
	}
	typical := make(map[ToolDurationKey]int64, len(samples))
	for key, values := range samples {
		if len(values) < 3 {
			continue
		}
		sorted := append([]int64(nil), values...)
		sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })
		middle := len(sorted) / 2
		median := sorted[middle]
		if len(sorted)%2 == 0 {
			median = sorted[middle-1] + (sorted[middle]-sorted[middle-1])/2
		}
		typical[key] = median
	}
	return typical, nil
}

func RecordToolDurationAt(root, agent, tool string, duration time.Duration) error {
	if root == "" {
		return errors.New("no state root resolved")
	}
	if strings.TrimSpace(agent) == "" || strings.TrimSpace(tool) == "" || len(agent) > 80 || len(tool) > 256 || duration < time.Millisecond {
		return nil
	}
	return withToolDurationLock(root, func() error {
		file, err := readToolDurationFile(root)
		if err != nil {
			return err
		}
		if file.Samples == nil {
			file.Samples = make(map[string]map[string][]int64)
		}
		tools := file.Samples[agent]
		if tools == nil {
			tools = make(map[string][]int64)
			file.Samples[agent] = tools
		}
		samples, exists := tools[tool]
		if !exists && toolDurationPairCount(file.Samples) >= maxToolDurationPairs {
			return nil
		}
		ms := duration.Milliseconds()
		if ms < 1 {
			return nil
		}
		samples = append(samples, ms)
		if len(samples) > maxToolDurationRuns {
			samples = append([]int64(nil), samples[len(samples)-maxToolDurationRuns:]...)
		}
		tools[tool] = samples
		return writeToolDurationFileLocked(root, file)
	})
}

func loadToolDurationSamplesAt(root string) (map[ToolDurationKey][]int64, error) {
	if root == "" {
		return nil, nil
	}
	file, err := readToolDurationFile(root)
	if err != nil {
		return nil, err
	}
	samples := make(map[ToolDurationKey][]int64)
	for agent, tools := range file.Samples {
		for tool, values := range tools {
			samples[ToolDurationKey{Agent: agent, Tool: tool}] = values
		}
	}
	return samples, nil
}

func readToolDurationFile(root string) (toolDurationFile, error) {
	data, err := os.ReadFile(toolDurationsPath(root))
	if errors.Is(err, os.ErrNotExist) {
		return toolDurationFile{}, nil
	}
	if err != nil {
		return toolDurationFile{}, err
	}
	var file toolDurationFile
	if err := json.Unmarshal(data, &file); err != nil {
		return toolDurationFile{}, fmt.Errorf("decode tool durations: %w", err)
	}
	return file, nil
}

func withToolDurationLock(root string, fn func() error) error {
	if err := EnsurePrivateStateRoot(root); err != nil {
		return fmt.Errorf("create state root: %w", err)
	}
	return withFileLock(toolDurationsPath(root)+".lock", fn)
}

func writeToolDurationFileLocked(root string, file toolDurationFile) error {
	data, err := json.Marshal(file)
	if err != nil {
		return fmt.Errorf("marshal tool durations: %w", err)
	}
	data = append(data, '\n')
	path := toolDurationsPath(root)
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return fmt.Errorf("write tool durations temp file: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("rename tool durations: %w", err)
	}
	return nil
}

func toolDurationPairCount(samples map[string]map[string][]int64) int {
	count := 0
	for _, tools := range samples {
		count += len(tools)
	}
	return count
}
