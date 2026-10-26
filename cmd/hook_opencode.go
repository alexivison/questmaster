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
	"github.com/alexivison/questmaster/internal/workerfeed"
)

const openCodeMinimumVersion = "1.17.11"

type openCodeHookPayload struct {
	Version    string        `json:"version"`
	CapturedAt time.Time     `json:"captured_at"`
	Event      openCodeEvent `json:"event"`
}

type openCodeEvent struct {
	ID         string                 `json:"id"`
	Type       string                 `json:"type"`
	Properties map[string]interface{} `json:"properties"`
}

type openCodePatch struct {
	state              string
	activity           string
	tool               string
	commandKey         string
	toolCallID         string
	failedToolCallID   string
	finishedSubagentID string
	clearTool          bool
	kind               string
	recent             []string
	hasRecent          bool
	sessionID          string
	eventID            string
	statusType         string
	version            string
	occurredAt         time.Time
	parentSessionID    string

	// A part has no role. Keep it until message.updated confirms the matching
	// assistant message, so user prompt text never enters the worker feed.
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
	if handleOpenCodeSubagentEvent(r, sessionID, payload, now, stderr) {
		return
	}
	patch := openCodePatchForEvent(payload)
	patch.occurredAt = now
	if !payload.CapturedAt.IsZero() {
		patch.occurredAt = payload.CapturedAt.UTC()
	}

	ev := state.StateEvent{
		Ts:       now,
		Agent:    "opencode",
		Role:     "agent",
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

	accepted, completed, appendErr, updateErr := updateOpenCodePane(r, sessionID, now, patch, &ev)
	if appendErr != nil {
		fmt.Fprintf(stderr, "questmaster hook opencode: append event: %v\n", appendErr)
	}
	if updateErr != nil {
		fmt.Fprintf(stderr, "questmaster hook opencode: update state: %v\n", updateErr)
		return
	}
	r.recordToolDuration("opencode", completed, stderr)
	if accepted && patch.sessionID != "" {
		captureOpenCodeSessionID(opts.ctx, r, stderr, sessionID, patch.sessionID)
	}
}

func handleOpenCodeSubagentEvent(r *HookRunner, sessionID string, payload openCodeHookPayload, now time.Time, stderr io.Writer) bool {
	event := payload.Event
	info, _ := event.Properties["info"].(map[string]interface{})
	id := openCodeSessionID(event)
	parentID, _ := info["parentID"].(string)
	familiar, _ := info["agent"].(string)
	var pane state.PaneState
	if r.LoadState != nil {
		if ss, err := r.LoadState(sessionID); err == nil && ss != nil {
			pane = ss.Panes["agent"]
		}
	}
	rootID := pane.OpenCodeSessionID

	if event.Type == "session.created" && strings.TrimSpace(parentID) != "" {
		id, _ = info["id"].(string)
		id = state.SanitizeResumeID(strings.TrimSpace(id))
		if rootID != "" && strings.TrimSpace(parentID) == rootID {
			recordOpenCodeSubagentChat(r, sessionID, now, rootID, id, familiar, "subagent_start", event.ID, stderr)
		}
		return true
	}
	if rootID == "" {
		return event.Type != "session.created" || id == "" || strings.TrimSpace(parentID) != ""
	}

	if id == "" || id == rootID {
		return false
	}
	if event.Type == "session.deleted" {
		recordOpenCodeSubagentChat(r, sessionID, now, rootID, id, "", "subagent_stop", event.ID, stderr)
	}
	if event.Type == "session.idle" || event.Type == "session.deleted" {
		return true
	}
	// Child sessions and other non-root sessions must never reach the parent pane.
	// A new root is identified only by session.created after the old root finished.
	if event.Type == "session.created" && strings.TrimSpace(parentID) == "" &&
		(rootID == "" || pane.State == "idle" || pane.State == "done") {
		return false
	}
	return true
}

func recordOpenCodeSubagentChat(r *HookRunner, sessionID string, now time.Time, parentID, childID, familiar, action, eventID string, stderr io.Writer) {
	ev := state.StateEvent{
		Ts: now, Agent: "opencode", AgentID: childID, AgentType: familiar,
		Role: "agent", Action: action, Kind: action,
		Fields: map[string]interface{}{"minimum_version": openCodeMinimumVersion, "subagent_id": childID},
	}
	if eventID != "" {
		ev.Fields["event_id"] = eventID
	}
	_, updateErr := r.updateAndLog(sessionID, &ev, func(ss *state.SessionState) bool {
		pane, exists := ss.Panes["agent"]
		if !exists || pane.OpenCodeSessionID != parentID || parentID == "" {
			return false
		}
		if !updateSubagentChat(&pane, &ev, action, childID, familiar) {
			return false
		}
		ss.SeenAt = now
		ss.Panes["agent"] = pane
		return true
	})
	if updateErr != nil {
		fmt.Fprintf(stderr, "questmaster hook opencode: update state: %v\n", updateErr)
	}
}

func openCodeTaskResultSessionID(event openCodeEvent) string {
	if event.Type == "tool.execute.after" && strings.EqualFold(openCodePropertyString(event.Properties, "tool"), "task") {
		metadata, _ := event.Properties["metadata"].(map[string]interface{})
		if background, _ := metadata["background"].(bool); background {
			return ""
		}
		return cleanSubagentID(openCodePropertyString(metadata, "sessionId"))
	}
	if event.Type != "message.part.updated" {
		return ""
	}
	part, _ := event.Properties["part"].(map[string]interface{})
	if partType, _ := part["type"].(string); partType == "tool" && strings.EqualFold(openCodePropertyString(part, "tool"), "task") {
		toolState, _ := part["state"].(map[string]interface{})
		status := openCodePropertyString(toolState, "status")
		metadata, _ := toolState["metadata"].(map[string]interface{})
		background, _ := metadata["background"].(bool)
		if !background && (status == "completed" || status == "error") {
			return cleanSubagentID(openCodePropertyString(metadata, "sessionId"))
		}
	}
	return ""
}

func cleanSubagentID(id string) string {
	return state.SanitizeResumeID(strings.TrimSpace(id))
}

func openCodePropertyString(values map[string]interface{}, key string) string {
	value, _ := values[key].(string)
	return value
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
		kind:               event.Type,
		sessionID:          openCodeSessionID(event),
		eventID:            strings.TrimSpace(event.ID),
		version:            openCodeVersion(payload),
		finishedSubagentID: openCodeTaskResultSessionID(event),
	}
	if info, _ := event.Properties["info"].(map[string]interface{}); info != nil {
		patch.parentSessionID, _ = info["parentID"].(string)
	}

	switch event.Type {
	case "session.created":
		patch.state = "starting"
		patch.activity = "Session created"
		patch.clearTool = true
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
		patch.commandKey = toolCommandKey("opencode", patch.tool, openCodeToolInput(event))
		patch.toolCallID = openCodeToolCallID(event)
		patch.activity = "Tool: " + patch.tool
	case "tool.execute.after":
		patch.tool = openCodeToolLabel(event)
		patch.activity = "Tool done: " + openCodeToolLabel(event)
		patch.toolCallID = openCodeToolCallID(event)
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
		patch.failedToolCallID = openCodeToolPartErrorCallID(event)
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
		p.sessionID != "" || p.partMsgID != "" || p.assistantMsgID != "" || p.failedToolCallID != ""
}

func updateOpenCodePane(r *HookRunner, sessionID string, now time.Time, patch openCodePatch, ev *state.StateEvent) (bool, *completedTool, error, error) {
	accepted := false
	var completed *completedTool
	appendErr, updateErr := r.updateAndLog(sessionID, ev, func(ss *state.SessionState) bool {
		if !patch.mutatesState() {
			return false
		}
		role := "agent"
		ss.SeenAt = now
		pane, exists := ss.Panes[role]
		if !exists {
			pane = state.PaneState{Role: role, Agent: "opencode"}
		}
		if patch.sessionID != "" && pane.OpenCodeSessionID != "" && pane.OpenCodeSessionID != patch.sessionID {
			newRootSession := patch.kind == "session.created" && patch.parentSessionID == "" &&
				(pane.State == "idle" || pane.State == "done")
			if !newRootSession {
				return false
			}
			pane.ActiveSubagents = nil
			pane.ActiveSubagentStartedAt = nil
		}
		accepted = true
		prev := struct {
			State, Activity, Tool, LastKind string
			LastEvent, WorkingSince         time.Time
			Recent                          []string
			OpenCodeSessionID               string
			PendingPartMsgID                string
			PendingPartText                 string
			PendingFinalMessage             string
			LastChatStatus                  string
			LastChatAt                      time.Time
		}{pane.State, pane.Activity, pane.Tool, pane.LastKind, pane.LastEvent, pane.WorkingSince, pane.Recent, pane.OpenCodeSessionID, pane.PendingPartMsgID, pane.PendingPartText, pane.PendingFinalMessage, pane.LastChatStatus, pane.LastChatAt}
		prevRunningTools := slices.Clone(pane.RunningTools)
		prevNarration := pane.Narration
		if patch.finishedSubagentID != "" && patch.sessionID == pane.OpenCodeSessionID {
			updateSubagentChat(&pane, ev, "subagent_stop", patch.finishedSubagentID, "")
		}

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
		if patch.clearTool && patch.kind != "tool.execute.after" {
			if patch.kind == "message.part.updated" {
				pane.Tool = ""
				if len(pane.RunningTools) > 0 {
					pane.Tool = pane.RunningTools[len(pane.RunningTools)-1].Tool
				}
			} else {
				state.ClearRunningTools(&pane)
			}
		}
		if patch.kind == "tool.execute.before" && !preservePermissionBlock {
			state.StartRunningTool(&pane, patch.tool, patch.toolCallID, patch.commandKey, patch.occurredAt)
		}
		if patch.kind == "tool.execute.after" {
			if ended, duration, matched := state.EndRunningTool(&pane, patch.tool, patch.toolCallID, patch.occurredAt); matched {
				completed = &completedTool{tool: ended.Tool, command: ended.Command, duration: duration, waitedForInput: ended.WaitedForInput}
			}
		}
		if patch.failedToolCallID != "" {
			state.EndRunningTool(&pane, "", patch.failedToolCallID, patch.occurredAt)
		}

		if setState != "" {
			pane.State = setState
		}
		if pane.State == "blocked" {
			state.MarkRunningToolsWaitedForInput(&pane)
		}
		normalizeHookWorkingSince(&pane, prev.State, prev.LastEvent, now)
		if setActivity != "" {
			pane.Activity = setActivity
		}
		if setTool != "" && patch.kind != "tool.execute.after" {
			pane.Tool = setTool
		} else if clearTool && patch.kind != "tool.execute.after" && patch.kind != "message.part.updated" {
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
			pane.PendingFinalMessage = workerfeed.CapText(pane.PendingPartText)
			pane.PendingPartMsgID = ""
			pane.PendingPartText = ""
		}
		if patch.kind == "tool.execute.before" {
			pane.PendingFinalMessage = ""
		}
		if lastKind != "" {
			pane.LastKind = lastKind
		}
		pane.LastEvent = now
		pane.Seq = now.UnixNano()
		pane.Agent = "opencode"
		pane.Role = role
		if !preservePermissionBlock {
			if patch.kind == "session.idle" && pane.State == "done" && pane.PendingFinalMessage != "" {
				addChatEntry(ev, &pane, "message", pane.PendingFinalMessage)
				pane.PendingFinalMessage = ""
			}
			if patch.kind == "tool.execute.before" {
				if pane.State != prev.State {
					addVisibleStatus(ev, &pane, pane.State)
				}
				if !isSubagentSpawnTool("opencode", patch.tool) {
					addChatEntry(ev, &pane, "action", patch.tool)
				}
			}
			if patch.kind != "tool.execute.before" && pane.State != prev.State {
				addVisibleStatus(ev, &pane, pane.State)
			}
		}
		ss.Panes[role] = pane

		return pane.State != prev.State ||
			pane.Activity != prev.Activity ||
			pane.Tool != prev.Tool ||
			pane.LastKind != prev.LastKind ||
			!pane.WorkingSince.Equal(prev.WorkingSince) ||
			!slices.Equal(pane.Recent, prev.Recent) ||
			pane.OpenCodeSessionID != prev.OpenCodeSessionID ||
			pane.PendingPartMsgID != prev.PendingPartMsgID ||
			pane.PendingPartText != prev.PendingPartText ||
			pane.PendingFinalMessage != prev.PendingFinalMessage ||
			pane.LastChatStatus != prev.LastChatStatus ||
			!pane.LastChatAt.Equal(prev.LastChatAt) ||
			pane.Narration != prevNarration ||
			!slices.Equal(pane.RunningTools, prevRunningTools)
	})
	return accepted, completed, appendErr, updateErr
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
	if tool, ok := event.Properties["tool"].(string); ok && strings.TrimSpace(tool) != "" {
		return truncatePromptLine(tool)
	}
	return "tool"
}

func openCodeToolCallID(event openCodeEvent) string {
	if id, ok := event.Properties["callID"].(string); ok {
		return strings.TrimSpace(id)
	}
	return ""
}

func openCodeToolInput(event openCodeEvent) interface{} {
	return event.Properties["args"]
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
	if status == "error" {
		return "working", "Failed: " + label, "", false
	}
	if status == "completed" {
		return "working", "Done: " + label, "", true
	}
	return "working", label, tool, false
}

func openCodeToolPartErrorCallID(event openCodeEvent) string {
	part, ok := event.Properties["part"].(map[string]interface{})
	if !ok || part["type"] != "tool" {
		return ""
	}
	stateObj, _ := part["state"].(map[string]interface{})
	if stateObj == nil || stateObj["status"] != "error" {
		return ""
	}
	id, _ := part["callID"].(string)
	return strings.TrimSpace(id)
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
