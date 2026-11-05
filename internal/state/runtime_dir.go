//go:build linux || darwin

package state

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"

	"golang.org/x/sys/unix"
)

// A session's runtime directory holds what its tmux hooks and agent bridges
// share at run time: the session-closed cleanup script, the session-name and
// resume-ID files, and Pi's messaging socket. A new session's directory is
// <state root>/runtime/<id>, owner-only. Its manifest records the path
// (runtime_dir) and the session gets it as $QUESTMASTER_RUNTIME_DIR; every
// reader takes it from one of the two.
const (
	// RuntimeDirEnv carries a session's runtime directory into its tmux
	// environment, for the bridges that are not Go (the Pi extension).
	RuntimeDirEnv = "QUESTMASTER_RUNTIME_DIR"
	// PiSocketName is Pi's messaging socket inside a runtime directory.
	PiSocketName = "pi.sock"

	runtimeDirName = "runtime"
	// maxUnixSocketPath is the longest path a Unix socket binds: sun_path is
	// 104 bytes on macOS, NUL included (Linux allows 108).
	maxUnixSocketPath = 103
)

// NewRuntimeDir returns the runtime directory a session gets under root. The
// session-closed hook relies on the shape: it finds a closed session's
// cleanup script at <root>/runtime/<closed session's name>.
func NewRuntimeDir(root, sessionID string) string {
	return filepath.Join(root, runtimeDirName, sessionID)
}

// RuntimeDirOrLegacy returns where the session's runtime files are. A recorded
// path must be absolute, clean and named after the session, since the cleanup
// script removes it.
func (m Manifest) RuntimeDirOrLegacy() (string, error) {
	if m.RuntimeDir == "" {
		// LEGACY: a session started before runtime_dir was recorded keeps its
		// /tmp/<id> directory until it stops. Questmaster reads and removes that
		// directory but never creates it; Continue moves a stopped session to
		// NewRuntimeDir. Delete this branch once no live manifest lacks
		// runtime_dir (the follow-up quest's gate).
		if !IsValidSessionID(m.SessionID) {
			return "", fmt.Errorf("invalid session ID %q", m.SessionID)
		}
		return filepath.Join("/tmp", m.SessionID), nil
	}
	dir := m.RuntimeDir
	if !filepath.IsAbs(dir) || filepath.Clean(dir) != dir || filepath.Base(dir) != m.SessionID {
		return "", fmt.Errorf("session %s records runtime_dir %q, which is not an absolute path named after the session", m.SessionID, dir)
	}
	return dir, nil
}

// PiSocketPath returns Pi's messaging socket in dir, or an error when the path
// is too long to bind.
func PiSocketPath(dir string) (string, error) {
	path := filepath.Join(dir, PiSocketName)
	if len(path) > maxUnixSocketPath {
		return "", fmt.Errorf("the Pi messaging socket %s is %d bytes, over the %d-byte Unix socket limit; set %s to a shorter state root", path, len(path), maxUnixSocketPath, StateRootEnv)
	}
	return path, nil
}

// EnsureRuntimeDir makes dir and its parent owner-only directories, creating
// them when absent. It refuses a symlink, a non-directory and a path another
// user owns, and never follows a symlink on the way.
func EnsureRuntimeDir(dir string) error {
	if err := ensurePrivateDir(filepath.Dir(dir)); err != nil {
		return err
	}
	return ensurePrivateDir(dir)
}

func ensurePrivateDir(path string) error {
	if err := os.Mkdir(path, 0o700); err != nil && !errors.Is(err, fs.ErrExist) {
		return fmt.Errorf("create runtime dir: %w", err)
	}
	fd, err := openOwnDir(path)
	if err != nil {
		return err
	}
	defer unix.Close(fd)
	if err := unix.Fchmod(fd, 0o700); err != nil {
		return fmt.Errorf("restrict runtime dir %s: %w", path, err)
	}
	return nil
}

// WriteRuntimeFile writes data to name in dir, mode 0600. dir must be a
// directory this user owns that no one else can write; neither it nor name
// may be a symlink.
func WriteRuntimeFile(dir, name string, data []byte) error {
	dirFD, err := openOwnDir(dir)
	if err != nil {
		return err
	}
	defer unix.Close(dirFD)
	fd, err := unix.Openat(dirFD, name, unix.O_WRONLY|unix.O_CREAT|unix.O_TRUNC|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0o600)
	if err != nil {
		return fmt.Errorf("open %s in runtime dir %s: %w", name, dir, err)
	}
	f := os.NewFile(uintptr(fd), filepath.Join(dir, name))
	defer f.Close()
	if err := f.Chmod(0o600); err != nil {
		return err
	}
	if _, err := f.Write(data); err != nil {
		return err
	}
	return f.Close()
}

// openOwnDir opens path as a directory without following a symlink and checks
// that this user owns it and no one else can write it.
func openOwnDir(path string) (int, error) {
	fd, err := unix.Open(path, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if errors.Is(err, unix.ELOOP) || errors.Is(err, unix.ENOTDIR) {
		return -1, fmt.Errorf("runtime dir %s is a symlink or not a directory", path)
	}
	if err != nil {
		return -1, fmt.Errorf("open runtime dir %s: %w", path, err)
	}
	var st unix.Stat_t
	if err := unix.Fstat(fd, &st); err != nil {
		unix.Close(fd)
		return -1, fmt.Errorf("stat runtime dir %s: %w", path, err)
	}
	if int(st.Uid) != os.Getuid() {
		unix.Close(fd)
		return -1, fmt.Errorf("runtime dir %s is owned by uid %d, not %d", path, st.Uid, os.Getuid())
	}
	if st.Mode&0o022 != 0 {
		unix.Close(fd)
		return -1, fmt.Errorf("runtime dir %s is writable by others (mode %04o)", path, st.Mode&0o777)
	}
	return fd, nil
}
