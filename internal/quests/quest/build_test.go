package quest

import (
	"reflect"
	"strings"
	"testing"
)

func TestBuildRoundTripsCanonicalJSON(t *testing.T) {
	q := workedExample()
	out, err := Build(q)
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	// The <script id="quest"> block must round-trip back to the source quest.
	got, err := Parse(out)
	if err != nil {
		t.Fatalf("Parse(Build(q)): %v", err)
	}
	if !reflect.DeepEqual(got, q) {
		t.Errorf("round-trip mismatch:\n got %#v\nwant %#v", got, q)
	}
}

func TestBuildEmitsDocsMeta(t *testing.T) {
	out := string(mustBuild(t, workedExample()))
	wantMeta := []string{
		`<meta name="docs-type" content="quest">`,
		`<meta name="docs-id" content="DEMO-1">`,
		`<meta name="docs-title" content="Widget shell refactor">`,
		`<meta name="docs-status" content="active">`,
		`<meta name="docs-date" content="2026-05-28">`,
		`<meta name="docs-agent" content="codex">`,
		`<meta name="docs-project" content="example-app">`,
		`<meta name="docs-related" content="TASK-1, TASK-2, PR-1">`,
	}
	for _, m := range wantMeta {
		if !strings.Contains(out, m) {
			t.Errorf("built HTML missing meta tag: %s", m)
		}
	}
}

func TestBuildRendersRelatedAsLinks(t *testing.T) {
	out := string(mustBuild(t, workedExample()))
	if !strings.Contains(out, `<a class="rlink" href="https://github.com/acme/web/pull/1" target="_blank" rel="noopener"><span class="rtype">github</span>PR-1</a>`) {
		t.Errorf("related link not rendered as an anchor with type badge:\n%s", out)
	}
}

func TestBuildEmitsBodyBlockHTML(t *testing.T) {
	out := string(mustBuild(t, workedExample()))
	want := []string{
		"<h2>Context</h2>",
		"<p>The legacy shell is duplicated per route and drifts.",
		"<ol><li>Land the layout behind the existing flag</li>",
		`<pre><code class="language-ts">flag.enable(&#39;example-flag&#39;)</code></pre>`,
	}
	for _, w := range want {
		if !strings.Contains(out, w) {
			t.Errorf("built HTML missing block fragment: %q", w)
		}
	}
}

func TestBuildInjectsRichContentByFormat(t *testing.T) {
	out := string(mustBuild(t, workedExample()))
	// mermaid: content injected into a .mermaid div.
	if !strings.Contains(out, `<div class="mermaid">graph LR; legacy --> shared --> cutover</div>`) {
		t.Errorf("mermaid content not injected:\n%s", out)
	}
	// table: raw HTML content injected verbatim.
	if !strings.Contains(out, `<figure class="rich rich-table"><table><tr><td>row</td></tr></table></figure>`) {
		t.Errorf("table content not injected verbatim")
	}
}

func TestBuildImageRichUsesContentAsSrc(t *testing.T) {
	q := &Quest{ID: "X", Title: "t", Summary: "s", Status: StatusWIP,
		Body: []Block{{Type: BlockRich, Format: "image", Fallback: "a chart", Content: "diagram.png"}}}
	out := string(mustBuild(t, q))
	if !strings.Contains(out, `<img src="diagram.png" alt="a chart">`) {
		t.Errorf("image rich block did not use content as src:\n%s", out)
	}
}

func TestBuildNeutralizesScriptClose(t *testing.T) {
	// A rich html block whose content contains </script> must not break the
	// canonical block; the quest must still round-trip.
	q := &Quest{ID: "X", Title: "t", Summary: "s", Status: StatusWIP,
		Body: []Block{{Type: BlockRich, Format: "html", Fallback: "raw", Content: "<b>hi</b></script><i>bye</i>"}}}
	out, err := Build(q)
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	got, err := Parse(out)
	if err != nil {
		t.Fatalf("Parse after embedded </script>: %v", err)
	}
	if !reflect.DeepEqual(got, q) {
		t.Errorf("round-trip with embedded </script> failed:\n got %#v\nwant %#v", got, q)
	}
}

func mustBuild(t *testing.T, q *Quest) []byte {
	t.Helper()
	out, err := Build(q)
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	return out
}
