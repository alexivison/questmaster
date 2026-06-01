package main

import (
	"fmt"
	"html"
	"os"
	"path/filepath"
	"strings"

	"github.com/alexivison/questmaster/internal/quests/quest"
	"github.com/alexivison/questmaster/internal/quests/runtime"
	"github.com/alexivison/questmaster/internal/state"
)

// loadQuestRuntime loads a quest's runtime record and overlays live observed
// state from the session spine: the sessions whose quest hat is this id, with
// their current agent/state. This is the Stage-1 quest↔session link — pure
// observed state, no loop required. Gate results and PR stay as recorded
// (harness-written in Stage 2).
func (e *env) loadQuestRuntime(id string) (*runtime.RuntimeRecord, error) {
	rec, err := e.runtimeStore().Load(id)
	if err != nil {
		return nil, err
	}
	manifests, derr := state.OpenStore(e.paths.StateRoot()).DiscoverSessions()
	if derr != nil {
		return rec, nil // best-effort overlay
	}
	var refs []runtime.SessionRef
	for _, m := range manifests {
		if m.QuestID != id {
			continue
		}
		ref := runtime.SessionRef{ID: m.SessionID, Role: sessionRole(m), Agent: primaryAgent(m)}
		if ss, e2 := state.LoadSessionState(m.SessionID); e2 == nil && ss != nil {
			if p, ok := primaryPane(ss); ok {
				ref.State = p.State
				if ref.Agent == "" {
					ref.Agent = p.Agent
				}
			}
		}
		refs = append(refs, ref)
	}
	if len(refs) > 0 {
		rec.Sessions = refs
		if rec.Status == runtime.StatusDraft {
			rec.Status = runtime.StatusInProgress // observed: a session is on it
		}
	}
	return rec, nil
}

func primaryAgent(m state.Manifest) string {
	for _, a := range m.Agents {
		if a.Role == "primary" {
			return a.Name
		}
	}
	if len(m.Agents) > 0 {
		return m.Agents[0].Name
	}
	return ""
}

func primaryPane(ss *state.SessionState) (state.PaneState, bool) {
	if p, ok := ss.Panes["primary"]; ok {
		return p, true
	}
	for _, p := range ss.Panes {
		return p, true
	}
	return state.PaneState{}, false
}

// openWithBanner renders a view-time copy of the quest with a live status
// banner injected (from head + runtime) and opens it in the browser. The stored
// quest file is never mutated — the banner is view-time, per the spec.
func (e *env) openWithBanner(id string) error {
	doc, err := e.store().Load(id)
	if err != nil {
		return err
	}
	rec, err := e.loadQuestRuntime(id)
	if err != nil {
		return err
	}
	viewed := injectBanner(doc.Body, statusBanner(doc.Head, rec))

	viewPath := filepath.Join(os.TempDir(), "quests-view-"+sanitizeForFile(id)+".html")
	if err := os.WriteFile(viewPath, viewed, 0o644); err != nil {
		return fmt.Errorf("write view file: %w", err)
	}
	return e.openInBrowser(viewPath)
}

// injectBanner inserts the banner HTML immediately after the <body> tag (or
// prepends it if there is no body tag).
func injectBanner(body []byte, banner string) []byte {
	s := string(body)
	lower := strings.ToLower(s)
	i := strings.Index(lower, "<body")
	if i < 0 {
		return []byte(banner + s)
	}
	gt := strings.IndexByte(s[i:], '>')
	if gt < 0 {
		return []byte(banner + s)
	}
	at := i + gt + 1
	return []byte(s[:at] + "\n" + banner + s[at:])
}

// statusBanner builds the view-time status strip from the head + runtime
// record. Inline styles keep it consistent regardless of the quest's own CSS.
func statusBanner(q quest.Quest, rec *runtime.RuntimeRecord) string {
	esc := html.EscapeString
	var b strings.Builder
	b.WriteString(`<div style="position:sticky;top:0;z-index:99;font-family:ui-monospace,Menlo,monospace;font-size:12px;background:#14110c;color:#a89e89;border-bottom:1px solid #2d271b;padding:8px 14px;display:flex;flex-wrap:wrap;align-items:center;gap:6px 14px;">`)
	b.WriteString(`<span style="color:#534b3d;letter-spacing:.12em;text-transform:uppercase;font-size:9px;">live ▾</span>`)

	status := string(runtime.StatusDraft)
	if rec != nil && rec.Status != "" {
		status = string(rec.Status)
	}
	b.WriteString(`<span>` + esc(status) + `</span>`)

	// Gates with their result glyph.
	for _, g := range q.Gates {
		result := ""
		if rec != nil {
			result = rec.GateResults[g.Name]
		}
		glyph, color := gateGlyphHTML(string(g.Type), result)
		fmt.Fprintf(&b, `<span style="color:%s;">%s %s</span>`, color, glyph, esc(g.Name))
	}

	// Sessions on the quest.
	if rec != nil {
		for _, s := range rec.Sessions {
			glyph, color := sessionGlyphHTML(s.State)
			label := s.ID
			if s.Agent != "" {
				label = s.Agent
			}
			fmt.Fprintf(&b, `<span style="color:%s;">%s %s</span>`, color, glyph, esc(label+" "+s.State))
		}
	}

	// PR (right-aligned).
	if rec != nil && rec.PR != nil {
		fmt.Fprintf(&b, `<span style="color:#b89cf0;margin-left:auto;">PR #%d ↗</span>`, rec.PR.Number)
	}
	b.WriteString(`</div>`)
	return b.String()
}

func gateGlyphHTML(gtype, result string) (glyph, color string) {
	switch result {
	case "green":
		return "✓", "#8fd88f"
	case "failed":
		return "✗", "#e87b6e"
	case "pending":
		return "◐", "#ffb454"
	}
	if gtype == "toggle" {
		return "☐", "#5fc9d8"
	}
	return "·", "#776d5b"
}

func sessionGlyphHTML(stateStr string) (glyph, color string) {
	switch stateStr {
	case "working", "starting", "busy":
		return "◐", "#ffb454"
	case "done":
		return "●", "#8fd88f"
	case "blocked", "error", "stuck":
		return "!", "#e87b6e"
	default:
		return "○", "#776d5b"
	}
}

func sanitizeForFile(id string) string {
	var b strings.Builder
	for _, r := range id {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '-', r == '_', r == '.':
			b.WriteRune(r)
		default:
			b.WriteByte('-')
		}
	}
	return b.String()
}
