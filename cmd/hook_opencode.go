package cmd

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/alexivison/questmaster/internal/state"
)

const openCodeMinimumVersion = "1.17.11"

type openCodeHookPayload struct {
	Version string        `json:"version"`
	Event   openCodeEvent `json:"event"`
}

type openCodeEvent struct {
	ID         string                 `json:"id"`
	Type       string                 `json:"type"`
	Properties map[string]interface{} `json:"properties"`
}

type openCodePatch struct {
	state      string
	activity   string
	tool       string
	clearTool  bool
	kind       string
	recent     []string
	hasRecent  bool
	sessionID  string
	eventID    string
	statusType string
	version    string

	// partText/partMsgID carry a message.part.updated whose author role is not
	// yet known; assistantMsgID carries the message.updated that confirms a
	// message is assistant-authored. See updateOpenCodePane for how the two are
	// correlated so a user prompt is never surfaced as the worker's activity.
	partText       string
	partMsgID      string
	assistantMsgID string
}

func handleOpenCode(r *HookRunner, sessionID string, opts hookOptions, stderr io.Writer) {
	if opts.action != "event" {
		fmt.Fprintf(stderr, "questmaster hook opencode: unknown action %q\n", opts.action)
		return
	}

	payload, ok := decodeOpenCodePayload(opts.stdin)
	if !ok {
		fmt.Fprintf(stderr, "questmaster hook opencode: malformed payload\n")
		return
	}
	now := r.Now().UTC()
	patch := openCodePatchForEvent(payload)

	ev := state.StateEvent{
		Ts:       now,
		Agent:    "opencode",
		Role:     "primary",
		Action:   patch.kind,
		State:    patch.state,
		Activity: patch.activity,
		Tool:     patch.tool,
		Kind:     patch.kind,
	}
	fields := map[string]interface{}{
		"minimum_version": openCodeMinimumVersion,
	}
	if patch.eventID != "" {
		fields["event_id"] = patch.eventID
	}
	if patch.sessionID != "" {
		fields["opencode_session_id"] = patch.sessionID
	}
	if patch.statusType != "" {
		fields["status"] = patch.statusType
	}
	if patch.version != "" {
		fields["version"] = patch.version
	}
	if patch.hasRecent {
		fields["recent_count"] = len(patch.recent)
	}
	ev.Fields = fields

	if err := r.AppendEvent(sessionID, ev); err != nil {
		fmt.Fprintf(stderr, "questmaster hook opencode: append event: %v\n", err)
	}

	if !patch.mutatesState() {
		return
	}
	accepted, err := updateOpenCodePane(r, sessionID, now, patch)
	if err != nil {
		fmt.Fprintf(stderr, "questmaster hook opencode: update state: %v\n", err)
		return
	}
	if accepted && patch.sessionID != "" {
		captureOpenCodeSessionID(opts.ctx, r, stderr, sessionID, patch.sessionID)
	}
}

func decodeOpenCodePayload(data []byte) (openCodeHookPayload, bool) {
	if len(data) == 0 {
		return openCodeHookPayload{}, false
	}
	var payload openCodeHookPayload
	if err := json.Unmarshal(data, &payload); err == nil && payload.Event.Type != "" {
		if payload.Event.Properties == nil {
			payload.Event.Properties = map[string]interface{}{}
		}
		return payload, true
	}
	var event openCodeEvent
	if err := json.Unmarshal(data, &event); err != nil || event.Type == "" {
		return openCodeHookPayload{}, false
	}
	if event.Properties == nil {
		event.Properties = map[string]interface{}{}
	}
	return openCodeHookPayload{Event: event}, true
}

func openCodePatchForEvent(payload openCodeHookPayload) openCodePatch {
	event := payload.Event
	patch := openCodePatch{
		kind:      event.Type,
		sessionID: openCodeSessionID(event),
		eventID:   strings.TrimSpace(event.ID),
		version:   openCodeVersion(payload),
	}

	switch event.Type {
	case "session.created":
		patch.state = "starting"
		patch.activity = "Session created"
	case "session.status":
		patch.statusType = openCodeStatusType(event.Properties)
		switch patch.statusType {
		case "busy":
			patch.state = "working"
		case "idle":
			patch.state = "idle"
			patch.clearTool = true
		}
	case "session.idle":
		patch.state = "done"
		patch.clearTool = true
	case "session.error":
		patch.state = "blocked"
		patch.activity = "Error: " + openCodeErrorLabel(event)
		patch.clearTool = true
	case "tool.execute.before":
		patch.state = "working"
		patch.tool = openCodeToolLabel(event)
		patch.activity = "Tool: " + patch.tool
	case "tool.execute.after":
		patch.activity = "Tool done: " + openCodeToolLabel(event)
		patch.clearTool = true
	case "permission.asked":
		patch.state = "blocked"
		patch.activity = "Permission: " + openCodePermissionLabel(event)
	case "permission.replied":
		patch.state = "working"
		patch.activity = "Permission replied"
	case "message.part.updated":
		// A part carries no role, so don't surface it yet: buffer it and let the
		// matching assistant message.updated decide whether to record it.
		if text, msgID := openCodePartText(event); text != "" && msgID != "" {
			patch.partText = text
			patch.partMsgID = msgID
		}
		if state, activity, tool, clearTool := openCodeNonTextPartActivity(event); activity != "" {
			patch.state = state
			patch.activity = activity
			patch.tool = tool
			patch.clearTool = clearTool
		}
	case "message.updated":
		patch.assistantMsgID = openCodeAssistantMessageID(event)
	}
	if patch.tool == "" && event.Type == "tool.execute.before" {
		patch.tool = "tool"
		patch.activity = "Tool: tool"
	}
	if patch.kind == "" {
		patch.kind = "unknown"
	}
	return patch
}

func (p openCodePatch) mutatesState() bool {
	return p.state != "" || p.activity != "" || p.tool != "" || p.clearTool || p.hasRecent ||
		p.sessionID != "" || p.partMsgID != "" || p.assistantMsgID != ""
}

func updateOpenCodePane(r *HookRunner, sessionID string, now time.Time, patch openCodePatch) (bool, error) {
	accepted := false
	err := r.Update(sessionID, func(ss *state.SessionState) bool {
		role := "primary"
		ss.SeenAt = now
		pane, exists := ss.Panes[role]
		if !exists {
			pane = state.PaneState{Role: role, Agent: "opencode"}
		}
		if patch.sessionID != "" && pane.OpenCodeSessionID != "" && pane.OpenCodeSessionID != patch.sessionID &&
			!((pane.State == "idle" || pane.State == "done") && patch.state == "working") {
			return false
		}
		accepted = true
		prev := struct {
			State, Activity, Tool, LastKind string
			LastEvent, WorkingSince         time.Time
			Recent                          []string
			OpenCodeSessionID               string
			PendingPartMsgID                string
			PendingPartText                 string
		}{pane.State, pane.Activity, pane.Tool, pane.LastKind, pane.LastEvent, pane.WorkingSince, pane.Recent, pane.OpenCodeSessionID, pane.PendingPartMsgID, pane.PendingPartText}

		setState := patch.state
		setActivity := patch.activity
		setTool := patch.tool
		clearTool := patch.clearTool
		lastKind := patch.kind

		preservePermissionBlock := pane.State == "blocked" &&
			(pane.LastKind == "permission.asked" || strings.HasPrefix(pane.Activity, "Permission: ")) &&
			(patch.kind == "session.status" || patch.kind == "session.idle" || patch.kind == "tool.execute.before")
		if preservePermissionBlock {
			setState = ""
			setActivity = ""
			setTool = ""
			clearTool = false
			lastKind = pane.LastKind
		}
		if patch.kind == "permission.replied" && pane.State != "blocked" {
			setState = ""
		}
		preserveDoneFromIdleStatus := pane.State == "done" && patch.kind == "session.status" && patch.statusType == "idle"
		if preserveDoneFromIdleStatus {
			setState = ""
			clearTool = false
			lastKind = pane.LastKind
		}

		if setState != "" {
			pane.State = setState
		}
		normalizeHookWorkingSince(&pane, prev.State, prev.LastEvent, now)
		if setActivity != "" {
			pane.Activity = setActivity
		}
		if setTool != "" {
			pane.Tool = setTool
		} else if clearTool {
			pane.Tool = ""
		}
		if patch.hasRecent {
			pane.Recent = patch.recent
		}
		if patch.sessionID != "" {
			pane.OpenCodeSessionID = patch.sessionID
		}
		// Role-correlate message parts. A part buffers its text; the matching
		// assistant message.updated promotes it to Activity/Recent. A user part
		// is buffered but never promoted (no message.updated names its id), so the
		// user's prompt is never surfaced as the worker's activity.
		if patch.partMsgID != "" {
			pane.PendingPartMsgID = patch.partMsgID
			pane.PendingPartText = patch.partText
		}
		if patch.assistantMsgID != "" && patch.assistantMsgID == pane.PendingPartMsgID {
			pane.Activity = truncatePromptLine(pane.PendingPartText)
			pane.Recent = cleanPiRecent(strings.Split(pane.PendingPartText, "\n"))
			pane.PendingPartMsgID = ""
			pane.PendingPartText = ""
		}
		if lastKind != "" {
			pane.LastKind = lastKind
		}
		pane.LastEvent = now
		pane.Seq = now.UnixNano()
		pane.Agent = "opencode"
		pane.Role = role
		ss.Panes[role] = pane

		return pane.State != prev.State ||
			pane.Activity != prev.Activity ||
			pane.Tool != prev.Tool ||
			pane.LastKind != prev.LastKind ||
			!pane.WorkingSince.Equal(prev.WorkingSince) ||
			!slices.Equal(pane.Recent, prev.Recent) ||
			pane.OpenCodeSessionID != prev.OpenCodeSessionID ||
			pane.PendingPartMsgID != prev.PendingPartMsgID ||
			pane.PendingPartText != prev.PendingPartText
	})
	return accepted, err
}

func captureOpenCodeSessionID(ctx context.Context, r *HookRunner, stderr io.Writer, sessionID, openCodeSessionID string) {
	captureResumeID(ctx, r, stderr, sessionID, "opencode_session_id", "OPENCODE_SESSION_ID", openCodeSessionID, "opencode")
	persistRuntimeResumeID(stderr, sessionID, "opencode-session-id", openCodeSessionID, "opencode")
}

func persistRuntimeResumeID(stderr io.Writer, sessionID, fileName, value, agent string) {
	if value == "" {
		return
	}
	dir := filepath.Join("/tmp", sessionID)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		fmt.Fprintf(stderr, "questmaster hook %s: create runtime dir: %v\n", agent, err)
		return
	}
	path := filepath.Join(dir, fileName)
	body := []byte(value + "\n")
	if existing, err := os.ReadFile(path); err == nil && string(existing) == string(body) {
		return
	}
	if err := os.WriteFile(path, body, 0o644); err != nil {
		fmt.Fprintf(stderr, "questmaster hook %s: write runtime resume id: %v\n", agent, err)
	}
}

func openCodeSessionID(event openCodeEvent) string {
	for _, candidate := range openCodeSessionIDCands(event.Properties, 0) {
		if clean := state.SanitizeResumeID(strings.TrimSpace(candidate)); clean != "" {
			return clean
		}
	}
	return ""
}

func openCodeSessionIDCands(value interface{}, depth int) []string {
	if value == nil || depth > 8 {
		return nil
	}
	obj, ok := value.(map[string]interface{})
	if !ok {
		return nil
	}
	var out []string
	for _, key := range []string{"sessionID", "sessionId", "session_id"} {
		if s, ok := obj[key].(string); ok && strings.TrimSpace(s) != "" {
			out = append(out, s)
		}
	}
	if info, ok := obj["info"].(map[string]interface{}); ok {
		if s, ok := info["id"].(string); ok && strings.TrimSpace(s) != "" {
			out = append(out, s)
		}
	}
	if session, ok := obj["session"].(map[string]interface{}); ok {
		if s, ok := session["id"].(string); ok && strings.TrimSpace(s) != "" {
			out = append(out, s)
		}
	}
	for _, child := range obj {
		out = append(out, openCodeSessionIDCands(child, depth+1)...)
	}
	return out
}

func openCodeVersion(payload openCodeHookPayload) string {
	if strings.TrimSpace(payload.Version) != "" {
		return strings.TrimSpace(payload.Version)
	}
	if info, ok := payload.Event.Properties["info"].(map[string]interface{}); ok {
		if version, ok := info["version"].(string); ok {
			return strings.TrimSpace(version)
		}
	}
	return ""
}

func openCodeStatusType(props map[string]interface{}) string {
	status, ok := props["status"]
	if !ok {
		return ""
	}
	if s, ok := status.(string); ok {
		return strings.ToLower(strings.TrimSpace(s))
	}
	if obj, ok := status.(map[string]interface{}); ok {
		if s, ok := obj["type"].(string); ok {
			return strings.ToLower(strings.TrimSpace(s))
		}
	}
	return ""
}

func openCodeToolLabel(event openCodeEvent) string {
	props := event.Properties
	for _, key := range []string{"tool", "name"} {
		if s, ok := props[key].(string); ok && strings.TrimSpace(s) != "" {
			return truncatePromptLine(s)
		}
	}
	for _, key := range []string{"call", "toolCall"} {
		obj, ok := props[key].(map[string]interface{})
		if !ok {
			continue
		}
		for _, nested := range []string{"tool", "name"} {
			if s, ok := obj[nested].(string); ok && strings.TrimSpace(s) != "" {
				return truncatePromptLine(s)
			}
		}
	}
	return "tool"
}

func openCodePermissionLabel(event openCodeEvent) string {
	props := event.Properties
	for _, key := range []string{"permission", "request"} {
		obj, ok := props[key].(map[string]interface{})
		if !ok {
			continue
		}
		for _, nested := range []string{"id", "type", "tool", "name", "action"} {
			if s, ok := obj[nested].(string); ok && strings.TrimSpace(s) != "" {
				return truncatePromptLine(s)
			}
		}
	}
	for _, key := range []string{"tool", "id", "type"} {
		if s, ok := props[key].(string); ok && strings.TrimSpace(s) != "" {
			return truncatePromptLine(s)
		}
	}
	return "permission"
}

func openCodeErrorLabel(event openCodeEvent) string {
	props := event.Properties
	if errObj, ok := props["error"].(map[string]interface{}); ok {
		if data, ok := errObj["data"].(map[string]interface{}); ok {
			if s, ok := data["message"].(string); ok && strings.TrimSpace(s) != "" {
				return truncatePromptLine(s)
			}
		}
		if s, ok := errObj["message"].(string); ok && strings.TrimSpace(s) != "" {
			return truncatePromptLine(s)
		}
	}
	for _, key := range []string{"message", "error"} {
		if s, ok := props[key].(string); ok && strings.TrimSpace(s) != "" {
			return truncatePromptLine(s)
		}
	}
	return "session.error"
}

// openCodePartText returns the text and owning message id of a text part, or
// empty strings when the part is non-text or carries no message id (without the
// id the author role can't be correlated, so the part must not be recorded).
func openCodePartText(event openCodeEvent) (string, string) {
	part, ok := event.Properties["part"].(map[string]interface{})
	if !ok {
		return "", ""
	}
	if typ, _ := part["type"].(string); typ != "" && typ != "text" {
		return "", ""
	}
	text, _ := part["text"].(string)
	var msgID string
	for _, key := range []string{"messageID", "messageId", "message_id"} {
		if s, ok := part[key].(string); ok && strings.TrimSpace(s) != "" {
			msgID = strings.TrimSpace(s)
			break
		}
	}
	return strings.TrimSpace(text), msgID
}

// openCodeAssistantMessageID returns the message id of a message.updated event
// only when it is assistant-authored. message.updated is the only event that
// carries the role, so it is what confirms a buffered part may be surfaced.
func openCodeAssistantMessageID(event openCodeEvent) string {
	info, ok := event.Properties["info"].(map[string]interface{})
	if !ok {
		return ""
	}
	if role, _ := info["role"].(string); strings.TrimSpace(role) != "assistant" {
		return ""
	}
	id, _ := info["id"].(string)
	return strings.TrimSpace(id)
}

func openCodeNonTextPartActivity(event openCodeEvent) (stateValue, activity, tool string, clearTool bool) {
	part, ok := event.Properties["part"].(map[string]interface{})
	if !ok {
		return "", "", "", false
	}
	typ, _ := part["type"].(string)
	switch typ {
	case "reasoning":
		text, _ := part["text"].(string)
		if strings.TrimSpace(text) == "" {
			return "", "", "", false
		}
		return "working", "Thinking: " + truncatePromptLine(text), "", false
	case "tool":
		return openCodeToolPartActivity(part)
	default:
		return "", "", "", false
	}
}

func openCodeToolPartActivity(part map[string]interface{}) (stateValue, activity, tool string, clearTool bool) {
	tool, _ = part["tool"].(string)
	tool = strings.TrimSpace(tool)
	if tool == "" {
		tool = "tool"
	}
	status := ""
	stateObj, _ := part["state"].(map[string]interface{})
	if stateObj != nil {
		status, _ = stateObj["status"].(string)
	}
	label := openCodeToolPartLabel(tool, stateObj)
	if status == "completed" {
		return "working", "Done: " + label, "", true
	}
	return "working", label, tool, false
}

func openCodeToolPartLabel(tool string, stateObj map[string]interface{}) string {
	input := map[string]interface{}{}
	if stateObj != nil {
		if in, ok := stateObj["input"].(map[string]interface{}); ok {
			input = in
		}
	}
	switch tool {
	case "bash":
		if command, _ := input["command"].(string); strings.TrimSpace(command) != "" {
			return "Bash: " + truncatePromptLine(command)
		}
	case "read":
		if path, _ := input["filePath"].(string); strings.TrimSpace(path) != "" {
			return "Read: " + truncatePath(path)
		}
	case "glob":
		if pattern, _ := input["pattern"].(string); strings.TrimSpace(pattern) != "" {
			return "Glob: " + truncatePromptLine(pattern)
		}
	case "grep":
		if pattern, _ := input["pattern"].(string); strings.TrimSpace(pattern) != "" {
			return "Grep: " + truncatePromptLine(pattern)
		}
	case "websearch", "web_search":
		if query, _ := input["query"].(string); strings.TrimSpace(query) != "" {
			return "Web: " + truncatePromptLine(query)
		}
	}
	if stateObj != nil {
		if title, _ := stateObj["title"].(string); strings.TrimSpace(title) != "" {
			return "Tool: " + truncatePromptLine(title)
		}
	}
	return "Tool: " + truncatePromptLine(tool)
}
