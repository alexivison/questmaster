package state

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func TestTmuxServerLabelsSurviveConcurrentCreation(t *testing.T) {
	root := t.TempDir()
	labels := []string{"dev_a", "dev_b", "dev_c"}
	var wg sync.WaitGroup
	for _, label := range labels {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := RecordTmuxServerLabel(root, label); err != nil {
				t.Errorf("record %s: %v", label, err)
			}
		}()
	}
	wg.Wait()
	if err := RecordTmuxServerLabel(root, labels[0]); err != nil {
		t.Fatal(err)
	}
	got, err := ReadTmuxServerLabels(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != len(labels) {
		t.Fatalf("labels = %v, want %v", got, labels)
	}
	for _, label := range labels {
		found := false
		for _, recorded := range got {
			found = found || recorded == label
		}
		if !found {
			t.Fatalf("missing %s from %v", label, got)
		}
	}
	info, err := os.Stat(filepath.Join(root, tmuxServersFile))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("registry permissions = %o, want 600", info.Mode().Perm())
	}
}

func TestTmuxServerLabelsDoNotOverwriteUnreadableRecord(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, tmuxServersFile)
	if err := os.WriteFile(path, []byte("{"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := RecordTmuxServerLabel(root, "dev_new"); err == nil || !strings.Contains(err.Error(), "repair or remove "+path) {
		t.Fatalf("recording over corrupt labels error = %v", err)
	}
	data, err := os.ReadFile(path)
	if err != nil || string(data) != "{" {
		t.Fatalf("corrupt labels changed: %q, %v", data, err)
	}
}
