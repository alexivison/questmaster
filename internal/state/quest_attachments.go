//go:build linux || darwin

package state

import (
	"crypto/rand"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
)

const MaxQuestAttachments = 20
const MaxQuestAttachmentBytes int64 = 25 << 20

// QuestAttachment describes a private copy, independent of the original file.
type QuestAttachment struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Path string `json:"path"`
	Size int64  `json:"size"`
}

func prepareQuestAttachments(root string, previous []QuestAttachment, paths, detachIDs []string) (next, created, removed []QuestAttachment, err error) {
	if len(paths) > MaxQuestAttachments || len(detachIDs) > MaxQuestAttachments {
		return nil, nil, nil, fmt.Errorf("a quest supports at most %d attachments", MaxQuestAttachments)
	}
	detach := make(map[string]bool, len(detachIDs))
	for _, id := range detachIDs {
		detach[id] = true
	}
	for _, attachment := range previous {
		if detach[attachment.ID] {
			removed = append(removed, attachment)
			delete(detach, attachment.ID)
		} else {
			next = append(next, attachment)
		}
	}
	if len(detach) != 0 {
		return nil, nil, nil, fmt.Errorf("attachment to remove was not found on this quest")
	}
	if len(next)+len(paths) > MaxQuestAttachments {
		return nil, nil, nil, fmt.Errorf("a quest supports at most %d attachments", MaxQuestAttachments)
	}
	defer func() {
		if err != nil {
			removeQuestAttachmentFiles(root, created)
		}
	}()
	for _, path := range paths {
		attachment, copyErr := copyQuestAttachment(root, path)
		if copyErr != nil {
			return nil, created, nil, copyErr
		}
		created = append(created, attachment)
		next = append(next, attachment)
	}
	return next, created, removed, nil
}

func copyQuestAttachment(root, sourcePath string) (QuestAttachment, error) {
	path, err := filepath.Abs(ExpandHome(sourcePath))
	if err != nil {
		return QuestAttachment{}, err
	}
	info, err := os.Stat(path)
	if err != nil {
		return QuestAttachment{}, fmt.Errorf("stat attachment: %w", err)
	}
	if !info.Mode().IsRegular() {
		return QuestAttachment{}, fmt.Errorf("attachment must be a regular file: %s", sourcePath)
	}
	if info.Size() > MaxQuestAttachmentBytes {
		return QuestAttachment{}, fmt.Errorf("attachment exceeds 25 MiB: %s", sourcePath)
	}
	input, err := os.Open(path)
	if err != nil {
		return QuestAttachment{}, fmt.Errorf("open attachment: %w", err)
	}
	defer input.Close()
	idBytes := make([]byte, 16)
	if _, err := rand.Read(idBytes); err != nil {
		return QuestAttachment{}, err
	}
	attachment := QuestAttachment{ID: fmt.Sprintf("att-%x", idBytes), Name: filepath.Base(path)}
	dir := filepath.Join(root, "quest-files", attachment.ID)
	if err := os.MkdirAll(filepath.Dir(dir), 0o700); err != nil {
		return QuestAttachment{}, err
	}
	if err := os.Mkdir(dir, 0o700); err != nil {
		return QuestAttachment{}, err
	}
	succeeded := false
	defer func() {
		if !succeeded {
			_ = os.RemoveAll(dir)
		}
	}()
	attachment.Path = filepath.Join(dir, attachment.Name)
	output, err := os.OpenFile(attachment.Path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return QuestAttachment{}, err
	}
	// Bound the copy even if the source grows after Stat.
	attachment.Size, err = io.Copy(output, io.LimitReader(input, MaxQuestAttachmentBytes+1))
	closeErr := output.Close()
	if err != nil {
		return QuestAttachment{}, fmt.Errorf("copy attachment: %w", err)
	}
	if closeErr != nil {
		return QuestAttachment{}, closeErr
	}
	if attachment.Size > MaxQuestAttachmentBytes {
		return QuestAttachment{}, fmt.Errorf("attachment exceeds 25 MiB: %s", sourcePath)
	}
	succeeded = true
	return attachment, nil
}

var questAttachmentID = regexp.MustCompile(`^att-[a-f0-9]{32}$`)

// Only delete files in our own library, even if registry metadata was edited.
func removeQuestAttachmentFiles(root string, attachments []QuestAttachment) {
	for _, attachment := range attachments {
		if !questAttachmentID.MatchString(attachment.ID) || filepath.Base(attachment.Name) != attachment.Name || attachment.Name == "." || attachment.Name == ".." {
			continue
		}
		dir := filepath.Join(root, "quest-files", attachment.ID)
		if attachment.Path == filepath.Join(dir, attachment.Name) {
			_ = os.RemoveAll(dir)
		}
	}
}
