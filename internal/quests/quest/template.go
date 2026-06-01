package quest

import _ "embed"

// templateHTML is the canonical quest scaffold shipped with the tool: the
// worked example that doubles as the few-shot for the planning agent. It is
// kept byte-identical to the handoff's quest-template-example.html and must
// always Parse + Validate.
//
//go:embed quest-template.html
var templateHTML []byte

// Template returns the canonical quest-template.html bytes.
func Template() []byte {
	out := make([]byte, len(templateHTML))
	copy(out, templateHTML)
	return out
}
