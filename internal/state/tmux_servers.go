//go:build linux || darwin

package state

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

const tmuxServersFile = "tmux-servers.json"

// ReadTmuxServerLabels returns labels this state root has created sessions on.
// Routers load it once at construction, so inventory does not reread the file.
func ReadTmuxServerLabels(root string) ([]string, error) {
	data, err := os.ReadFile(filepath.Join(root, tmuxServersFile))
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read tmux server labels: %w", err)
	}
	var labels []string
	if err := json.Unmarshal(data, &labels); err != nil {
		return nil, fmt.Errorf("parse tmux server labels: %w", err)
	}
	if labels == nil {
		return nil, fmt.Errorf("parse tmux server labels: expected an array")
	}
	return labels, nil
}

// RecordTmuxServerLabel persists a named creation label before new-session.
// The file only grows; an unreadable record prevents new creation.
func RecordTmuxServerLabel(root, label string) error {
	if label == "" || label == "default" {
		return fmt.Errorf("invalid named tmux server label %q", label)
	}
	if err := EnsurePrivateStateRoot(root); err != nil {
		return err
	}
	lock, err := os.OpenFile(filepath.Join(root, tmuxServersFile+".lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return fmt.Errorf("open tmux server labels lock: %w", err)
	}
	defer lock.Close()
	if err := acquireFlock(lock); err != nil {
		return fmt.Errorf("lock tmux server labels: %w", err)
	}
	defer releaseFlock(lock)

	labels, err := ReadTmuxServerLabels(root)
	if err != nil {
		return err
	}
	for _, existing := range labels {
		if existing == label {
			return nil
		}
	}
	labels = append(labels, label)
	data, err := json.Marshal(labels)
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(root, ".tmux-servers-*")
	if err != nil {
		return fmt.Errorf("create tmux server labels temp file: %w", err)
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(append(data, '\n')); err != nil {
		tmp.Close()
		return fmt.Errorf("write tmux server labels: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return fmt.Errorf("sync tmux server labels: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmp.Name(), filepath.Join(root, tmuxServersFile)); err != nil {
		return fmt.Errorf("replace tmux server labels: %w", err)
	}
	return nil
}
