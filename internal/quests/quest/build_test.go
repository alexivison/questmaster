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
	want := *q
	want.Agent = ""
	if !reflect.DeepEqual(got, &want) {
		t.Errorf("round-trip mismatch:\n got %#v\nwant %#v", got, &want)
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
		`<meta name="docs-project" content="example-app">`,
		`<meta name="docs-related" content="TASK-1, TASK-2, PR-1">`,
	}
	for _, m := range wantMeta {
		if !strings.Contains(out, m) {
			t.Errorf("built HTML missing meta tag: %s", m)
		}
	}
	if strings.Contains(out, "docs-agent") || strings.Contains(out, ">codex</span>") {
		t.Fatalf("built HTML should not persist or display an authored agent:\n%s", out)
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

func TestBuildRendersAnchoredComments(t *testing.T) {
	q := &Quest{
		ID:      "COMMENT-1",
		Title:   "Commented",
		Summary: "s",
		Status:  StatusActive,
		Gates:   []Gate{{Name: "review", Type: GateToggle}},
		Related: []RelatedLink{{ID: "rel-1", Title: "TASK-1"}},
		Body:    []Block{{ID: "block-1", Type: BlockText, Text: "body text"}},
		Comments: []QuestComment{
			{ID: "comment-quest", Anchor: CommentAnchor{Kind: CommentAnchorQuest}, Status: CommentOpen, Author: "aleksi", Body: "quest note", CreatedAt: "2026-06-17T00:00:00Z"},
			{ID: "comment-gate", Anchor: CommentAnchor{Kind: CommentAnchorGate, ID: "review"}, Status: CommentOpen, Body: "gate note", CreatedAt: "2026-06-17T00:01:00Z"},
			{ID: "comment-related", Anchor: CommentAnchor{Kind: CommentAnchorRelated, ID: "rel-1"}, Status: CommentOpen, Body: "related note", CreatedAt: "2026-06-17T00:02:00Z"},
			{ID: "comment-body", Anchor: CommentAnchor{Kind: CommentAnchorBody, ID: "block-1"}, Status: CommentResolved, Body: "body note", CreatedAt: "2026-06-17T00:03:00Z", ResolvedAt: "2026-06-17T00:04:00Z"},
		},
	}
	out := string(mustBuild(t, q))
	questAnchor := anchorFragmentID(CommentAnchor{Kind: CommentAnchorQuest})
	gateAnchor := anchorFragmentID(CommentAnchor{Kind: CommentAnchorGate, ID: "review"})
	relatedAnchor := anchorFragmentID(CommentAnchor{Kind: CommentAnchorRelated, ID: "rel-1"})
	bodyAnchor := anchorFragmentID(CommentAnchor{Kind: CommentAnchorBody, ID: "block-1"})
	questComment := commentFragmentID("comment-quest")
	for _, want := range []string{
		`id="` + questAnchor + `" data-anchor="quest"`,
		`id="` + gateAnchor + `" data-anchor="gate:review"`,
		`id="` + relatedAnchor + `" data-anchor="related:rel-1"`,
		`id="` + bodyAnchor + `" data-anchor="block:block-1"`,
		`id="` + questComment + `"`,
		`href="#` + questComment + `"`,
		`href="#` + gateAnchor + `">on gate:review</a>`,
		`data-anchor="quest"`,
		`data-anchor="gate:review"`,
		`data-anchor="related:rel-1"`,
		`data-anchor="block:block-1"`,
		`data-comment-status="open"`,
		`data-comment-status="resolved"`,
		`<span class="comment-author">aleksi</span>`,
		`<div class="comment-body">body note</div>`,
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("built HTML missing comment fragment %q:\n%s", want, out)
		}
	}
	for _, forbidden := range []string{
		`class="comment-form"`,
		`class="comment-resolve"`,
		`<button type="submit">add comment</button>`,
		`<button type="submit">resolve</button>`,
	} {
		if strings.Contains(out, forbidden) {
			t.Fatalf("static HTML should be read-only, found %q:\n%s", forbidden, out)
		}
	}
}

func TestBuildAddsResolvedCommentFilter(t *testing.T) {
	q := &Quest{
		ID:      "COMMENT-1",
		Title:   "Commented",
		Summary: "s",
		Status:  StatusActive,
		Comments: []QuestComment{
			{ID: "comment-open", Anchor: CommentAnchor{Kind: CommentAnchorQuest}, Status: CommentOpen, Body: "open note", CreatedAt: "2026-06-17T00:00:00Z"},
			{ID: "comment-resolved", Anchor: CommentAnchor{Kind: CommentAnchorQuest}, Status: CommentResolved, Body: "resolved note", CreatedAt: "2026-06-17T00:01:00Z", ResolvedAt: "2026-06-17T00:02:00Z"},
		},
	}
	out := string(mustBuild(t, q))
	for _, want := range []string{
		`id="show-resolved-comments" type="checkbox"`,
		`show resolved comments`,
		`#show-resolved-comments:not(:checked)~.layout .comment-resolved{display:none;}`,
		`#show-resolved-comments:not(:checked)~.layout .comment-resolved:target{display:block;}`,
		`class="comment comment-open"`,
		`class="comment comment-resolved"`,
		`resolved note`,
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("built HTML missing resolved filter fragment %q:\n%s", want, out)
		}
	}
}

func TestBuildRendersListItemCommentsInsideItem(t *testing.T) {
	q := &Quest{
		ID:      "COMMENT-1",
		Title:   "Commented",
		Summary: "s",
		Status:  StatusActive,
		Body: []Block{{
			ID:    "steps",
			Type:  BlockList,
			Items: []string{"first step", "second step"},
		}},
		Comments: []QuestComment{
			{ID: "comment-item", Anchor: CommentAnchor{Kind: CommentAnchorBody, ID: "steps"}.WithItem(0), Status: CommentOpen, Body: "first item note", CreatedAt: "2026-06-17T00:00:00Z"},
			{ID: "comment-block", Anchor: CommentAnchor{Kind: CommentAnchorBody, ID: "steps"}, Status: CommentOpen, Body: "whole list note", CreatedAt: "2026-06-17T00:01:00Z"},
		},
	}
	out := string(mustBuild(t, q))
	blockAnchor := anchorFragmentID(CommentAnchor{Kind: CommentAnchorBody, ID: "steps"})
	itemAnchor := anchorFragmentID(CommentAnchor{Kind: CommentAnchorBody, ID: "steps"}.WithItem(0))
	for _, want := range []string{
		`id="` + blockAnchor + `" data-anchor="block:steps"`,
		`id="` + itemAnchor + `" data-anchor="block:steps#item:0"`,
		`data-anchor="block:steps#item:0"`,
		`data-anchor="block:steps"`,
		`href="#` + itemAnchor + `">on block:steps#item:0</a>`,
		`first item note`,
		`whole list note`,
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("built HTML missing list comment fragment %q:\n%s", want, out)
		}
	}
	first := strings.Index(out, "first step")
	item := strings.Index(out, "first item note")
	second := strings.Index(out, "second step")
	block := strings.Index(out, "whole list note")
	if first < 0 || item < 0 || second < 0 || block < 0 {
		t.Fatalf("could not locate list/comment fragments:\n%s", out)
	}
	if !(first < item && item < second && second < block) {
		t.Fatalf("list item comment should render inside first li and block comment after list:\n%s", out)
	}
}

func TestBuildEscapesCommentDeepLinkHTML(t *testing.T) {
	q := &Quest{
		ID:      "COMMENT-1",
		Title:   "Commented",
		Summary: "s",
		Status:  StatusActive,
		Comments: []QuestComment{{
			ID:        `comment-"><script>`,
			Anchor:    CommentAnchor{Kind: CommentAnchorQuest},
			Status:    CommentOpen,
			Author:    `<owner>`,
			Body:      `<script>alert("x")</script>`,
			CreatedAt: "2026-06-17T00:00:00Z",
		}},
	}
	out := string(mustBuild(t, q))
	for _, want := range []string{
		`id="` + commentFragmentID(`comment-"><script>`) + `"`,
		`comment-&#34;&gt;&lt;script&gt;`,
		`&lt;owner&gt;`,
		`&lt;script&gt;alert(&#34;x&#34;)&lt;/script&gt;`,
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("built HTML missing escaped fragment %q:\n%s", want, out)
		}
	}
	if strings.Contains(out, `<script>alert("x")</script>`) {
		t.Fatalf("comment body was not escaped:\n%s", out)
	}
}

func TestHTMLFragmentIDDoesNotCollapseDistinctAnchorsOrComments(t *testing.T) {
	item := 0
	a := anchorFragmentID(CommentAnchor{Kind: CommentAnchorBody, ID: "a", Item: &item})
	b := anchorFragmentID(CommentAnchor{Kind: CommentAnchorBody, ID: "a-item-0"})
	if a == b {
		t.Fatalf("body list-item anchor fragment collided with body id fragment: %q", a)
	}

	c := commentFragmentID("a:b")
	d := commentFragmentID("a-b")
	if c == d {
		t.Fatalf("comment fragments collided: %q", c)
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
