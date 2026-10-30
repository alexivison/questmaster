package state

import (
	"crypto/rand"
	"crypto/sha256"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// ArtifactCreateOptions describes one file that CreateArtifactAt writes into
// Questmaster's project library. Exactly one of SourcePath and Content is set.
type ArtifactCreateOptions struct {
	Name       string
	Label      string
	ProjectID  string
	SourcePath string
	Content    io.Reader
}

// CreateArtifactAt writes or imports a file, then links it to the creating session.
func CreateArtifactAt(root, sessionID string, opts ArtifactCreateOptions) (Artifact, error) {
	if !IsValidSessionID(sessionID) {
		return Artifact{}, fmt.Errorf("invalid session id: %q", sessionID)
	}
	if root == "" {
		return Artifact{}, fmt.Errorf("no state root resolved")
	}
	name := strings.TrimSpace(opts.Name)
	if name == "" || name == "." || name == ".." || filepath.Base(name) != name || strings.ContainsAny(name, "\\\x00") {
		return Artifact{}, fmt.Errorf("artifact name must be a file name without directories: %q", opts.Name)
	}
	if (opts.SourcePath == "") == (opts.Content == nil) {
		return Artifact{}, fmt.Errorf("provide exactly one of source path or content")
	}
	idBytes := make([]byte, 16)
	if _, err := rand.Read(idBytes); err != nil {
		return Artifact{}, fmt.Errorf("generate artifact id: %w", err)
	}
	id := fmt.Sprintf("art-%x", idBytes)
	key := "ungrouped"
	if opts.ProjectID != "" {
		sum := sha256.Sum256([]byte(opts.ProjectID))
		key = fmt.Sprintf("project-%x", sum[:8])
	}
	library := filepath.Join(root, "artifact-files")
	projectDir := filepath.Join(library, key)
	dir := filepath.Join(projectDir, id)
	if err := os.MkdirAll(projectDir, 0o700); err != nil {
		return Artifact{}, fmt.Errorf("create project artifact directory: %w", err)
	}
	if err := os.Mkdir(dir, 0o700); err != nil {
		return Artifact{}, fmt.Errorf("create artifact directory: %w", err)
	}
	succeeded := false
	defer func() {
		if !succeeded {
			_ = os.RemoveAll(dir)
			_ = os.Remove(projectDir) // Only remove the directory if no other artifacts use it.
			_ = os.Remove(library)
		}
	}()

	source := opts.Content
	if opts.SourcePath != "" {
		input, err := os.Open(opts.SourcePath)
		if err != nil {
			return Artifact{}, fmt.Errorf("open artifact source: %w", err)
		}
		defer input.Close()
		source = input
	}
	temp, err := os.CreateTemp(dir, ".artifact-*")
	if err != nil {
		return Artifact{}, fmt.Errorf("create temporary artifact: %w", err)
	}
	tempPath := temp.Name()
	defer os.Remove(tempPath)
	if _, err := io.Copy(temp, source); err != nil {
		temp.Close()
		return Artifact{}, fmt.Errorf("write artifact: %w", err)
	}
	if err := temp.Close(); err != nil {
		return Artifact{}, fmt.Errorf("close artifact: %w", err)
	}
	path := filepath.Join(dir, name)
	if err := os.Rename(tempPath, path); err != nil {
		return Artifact{}, fmt.Errorf("publish artifact: %w", err)
	}
	artifact := Artifact{
		ID: id, Kind: ArtifactKindForPath(name), Path: path, Label: opts.Label,
		SessionIDs: []string{sessionID}, CreatedBySessionID: sessionID, ProjectID: opts.ProjectID,
	}
	artifact = normalizeArtifact(artifact)
	if err := UpsertArtifactAt(root, sessionID, artifact); err != nil {
		// A sidecar write can fail after the registry commit. Remove any
		// committed reference before the deferred cleanup removes its file.
		_, _ = RemoveArtifactGlobal(root, path)
		return Artifact{}, fmt.Errorf("register artifact: %w", err)
	}
	succeeded = true
	return artifact, nil
}
