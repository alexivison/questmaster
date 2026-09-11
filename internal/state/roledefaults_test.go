//go:build linux || darwin

package state

import (
	"os"
	"testing"
)

func TestRoleDefaultsStoreRoundTrip(t *testing.T) {
	t.Parallel()

	store := NewRoleDefaultsStore(t.TempDir())

	if err := store.Set("claude", "worker", RoleDefault{Model: "sonnet", ReasoningEffort: "medium"}); err != nil {
		t.Fatalf("set: %v", err)
	}
	def, ok, err := store.Get("claude", "worker")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if !ok {
		t.Fatal("expected default set")
	}
	if def.Model != "sonnet" || def.ReasoningEffort != "medium" {
		t.Fatalf("def = %+v, want sonnet/medium", def)
	}
	if ParseColorStamp(def.UpdatedAt).IsZero() {
		t.Fatalf("UpdatedAt = %q, want a real timestamp", def.UpdatedAt)
	}
}

func TestRoleDefaultsStoreKeysByAgentAndRole(t *testing.T) {
	t.Parallel()

	store := NewRoleDefaultsStore(t.TempDir())
	if err := store.Set("claude", "worker", RoleDefault{Model: "sonnet"}); err != nil {
		t.Fatalf("set worker: %v", err)
	}
	if err := store.Set("claude", "master", RoleDefault{Model: "opus"}); err != nil {
		t.Fatalf("set master: %v", err)
	}

	worker, ok, err := store.Get("claude", "worker")
	if err != nil || !ok || worker.Model != "sonnet" {
		t.Fatalf("worker = %+v ok=%v err=%v, want sonnet", worker, ok, err)
	}
	master, ok, err := store.Get("claude", "master")
	if err != nil || !ok || master.Model != "opus" {
		t.Fatalf("master = %+v ok=%v err=%v, want opus", master, ok, err)
	}
}

func TestRoleDefaultsStorePersistsAcrossInstances(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	if err := NewRoleDefaultsStore(root).Set("codex", "master", RoleDefault{Model: "gpt-5.6", ReasoningEffort: "high"}); err != nil {
		t.Fatalf("set: %v", err)
	}

	// A fresh store (simulating a tracker restart) sees the persisted default.
	def, ok, err := NewRoleDefaultsStore(root).Get("codex", "master")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if !ok || def.Model != "gpt-5.6" || def.ReasoningEffort != "high" {
		t.Fatalf("reloaded def = %+v ok=%v, want gpt-5.6/high", def, ok)
	}
}

func TestRoleDefaultsStoreEmptyDefaultClears(t *testing.T) {
	t.Parallel()

	store := NewRoleDefaultsStore(t.TempDir())
	if err := store.Set("pi", "worker", RoleDefault{Model: "opus"}); err != nil {
		t.Fatalf("set: %v", err)
	}
	if err := store.Set("pi", "worker", RoleDefault{}); err != nil {
		t.Fatalf("clear: %v", err)
	}
	if _, ok, err := store.Get("pi", "worker"); err != nil || ok {
		t.Fatalf("after clear: ok=%v err=%v, want cleared", ok, err)
	}
}

func TestRoleDefaultsStoreEmptyAgentOrRoleIsNoOp(t *testing.T) {
	t.Parallel()

	store := NewRoleDefaultsStore(t.TempDir())
	if err := store.Set("", "worker", RoleDefault{Model: "sonnet"}); err != nil {
		t.Fatalf("set empty agent: %v", err)
	}
	if err := store.Set("claude", "", RoleDefault{Model: "sonnet"}); err != nil {
		t.Fatalf("set empty role: %v", err)
	}
	m, err := store.Load()
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if len(m) != 0 {
		t.Fatalf("store = %v, want empty", m)
	}
}

func TestRoleDefaultsStoreLoadMissingFileIsEmpty(t *testing.T) {
	t.Parallel()

	m, err := NewRoleDefaultsStore(t.TempDir()).Load()
	if err != nil {
		t.Fatalf("load missing: %v", err)
	}
	if len(m) != 0 {
		t.Fatalf("missing-file load = %v, want empty map", m)
	}
}

func TestRoleDefaultsStoreSetResetsCorruptFile(t *testing.T) {
	t.Parallel()

	store := NewRoleDefaultsStore(t.TempDir())
	if err := os.WriteFile(store.path, []byte("{not json"), 0o644); err != nil {
		t.Fatalf("write corrupt role-defaults: %v", err)
	}

	if err := store.Set("opencode", "worker", RoleDefault{Model: "openai/gpt-5.6"}); err != nil {
		t.Fatalf("set after corrupt file: %v", err)
	}

	def, ok, err := store.Get("opencode", "worker")
	if err != nil {
		t.Fatalf("get after reset: %v", err)
	}
	if !ok || def.Model != "openai/gpt-5.6" {
		t.Fatalf("def after reset = %+v ok=%v, want openai/gpt-5.6", def, ok)
	}
}
