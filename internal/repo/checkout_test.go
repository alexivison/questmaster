package repo

import (
	"path/filepath"
	"testing"
)

func TestResolveReportsTheCheckoutHoldingTheGitEntry(t *testing.T) {
	t.Parallel()

	mainRoot := filepath.Join(eval(t, t.TempDir()), "main")
	wtRoot := filepath.Join(mainRoot, ".worktrees", "branch", "feature")
	mkWorktree(t, mainRoot, wtRoot, "feature")

	tests := []struct {
		name         string
		path         string
		wantCheckout string
		wantRoot     string
	}{
		{name: "main checkout", path: mainRoot, wantCheckout: mainRoot, wantRoot: mainRoot},
		{name: "subfolder of main checkout", path: filepath.Join(mainRoot, "pkg"), wantCheckout: mainRoot, wantRoot: mainRoot},
		{name: "linked worktree keeps its own top level", path: wtRoot, wantCheckout: wtRoot, wantRoot: mainRoot},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			r, ok := Resolve(tt.path)
			if !ok {
				t.Fatalf("Resolve(%q) not a repo", tt.path)
			}
			if r.Checkout != tt.wantCheckout || r.Root != tt.wantRoot {
				t.Fatalf("Checkout = %q, Root = %q; want %q, %q", r.Checkout, r.Root, tt.wantCheckout, tt.wantRoot)
			}
		})
	}
}
