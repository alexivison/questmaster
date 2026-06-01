package adapter

import "testing"

func TestParseRef(t *testing.T) {
	cases := []struct {
		ref         string
		scheme, val string
	}{
		{"linear:ENG-142", "linear", "ENG-142"},
		{"slack:#auth", "slack", "#auth"},
		{"notion:RFC-9", "notion", "RFC-9"},
		{"bare", "", "bare"},
	}
	for _, c := range cases {
		s, v := ParseRef(c.ref)
		if s != c.scheme || v != c.val {
			t.Errorf("ParseRef(%q) = (%q,%q), want (%q,%q)", c.ref, s, v, c.scheme, c.val)
		}
	}
}

func TestMapContextSourceResolve(t *testing.T) {
	src := MapContextSource{"linear:ENG-142": "Auth refresh loop ticket body"}
	got, err := src.Resolve("linear:ENG-142")
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if got != "Auth refresh loop ticket body" {
		t.Errorf("Resolve = %q", got)
	}
	if _, err := src.Resolve("linear:UNKNOWN"); err == nil {
		t.Errorf("Resolve of unknown ref should error")
	}
}

func TestSchemeRouter(t *testing.T) {
	router := NewSchemeRouter(map[string]ContextSource{
		"linear": MapContextSource{"linear:ENG-142": "ticket"},
		"notion": MapContextSource{"notion:RFC-9": "rfc body"},
	})

	if got, err := router.Resolve("linear:ENG-142"); err != nil || got != "ticket" {
		t.Errorf("router.Resolve(linear) = %q,%v", got, err)
	}
	if got, err := router.Resolve("notion:RFC-9"); err != nil || got != "rfc body" {
		t.Errorf("router.Resolve(notion) = %q,%v", got, err)
	}
	if _, err := router.Resolve("slack:#auth"); err == nil {
		t.Errorf("router should error for an unregistered scheme")
	}
}
