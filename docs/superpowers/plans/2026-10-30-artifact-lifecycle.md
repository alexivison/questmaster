# Artifact Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create and register artifacts in one command, link one artifact to multiple sessions, permanently delete it from any app view, and open it externally with `o`.

**Architecture:** The Go registry holds one artifact record with a stable ID, origin project, and session links. `artifact create` writes/imports into project-based managed storage and commits the registration under the existing registry lock; `artifact add` links existing records. The daemon remains the app's snapshot/mutation transport; the App target launches external applications or a new tmux editor window.

**Tech Stack:** Go/Cobra, JSON registry and file locks, serve socket protocol, Swift Core, AppKit/SwiftUI, tmux.

**Spec:** `docs/superpowers/specs/2026-10-30-artifact-lifecycle-design.md`

## Global Constraints

- Keep artifact file location, origin project, and session links independent; no session ID in managed storage paths.
- Preserve legacy paths, labels, and one-session registrations during migration. Do not move old files.
- The app's Delete removes the file, record, and all session links in every view. `artifact rm` remains registration-only for CLI compatibility.
- `o` uses the attached session's `$EDITOR` in a separate tmux window for Markdown; HTML uses the browser, images Preview, others the system default.
- Go/Swift wire fixtures are authoritative. Regenerate `internal/serve/testdata/*.json` and bump `ServeProtocolVersion` for the new membership shape.
- Follow `AGENTS.md`: Go build with `-buildvcs=false`, Core owns decisions, App owns I/O, token styling, and relevant self-tests.

## Review Focus

1. Two sessions add the same path concurrently: one record retains both links; Task 1 tests lock behavior.
2. A legacy root registry or sidecar has only `session_id`: migration retains that session, path, kind, label, and project; Task 1 tests both inputs.
3. A source path is inside a linked Git worktree or outside Git: project inference uses the source repo's canonical identity or falls back to the session repo; Task 2 tests both.
4. Creation receives an invalid name, an unreadable source, or a registry write failure: no registered partial file and no managed output remains; Task 2 tests failure paths.
5. Permanent deletion sees a missing, symlinked, or undeletable file: it removes only the named file/link, keeps registration on disk errors, and removes registration when the file is already absent; Task 3 tests each.
6. `$EDITOR` has arguments and the artifact path contains spaces: opening receives the exact path in the attached session's tmux window without shell injection; Task 5 tests command construction.

---

### Task 1: Multi-session artifact registry

**Files:** Modify `internal/state/hookstate.go`; create `internal/state/artifacts_test.go`; update existing artifact assertions in `internal/state/hookstate_test.go` and `cmd/artifact_test.go` as needed.

**Interfaces:** `Artifact` gains `ID`, `SessionIDs []string`, and `CreatedBySessionID`; `SessionID` remains a legacy JSON projection during migration. `UpsertArtifactAt(root, sessionID string, artifact Artifact) error` links a path without removing other links. `RemoveArtifactAt(root, sessionID, path string) (bool,error)` unlinks only that session. `FilterArtifacts` tests membership. Add `ArtifactByIDOrPath(artifacts []Artifact, value string) (Artifact,bool)` for CLI and mutations.

- [ ] Write tests `TestArtifactLinksRemainAfterSecondSessionAdd`, `TestArtifactConcurrentLinks`, `TestArtifactUnlinkPreservesOtherSessions`, and `TestArtifactLegacyRegistryAndSidecarMigration`: assert unique IDs, sorted/deduped links, stable metadata, and both migration sources.
- [ ] Run `go test -buildvcs=false ./internal/state -run 'TestArtifact(Links|Concurrent|Unlink|Legacy)' -count=1`; expect failing assertions.
- [ ] Implement ID generation and legacy normalization, path dedupe that unions links, locked upsert/unlink, and sidecar sync for every affected session. Keep migrated IDs stable across repeated loads.
- [ ] Run `go test -buildvcs=false ./internal/state ./cmd -count=1`; expect pass.
- [ ] Commit registry and tests.

### Task 2: One-command creation and explicit linking

**Files:** Create `internal/state/artifact_create.go`, `cmd/artifact_create.go`; modify `cmd/artifact.go`, `internal/agent/prompts/artifact_guide.md`, `README.md`; create `cmd/artifact_create_test.go`.

**Interfaces:** `state.CreateArtifactAt(root, sessionID string, opts ArtifactCreateOptions) (Artifact,error)` where options supply `Name`, `Label`, `ProjectID`, `SourcePath`, and `Content io.Reader` (exactly one input mode). `artifact create <name> [--from <path>] [--label <label>]` reads stdin otherwise; stdout reports ID and final path. `artifact add <path-or-id> --session <id>` creates an existing-path record or links an existing record by ID/path.

- [ ] Write `TestArtifactCreateFromStdinAndImport`, `TestArtifactCreateInfersProject`, `TestArtifactCreateRejectsInvalidNameAndCleansFailure`, and `TestArtifactAddLinksIDWithoutCopy`: assert a managed project path without a session ID, one registry record, source repo/fallback inference, exact bytes, and no output on failure.
- [ ] Run `go test -buildvcs=false ./cmd -run 'TestArtifact(Create|AddLinks)' -count=1`; expect fail.
- [ ] Implement managed storage with an artifact-ID directory under a stable project key, reject traversal in artifact names, atomically publish file bytes, roll back on registration failure, and add CLI syntax. Preserve old `artifact add` path behavior (including its missing-file warning), but union memberships and do not reset creation time on linking.
- [ ] Update the bundled agent guide to use `create` for newly generated deliverables and `add` for sharing/existing files; document examples for stdin and `--from`.
- [ ] Run `go test -buildvcs=false ./cmd ./internal/state ./internal/agent -count=1`; expect pass.
- [ ] Commit creation, CLI, guide, and tests.

### Task 3: Permanent deletion and Go runtime contract

**Files:** Modify `internal/state/hookstate.go`, `internal/serve/mutations.go`, `internal/serve/snapshot.go`, `internal/serve/server.go`, `internal/serve/contract_golden_test.go`, `internal/serve/testdata/*.json`, `cmd/artifact.go`; create `cmd/artifact_delete.go`; add state, CLI, and serve tests to their existing test files.

**Interfaces:** `state.DeleteArtifactAt(root, idOrPath string) (bool,error)` removes the file before its record under the registry lock, treating a missing file as already removed; `artifact.delete` accepts ID or path and always deletes globally; CLI `artifact delete` uses the same operation while `artifact rm` remains registration-only. `ArtifactSnapshot` includes ID, session IDs, and creator ID. `ServeProtocolVersion` becomes 3. Preserve `session_id` as a compatibility projection but app logic uses `session_ids`.

- [ ] Write `TestDeleteArtifactRemovesFileAndEveryLink`, `TestDeleteArtifactMissingAndDiskFailure`, `TestDeleteArtifactSymlinkDoesNotFollowTarget`, and serve snapshot/mutation tests asserting session membership and one All entry.
- [ ] Run focused `go test -buildvcs=false ./internal/state ./internal/serve -run 'Test(DeleteArtifact|ArtifactDelete|ArtifactSnapshot)' -count=1`; expect fail.
- [ ] Implement locked deletion, serve mutation, snapshot fields, and broad tracker invalidation. On disk failure preserve the record and report the error.
- [ ] Regenerate fixtures with `go test -buildvcs=false ./internal/serve -update`; inspect `git diff` for only intended payload/protocol changes.
- [ ] Run `go test -buildvcs=false ./internal/state ./internal/serve -count=1`; expect pass.
- [ ] Commit deletion and wire contract.

### Task 4: Swift membership, deletion, and `o` intent

**Files:** Modify `app/Sources/Core/Models/ArtifactModels.swift`, `app/Sources/Core/Artifacts/ArtifactDisplayState.swift`, `app/Sources/Core/Stores/RuntimeStore.swift`, `app/Sources/Core/Navigation/KeymapBindings.swift`, `app/Sources/Core/Navigation/ListKeys.swift`, `app/Sources/Core/Mutations/MutationRequests.swift`, `app/Sources/Core/Mutations/DestructiveConfirmation.swift`, `app/Sources/Core/Runtime/ServeContract.swift`, `app/Sources/App/Dock/DockPaneModel.swift`, `app/Sources/App/Dock/DockPane.swift`, and `app/Sources/App/Runtime/LogicSelfTests.swift`.

**Interfaces:** `ArtifactReference.id` decodes the stable ID and `sessionIDs` decodes `session_ids` with legacy `session_id` fallback. Add `ListCommand.openExternal`, `ListCapabilities.externalOpen`, and `Keymap.Action.openExternal` bound to `o`. `DockPaneModel.onOpenArtifactExternal` passes the selected/current `ArtifactReference`; `ServeMutationRequests.artifactDelete` sends artifact ID/path without a session ID.

- [ ] Add logic tests for two-session visibility in Session and one row in All, stable selection by ID, `o` only when artifact list/viewer has keys, deletion mutation without `session_id`, and confirmation copy naming physical deletion and all-session effect.
- [ ] Run `swift run --package-path app QuestmasterLogicTests`; expect new tests fail.
- [ ] Implement decoding/filtering/store cleanup, key intent routing, mutation request, and confirmation model. Preserve Return and click behavior.
- [ ] Run `swift run --package-path app QuestmasterLogicTests`; expect 0 failures, including shared Go fixture decoding.
- [ ] Commit Swift Core and dock routing.

### Task 5: External opener and integrated app behavior

**Files:** Create `app/Sources/App/Dock/Artifact/ArtifactExternalOpener.swift`; modify `app/Sources/App/Terminal/TerminalTmuxClient.swift`, `app/Sources/App/AppDelegate.swift`, `app/Sources/App/Runtime/LogicSelfTests.swift`, and `app/Sources/Core/Artifacts/ArtifactKind.swift` only if an actual-path classifier is needed.

**Interfaces:** `ArtifactExternalOpener.open(artifact: ArtifactReference, attachedSessionID: String, tmuxPath: String, environment: [String:String]) throws` selects HTML browser, image Preview, Markdown tmux editor window, or system default by actual extension. `TerminalTmuxClientProcess.editorWindowArguments(sessionID:path:shell:)` returns testable argv. The app's Delete callback uses global permanent deletion and removes the artifact from every local snapshot on acknowledgment.

- [ ] Add tests for opener classification, tmux editor argv with spaces/editor arguments, missing file, and app deletion from Session/All invoking the same global mutation.
- [ ] Run `swift run --package-path app QuestmasterLogicTests`; expect new tests fail.
- [ ] Implement AppKit launches and tmux window command. Use the attached session's login shell for `$EDITOR`, never inject editor keystrokes into the agent pane; show an actionable error when no editor is configured.
- [ ] Run `swift run --package-path app QuestmasterLogicTests`; expect pass.
- [ ] Run `go mod tidy`, `git diff --exit-code -- go.mod go.sum`, `go build -buildvcs=false ./...`, `go vet ./...`, `go test -buildvcs=false ./...`, and `swift build --package-path app`; expect all pass.
- [ ] Review the integrated diff against the spec, including state rules scan tests; commit the final App wiring.

## Review and delivery

Use the `pr-slicing` check before opening PRs. Expected review map: (1) Go registry and creation CLI on `main` (~600 reviewed LOC), (2) permanent deletion plus Go/Swift membership contract atop 1 (~700 LOC), (3) external opener and final app integration atop 2 (~450 LOC). Keep each slice independently testable; adjust boundaries to actual reviewed LOC and coupling. Request a correctness review of the integrated branch. Open draft PRs if the worktree can be branched and pushed; otherwise provide the committed worktree and integration instructions.
