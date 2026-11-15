package agent

import (
	"embed"
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

//go:embed prompts/class_voice.md
var classVoiceMD string

//go:embed prompts/class_voice/*.md prompts/voice_archetypes/*.md
var classVoiceFS embed.FS

// classVoiceClasses lists the classes that have a voice mapping, in file order.
func classVoiceClasses() []string {
	entries, _ := classVoiceFS.ReadDir("prompts/class_voice")
	classes := make([]string, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".md") {
			continue
		}
		classes = append(classes, strings.TrimSuffix(entry.Name(), ".md"))
	}
	return classes
}

type classVoiceSpec struct {
	archetype string
	flavour   string
}

func classVoiceSpecFor(class string) (classVoiceSpec, bool) {
	if class == "" {
		return classVoiceSpec{}, false
	}
	data, err := classVoiceFS.ReadFile("prompts/class_voice/" + class + ".md")
	if err != nil {
		return classVoiceSpec{}, false
	}
	var spec classVoiceSpec
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		key, value, ok := strings.Cut(strings.TrimSpace(line), ":")
		if !ok {
			return classVoiceSpec{}, false
		}
		value = strings.TrimSpace(value)
		switch strings.TrimSpace(key) {
		case "Archetype":
			spec.archetype = value
		case "Flavour":
			spec.flavour = value
		default:
			return classVoiceSpec{}, false
		}
	}
	return spec, spec.archetype != "" && spec.flavour != ""
}

// ClassVoice returns the shared voice rules, the mapped archetype and example,
// and the class-specific flavour for a master session of the given class.
// A blank or unknown class has no voice and returns "".
//
// The voice is part of the system prompt fixed at launch. Reclassing a live
// session does not change its current process; the next launch, including a
// continue of a stopped session or a restart, uses the new class and rebuilds
// the launch command (and, for OpenCode, selects the new class's agent file).
func ClassVoice(class string) string {
	spec, ok := classVoiceSpecFor(class)
	if !ok {
		return ""
	}
	archetype, err := classVoiceFS.ReadFile("prompts/voice_archetypes/" + strings.ToLower(spec.archetype) + ".md")
	if err != nil {
		return ""
	}
	name := strings.ToUpper(class[:1]) + class[1:]
	shared := strings.ReplaceAll(strings.TrimSpace(classVoiceMD), "{Class}", name)
	return strings.Join([]string{
		shared,
		strings.TrimSpace(string(archetype)),
		"Flavour: " + spec.flavour,
	}, "\n\n")
}
