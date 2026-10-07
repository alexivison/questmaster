//go:build linux || darwin

// Package workerfeed reads and renders the shared worker chat feed.
package workerfeed

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"
	"syscall"
	"time"

	"github.com/alexivison/questmaster/internal/state"
)

const (
	maxTextChars       = 1500
	InitialTailBytes   = 256 * 1024
	maxIncrementalRead = 256 * 1024
	DefaultLimit       = 50
	MaxLimit           = 200
	maxLogLineBytes    = 64 * 1024
)

type Entry struct {
	Timestamp   time.Time `json:"timestamp"`
	WorkerID    string    `json:"worker_id"`
	WorkerTitle string    `json:"worker_title,omitempty"`
	Kind        string    `json:"kind"`
	Text        string    `json:"text"`
	Summary     string    `json:"summary,omitempty"`
	AgentID     string    `json:"-"`
}

type Cursor struct {
	Offset           int64      `json:"offset"`
	FileID           string     `json:"file_id,omitempty"`
	LastState        string     `json:"last_state,omitempty"`
	PendingPartID    string     `json:"pending_part_id,omitempty"`
	PendingPartText  string     `json:"pending_part_text,omitempty"`
	PendingPartAt    *time.Time `json:"pending_part_at,omitempty"`
	PendingFinalText string     `json:"pending_final_text,omitempty"`
	PendingFinalAt   *time.Time `json:"pending_final_at,omitempty"`
}

type Response struct {
	Entries []Entry           `json:"entries"`
	Cursors map[string]Cursor `json:"cursors"`
}

type HistoryPage struct {
	MasterID   string  `json:"master_id"`
	WorkerID   string  `json:"worker_id,omitempty"`
	Entries    []Entry `json:"entries"`
	NextBefore string  `json:"next_before,omitempty"`
}

type worker struct {
	id    string
	title string
}

// CapText keeps the first three paragraphs and at most 1500 Unicode characters.
func CapText(text string) string {
	text = strings.ReplaceAll(text, "\r\n", "\n")
	text = strings.ReplaceAll(text, "\r", "\n")
	paragraphs := make([]string, 0, 3)
	var lines []string
	flush := func() {
		if len(lines) > 0 {
			paragraphs = append(paragraphs, strings.Join(lines, "\n"))
			lines = nil
		}
	}
	for _, line := range strings.Split(strings.TrimSpace(text), "\n") {
		if strings.TrimSpace(line) == "" {
			flush()
			if len(paragraphs) == 3 {
				break
			}
			continue
		}
		lines = append(lines, line)
	}
	if len(paragraphs) < 3 {
		flush()
	}
	text = strings.Join(paragraphs, "\n\n")
	runes := []rune(text)
	if len(runes) > maxTextChars {
		return string(runes[:maxTextChars])
	}
	return text
}

// ReadSince returns bounded new entries for the workers listed by a master's manifest.
func ReadSince(root, masterID string, cursors map[string]Cursor) (Response, error) {
	workers, err := workersForMaster(root, masterID, "")
	if err != nil {
		return Response{}, err
	}
	result := Response{Entries: []Entry{}, Cursors: make(map[string]Cursor, len(workers))}
	for _, worker := range workers {
		entries, cursor, err := readWorkerSince(root, worker, cursors[worker.id])
		if err != nil {
			return Response{}, fmt.Errorf("read worker %s feed: %w", worker.id, err)
		}
		result.Entries = append(result.Entries, entries...)
		result.Cursors[worker.id] = cursor
	}
	sortEntries(result.Entries)
	return result, nil
}

// ReadHistory returns the newest bounded page, optionally for one worker and before a timestamp.
func ReadHistory(root, masterID, workerID string, before time.Time, limit int) (HistoryPage, error) {
	workers, err := workersForMaster(root, masterID, workerID)
	if err != nil {
		return HistoryPage{}, err
	}
	limit = normalizeLimit(limit)
	page := HistoryPage{MasterID: masterID, WorkerID: workerID, Entries: []Entry{}}
	for _, worker := range workers {
		entries, err := readWorkerHistory(root, worker)
		if err != nil {
			return HistoryPage{}, fmt.Errorf("read worker %s feed: %w", worker.id, err)
		}
		eligible := entries[:0]
		for _, entry := range entries {
			if before.IsZero() || entry.Timestamp.Before(before) {
				eligible = append(eligible, entry)
			}
		}
		if len(eligible) > limit {
			eligible = eligible[len(eligible)-limit:]
		}
		page.Entries = append(page.Entries, eligible...)
		sortEntries(page.Entries)
		if len(page.Entries) > limit {
			page.Entries = page.Entries[len(page.Entries)-limit:]
		}
	}
	if len(page.Entries) == limit {
		page.NextBefore = page.Entries[0].Timestamp.UTC().Format(time.RFC3339Nano)
	}
	return page, nil
}

func normalizeLimit(limit int) int {
	if limit <= 0 {
		return DefaultLimit
	}
	if limit > MaxLimit {
		return MaxLimit
	}
	return limit
}

func workersForMaster(root, masterID, filter string) ([]worker, error) {
	if !state.IsValidSessionID(masterID) {
		return nil, fmt.Errorf("invalid master id %q", masterID)
	}
	store := state.OpenStore(root)
	manifest, err := store.Read(masterID)
	if err != nil {
		return nil, fmt.Errorf("read master manifest: %w", err)
	}
	if manifest.SessionType != "master" {
		return nil, fmt.Errorf("session %q is not a master", masterID)
	}
	if filter != "" && !state.IsValidSessionID(filter) {
		return nil, fmt.Errorf("invalid worker id %q", filter)
	}
	seen := make(map[string]bool, len(manifest.Workers))
	workers := make([]worker, 0, len(manifest.Workers))
	for _, id := range manifest.Workers {
		if seen[id] || !state.IsValidSessionID(id) || (filter != "" && id != filter) {
			continue
		}
		seen[id] = true
		row := worker{id: id, title: id}
		if child, err := store.Read(id); err == nil && strings.TrimSpace(child.Title) != "" {
			row.title = child.Title
		}
		workers = append(workers, row)
	}
	if filter != "" && !seen[filter] {
		return nil, fmt.Errorf("worker %q is not listed by master %q", filter, masterID)
	}
	return workers, nil
}

func readWorkerSince(root string, worker worker, cursor Cursor) ([]Entry, Cursor, error) {
	path := state.SessionStateLogPath(root, worker.id)
	current, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		rotated, rotatedErr := os.Open(path + ".1")
		if rotatedErr == nil {
			defer rotated.Close()
			info, statErr := rotated.Stat()
			if statErr != nil {
				return nil, Cursor{}, statErr
			}
			if cursor.FileID != "" && cursor.FileID == fileIdentity(info) {
				entries, next, _, readErr := readForward(rotated, worker, cursor.FileID, cursor.Offset, maxIncrementalRead, cursor, false)
				return entries, next, readErr
			}
			entries, next, _, readErr := readTail(rotated, worker, fileIdentity(info), InitialTailBytes, Cursor{})
			return entries, next, readErr
		}
		if !errors.Is(rotatedErr, os.ErrNotExist) {
			return nil, Cursor{}, rotatedErr
		}
		return nil, Cursor{}, nil
	}
	if err != nil {
		return nil, cursor, err
	}
	defer current.Close()
	info, err := current.Stat()
	if err != nil {
		return nil, cursor, err
	}
	currentID := fileIdentity(info)
	if cursor.FileID == "" {
		budget := int64(InitialTailBytes)
		if info.Size() < budget {
			rotated, openErr := os.Open(path + ".1")
			if openErr == nil {
				defer rotated.Close()
				rolledInfo, statErr := rotated.Stat()
				if statErr != nil {
					return nil, Cursor{}, statErr
				}
				rolledBudget := budget - info.Size()
				rolledEntries, next, used, readErr := readTail(rotated, worker, fileIdentity(rolledInfo), rolledBudget, Cursor{})
				if readErr != nil {
					return nil, Cursor{}, readErr
				}
				budget -= int64(used)
				currentEntries, currentCursor, _, readErr := readForward(current, worker, currentID, 0, int(budget), next, false)
				return append(rolledEntries, currentEntries...), currentCursor, readErr
			}
			if !errors.Is(openErr, os.ErrNotExist) {
				return nil, Cursor{}, openErr
			}
		}
		entries, next, _, readErr := readTail(current, worker, currentID, budget, Cursor{})
		return entries, next, readErr
	}
	if cursor.FileID == currentID {
		entries, next, _, err := readForward(current, worker, currentID, cursor.Offset, maxIncrementalRead, cursor, false)
		return entries, next, err
	}

	rotated, openErr := os.Open(path + ".1")
	if openErr == nil {
		defer rotated.Close()
		rolledInfo, statErr := rotated.Stat()
		if statErr != nil {
			return nil, cursor, statErr
		}
		if fileIdentity(rolledInfo) == cursor.FileID {
			entries, next, used, readErr := readForward(rotated, worker, cursor.FileID, cursor.Offset, maxIncrementalRead, cursor, false)
			if readErr != nil {
				return nil, cursor, readErr
			}
			if next.Offset < rolledInfo.Size() || used >= maxIncrementalRead {
				return entries, next, nil
			}
			more, currentCursor, _, readErr := readForward(current, worker, currentID, 0, maxIncrementalRead-used, next, false)
			return append(entries, more...), currentCursor, readErr
		}
	}
	if openErr != nil && !errors.Is(openErr, os.ErrNotExist) {
		return nil, cursor, openErr
	}
	start := info.Size() - InitialTailBytes
	if start < 0 {
		start = 0
	}
	entries, next, _, err := readForward(current, worker, currentID, start, InitialTailBytes, cursor, start > 0)
	return entries, next, err
}

func readTail(file *os.File, worker worker, fileID string, limit int64, cursor Cursor) ([]Entry, Cursor, int, error) {
	if limit <= 0 {
		return nil, cursor, 0, nil
	}
	info, err := file.Stat()
	if err != nil {
		return nil, cursor, 0, err
	}
	start := info.Size() - limit
	if start < 0 {
		start = 0
	}
	entries, next, used, err := readForward(file, worker, fileID, start, int(limit), cursor, start > 0)
	return entries, next, used, err
}

func readForward(file *os.File, worker worker, fileID string, offset int64, maxBytes int, cursor Cursor, skipPartial bool) ([]Entry, Cursor, int, error) {
	info, err := file.Stat()
	if err != nil {
		return nil, cursor, 0, err
	}
	if offset < 0 || offset > info.Size() {
		offset = 0
	}
	available := info.Size() - offset
	if available > int64(maxBytes) {
		available = int64(maxBytes)
	}
	data := make([]byte, available)
	n, readErr := file.ReadAt(data, offset)
	if readErr != nil && !errors.Is(readErr, io.EOF) {
		return nil, cursor, n, readErr
	}
	data = data[:n]
	used := n
	if skipPartial {
		if newline := bytes.IndexByte(data, '\n'); newline >= 0 {
			offset += int64(newline + 1)
			data = data[newline+1:]
		} else {
			cursor.Offset = offset + int64(n)
			cursor.FileID = fileID
			return nil, cursor, used, nil
		}
	}
	if cursor.FileID != fileID {
		cursor.Offset = offset
		cursor.FileID = fileID
	}
	lineStart := offset
	var allEntries []Entry
	for len(data) > 0 {
		i := bytes.IndexByte(data, '\n')
		if i < 0 {
			break
		}
		line := data[:i]
		var event state.StateEvent
		if len(line) > 0 && json.Unmarshal(line, &event) == nil {
			entries := deriveWorkerEvent(worker.id, worker.title, event, &cursor)
			cursor.Offset = lineStart + int64(i+1)
			allEntries = append(allEntries, entries...)
		} else {
			cursor.Offset = lineStart + int64(i+1)
		}
		lineStart += int64(i + 1)
		data = data[i+1:]
	}
	return allEntries, cursor, used, nil
}

func readWorkerHistory(root string, worker worker) ([]Entry, error) {
	paths := []string{state.SessionStateLogPath(root, worker.id) + ".1", state.SessionStateLogPath(root, worker.id)}
	cursor := Cursor{}
	entries := make([]Entry, 0)
	for _, path := range paths {
		file, err := os.Open(path)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return nil, err
		}
		info, statErr := file.Stat()
		if statErr != nil {
			file.Close()
			return nil, statErr
		}
		identity := fileIdentity(info)
		chunkLimit := int64(state.StateJSONLMaxSize + maxLogLineBytes)
		data, readErr := io.ReadAll(io.LimitReader(file, chunkLimit))
		file.Close()
		if readErr != nil {
			return nil, readErr
		}
		if len(data) > 0 {
			chunk, next, err := deriveLines(worker, identity, data, cursor)
			if err != nil {
				return nil, err
			}
			entries = append(entries, chunk...)
			cursor = next
		}
	}
	return entries, nil
}

func deriveLines(worker worker, fileID string, data []byte, cursor Cursor) ([]Entry, Cursor, error) {
	var entries []Entry
	reader := bufio.NewScanner(bytes.NewReader(data))
	reader.Buffer(make([]byte, 4096), maxLogLineBytes)
	for reader.Scan() {
		var event state.StateEvent
		if json.Unmarshal(reader.Bytes(), &event) == nil {
			entries = append(entries, deriveWorkerEvent(worker.id, worker.title, event, &cursor)...)
		}
	}
	if err := reader.Err(); err != nil {
		return nil, cursor, err
	}
	cursor.FileID = fileID
	cursor.Offset = int64(len(data))
	return entries, cursor, nil
}

func deriveWorkerEvent(workerID, title string, event state.StateEvent, cursor *Cursor) []Entry {
	fields := event.Fields
	if event.AgentID != "" {
		return nil
	}
	if value, ok := fields["agent_id"].(string); ok && value != "" {
		return nil
	}
	entry := func(kind, text, summary string, at time.Time) Entry {
		if at.IsZero() {
			at = event.Ts
		}
		return Entry{Timestamp: at, WorkerID: workerID, WorkerTitle: title, Kind: kind, Text: CapText(text), Summary: CapText(summary), AgentID: event.AgentID}
	}
	var entries []Entry
	kind, _ := fields["chat_kind"].(string)
	text, _ := fields["chat_text"].(string)
	summary, _ := fields["chat_summary"].(string)
	if kind == "message" && strings.TrimSpace(text) != "" {
		entries = append(entries, entry(kind, text, "", event.Ts))
	}

	partID, _ := fields["workerfeed_part_id"].(string)
	partText, _ := fields["workerfeed_part_text"].(string)
	if partID != "" && partText != "" {
		cursor.PendingPartID = partID
		cursor.PendingPartText = CapText(partText)
		partAt := event.Ts
		cursor.PendingPartAt = &partAt
	}
	assistantID, _ := fields["workerfeed_assistant_message_id"].(string)
	if assistantID != "" && assistantID == cursor.PendingPartID {
		cursor.PendingFinalText = cursor.PendingPartText
		cursor.PendingFinalAt = cursor.PendingPartAt
		cursor.PendingPartID = ""
		cursor.PendingPartText = ""
		cursor.PendingPartAt = nil
	}
	if event.Action == "tool.execute.before" {
		cursor.PendingFinalText = ""
		cursor.PendingFinalAt = nil
	}
	if event.State == "done" && cursor.PendingFinalText != "" {
		at := event.Ts
		if cursor.PendingFinalAt != nil {
			at = *cursor.PendingFinalAt
		}
		entries = append(entries, entry("message", cursor.PendingFinalText, "", at))
		cursor.PendingFinalText = ""
		cursor.PendingFinalAt = nil
	}
	if event.State != "" {
		previous := cursor.LastState
		cursor.LastState = event.State
		if event.State != previous && (event.State == "working" || event.State == "done" || event.State == "blocked") {
			entries = append(entries, entry("status", event.State, "", event.Ts))
		}
	}
	if kind != "message" && (kind == "action" || kind == "report" || kind == "say") && strings.TrimSpace(text) != "" {
		entries = append(entries, entry(kind, text, summary, event.Ts))
	}
	return entries
}

func fileIdentity(info os.FileInfo) string {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return ""
	}
	return fmt.Sprintf("%d:%d", stat.Dev, stat.Ino)
}

func sortEntries(entries []Entry) {
	sort.SliceStable(entries, func(i, j int) bool { return entries[i].Timestamp.Before(entries[j].Timestamp) })
}

func RenderText(entries []Entry, expandTools bool) string {
	var out strings.Builder
	lastHeader := ""
	write := func(entry Entry, text string) {
		header := entry.Timestamp.Format("15:04")
		if header != lastHeader {
			if out.Len() > 0 {
				out.WriteByte('\n')
			}
			fmt.Fprintf(&out, "[%s]\n", header)
			lastHeader = header
		}
		fmt.Fprintf(&out, "%s: %s\n", displayName(entry), text)
	}
	for i := 0; i < len(entries); {
		entry := entries[i]
		if entry.Kind == "action" && !expandTools {
			counts := make(map[string]int)
			order := make([]string, 0, 3)
			j := i
			for j < len(entries) && entries[j].Kind == "action" && entries[j].WorkerID == entry.WorkerID && entries[j].AgentID == entry.AgentID {
				tool := entries[j].Text
				if _, exists := counts[tool]; !exists {
					order = append(order, tool)
				}
				counts[tool]++
				j++
			}
			parts := make([]string, 0, len(order))
			for _, tool := range order {
				label := "[" + tool + "]"
				if counts[tool] > 1 {
					label += fmt.Sprintf(" x%d", counts[tool])
				}
				parts = append(parts, label)
			}
			write(entry, "Cast "+strings.Join(parts, ", "))
			i = j
			continue
		}
		write(entry, renderEntry(entry, expandTools))
		i++
	}
	return strings.TrimRight(out.String(), "\n")
}

func renderEntry(entry Entry, expandTools bool) string {
	switch entry.Kind {
	case "action":
		if expandTools && entry.Summary != "" {
			return "Cast [" + entry.Text + "] — " + entry.Summary
		}
		return "Cast [" + entry.Text + "]"
	case "status":
		label := map[string]string{"working": "Working", "done": "Done", "blocked": "Blocked"}[entry.Text]
		return "Received status: [" + label + "]"
	case "report":
		return "Reported to Master - " + entry.Text
	case "message", "say":
		return entry.Text
	default:
		return entry.Text
	}
}

func displayName(entry Entry) string {
	name := strings.TrimSpace(entry.WorkerTitle)
	if name == "" {
		name = entry.WorkerID
	}
	runes := []rune(name)
	if len(runes) > 16 {
		name = string(runes[:16])
	}
	return name
}
