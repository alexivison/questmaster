//go:build darwin

package daemon

import (
	"crypto/rand"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

var legacyToken = regexp.MustCompile(`^[0-9a-f]{16}$`)
var legacyDirect = regexp.MustCompile(`^#!/bin/sh\nexec '(?:[^']|'\\'')*' "\$@"\n$`)
var legacyDev = regexp.MustCompile(`^#!/bin/sh\ncd '(?:[^']|'\\'')*' && exec '(?:[^']|'\\'')*' run \. "\$@"\n(?:exec '(?:[^']|'\\'')*' "\$@"\n|echo 'questmaster dev backend worktree is unavailable' >&2\nexit 127\n)$`)

func legacyShim(content string) bool {
	return legacyDirect.MatchString(content) || legacyDev.MatchString(content)
}

func legacyShimRoot(home string) string {
	return filepath.Join(home, "Library", "Application Support", "Questmaster")
}

func openLegacyRoot(home string) (*os.Root, error) {
	root, err := os.OpenRoot(home)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	for _, name := range []string{"Library", "Library/Application Support", "Library/Application Support/Questmaster"} {
		info, err := root.Lstat(name)
		if os.IsNotExist(err) {
			return nil, nil
		}
		if err != nil {
			return nil, err
		}
		if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return nil, fmt.Errorf("unsafe legacy shim directory %s", name)
		}
	}
	return root.OpenRoot("Library/Application Support/Questmaster")
}

func legacyEntries(root *os.Root, name string) ([]os.DirEntry, error) {
	dir, err := root.Open(name)
	if err != nil {
		return nil, err
	}
	defer dir.Close()
	return dir.ReadDir(-1)
}

func legacyDirectory(root *os.Root, token string) (*os.Root, error) {
	for _, name := range []string{token, filepath.Join(token, "bin")} {
		info, err := root.Lstat(name)
		if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return nil, fmt.Errorf("unsafe legacy shim directory %s", name)
		}
	}
	return root.OpenRoot(filepath.Join(token, "bin"))
}

func legacyShims(bin *os.Root) (map[string]string, bool) {
	files := make(map[string]string, 2)
	for _, name := range []string{"qm", "questmaster"} {
		info, err := bin.Lstat(name)
		if err != nil || !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 || info.Size() > 4096 {
			return nil, false
		}
		body, err := bin.ReadFile(name)
		if err != nil || !legacyShim(string(body)) {
			return nil, false
		}
		files[name] = string(body)
	}
	return files, true
}

// MigrateLegacyShims keeps old sessions' PATH and hook binaries usable after cutover.
func MigrateLegacyShims(home, canonical string) error {
	root, err := openLegacyRoot(home)
	if err != nil {
		return err
	}
	if root == nil {
		return nil
	}
	defer root.Close()
	entries, err := legacyEntries(root, ".")
	if err != nil {
		return err
	}
	script := "#!/bin/sh\nexec '" + strings.ReplaceAll(canonical, "'", "'\\''") + "' \"$@\"\n"
	for _, entry := range entries {
		if !legacyToken.MatchString(entry.Name()) {
			continue
		}
		bin, err := legacyDirectory(root, entry.Name())
		if err != nil {
			continue
		}
		files, ok := legacyShims(bin)
		if ok {
			for name, old := range files {
				if old == script {
					continue
				}
				var nonce [8]byte
				if _, err := rand.Read(nonce[:]); err != nil {
					bin.Close()
					return err
				}
				tmpName := fmt.Sprintf(".%s.migration-%x", name, nonce)
				tmp, err := bin.OpenFile(tmpName, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o700)
				if err != nil {
					bin.Close()
					return err
				}
				_, writeErr := tmp.WriteString(script)
				closeErr := tmp.Close()
				if writeErr != nil || closeErr != nil {
					_ = bin.Remove(tmpName)
					bin.Close()
					return fmt.Errorf("write legacy shim: %v %v", writeErr, closeErr)
				}
				if err := bin.Rename(tmpName, name); err != nil {
					_ = bin.Remove(tmpName)
					bin.Close()
					return err
				}
			}
		}
		bin.Close()
	}
	return nil
}

// PruneLegacyShims removes only app-authored shim directories no live manifest uses.
func PruneLegacyShims(home string, agentPaths []string, dryRun bool) ([]string, error) {
	path := legacyShimRoot(home)
	root, err := openLegacyRoot(home)
	if err != nil {
		return nil, err
	}
	if root == nil {
		return nil, nil
	}
	defer root.Close()
	entries, err := legacyEntries(root, ".")
	if err != nil {
		return nil, err
	}
	var removed []string
	for _, entry := range entries {
		token := entry.Name()
		if !legacyToken.MatchString(token) {
			continue
		}
		binPath := filepath.Join(path, token, "bin")
		used := false
		for _, agentPath := range agentPaths {
			for _, component := range filepath.SplitList(agentPath) {
				if component == binPath {
					used = true
					break
				}
			}
		}
		if used {
			continue
		}
		bin, err := legacyDirectory(root, token)
		if err != nil {
			continue
		}
		_, ok := legacyShims(bin)
		binEntries, binErr := legacyEntries(bin, ".")
		bin.Close()
		if !ok || binErr != nil || len(binEntries) != 2 {
			continue
		}
		tokenEntries, err := legacyEntries(root, token)
		if err != nil || len(tokenEntries) > 2 {
			continue
		}
		allowed := true
		for _, item := range tokenEntries {
			if item.Name() == "bin" {
				continue
			}
			if item.Name() != "serve.sock" {
				allowed = false
				break
			}
			info, err := root.Lstat(filepath.Join(token, "serve.sock"))
			if err != nil || info.Mode()&os.ModeSocket == 0 {
				allowed = false
				break
			}
			conn, err := net.Dial("unix", filepath.Join(path, token, "serve.sock"))
			if err == nil {
				conn.Close()
				allowed = false
				break
			}
		}
		if !allowed {
			continue
		}
		if !dryRun {
			if err := root.RemoveAll(token); err != nil {
				return removed, err
			}
		}
		removed = append(removed, filepath.Join(path, token))
	}
	return removed, nil
}
