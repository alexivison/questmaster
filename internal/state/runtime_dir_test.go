//go:build linux || darwin

package state

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestManifestRuntimeDirRoundTripsAsTypedField(t *testing.T) {
	t.Parallel()
	in := `{"runtime_dir":"/state/runtime/qm-1","session_id":"qm-1"}`
	var m Manifest
	if err := json.Unmarshal([]byte(in), &m); err != nil {
		t.Fatal(err)
	}
	if m.RuntimeDir != "/state/runtime/qm-1" {
		t.Fatalf("RuntimeDir = %q", m.RuntimeDir)
	}
	if _, ok := m.Extra["runtime_dir"]; ok {
		t.Fatal("runtime_dir also kept in Extra")
	}
	m.SetExtra("parent_session", "qm-0")
	out, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	if want := `{"parent_session":"qm-0","runtime_dir":"/state/runtime/qm-1","session_id":"qm-1"}`; string(out) != want {
		t.Fatalf("Marshal = %s, want %s", out, want)
	}
}

func TestRuntimeDirOrLegacy(t *testing.T) {
	t.Parallel()
	tests := map[string]struct {
		m       Manifest
		want    string
		wantErr bool
	}{
		"recorded":           {m: Manifest{SessionID: "qm-1", RuntimeDir: "/state/runtime/qm-1"}, want: "/state/runtime/qm-1"},
		"legacy, no field":   {m: Manifest{SessionID: "qm-1"}, want: "/tmp/qm-1"},
		"relative":           {m: Manifest{SessionID: "qm-1", RuntimeDir: "runtime/qm-1"}, wantErr: true},
		"other session":      {m: Manifest{SessionID: "qm-1", RuntimeDir: "/state/runtime/qm-2"}, wantErr: true},
		"not clean":          {m: Manifest{SessionID: "qm-1", RuntimeDir: "/state/runtime/../qm-1"}, wantErr: true},
		"root":               {m: Manifest{SessionID: "qm-1", RuntimeDir: "/"}, wantErr: true},
		"legacy, invalid id": {m: Manifest{SessionID: "../x"}, wantErr: true},
	}
	for name, tt := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			got, err := tt.m.RuntimeDirOrLegacy()
			if tt.wantErr {
				if err == nil {
					t.Fatalf("RuntimeDirOrLegacy() = %q, want an error", got)
				}
				return
			}
			if err != nil || got != tt.want {
				t.Fatalf("RuntimeDirOrLegacy() = %q, %v; want %q", got, err, tt.want)
			}
		})
	}
}

func TestEnsureRuntimeDirIsOwnerOnly(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	dir := NewRuntimeDir(root, "qm-1")
	if want := filepath.Join(root, "runtime", "qm-1"); dir != want {
		t.Fatalf("NewRuntimeDir = %q, want %q", dir, want)
	}
	if err := EnsureRuntimeDir(dir); err != nil {
		t.Fatalf("EnsureRuntimeDir: %v", err)
	}
	assertMode(t, filepath.Dir(dir), 0o700)
	assertMode(t, dir, 0o700)

	if err := WriteRuntimeFile(dir, "session-name", []byte("qm-1\n")); err != nil {
		t.Fatalf("WriteRuntimeFile: %v", err)
	}
	assertMode(t, filepath.Join(dir, "session-name"), 0o600)

	// A second call keeps the directory and tightens a loosened mode.
	if err := os.Chmod(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := EnsureRuntimeDir(dir); err != nil {
		t.Fatalf("EnsureRuntimeDir again: %v", err)
	}
	assertMode(t, dir, 0o700)
	if _, err := os.Stat(filepath.Join(dir, "session-name")); err != nil {
		t.Fatalf("existing file lost: %v", err)
	}
}

func TestEnsureRuntimeDirRefusesSymlinks(t *testing.T) {
	t.Parallel()
	for _, link := range []string{"dir", "parent"} {
		t.Run(link, func(t *testing.T) {
			t.Parallel()
			root := t.TempDir()
			target := t.TempDir()
			if err := os.Chmod(target, 0o755); err != nil {
				t.Fatal(err)
			}
			dir := NewRuntimeDir(root, "qm-1")
			planted := dir
			if link == "parent" {
				planted = filepath.Dir(dir)
			} else if err := os.Mkdir(filepath.Dir(dir), 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(target, planted); err != nil {
				t.Fatal(err)
			}
			if err := EnsureRuntimeDir(dir); err == nil {
				t.Fatal("EnsureRuntimeDir followed a symlink")
			}
			assertMode(t, target, 0o755)
			entries, err := os.ReadDir(target)
			if err != nil || len(entries) != 0 {
				t.Fatalf("symlink target changed: %v, %v", entries, err)
			}
		})
	}
}

func TestEnsureRuntimeDirRefusesAForeignOwner(t *testing.T) {
	t.Parallel()
	if os.Getuid() == 0 {
		t.Skip("root owns every directory this test could use")
	}
	// /usr exists and belongs to root: the parent check refuses it before
	// anything is created or changed.
	if err := EnsureRuntimeDir("/usr/qm-1"); err == nil || !strings.Contains(err.Error(), "owned by") {
		t.Fatalf("EnsureRuntimeDir under a root-owned parent = %v, want an ownership error", err)
	}
}

func TestWriteRuntimeFileRefusesSymlinks(t *testing.T) {
	t.Parallel()
	dir := NewRuntimeDir(t.TempDir(), "qm-1")
	if err := EnsureRuntimeDir(dir); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(t.TempDir(), "target")
	if err := os.WriteFile(target, []byte("keep\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(dir, "session-name")); err != nil {
		t.Fatal(err)
	}
	if err := WriteRuntimeFile(dir, "session-name", []byte("qm-1\n")); err == nil {
		t.Fatal("WriteRuntimeFile followed a symlink")
	}
	if data, _ := os.ReadFile(target); string(data) != "keep\n" {
		t.Fatalf("symlink target overwritten: %q", data)
	}

	// The directory itself must not be a symlink either.
	linked := filepath.Join(t.TempDir(), "qm-2")
	if err := os.Symlink(dir, linked); err != nil {
		t.Fatal(err)
	}
	if err := WriteRuntimeFile(linked, "other", []byte("x")); err == nil {
		t.Fatal("WriteRuntimeFile wrote through a symlinked directory")
	}
}

// The Pi socket lives in the runtime directory, and a Unix socket path is
// limited to 103 bytes on macOS (sun_path is 104 with its NUL). The default
// root fits with room to spare: a 32-character user name and a collision-retry
// session ID come to 94 bytes. A longer root is refused by name.
func TestPiSocketPathLength(t *testing.T) {
	t.Parallel()
	user := strings.Repeat("u", 32)
	id := NewSessionIDWithSuffix(1793778967, 99999)
	dir := NewRuntimeDir(defaultStateRoot("/Users/"+user), id)
	path, err := PiSocketPath(dir)
	if err != nil {
		t.Fatalf("PiSocketPath(default root, long user) = %v", err)
	}
	if len(path) != 94 || path != dir+"/pi.sock" {
		t.Fatalf("PiSocketPath = %q (%d bytes), want %q (94 bytes)", path, len(path), dir+"/pi.sock")
	}

	// The longest user name the default root still fits: 41 characters.
	fits := NewRuntimeDir(defaultStateRoot("/Users/"+strings.Repeat("u", 41)), id)
	if path, err := PiSocketPath(fits); err != nil || len(path) != 103 {
		t.Fatalf("PiSocketPath at the limit = %q (%d bytes), %v; want 103 bytes", path, len(path), err)
	}
	long := NewRuntimeDir(defaultStateRoot("/Users/"+strings.Repeat("u", 42)), id)
	_, err = PiSocketPath(long)
	if err == nil || !strings.Contains(err.Error(), "104 bytes") || !strings.Contains(err.Error(), StateRootEnv) {
		t.Fatalf("PiSocketPath over the limit = %v, want an error naming the length and %s", err, StateRootEnv)
	}
}

func assertMode(t *testing.T, path string, want os.FileMode) {
	t.Helper()
	info, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != want {
		t.Fatalf("%s mode = %04o, want %04o", path, got, want)
	}
}
