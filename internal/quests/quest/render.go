package quest

import (
	"bytes"
	"encoding/json"
	"fmt"
	"html"
)

// Render produces a complete, valid quest HTML document for q: the canonical
// JSON head in an id="quest-head" block plus a readable body (goal, context,
// steps, gates). The output always Parses and Validates back to q, so
// `quest new` writes a conformant file and the planner can elaborate the body.
//
// The head is json.Marshal output, which escapes <, >, & as \uXXXX, so the
// embedded JSON never disturbs HTML parsing; the body's authored text is
// HTML-escaped.
func Render(q Quest) ([]byte, error) {
	if err := Validate(q); err != nil {
		return nil, err
	}
	headJSON, err := json.MarshalIndent(q, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("marshal quest head: %w", err)
	}

	var b bytes.Buffer
	esc := html.EscapeString

	fmt.Fprintf(&b, `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Quest · %s</title>
<style>
  :root{--bg:#0f0d0a;--ink:#ece4d3;--muted:#a89e89;--faint:#776d5b;--line:#2d271b;--amber:#ffb454;--green:#8fd88f;--cyan:#5fc9d8;--mono:ui-monospace,Menlo,monospace;--serif:Georgia,serif;}
  *{box-sizing:border-box;}
  body{margin:0;background:var(--bg);color:var(--ink);font-family:var(--serif);line-height:1.6;}
  .wrap{max-width:980px;margin:0 auto;padding:32px 24px 80px;}
  .kicker{font-family:var(--mono);font-size:11px;letter-spacing:.24em;text-transform:uppercase;color:var(--amber);}
  h1{font-family:var(--mono);font-size:30px;margin:.3em 0 .2em;}
  .goal{font-style:italic;font-size:19px;max-width:46ch;}
  .refs{font-family:var(--mono);font-size:12px;color:var(--cyan);margin-top:12px;}
  h2{font-family:var(--mono);font-size:12px;letter-spacing:.14em;text-transform:uppercase;color:var(--amber);margin:28px 0 8px;}
  ul.steps{list-style:none;padding:0;} ul.steps li{padding:7px 0 7px 24px;position:relative;border-bottom:1px solid var(--line);}
  ul.steps li::before{content:"○";position:absolute;left:2px;color:var(--faint);}
  .gate{font-family:var(--mono);font-size:14px;padding:8px 0;border-bottom:1px solid var(--line);}
  .gtag{font-size:10px;text-transform:uppercase;padding:2px 6px;border-radius:999px;color:#0f0d0a;}
  .gtag.auto{background:var(--green);} .gtag.toggle{background:var(--cyan);}
  pre{background:#1a160f;border:1px solid rgba(95,201,216,.32);border-radius:10px;padding:13px;overflow:auto;}
  code#quest-head{font-family:var(--mono);font-size:12px;color:var(--ink);white-space:pre;}
  footer{margin-top:32px;border-top:1px solid var(--line);padding-top:14px;font-family:var(--mono);font-size:11px;color:var(--faint);}
</style>
</head>
<body>
<div class="wrap">
  <header>
    <div class="kicker">Quest · %s</div>
    <h1>%s</h1>
    <p class="goal">%s</p>
`, esc(q.ID), esc(q.ID), esc(q.ID), esc(q.Goal))

	if len(q.Context) > 0 {
		b.WriteString(`    <div class="refs">`)
		for i, ref := range q.Context {
			if i > 0 {
				b.WriteString(" · ")
			}
			b.WriteString(esc(ref))
		}
		b.WriteString("</div>\n")
	}
	b.WriteString("  </header>\n\n  <main class=\"plan\">\n")

	if len(q.Next) > 0 {
		b.WriteString("    <h2>Steps</h2>\n    <ul class=\"steps\">\n")
		for _, step := range q.Next {
			fmt.Fprintf(&b, "      <li>%s</li>\n", esc(step))
		}
		b.WriteString("    </ul>\n")
	}

	if len(q.Gates) > 0 {
		b.WriteString("    <h2>Gates</h2>\n")
		for _, g := range q.Gates {
			detail := ""
			if g.Check != "" {
				detail = " — " + esc(g.Check)
			}
			if g.Before != "" {
				detail += " (before " + esc(g.Before) + ")"
			}
			fmt.Fprintf(&b, "    <div class=\"gate\"><span class=\"gtag %s\">%s</span> %s%s</div>\n",
				esc(string(g.Type)), esc(string(g.Type)), esc(g.Name), detail)
		}
	}

	b.WriteString("  </main>\n\n")
	fmt.Fprintf(&b, "  <pre><code id=\"%s\">%s</code></pre>\n", HeadElementID, headJSON)
	b.WriteString(`  <footer>one file · canonical head above · authored body is the plan — keep them in agreement</footer>
</div>
</body>
</html>
`)

	return b.Bytes(), nil
}
