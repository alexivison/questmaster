// Package adapter is the read-only context + status layer. In Stage 1 it
// surfaces GitHub PR/CI state for display in the cockpit and resolves
// Linear/Notion/Slack context refs. The quest store is the source of truth;
// adapters never own quest state, and there is no write-back yet (Stage 2).
package adapter

import (
	"fmt"
	"strings"

	"github.com/alexivison/questmaster/internal/quests/runtime"
)

// StatusSource reads PR/CI status for a repo branch (GitHub, via projdash's
// read path). It returns nil when there is no PR for the branch.
type StatusSource interface {
	PR(repo, branch string) (*runtime.PRStatus, error)
}

// ContextSource resolves a context ref (e.g. "linear:ENG-142", "slack:#auth",
// "notion:RFC-9") to text, via the existing MCP connectors.
type ContextSource interface {
	Resolve(ref string) (text string, err error)
}

// ParseRef splits a context ref into its scheme and value, e.g.
// "linear:ENG-142" -> ("linear", "ENG-142"). A ref with no scheme returns an
// empty scheme and the whole ref as the value.
func ParseRef(ref string) (scheme, value string) {
	if i := strings.IndexByte(ref, ':'); i >= 0 {
		return ref[:i], ref[i+1:]
	}
	return "", ref
}

// MapContextSource resolves refs from an in-memory map. It is the mock/fixture
// resolver and a stand-in until the live MCP connectors are wired through.
type MapContextSource map[string]string

var _ ContextSource = MapContextSource(nil)

// Resolve returns the mapped text for ref, or an error if the ref is unknown.
func (m MapContextSource) Resolve(ref string) (string, error) {
	if text, ok := m[ref]; ok {
		return text, nil
	}
	return "", fmt.Errorf("unresolved context ref %q", ref)
}

// SchemeRouter dispatches a ref to a per-scheme ContextSource (linear/notion/
// slack). It is how the cockpit wires each connector independently; an
// unregistered scheme returns an error rather than guessing.
type SchemeRouter struct {
	bySrc map[string]ContextSource
}

var _ ContextSource = (*SchemeRouter)(nil)

// NewSchemeRouter builds a router from scheme -> source.
func NewSchemeRouter(bySrc map[string]ContextSource) *SchemeRouter {
	return &SchemeRouter{bySrc: bySrc}
}

// Resolve routes ref to the source registered for its scheme.
func (r *SchemeRouter) Resolve(ref string) (string, error) {
	scheme, _ := ParseRef(ref)
	src, ok := r.bySrc[scheme]
	if !ok {
		return "", fmt.Errorf("no context source for scheme %q (ref %q)", scheme, ref)
	}
	return src.Resolve(ref)
}
