//go:build darwin

package daemon

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLegacyShimsMigrateAndPruneSafely(t *testing.T) {
	t.Parallel()
	home := t.TempDir()
	support := legacyShimRoot(home)
	live := "0123456789abcdef"
	stale := "fedcba9876543210"
	unknown := "aaaaaaaaaaaaaaaa"
	escape := "bbbbbbbbbbbbbbbb"
	linkedFile := "cccccccccccccccc"
	outside := filepath.Join(t.TempDir(), "outside")
	if err := os.WriteFile(outside, []byte("keep"), 0o600); err != nil {
		t.Fatal(err)
	}
	old := "#!/bin/sh\nexec '/old/qm' \"$@\"\n"
	for _, token := range []string{live, stale, unknown} {
		bin := filepath.Join(support, token, "bin")
		if err := os.MkdirAll(bin, 0o700); err != nil {
			t.Fatal(err)
		}
		for _, name := range []string{"qm", "questmaster"} {
			body := old
			if token == unknown {
				body = "#!/bin/sh\necho user-owned\n"
			}
			if err := os.WriteFile(filepath.Join(bin, name), []byte(body), 0o700); err != nil {
				t.Fatal(err)
			}
		}
	}
	if err := os.Symlink(filepath.Dir(outside), filepath.Join(support, escape)); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(support, live, "bin", ".qm.migration"), []byte("interrupted"), 0o600); err != nil {
		t.Fatal(err)
	}
	linkedBin := filepath.Join(support, linkedFile, "bin")
	if err := os.MkdirAll(linkedBin, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(linkedBin, "qm")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(linkedBin, "questmaster"), []byte(old), 0o700); err != nil {
		t.Fatal(err)
	}
	canonical := "/Applications/Questmaster.app/Contents/Resources/qm"
	for range 2 {
		if err := MigrateLegacyShims(home, canonical); err != nil {
			t.Fatal(err)
		}
	}
	want := "#!/bin/sh\nexec '" + canonical + "' \"$@\"\n"
	for _, token := range []string{live, stale} {
		for _, name := range []string{"qm", "questmaster"} {
			body, err := os.ReadFile(filepath.Join(support, token, "bin", name))
			if err != nil || string(body) != want {
				t.Fatalf("%s/%s: %q %v", token, name, body, err)
			}
		}
	}
	body, err := os.ReadFile(filepath.Join(support, unknown, "bin", "qm"))
	if err != nil || string(body) != "#!/bin/sh\necho user-owned\n" {
		t.Fatalf("unknown changed: %q %v", body, err)
	}
	body, err = os.ReadFile(outside)
	if err != nil || string(body) != "keep" {
		t.Fatalf("symlink escaped: %q %v", body, err)
	}
	agentPath := filepath.Join(support, live, "bin") + ":/usr/bin"
	preview, err := PruneLegacyShims(home, []string{agentPath}, true)
	if err != nil || len(preview) != 1 || preview[0] != filepath.Join(support, stale) {
		t.Fatalf("dry run: %v %v", preview, err)
	}
	if _, err := os.Stat(filepath.Join(support, stale)); err != nil {
		t.Fatal("dry run removed shim")
	}
	removed, err := PruneLegacyShims(home, []string{agentPath}, false)
	if err != nil || len(removed) != 1 {
		t.Fatalf("prune: %v %v", removed, err)
	}
	if _, err := os.Stat(filepath.Join(support, stale)); !os.IsNotExist(err) {
		t.Fatalf("stale shim remains: %v", err)
	}
	for _, token := range []string{live, unknown, escape, linkedFile} {
		if _, err := os.Lstat(filepath.Join(support, token)); err != nil {
			t.Fatalf("%s removed: %v", token, err)
		}
	}
	linkedHome := t.TempDir()
	if err := os.Symlink(filepath.Join(home, "Library"), filepath.Join(linkedHome, "Library")); err != nil {
		t.Fatal(err)
	}
	if err := MigrateLegacyShims(linkedHome, canonical); err == nil {
		t.Fatal("parent symlink was followed")
	}
}
