//go:build linux || darwin

// Package workerfeed reads and renders the shared worker chat feed.
package workerfeed

import (
	"bytes"
	"encoding/base64"
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
	historyChunkBytes  = 64 * 1024
	maxHistoryLineSize = 2 * 1024 * 1024
	DefaultLimit       = 50
	MaxLimit           = 200
)

type Entry struct {
	Timestamp   time.Time `json:"timestamp"`
	WorkerID    string    `json:"worker_id"`
	WorkerTitle string    `json:"worker_title,omitempty"`
	Kind        string    `json:"kind"`
	Text        string    `json:"text"`
	Summary     string    `json:"summary,omitempty"`
	position    entryPosition
}

type Cursor struct {
	Offset int64  `json:"offset"`
	FileID string `json:"file_id"`
}

type Response struct {
	Entries []Entry           `json:"entries"`
	Cursors map[string]Cursor `json:"cursors"`
	HasMore map[string]bool   `json:"has_more"`
	Errors  map[string]string `json:"errors,omitempty"`
}

type HistoryPage struct {
	MasterID   string            `json:"master_id"`
	WorkerID   string            `json:"worker_id,omitempty"`
	Entries    []Entry           `json:"entries"`
	NextBefore string            `json:"next_before,omitempty"`
	Errors     map[string]string `json:"errors,omitempty"`
}

type worker struct {
	id    string
	title string
}

type entryPosition struct {
	timestamp time.Time
	workerID  string
	fileID    string
	offset    int64
	index     int
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
	result := Response{Entries: []Entry{}, Cursors: make(map[string]Cursor, len(workers)), HasMore: make(map[string]bool, len(workers))}
	for _, worker := range workers {
		result.HasMore[worker.id] = false
		entries, cursor, hasMore, err := readWorkerSince(root, worker, cursors[worker.id])
		if err != nil {
			result.Cursors[worker.id] = cursors[worker.id]
			if result.Errors == nil {
				result.Errors = make(map[string]string)
			}
			result.Errors[worker.id] = err.Error()
			continue
		}
		result.Entries = append(result.Entries, entries...)
		result.Cursors[worker.id] = cursor
		result.HasMore[worker.id] = hasMore
	}
	sortEntries(result.Entries)
	return result, nil
}

// ReadHistory returns the newest bounded page, optionally for one worker and before a timestamp or entry token.
func ReadHistory(root, masterID, workerID, before string, limit int) (HistoryPage, error) {
	workers, err := workersForMaster(root, masterID, workerID)
	if err != nil {
		return HistoryPage{}, err
	}
	limit = normalizeLimit(limit)
	constraint, err := parseBefore(before)
	if err != nil {
		return HistoryPage{}, err
	}
	page := HistoryPage{MasterID: masterID, WorkerID: workerID, Entries: []Entry{}}
	pageCandidates := make([]Entry, 0, limit+1)
	for _, worker := range workers {
		entries, err := readWorkerHistory(root, worker, constraint, limit+1)
		if err != nil {
			if workerID != "" {
				return HistoryPage{}, fmt.Errorf("read worker %s history: %w", worker.id, err)
			}
			if page.Errors == nil {
				page.Errors = make(map[string]string)
			}
			page.Errors[worker.id] = err.Error()
			continue
		}
		pageCandidates = append(pageCandidates, entries...)
	}
	sortEntries(pageCandidates)
	hasOlder := len(pageCandidates) > limit
	if hasOlder {
		pageCandidates = pageCandidates[len(pageCandidates)-limit:]
	}
	page.Entries = pageCandidates
	if hasOlder && len(page.Entries) > 0 {
		page.NextBefore = encodePosition(page.Entries[0].position)
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

func readWorkerSince(root string, worker worker, cursor Cursor) ([]Entry, Cursor, bool, error) {
	path := state.SessionStateLogPath(root, worker.id)
	current, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		rotated, rotatedErr := os.Open(path + ".1")
		if rotatedErr == nil {
			defer rotated.Close()
			info, statErr := rotated.Stat()
			if statErr != nil {
				return nil, Cursor{}, false, statErr
			}
			if cursor.FileID != "" && cursor.FileID == fileIdentity(info) {
				entries, next, _, readErr := readForward(rotated, worker, cursor.FileID, cursor.Offset, maxIncrementalRead, cursor, false)
				return entries, next, hasCompleteLineAfter(rotated, next.Offset, info.Size()), readErr
			}
			entries, next, _, readErr := readTail(rotated, worker, fileIdentity(info), InitialTailBytes, Cursor{})
			return entries, next, hasCompleteLineAfter(rotated, next.Offset, info.Size()), readErr
		}
		if !errors.Is(rotatedErr, os.ErrNotExist) {
			return nil, Cursor{}, false, rotatedErr
		}
		return nil, cursor, false, nil
	}
	if err != nil {
		return nil, cursor, false, err
	}
	defer current.Close()
	info, err := current.Stat()
	if err != nil {
		return nil, cursor, false, err
	}
	currentID := fileIdentity(info)
	if cursor.FileID == "" {
		return readInitialTail(path, current, worker, info)
	}
	if cursor.FileID == currentID {
		entries, next, _, err := readForward(current, worker, currentID, cursor.Offset, maxIncrementalRead, cursor, false)
		return entries, next, hasCompleteLineAfter(current, next.Offset, info.Size()), err
	}

	rotated, openErr := os.Open(path + ".1")
	if openErr == nil {
		defer rotated.Close()
		rolledInfo, statErr := rotated.Stat()
		if statErr != nil {
			return nil, cursor, false, statErr
		}
		if fileIdentity(rolledInfo) == cursor.FileID {
			entries, next, used, readErr := readForward(rotated, worker, cursor.FileID, cursor.Offset, maxIncrementalRead, cursor, false)
			if readErr != nil {
				return nil, cursor, false, readErr
			}
			if next.Offset < rolledInfo.Size() || used >= maxIncrementalRead {
				return entries, next, hasCompleteLineAfter(rotated, next.Offset, rolledInfo.Size()) || hasCompleteLineAfter(current, 0, info.Size()), nil
			}
			more, currentCursor, _, readErr := readForward(current, worker, currentID, 0, maxIncrementalRead-used, next, false)
			return append(entries, more...), currentCursor, hasCompleteLineAfter(current, currentCursor.Offset, info.Size()), readErr
		}
	}
	if openErr != nil && !errors.Is(openErr, os.ErrNotExist) {
		return nil, cursor, false, openErr
	}
	return readInitialTail(path, current, worker, info)
}

func readInitialTail(path string, current *os.File, worker worker, currentInfo os.FileInfo) ([]Entry, Cursor, bool, error) {
	currentID := fileIdentity(currentInfo)
	budget := int64(InitialTailBytes)
	if currentInfo.Size() < budget {
		rotated, err := os.Open(path + ".1")
		if err == nil {
			defer rotated.Close()
			rotatedInfo, err := rotated.Stat()
			if err != nil {
				return nil, Cursor{}, false, err
			}
			rotatedBudget := budget - currentInfo.Size()
			rotatedEntries, cursor, used, err := readTail(rotated, worker, fileIdentity(rotatedInfo), rotatedBudget, Cursor{})
			if err != nil {
				return nil, Cursor{}, false, err
			}
			budget -= int64(used)
			currentEntries, next, _, err := readForward(current, worker, currentID, 0, int(budget), cursor, false)
			return append(rotatedEntries, currentEntries...), next, hasCompleteLineAfter(current, next.Offset, currentInfo.Size()), err
		}
		if !errors.Is(err, os.ErrNotExist) {
			return nil, Cursor{}, false, err
		}
	}
	entries, next, _, err := readTail(current, worker, currentID, budget, Cursor{})
	return entries, next, hasCompleteLineAfter(current, next.Offset, currentInfo.Size()), err
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
		if offset < 0 {
			offset = 0
		} else {
			offset = info.Size()
		}
	}
	if cursor.FileID == fileID && cursor.Offset > info.Size() {
		cursor.Offset = info.Size()
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
		atLineStart := offset == 0
		if offset > 0 {
			var prev [1]byte
			if _, err := file.ReadAt(prev[:], offset-1); err == nil && prev[0] == '\n' {
				atLineStart = true
			}
		}
		if !atLineStart {
			if newline := bytes.IndexByte(data, '\n'); newline >= 0 {
				offset += int64(newline + 1)
				data = data[newline+1:]
			} else {
				cursor.Offset = offset + int64(n)
				cursor.FileID = fileID
				return nil, cursor, used, nil
			}
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
			entries := deriveWorkerEvent(worker, fileID, lineStart, event)
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

func readWorkerHistory(root string, worker worker, before beforeConstraint, limit int) ([]Entry, error) {
	paths := []string{state.SessionStateLogPath(root, worker.id), state.SessionStateLogPath(root, worker.id) + ".1"}
	entries := make([]Entry, 0, limit)
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
		page, readErr := readHistoryFile(file, worker, fileIdentity(info), before, limit-len(entries))
		file.Close()
		if readErr != nil {
			return nil, readErr
		}
		entries = append(entries, page...)
		if len(entries) >= limit {
			break
		}
	}
	return entries, nil
}

func readHistoryFile(file *os.File, worker worker, fileID string, before beforeConstraint, limit int) ([]Entry, error) {
	info, err := file.Stat()
	if err != nil {
		return nil, err
	}
	end := info.Size()
	entries := make([]Entry, 0, limit)
	reverse := reverseHistoryReader{file: file, size: end}
	for end > 0 && len(entries) < limit {
		start, lineEnd, line, err := reverse.previousLine(end)
		if err != nil {
			return nil, err
		}
		end = start
		if lineEnd-start > maxHistoryLineSize {
			continue
		}
		if line == nil {
			line = make([]byte, lineEnd-start)
			if _, err := file.ReadAt(line, start); err != nil && !errors.Is(err, io.EOF) {
				return nil, err
			}
		}
		var event state.StateEvent
		if json.Unmarshal(line, &event) != nil {
			continue
		}
		lineEntries := deriveWorkerEvent(worker, fileID, start, event)
		for i := len(lineEntries) - 1; i >= 0 && len(entries) < limit; i-- {
			entry := lineEntries[i]
			if before.includes(entry.position) {
				entries = append(entries, entry)
			}
		}
	}
	return entries, nil
}

type reverseHistoryReader struct {
	file       *os.File
	size       int64
	chunk      []byte
	chunkStart int64
	loaded     bool
}

func (r *reverseHistoryReader) previousLine(end int64) (start, lineEnd int64, line []byte, err error) {
	lineEnd = end
	if end > 0 {
		last, err := r.byteAt(end - 1)
		if err != nil {
			return 0, 0, nil, err
		}
		if last == '\n' {
			lineEnd--
		}
	}
	pos := lineEnd
	for pos > 0 {
		if err := r.load(pos - 1); err != nil {
			return 0, 0, nil, err
		}
		chunkEnd := r.chunkStart + int64(len(r.chunk))
		if pos > chunkEnd {
			pos = chunkEnd
		}
		chunk := r.chunk[:pos-r.chunkStart]
		if index := bytes.LastIndexByte(chunk, '\n'); index >= 0 {
			start = r.chunkStart + int64(index+1)
			if lineEnd <= chunkEnd {
				line = r.chunk[index+1 : lineEnd-r.chunkStart]
			}
			return start, lineEnd, line, nil
		}
		pos = r.chunkStart
	}
	return 0, lineEnd, nil, nil
}

func (r *reverseHistoryReader) byteAt(offset int64) (byte, error) {
	if err := r.load(offset); err != nil {
		return 0, err
	}
	return r.chunk[offset-r.chunkStart], nil
}

func (r *reverseHistoryReader) load(offset int64) error {
	if r.loaded && offset >= r.chunkStart && offset < r.chunkStart+int64(len(r.chunk)) {
		return nil
	}
	chunkSize := int64(historyChunkBytes)
	r.chunkStart = offset / chunkSize * chunkSize
	length := chunkSize
	if remaining := r.size - r.chunkStart; remaining < length {
		length = remaining
	}
	if length <= 0 {
		r.chunk = nil
		r.loaded = true
		return nil
	}
	r.chunk = make([]byte, length)
	if _, err := r.file.ReadAt(r.chunk, r.chunkStart); err != nil && !errors.Is(err, io.EOF) {
		return err
	}
	r.loaded = true
	return nil
}

type beforeConstraint struct {
	timestamp *time.Time
	position  *entryPosition
}

func parseBefore(value string) (beforeConstraint, error) {
	if value == "" {
		return beforeConstraint{}, nil
	}
	if timestamp, err := time.Parse(time.RFC3339Nano, value); err == nil {
		return beforeConstraint{timestamp: &timestamp}, nil
	}
	data, err := base64.RawURLEncoding.DecodeString(value)
	if err != nil {
		return beforeConstraint{}, fmt.Errorf("parse --before as RFC3339 timestamp or entry token")
	}
	var token struct {
		Timestamp time.Time `json:"timestamp"`
		WorkerID  string    `json:"worker_id"`
		FileID    string    `json:"file_id"`
		Offset    int64     `json:"offset"`
		Index     int       `json:"index"`
	}
	if err := json.Unmarshal(data, &token); err != nil || token.Timestamp.IsZero() || token.WorkerID == "" || token.FileID == "" {
		return beforeConstraint{}, fmt.Errorf("parse --before entry token")
	}
	pos := entryPosition{timestamp: token.Timestamp, workerID: token.WorkerID, fileID: token.FileID, offset: token.Offset, index: token.Index}
	return beforeConstraint{position: &pos}, nil
}

func (b beforeConstraint) includes(pos entryPosition) bool {
	if b.timestamp != nil {
		return pos.timestamp.Before(*b.timestamp)
	}
	return b.position == nil || comparePositions(pos, *b.position) < 0
}

func encodePosition(pos entryPosition) string {
	token, _ := json.Marshal(struct {
		Timestamp time.Time `json:"timestamp"`
		WorkerID  string    `json:"worker_id"`
		FileID    string    `json:"file_id"`
		Offset    int64     `json:"offset"`
		Index     int       `json:"index"`
	}{pos.timestamp, pos.workerID, pos.fileID, pos.offset, pos.index})
	return base64.RawURLEncoding.EncodeToString(token)
}

func deriveWorkerEvent(worker worker, fileID string, offset int64, event state.StateEvent) []Entry {
	if event.Fields == nil {
		return nil
	}
	rawEntries, _ := event.Fields["chat_entries"].([]interface{})
	entries := make([]Entry, 0, len(rawEntries))
	for i, raw := range rawEntries {
		fields, ok := raw.(map[string]interface{})
		if !ok {
			continue
		}
		kind, _ := fields["chat_kind"].(string)
		text, _ := fields["chat_text"].(string)
		if strings.TrimSpace(text) == "" || !validChatKind(kind) {
			continue
		}
		entry := Entry{
			Timestamp: event.Ts, WorkerID: worker.id, WorkerTitle: worker.title,
			Kind: kind, Text: text,
			position: entryPosition{timestamp: event.Ts, workerID: worker.id, fileID: fileID, offset: offset, index: i},
		}
		if kind == "action" {
			entry.Summary = event.Activity
		}
		entries = append(entries, entry)
	}
	return entries
}

func validChatKind(kind string) bool {
	switch kind {
	case "status", "action", "message", "report", "say":
		return true
	default:
		return false
	}
}

func fileIdentity(info os.FileInfo) string {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return ""
	}
	return fmt.Sprintf("%d:%d", stat.Dev, stat.Ino)
}

func sortEntries(entries []Entry) {
	sort.SliceStable(entries, func(i, j int) bool {
		if !entries[i].Timestamp.Equal(entries[j].Timestamp) {
			return entries[i].Timestamp.Before(entries[j].Timestamp)
		}
		return comparePositions(entries[i].position, entries[j].position) < 0
	})
}

func comparePositions(a, b entryPosition) int {
	if !a.timestamp.Equal(b.timestamp) {
		if a.timestamp.Before(b.timestamp) {
			return -1
		}
		return 1
	}
	if a.workerID != b.workerID {
		if a.workerID < b.workerID {
			return -1
		}
		return 1
	}
	if a.fileID != b.fileID {
		if a.fileID < b.fileID {
			return -1
		}
		return 1
	}
	if a.offset != b.offset {
		if a.offset < b.offset {
			return -1
		}
		return 1
	}
	if a.index < b.index {
		return -1
	}
	if a.index > b.index {
		return 1
	}
	return 0
}

func hasCompleteLineAfter(file *os.File, offset, size int64) bool {
	if offset < 0 {
		offset = 0
	}
	if offset >= size {
		return false
	}
	lookaheadEnd := size
	if size-offset > int64(maxIncrementalRead) {
		lookaheadEnd = offset + int64(maxIncrementalRead)
	}
	for offset < lookaheadEnd {
		length := int64(historyChunkBytes)
		if lookaheadEnd-offset < length {
			length = lookaheadEnd - offset
		}
		data := make([]byte, length)
		n, err := file.ReadAt(data, offset)
		if err != nil && !errors.Is(err, io.EOF) {
			return false
		}
		if bytes.IndexByte(data[:n], '\n') >= 0 {
			return true
		}
		offset += int64(n)
		if n == 0 {
			return false
		}
	}
	return false
}

func RenderText(entries []Entry, expandTools bool) string {
	var out strings.Builder
	lastHeader := ""
	write := func(entry Entry, text string) {
		header := entry.Timestamp.Local().Format("15:04")
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
			for j < len(entries) && entries[j].Kind == "action" && entries[j].WorkerID == entry.WorkerID {
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
					label += fmt.Sprintf("(x%d)", counts[tool])
				}
				parts = append(parts, label)
			}
			write(entry, "Cast "+strings.Join(parts, " "))
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
		return "Received status [" + label + "]"
	case "report":
		return "[Report] " + entry.Text
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
	return name
}
