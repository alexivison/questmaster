// Command quests is the Stage-1 plan-layer cockpit. It is a second binary in
// the questmaster repo, sharing the internal spine with fully isolated runtime
// state (see docs/quests-build-handoff). `go install ./cmd/quests` builds only
// Quests.
package main

import (
	"fmt"
	"os"
)

func main() {
	if err := NewRootCmd().Execute(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}
