---
name: questmaster-write-quest
description: >-
  Use when creating or refining a project quest with Questmaster's `quest` CLI.
  Choose add versus edit, preserve existing fields, assign optional project and
  tags intentionally, and verify the saved result. Not for general task planning.
---

# Create or refine a Questmaster quest

Use this skill when the user asks to record or change work in Questmaster's project quest list.

- For likely existing work, inspect `questmaster quest ls`; narrow it with `--project`
  or `--search` when useful. Edit the matching quest instead of adding a duplicate.
  Add a quest for distinct work.
- Keep the user's scope and decisions. Write only enough detail to make the requested
  work understandable, including acceptance details the user supplied. A short quest
  needs no fixed template, and missing requirements should not be invented.
- Project, type, and size are optional. `questmaster quest add` tries to infer a
  project from the session cwd or current directory; it leaves the quest
  unassigned if neither resolves. Use `--project <path>` when the work belongs
  elsewhere or inference fails. `questmaster quest start` requires a project.
  On edit, omit `--project` to keep the current project; pass
  `--project ""` only to clear it.
- Supported type tags are `bug`, `improvement`, `feature`, `research`, `decision`,
  and `cleanup`; size is `S`, `M`, or `L`. Choose only tags supported by the request.
  On edit, `--type` replaces the full type set and `--size` replaces the size.
  Omitted flags preserve existing values; `--type ""` and `--size ""` clear them.
- `questmaster quest edit <id> --content ...` replaces the full quest content.
  Preserve relevant existing details when rewriting it, and change content only when
  requested or needed to reflect the user's stated change. Use `--file` when content
  is more practical to provide from a file or stdin.

After `questmaster quest add` or `questmaster quest edit`, inspect the returned quest
object. Confirm its content, project, tags, size, and ID reflect the request; use
`questmaster quest ls <id>` if a separate read helps confirm the saved result.
