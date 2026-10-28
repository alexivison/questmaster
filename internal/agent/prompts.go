package agent

import (
	_ "embed"
	"strings"
)

// Prompt text lives in prompts/*.md (not here) so it can be read and edited
// as plain markdown instead of Go string literals. Each file holds one
// self-contained fragment; the numbered "common guide" / "quest guide" /
// "artifact guide" rules are appended by the role prompts below so the
// shared fragments stay unnumbered and reusable across roles.

//go:embed prompts/artifact_guide.md
var artifactGuideMD string

//go:embed prompts/common_guide.md
var commonGuideMD string

//go:embed prompts/quest_guide.md
var questGuideMD string

//go:embed prompts/master.md
var masterPromptMD string

//go:embed prompts/worker.md
var workerPromptMD string

var artifactPromptGuide = strings.TrimSpace(artifactGuideMD)

// commonPromptGuide covers CLI discovery, messaging, and PR alerts for both roles.
var commonPromptGuide = strings.TrimSpace(commonGuideMD)

var questPromptGuide = strings.TrimSpace(questGuideMD)

// masterPrompt is the canonical system prompt for master sessions.
var masterPrompt = strings.TrimRight(masterPromptMD, "\n") + `
(4) ` + commonPromptGuide + `
(5) ` + questPromptGuide + `
(6) ` + artifactPromptGuide

// workerPrompt is the canonical system prompt for worker sessions.
var workerPrompt = strings.TrimRight(workerPromptMD, "\n") + `
(3) ` + commonPromptGuide + `
(4) ` + questPromptGuide + `
(5) ` + artifactPromptGuide
