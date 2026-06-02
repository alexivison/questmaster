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
		writeMeta(&b, "docs-related", strings.Join(q.Related, ", "))
	}

	fmt.Fprintf(&b, "<title>%s</title>\n", html.EscapeString(q.ID+" · "+q.Title))
	b.WriteString(buildStyle)
	b.WriteString("</head>\n<body>\n")

	b.WriteString(`<main class="quest">` + "\n")

	// Header: id + status, title, meta, objective.
	b.WriteString(`<header class="qhead">` + "\n")
	fmt.Fprintf(&b, `<div class="hl"><span class="hid">%s</span><span class="hst hst-%s">%s</span></div>`+"\n",
		html.EscapeString(q.ID), html.EscapeString(string(q.Status)), html.EscapeString(string(q.Status)))
	fmt.Fprintf(&b, `<h1 class="htitle">%s</h1>`+"\n", html.EscapeString(q.Title))
	if meta := metaLine(q); meta != "" {
		fmt.Fprintf(&b, `<div class="frm">%s</div>`+"\n", html.EscapeString(meta))
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
				glyphGate, html.EscapeString(g.Name), html.EscapeString(string(g.Type)), html.EscapeString(gateCheckText(g)))
		}
		b.WriteString("</tbody></table>\n")
		b.WriteString(`<p class="gnote">read by eye this stage · you stamp it done when they hold</p>` + "\n")
		b.WriteString("</section>\n")
	}

	// Related.
	if len(q.Related) > 0 {
		b.WriteString(`<section class="related"><h2>Related</h2><p class="rel">`)
		for i, r := range q.Related {
			if i > 0 {
				b.WriteString(" ")
			}
			fmt.Fprintf(&b, `<span>%s</span>`, html.EscapeString(r))
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

	// Collapsible Source panel: the same JSON, pretty-printed for audit.
	b.WriteString(`<details class="source"><summary>Source</summary><pre>`)
	b.WriteString(html.EscapeString(string(pretty)))
	b.WriteString("</pre></details>\n")

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
.quest{max-width:820px;margin:0 auto;padding:34px 22px 60px;}
.hl{display:flex;align-items:baseline;gap:10px;}
.hid{color:var(--cyan);font-weight:700;font-size:15px;}
.hst{margin-left:auto;font-size:12px;letter-spacing:.08em;color:var(--muted);}
.hst-active{color:var(--green);}.hst-done{color:var(--dim);}.hst-wip{color:var(--muted);font-style:italic;}
.htitle{font-weight:600;font-size:18px;margin:4px 0 6px;color:#eef3fb;}
.frm{color:var(--dim);font-size:12px;margin:0 0 10px;}
h2{color:var(--amber);font-size:11px;letter-spacing:.16em;text-transform:uppercase;margin:24px 0 8px;}
.objective p{color:var(--fg);max-width:64ch;}
.gates{border-collapse:collapse;font-size:13px;}
.gates td{padding:2px 14px 2px 0;vertical-align:baseline;}
.gates .dia{color:var(--faint);}.gates .gn{color:#dbe4f1;}.gates .gt,.gates .gc{color:var(--dim);}
.gnote{color:var(--faint);font-size:11px;font-style:italic;}
.rel span{color:var(--cyan);margin-right:12px;}
.body p{color:var(--muted);max-width:64ch;}
.body h1,.body h2,.body h3,.body h4,.body h5,.body h6{color:#dbe4f1;text-transform:none;letter-spacing:0;}
.body pre{background:#0a0d13;border:1px solid var(--line);border-radius:5px;padding:10px 12px;overflow:auto;color:var(--fg);}
.rich{margin:12px 0;border:1px dashed var(--line);border-radius:5px;padding:10px 12px;}
.source{margin-top:30px;border-top:1px solid var(--line);padding-top:12px;color:var(--dim);}
.source summary{cursor:pointer;color:var(--muted);}
.source pre{overflow:auto;color:var(--dim);font-size:12px;}
</style>
`
