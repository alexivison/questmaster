package quest

import (
	"fmt"
	"html"
	"strconv"
	"strings"
)

// Build renders a quest to a self-contained, browser-openable HTML document.
// It is the sibling of the terminal renderer: the same body-block dispatch,
// HTML output. The canonical JSON is written verbatim into the
// <script type="application/json" id="quest"> block (the source of truth,
// machine-read back by Parse), the docs-style <meta> frontmatter is emitted so
// a future quest index can read the built files, and a collapsible Source panel
// pretty-prints the same JSON for in-browser audit. Runs on save and on
// `quest open`.
func Build(q *Quest) ([]byte, error) {
	pretty, err := Marshal(q)
	if err != nil {
		return nil, err
	}

	var b strings.Builder
	b.WriteString("<!doctype html>\n<html lang=\"en\">\n<head>\n")
	b.WriteString(`<meta charset="utf-8">` + "\n")
	b.WriteString(`<meta name="viewport" content="width=device-width, initial-scale=1">` + "\n")

	// docs-style frontmatter, emitted from the JSON so a quest index reads the
	// built files the way docs-index reads the plan docs.
	writeMeta(&b, "docs-type", "quest")
	writeMeta(&b, "docs-id", q.ID)
	writeMeta(&b, "docs-title", q.Title)
	writeMeta(&b, "docs-status", string(q.Status))
	writeMeta(&b, "docs-summary", q.Summary)
	writeMeta(&b, "docs-date", q.Date)
	writeMeta(&b, "docs-agent", q.Agent)
	writeMeta(&b, "docs-project", q.Project)
	if len(q.Related) > 0 {
		writeMeta(&b, "docs-related", strings.Join(relatedTitles(q.Related), ", "))
	}

	fmt.Fprintf(&b, "<title>%s</title>\n", html.EscapeString(q.ID+" · "+q.Title))
	b.WriteString(buildStyle)
	b.WriteString("</head>\n<body>\n")
	b.WriteString(`<div class="layout">` + "\n")

	b.WriteString(`<main class="quest">` + "\n")

	// Header: id + status, title, meta, objective.
	b.WriteString(`<header class="qhead">` + "\n")
	fmt.Fprintf(&b, `<div class="hl"><span class="hid">%s</span><span class="hst hst-%s">%s</span></div>`+"\n",
		html.EscapeString(q.ID), html.EscapeString(string(q.Status)), html.EscapeString(string(q.Status)))
	fmt.Fprintf(&b, `<h1 class="htitle">%s</h1>`+"\n", html.EscapeString(q.Title))
	if tags := htmlMetaTags(q); tags != "" {
		fmt.Fprintf(&b, `<div class="frm">%s</div>`+"\n", tags)
	}
	b.WriteString("</header>\n")

	fmt.Fprintf(&b, `<section class="objective"><h2>Objective</h2><p>%s</p></section>`+"\n",
		html.EscapeString(q.Summary))

	// Definition of done.
	if len(q.Gates) > 0 {
		b.WriteString(`<section class="dod"><h2>Definition of done</h2>` + "\n")
		b.WriteString(`<table class="gates"><tbody>` + "\n")
		for _, g := range q.Gates {
			fmt.Fprintf(&b, `<tr><td class="dia">%s</td><td class="gn">%s</td><td class="gt">%s</td><td class="gc">%s</td></tr>`+"\n",
				html.EscapeString(gateGlyph(g)), html.EscapeString(g.Name), html.EscapeString(string(g.Type)), html.EscapeString(gateCheckText(g)))
		}
		b.WriteString("</tbody></table>\n")
		b.WriteString(`<p class="gnote">toggles you check · autos qm runs · you stamp it done</p>` + "\n")
		b.WriteString("</section>\n")
	}

	// Related — structured links (type · title · url), rendered as anchors.
	if len(q.Related) > 0 {
		b.WriteString(`<section class="related"><h2>Related</h2><p class="rel">` + svgLink)
		for _, r := range q.Related {
			b.WriteString(relatedLinkHTML(r))
		}
		b.WriteString("</p></section>\n")
	}

	// Body.
	b.WriteString(`<section class="body">` + "\n")
	for _, blk := range q.Body {
		b.WriteString(buildBlock(blk))
		b.WriteString("\n")
	}
	b.WriteString("</section>\n")

	b.WriteString("</main>\n")

	// Source panel: right column, open by default and sticky, so the canonical
	// JSON stays in view while you scroll the rendered plan.
	b.WriteString(`<aside class="source"><h2>Source</h2><pre>`)
	b.WriteString(html.EscapeString(string(pretty)))
	b.WriteString("</pre></aside>\n")

	b.WriteString("</div>\n") // .layout

	// Canonical JSON — the source of truth, read back by Parse. "</" is
	// neutralized to "<\/" so an embedded </script> can never close the block
	// early; it remains valid JSON (\/ is an escaped forward slash).
	b.WriteString(`<script type="application/json" id="quest">` + "\n")
	b.WriteString(strings.ReplaceAll(string(pretty), "</", `<\/`))
	b.WriteString("\n</script>\n</body>\n</html>\n")

	return []byte(b.String()), nil
}

// buildBlock dispatches one body block to its HTML. Unknown types degrade to
// their fallback (or a comment), mirroring the terminal renderer.
func buildBlock(b Block) string {
	switch b.Type {
	case BlockHeading:
		lvl := b.Level
		if lvl < 1 {
			lvl = 1
		}
		if lvl > 6 {
			lvl = 6
		}
		tag := "h" + strconv.Itoa(lvl)
		return fmt.Sprintf("<%s>%s</%s>", tag, html.EscapeString(b.Text), tag)
	case BlockText:
		return "<p>" + html.EscapeString(b.Text) + "</p>"
	case BlockList:
		tag := "ul"
		if b.Ordered {
			tag = "ol"
		}
		var sb strings.Builder
		fmt.Fprintf(&sb, "<%s>", tag)
		for _, it := range b.Items {
			sb.WriteString("<li>" + html.EscapeString(it) + "</li>")
		}
		fmt.Fprintf(&sb, "</%s>", tag)
		return sb.String()
	case BlockCode:
		cls := ""
		if b.Lang != "" {
			cls = ` class="language-` + html.EscapeString(b.Lang) + `"`
		}
		return "<pre><code" + cls + ">" + html.EscapeString(b.Text) + "</code></pre>"
	case BlockRich:
		return buildRich(b)
	default:
		fb := b.Fallback
		if fb == "" {
			fb = "[unsupported block]"
		}
		return `<div class="rich rich-unsupported">` + html.EscapeString(fb) + "</div>"
	}
}

// buildRich injects a rich block's content per its format. mermaid/table/
// chart/html inject the raw content payload; image treats content as a src.
func buildRich(b Block) string {
	switch b.Format {
	case "mermaid":
		return `<figure class="rich rich-mermaid"><div class="mermaid">` + b.Content + "</div></figure>"
	case "table":
		return `<figure class="rich rich-table">` + b.Content + "</figure>"
	case "chart":
		return `<figure class="rich rich-chart">` + b.Content + "</figure>"
	case "image":
		return `<figure class="rich rich-image"><img src="` + html.EscapeString(b.Content) + `" alt="` + html.EscapeString(b.Fallback) + `"></figure>`
	case "html":
		return `<figure class="rich rich-html">` + b.Content + "</figure>"
	default:
		return `<figure class="rich">` + html.EscapeString(b.Fallback) + "</figure>"
	}
}

// Inline SVG tag icons (feather-style, stroke=currentColor) so the HTML carries
// the same iconography as the terminal without depending on a nerd font. The
// agent is shown as a brand-coloured dot (parity with the terminal's coloured
// agent glyph).
const (
	svgFolder   = `<svg class="ic" viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></svg>`
	svgCalendar = `<svg class="ic" viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="18" rx="2" ry="2"/><line x1="16" y1="2" x2="16" y2="6"/><line x1="8" y1="2" x2="8" y2="6"/><line x1="3" y1="10" x2="21" y2="10"/></svg>`
	svgLink     = `<svg class="ic" viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/></svg>`
)

// htmlMetaTags renders the glyph-tagged frontmatter (project · date · agent),
// mirroring the terminal meta line; "type" is omitted (all are quests).
func htmlMetaTags(q *Quest) string {
	var sb strings.Builder
	if q.Project != "" {
		fmt.Fprintf(&sb, `<span class="tag">%s%s</span>`, svgFolder, html.EscapeString(q.Project))
	}
	if q.Date != "" {
		fmt.Fprintf(&sb, `<span class="tag">%s%s</span>`, svgCalendar, html.EscapeString(q.Date))
	}
	if q.Agent != "" {
		fmt.Fprintf(&sb, `<span class="tag"><span class="dot" style="background:%s"></span>%s</span>`,
			agentDotColor(q.Agent), html.EscapeString(q.Agent))
	}
	return sb.String()
}

// relatedLinkHTML renders one related reference: an anchor when it has a URL,
// otherwise plain text, with an optional dim type badge ("linear", "github", …).
func relatedLinkHTML(r RelatedLink) string {
	badge := ""
	if r.Type != "" {
		badge = `<span class="rtype">` + html.EscapeString(r.Type) + `</span>`
	}
	title := html.EscapeString(r.Title)
	if r.URL != "" {
		return fmt.Sprintf(`<a class="rlink" href="%s" target="_blank" rel="noopener">%s%s</a>`,
			html.EscapeString(r.URL), badge, title)
	}
	return `<span class="rlink">` + badge + title + `</span>`
}

// agentDotColor matches the terminal's per-agent brand hues.
func agentDotColor(name string) string {
	switch name {
	case "claude":
		return "#CC785C"
	case "codex":
		return "#1A73E8"
	case "pi":
		return "#A371F7"
	default:
		return "#7e8a9e"
	}
}

func writeMeta(b *strings.Builder, name, content string) {
	if content == "" {
		return
	}
	fmt.Fprintf(b, `<meta name="%s" content="%s">`+"\n", name, html.EscapeString(content))
}

// buildStyle is a compact, terminal-honest stylesheet: one flat background,
// monospace, structure from colour and thin lines. Styling polish is a
// non-goal this stage; this keeps the built file legible when opened.
const buildStyle = `<style>
:root{--bg:#0c1017;--line:#222a38;--fg:#c2ccdb;--muted:#7e8a9e;--dim:#5a6577;--faint:#3a4354;
--cyan:#4ec3d6;--amber:#e6b860;--green:#82d273;--mono:'JetBrains Mono',ui-monospace,Menlo,Consolas,monospace;}
*{box-sizing:border-box}
html,body{margin:0;background:var(--bg);color:var(--fg);font-family:var(--mono);font-size:13px;line-height:1.6;}
/* Two columns: the wider rendered plan on the left, sticky Source on the right. */
.layout{max-width:1260px;margin:0 auto;padding:30px 24px 60px;display:grid;
  grid-template-columns:minmax(0,1fr) 360px;gap:36px;align-items:start;}
@media(max-width:900px){.layout{grid-template-columns:1fr;}}
.source{position:sticky;top:18px;max-height:calc(100vh - 36px);overflow:auto;
  border:1px solid var(--line);border-radius:6px;padding:12px 14px;color:var(--dim);}
.source h2{margin:0 0 8px;}
.source pre{white-space:pre;overflow:auto;color:var(--dim);font-size:12px;margin:0;line-height:1.5;}
.quest{min-width:0;}
.hl{display:flex;align-items:baseline;gap:10px;}
.hid{color:var(--cyan);font-weight:700;font-size:16px;}
.hst{margin-left:auto;font-size:12px;letter-spacing:.08em;color:var(--muted);}
.hst-active{color:var(--green);}.hst-done{color:var(--dim);}.hst-wip{color:var(--muted);font-style:italic;}
.htitle{font-weight:600;font-size:20px;margin:4px 0 8px;color:#eef3fb;}
.frm{color:var(--muted);font-size:12.5px;margin:0 0 10px;display:flex;flex-wrap:wrap;gap:4px 18px;}
.frm .tag{display:inline-flex;align-items:center;}
.frm .ic{margin-right:6px;color:var(--dim);}
.frm .dot{width:9px;height:9px;border-radius:50%;margin-right:6px;display:inline-block;}
h2{color:var(--amber);font-size:11px;letter-spacing:.16em;text-transform:uppercase;margin:24px 0 8px;}
.objective p{color:var(--fg);max-width:72ch;}
.gates{border-collapse:collapse;font-size:13px;}
.gates td{padding:2px 14px 2px 0;vertical-align:baseline;}
.gates .dia{color:var(--faint);}.gates .gn{color:#dbe4f1;}.gates .gt,.gates .gc{color:var(--dim);}
.gnote{color:var(--faint);font-size:11px;font-style:italic;}
.rel{display:flex;align-items:center;flex-wrap:wrap;gap:6px 14px;}
.rel .ic{color:var(--dim);}
.rlink{color:var(--cyan);text-decoration:none;display:inline-flex;align-items:center;}
.rlink:hover{text-decoration:underline;}
.rtype{color:var(--dim);font-size:10px;letter-spacing:.08em;text-transform:uppercase;
  border:1px solid var(--line);border-radius:3px;padding:0 5px;margin-right:6px;}
.body p{color:var(--muted);max-width:72ch;}
.body h1,.body h2,.body h3,.body h4,.body h5,.body h6{color:#dbe4f1;text-transform:none;letter-spacing:0;}
.body pre{background:#0a0d13;border:1px solid var(--line);border-radius:5px;padding:10px 12px;overflow:auto;color:var(--fg);}
.rich{margin:12px 0;border:1px dashed var(--line);border-radius:5px;padding:10px 12px;}
</style>
`
