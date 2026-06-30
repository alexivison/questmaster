# Performance Audit: questmaster (Go CLI + Swift App)

## Executive Summary

questmaster is a fundamentally healthy, low-throughput system: a single-user macOS client talking to one local `qm serve` over a loopback Unix socket, plus a per-event `qm hook` process that agents spawn on every tool call. The biggest genuine drag sits in two places. First, the **Go hook path** (`cmd/hook.go`), which is on a documented sub-20ms budget yet takes two independent flock round-trips per event and unconditionally reads+decodes the whole `state.json` on every tool call. Second, the **serve push path** (`internal/serve/server.go`), which marshals the largest payloads (board/tracker) twice per push and re-fires every clock tick. Everything else — the Swift decode/render path and the IPC bridge — is allocation/CoW/syscall hygiene that is real but bounded by the tiny single-user workload, not a measurable bottleneck. Only the two Go findings are genuine hot-path issues; the rest is honest hygiene.

## Detailed Findings

### Critical (Fix immediately)
_None._

### Major (High impact on hot paths)

#### pushChanged marshals each board/tracker payload twice per push
- **Component/File:** `internal/serve/server.go` (lines 265-275; second marshal at `writeEnvelope`, lines 321-326)
- **Hot path:** per clock tick (1s) per client, plus per file-watch event
- **The Issue:** For each changed topic, `pushChanged` calls `json.Marshal(data)` purely to compare against `last[topic]` for dedup, then — if it differs — calls `writeEnvelope(enc, Envelope{... Data: data})`, where `enc.Encode` serializes the same `data` value a *second* time (now nested in the envelope). Board (`snapshot.go:129`, every quest + full `quest.Quest` + runtime) and tracker (`snapshot.go:178`, every session row) are the largest serve payloads. Critically, the dedup at line 269 does *not* short-circuit the clock-driven tracker push: `clockTracker` (`snapshot.go:514+`) recomputes `ObservedAt`/elapsed/runtime fields every tick, so the tracker payload differs every second and the redundant second marshal fires every second per subscribed client.
- **The Impact:** Sustained 2x JSON serialization CPU and allocations of the heaviest payloads, every clock tick (1s) per client plus per file-watch event. The dedup marshal itself is inherent (you need bytes to compare) and only runs for topics the change actually `Affects()` (line 258), so the avoidable cost is precisely the second marshal.
- **Remediation:**
  ```go
  // Before
  raw, err := json.Marshal(data)
  if err != nil { /* ... */ }
  if string(raw) == string(last[topic]) {
      continue
  }
  last[topic] = raw
  if err := writeEnvelope(enc, Envelope{Type: "event", Topic: topic, Data: data}); err != nil {

  // After
  raw, err := json.Marshal(data)
  if err != nil { /* ... */ }
  if bytes.Equal(raw, last[topic]) {
      continue
  }
  last[topic] = raw
  // Reuse the bytes already marshaled instead of re-encoding data:
  env := Envelope{ProtocolVersion: ServeProtocolVersion, Type: "event", Topic: topic, Data: json.RawMessage(raw)}
  if err := writeEnvelope(enc, env); err != nil {
  ```
  `json.RawMessage` emits its bytes verbatim through `enc.Encode`, producing byte-identical wire output while eliminating the second marshal. `raw` is only used for comparison/storage in `last`, never written, so the missing trailing newline is irrelevant.

#### Two separate flock acquisitions + full state.json read on every hook event
- **Component/File:** `cmd/hook.go` (lines 356-433; identical pattern at 794 and 1187). Implementations in `internal/state/hookstate.go` (`UpdateSessionState` 234-262, `AppendStateEvent`/`appendStateEventAt` 585-634, `withFileLock`/`withStateLock` 657-699)
- **Hot path:** per-event (every PreToolUse/PostToolUse, many per turn per agent, across N concurrent agents)
- **The Issue:** Each hook handler does `AppendEvent` then `Update` as two independent critical sections that both flock the *same* per-session lock file (`SessionStateLockPath`). `AppendStateEvent` acquires a flock, stats the jsonl, marshals one event, appends; then `UpdateSessionState` acquires a *second* flock on the identical lock file, does a full `os.ReadFile` of `state.json`, `json.Unmarshal` into `SessionState` (map alloc + every `PaneState`), mutates, and conditionally marshals to a `.tmp` + rename. The read+decode is unconditional; only the marshal+rewrite is skipped on a no-op (conditional flush at `hook.go:422-428`). So every event pays two flock open+acquire+release cycles plus two `ensureSessionStateDir` stats, even when nothing changes.
- **The Impact:** This is on a documented sub-20ms hook budget (`hook.go:598`), multiplied across every tool call and every concurrent agent. Lock-hold time also gates the serve-side fsnotify readers. Merging the two operations into one critical section eliminates one flock round-trip and one redundant `ensureSessionStateDir` stat per event and shortens lock-hold. (Note: it does *not* remove the `os.ReadFile`+`json.Unmarshal`, which is inherent to a locked read-modify-write; eliminating that would need a bigger redesign such as in-process cached state.)
- **Remediation:**
  ```go
  // Before
  if err := r.AppendEvent(sessionID, ev); err != nil { /* ... */ }
  // ...
  mutateErr := r.Update(sessionID, func(ss *state.SessionState) bool { /* ... */ })

  // After
  // Fold the JSONL append into the same critical section as the state
  // read-modify-write so the per-event hook takes one flock instead of two:
  r.UpdateAndLog(sessionID, ev, func(ss *state.SessionState) bool { /* ... */ })
  // UpdateAndLog holds withStateLock once, always appends the event line,
  // then conditionally writes state.json.
  ```

### Optimization (Hygiene)

#### captureResumeID does a full manifest read (with double-unmarshal) on every Claude/Codex event
- **Component/File:** `cmd/hook.go` (lines 438-440 and 889-909); double-unmarshal at `internal/state/manifest.go` (lines 79-103); read path at `internal/state/store.go` (lines 92-96, 173)
- **Hot path:** per-event (every Claude/Codex tool event)
- **The Issue:** `handleClaude` calls `captureResumeID` whenever `payload.SessionID != ""` — essentially every event. `captureResumeID` unconditionally does `r.Store.Read(sessionID)` = `os.ReadFile` of the manifest + `Manifest.UnmarshalJSON`, which itself unmarshals the bytes *twice* (once into the typed struct, once into `map[string]json.RawMessage` to capture `Extra`). The session ID is fixed for the session lifetime, so after the first event `resumeIDPersisted` returns true and the read is pure waste.
- **The Impact:** One extra whole-manifest `os.ReadFile` plus a double `json.Unmarshal` per event, on a path that already does an event append + a flock-guarded session-state read-and-write — so it is incremental waste, not the dominant cost. Manifest size is small, bounding the double-unmarshal cost.
- **Remediation:** Do **not** guard on `os.Getenv("CLAUDE_SESSION_ID")` — that env reflects the tmux session env, a different persistence target from the on-disk manifest, and skipping the read on an env match would break `TestCaptureResumeIDCurrentEnvPersistsMissingManifestAndSkipsTmuxEnv` (`hook_test.go:906`), which asserts the manifest is still read+persisted when the env matches. Instead gate on a signal that actually reflects manifest currency:
  ```go
  // Before
  if payload.SessionID != "" {
      captureResumeID(opts.ctx, r, stderr, sessionID, "claude_session_id", "CLAUDE_SESSION_ID", payload.SessionID, "claude")
  }

  // After
  // Track an "already persisted" marker in the in-process SessionState that
  // handleClaude already reads/writes via r.Update, and skip the manifest
  // read+decode once the resume ID is known-current for this session.
  if payload.SessionID != "" && !ss.ResumeIDPersisted("claude") {
      captureResumeID(opts.ctx, r, stderr, sessionID, "claude_session_id", "CLAUDE_SESSION_ID", payload.SessionID, "claude")
  }
  ```

#### Socket writer is unbuffered: every pushed envelope is a direct write syscall
- **Component/File:** `internal/serve/server.go` (lines 173-174; flush boundaries would touch 181, 188, 196, 199, 207, 210, 234, 246, 263, 267, 273)
- **Hot path:** per-event and per clock tick (1s) per client
- **The Issue:** `handleConn` wraps the raw `net.Conn` directly: `enc := json.NewEncoder(conn)`. Every envelope (initial multi-topic snapshot burst, every clock tick, every event) is at least one `write()` syscall on the socket, with no `Flush` boundary or batching. A multi-topic change issues several back-to-back writes per client.
- **The Impact:** Negligible in practice. The workload is a few loopback clients, default 2 topics (`server.go:302`), ticking at 1Hz — single-digit sub-microsecond writes per second per client. The per-topic dedup at `server.go:269` zeroes most idle ticks entirely. This is syscall hygiene, not a bottleneck, and the fix is more invasive than a one-liner: the encoder is threaded by value into `writeResponse`, `subscribe`, `pushChanged`, `writeMutationResponse`, `dirSuggest` and several error paths, so a `bufio.Writer` must be `Flush()`ed at *every* one of those exit points — a single missed flush silently buffers an interactive client's event.
- **Remediation:**
  ```go
  // Before
  dec := json.NewDecoder(conn)
  enc := json.NewEncoder(conn)

  // After
  dec := json.NewDecoder(conn)
  bw := bufio.NewWriter(conn)
  enc := json.NewEncoder(bw)
  // Then call bw.Flush() at the end of every push/response/error exit point
  // that currently shares enc (pushChanged, writeResponse, writeMutationResponse,
  // dirSuggest, and the error paths).
  ```

#### cachedRuntimes copies the id slice on every board snapshot even when no refresh is needed
- **Component/File:** `internal/serve/snapshot.go` (lines 419-455; key line 426)
- **Hot path:** per board/quest event per client
- **The Issue:** `cachedRuntimes` does `refreshIDs := append([]string(nil), ids...)` unconditionally at line 426, allocating a full copy of the id list before deciding whether any refresh is warranted. The narrowing branch immediately reassigns `refreshIDs = make(...)` (line 432), discarding the copy; the non-narrowing path only passes `refreshIDs` to `qruntime.Snapshot`, which reads it. `refreshIDs` is never mutated in place, and the caller builds `ids` fresh (`snapshot.go:238`), so aliasing is safe.
- **The Impact:** One slice allocation per board snapshot proportional to quest count, on the event-driven push path (quest/board file-changes and the per-connect `allTopicsChange` burst — clock ticks target only the tracker topic, so they do not reach here). Avoidable with a one-line change.
- **Remediation:**
  ```go
  // Before
  refreshIDs := append([]string(nil), ids...)
  if len(change.Topics) > 0 && len(change.QuestIDs) > 0 && len(s.runtimeCache) > 0 {
      // ...
      refreshIDs = make([]string, 0, len(change.QuestIDs))
      // ...
  }

  // After
  refreshIDs := ids // reuse caller slice; only copy when narrowing
  if len(change.Topics) > 0 && len(change.QuestIDs) > 0 && len(s.runtimeCache) > 0 {
      // ...
      refreshIDs = make([]string, 0, len(change.QuestIDs))
      // ...
  }
  ```

#### publish() holds the subscribers mutex across the entire fan-out
- **Component/File:** `internal/serve/watch.go` (lines 433-455)
- **Hot path:** per-event (debounced fs change) and per clock tick
- **The Issue:** `publish` locks `s.mu` and, while holding it, iterates every subscriber channel doing non-blocking sends. The same mutex also guards `Subscribe`/`unsubscribe` and the map check in `watchDir`/`maybeWatchSessionDir`, so the fan-out serializes those operations behind every publish.
- **The Impact:** Microscopic. This is the local single-user app with ~1 subscriber, and the work under the lock is purely nanosecond-scale non-blocking channel sends — `watchDir` already does its blocking syscalls (`os.MkdirAll`, `watcher.Add`) *before* acquiring `s.mu`, so publish never serializes against I/O. The snapshot fix is correct but adds a per-publish slice allocation, making it net-neutral at this subscriber count.
- **Remediation:**
  ```go
  // Before
  s.mu.Lock()
  defer s.mu.Unlock()
  for ch := range s.subscribers {
      select {
      case ch <- change:
      default: // drain + resend allTopics
      }
  }

  // After
  s.mu.Lock()
  chans := make([]chan Change, 0, len(s.subscribers))
  for ch := range s.subscribers {
      chans = append(chans, ch)
  }
  s.mu.Unlock()
  for _, ch := range chans {
      select {
      case ch <- change:
      default: // drain + resend allTopics
      }
  }
  ```

#### os.Stat of the JSONL on every append just to check rotation threshold
- **Component/File:** `internal/state/hookstate.go` (lines 636-655)
- **Hot path:** per-event (every AppendStateEvent), inside the flock
- **The Issue:** `appendRotatingJSONL` does `os.Stat(path)` on every append solely to compare `Size()` against the 1 MiB rotation threshold, then immediately opens the same path with `O_APPEND` — the size is already obtainable from the open fd via `f.Stat()`.
- **The Impact:** Marginal. The saving is `stat`-vs-`fstat` on the same (OS-cached) inode, not the elimination of a syscall — well inside the noise floor of the surrounding flock + `json.Marshal` + write. The proposed reorder is functionally correct but trades the clean 4-line guard for a close/rename/reopen dance; leaving it as-is is defensible, and if pursued the simplest variant just swaps `os.Stat(path)` for an `f.Stat()` after the single open.
- **Remediation:**
  ```go
  // Before
  if info, err := os.Stat(path); err == nil && info.Size() >= StateJSONLMaxSize {
      _ = os.Remove(path + ".1")
      _ = os.Rename(path, path+".1")
  }
  // ...
  f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)

  // After
  f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
  if err != nil { return /* ... */ }
  defer f.Close()
  if info, err := f.Stat(); err == nil && info.Size() >= StateJSONLMaxSize {
      f.Close(); _ = os.Remove(path+".1"); _ = os.Rename(path, path+".1")
      f, err = os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
      // ...
  }
  ```

#### Pi/omp build a fresh map for event Fields on every event
- **Component/File:** `cmd/hook.go` (lines 1173-1185)
- **Hot path:** per-event (Pi/omp `message_update` streaming)
- **The Issue:** `handlePiLike` allocates `fields := map[string]interface{}{}` on every Pi/omp event and conditionally fills it; most steady-state events (`message_update`, `tool_execution_start/end`) carry no fields, so the map is allocated, found empty, and discarded.
- **The Impact:** Minor. `qm hook` runs as a fresh OS process per event, whose dominant costs are fork/exec, parsing, and two flock-guarded synchronous file operations (`appendStateEventAt` + `r.Update`). An empty-map-literal header allocation runs once per process and is noise against that. Hygiene only.
- **Remediation:**
  ```go
  // Before
  fields := map[string]interface{}{}
  if sessionFile != "" { fields["session_file"] = sessionFile }
  if piSessionID != "" { fields["pi_session_id"] = piSessionID }
  if hasRecent { fields["recent_count"] = len(recent) }
  if len(fields) > 0 { ev.Fields = fields }

  // After
  if sessionFile != "" || piSessionID != "" || hasRecent {
      fields := make(map[string]interface{}, 3)
      if sessionFile != "" { fields["session_file"] = sessionFile }
      if piSessionID != "" { fields["pi_session_id"] = piSessionID }
      if hasRecent { fields["recent_count"] = len(recent) }
      ev.Fields = fields
  }
  ```

#### saidSnippet splits the entire 64 KiB transcript tail before scanning in reverse
- **Component/File:** `cmd/hook.go` (lines 294-298 call site, 631-667 `saidSnippet`; split at 632)
- **Hot path:** per-turn (Stop/done event only, when payload `LastAssistantMessage` absent)
- **The Issue:** On the `done` event, when `LastAssistantMessage` is absent, `saidSnippet` does `strings.Split(string(tail), "\n")` over the 64 KiB tail — allocating a `[]string` of every line — then walks it in reverse and returns on the first matching assistant line (typically near the end).
- **The Impact:** Once per turn-end (not per tool call), and only when the payload lacks the message (the comment at 287-291 notes that is common). Allocates a large slice + string copy for a result drawn from the last few lines. The fix removes only the `[]string` allocation; the per-line `json.Unmarshal` cost is unchanged, but the loop returns on the first match from EOF, so few unmarshals run.
- **Remediation:**
  ```go
  // Before
  lines := strings.Split(string(tail), "\n")
  for i := len(lines) - 1; i >= 0; i-- {
      raw := strings.TrimSpace(lines[i])
      // ...
  }

  // After
  s := string(tail)
  for end := len(s); end > 0; {
      start := strings.LastIndexByte(s[:end], '\n') + 1
      raw := strings.TrimSpace(s[start:end])
      end = start - 1
      if raw == "" { continue }
      // ...decode raw, return on first assistant match...
  }
  ```

#### Tracker OrderSessionRows copies the full SessionRow into a map used only for existence checks
- **Component/File:** `internal/tracker/session.go` (lines 213-238; `byID` declared 215, populated 222, read for membership 230)
- **Hot path:** per full tracker rebuild (broad changes, cache misses, uncacheable deltas — *not* every refresh)
- **The Issue:** `OrderSessionRows` builds `byID := make(map[string]SessionRow, len(rows))` and stores a full `SessionRow` value per row, but the map is only read for a membership test (`if _, ok := byID[row.ParentID]; ok`). `SessionRow` is a large value type (~17 strings, a `time.Time`, ints, a bool, a `*quest.LoopRuntime` — well over 200 bytes), so this copies every row's entire struct just to answer yes/no.
- **The Impact:** Per full rebuild, O(rows) large-struct copies. Correction to the original framing: this is *not* on every serve snapshot refresh — the frequent incremental (`TrackerForChange`) and clock (`clockTracker`) paths clone the cached snapshot and never invoke the fetcher. `OrderSessionRows` runs only via `fullTracker`, an I/O-dominated path (`DiscoverSessions`, per-session `LoadSessionStateAt`, quest HTML+regex, tmux `ListSessions`), where a flat ~250-byte struct copy per row is negligible. Pure hygiene.
- **Remediation:**
  ```go
  // Before
  order := make(map[string]int, len(rows))
  byID := make(map[string]SessionRow, len(rows))
  // ...
  for i, row := range rows {
      order[row.ID] = i
      byID[row.ID] = row
  }
  // ...
  case "worker":
      if _, ok := byID[row.ParentID]; ok {

  // After
  order := make(map[string]int, len(rows))
  exists := make(map[string]struct{}, len(rows))
  // ...
  for i := range rows {
      order[rows[i].ID] = i
      exists[rows[i].ID] = struct{}{}
  }
  // ...
  case "worker":
      if _, ok := exists[row.ParentID]; ok {
  ```

#### GroupRowsByRepo grows the units slice without pre-allocation
- **Component/File:** `internal/tracker/session.go` (lines 276-293)
- **Hot path:** per full tracker rebuild
- **The Issue:** `var units []unit` starts nil and grows via `append` once per top-level unit. The upper bound is `len(rows)` (every row could be its own unit when there are no masters). Each `unit` also carries a `rows []SessionRow`.
- **The Impact:** Minor per-rebuild reallocation of the units backing array. Session counts are small (single digits to low tens), so savings are negligible — this is consistency with the adjacent pre-sized slices (`ordered := make(...)` at line 299, and `OrderSessionRows` at 251).
- **Remediation:**
  ```go
  // Before
  var units []unit
  for i := 0; i < len(rows); {

  // After
  units := make([]unit, 0, len(rows))
  for i := 0; i < len(rows); {
  ```

#### agent.Resolve rebuilds the entire DefaultConfig on every fallback lookup
- **Component/File:** `internal/agent/registry.go` (lines 123-127; allocation at `config.go:35-46`)
- **Hot path:** per session-continue/spawn, only on the registry-miss fallback branch
- **The Issue:** In `Resolve`'s fallback branch, `DefaultConfig().Agents[name]` allocates a fresh map and calls `d.defaultConfig()` on every `providerDef`, then indexes a single key and discards the rest.
- **The Impact:** Minor. `Resolve` returns early when `registry.Get(name)` succeeds, which is the steady-state path; the `DefaultConfig()` call only runs on a registry miss, and even then it is a 5-entry map allocation on a user-initiated continue/spawn (session lifecycle), not a per-event loop. A memoized package-level map (mirroring the existing `specsByName = buildSpecsByName()` pattern at `descriptor.go:33`) is a clean hygiene fix.
- **Remediation:**
  ```go
  // Before
  cfg := AgentConfig{}
  if builtin, ok := DefaultConfig().Agents[name]; ok {
      cfg = builtin
  }
  return constructor(cfg), nil

  // After
  cfg := AgentConfig{}
  if builtin, ok := defaultConfigAgents()[name]; ok { // package-level memoized map
      cfg = builtin
  }
  return constructor(cfg), nil
  ```

#### FailureMessage / failureSignature recompute failingResults + bounded output twice per loop iteration
- **Component/File:** `internal/quests/loop/engine.go` (lines 188-201; helpers at 232-247, 266-286, 288-314)
- **Hot path:** per failing-and-injecting auto-gate iteration (agent done-edge, agent-turn cadence)
- **The Issue:** On a failing iteration the engine calls `failureSignature(results)` (which calls `failingResults` + `boundedOutput` per failure to build a sha256) and then `FailureMessage(results)` (which calls `failingResults` + `boundedOutput` *again* per failure). `failingResults` allocates+sorts a fresh slice; `boundedOutput` does `strings.TrimRight`, `strings.Split(output, "\n")` and `len([]rune(output))` over the *full* untruncated output — allocation-heavy on large gate logs, done twice.
- **The Impact:** Doubles the sort + per-gate bounded-output work over potentially large gate output. Runs at agent-turn timescale (seconds–minutes apart), not a high-frequency throughput path, so the absolute frequency is low even though the duplicated work is real.
- **Remediation:**
  ```go
  // Before
  signature := failureSignature(results)
  // ...
  if err := e.Inject(ctx, FailureMessage(results)); err != nil {

  // After
  failures := failingResults(results)      // sort once
  bounded := boundedOutputs(failures)      // []string, computed once
  signature := failureSignatureFrom(failures, bounded)
  // ...
  if err := e.Inject(ctx, failureMessageFrom(failures, bounded)); err != nil {
  ```

#### Every serve update line triggers a full uncoalesced renderSnapshot() on the main thread
- **Component/File:** `app/Sources/App/AppDelegate.swift` (lines 524-535; render body 587-644)
- **Hot path:** per-event (every serve push line; bursts on subscribe and agent hook activity)
- **The Issue:** The serve read loop decodes one update per line on a background queue, then for *each* line does a separate `DispatchQueue.main.async` that calls `runtimeStore.apply(update)` followed by `renderSnapshot()`. `renderSnapshot()` reconciles dock route state, calls `dockView.apply`, builds `Set(...flatMap(\.sessions).map(\.id))` over all sessions (line 641), and prunes per-session/artifact caches every call. There is no coalescing, so N lines = N full renders on the UI thread; subscribe pushes board+tracker(+quest) as separate lines, and hook-driven changes push board+tracker rapidly.
- **The Impact:** Bounded. Each render is O(sessions) over a small collection with cheap ops; the server already dedupes identical topic payloads (`server.go:269`), and subscribe bursts (~3 lines) are once per reconnect. Coalescing to one render per runloop turn is correct/idiomatic hygiene and would also naturally cover the `onStatus` call site (line 537-544), which also calls `renderSnapshot()`.
- **Remediation:**
  ```swift
  // Before
  client.start(
      onUpdate: { [weak self] update in
          DispatchQueue.main.async {
              guard let self else { return }
              self.runtimeStore.apply(update)
              // ...
              self.renderSnapshot()
          }
      },

  // After
  client.start(
      onUpdate: { [weak self] update in
          DispatchQueue.main.async {
              guard let self else { return }
              self.runtimeStore.apply(update)
              if self.runtimeStore.snapshot.serviceStateMessage == nil {
                  self.runtimeStore.setServeConnectionState(.ready)
              }
              self.scheduleCoalescedRender() // sets a flag; renders once per runloop turn
          }
      },
  ```

#### Two ISO8601DateFormatter instances allocated per session on every tracker decode
- **Component/File:** `app/Sources/Core/Models/TrackerModels.swift` (lines 278-288; called from 243; array decode at 21)
- **Hot path:** per serve tracker push, once per session (background thread)
- **The Issue:** `parseInstant()` unconditionally constructs a fractional-seconds `ISO8601DateFormatter` (line 282) and, on the fallback path, a second plain one (line 287). `ISO8601DateFormatter` is one of the most expensive Foundation objects to allocate (it lazily builds an internal `CFDateFormatter` with locale/timezone state). It runs once per session inside `TrackerSession.init(from:)`.
- **The Impact:** Off-main alloc/ARC churn proportional to session count x tracker push frequency. Correction to the original framing: decode runs on a background `DispatchQueue` (`ServeClient.swift:13`), *not* the main thread, so there is no user-visible latency; and the second formatter only allocates on the rare non-fractional fallback. Caching as file-private statics is thread-safe here (configured once, read-only `.date(from:)`).
- **Remediation:**
  ```swift
  // Before
  let fractional = ISO8601DateFormatter()
  fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  if let date = fractional.date(from: value) { return date }
  return ISO8601DateFormatter().date(from: value)

  // After
  private static let fractionalInstantFormatter: ISO8601DateFormatter = {
      let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
  }()
  private static let plainInstantFormatter = ISO8601DateFormatter()
  // in parseInstant:
  if let date = Self.fractionalInstantFormatter.date(from: value) { return date }
  return Self.plainInstantFormatter.date(from: value)
  ```

#### A fresh JSONDecoder is allocated for every serve update line
- **Component/File:** `app/Sources/Core/Models/ServeContract.swift` (lines 6-11; JSONDecoder construction on line 10; call site `app/Sources/App/Runtime/ServeClient.swift:207`)
- **Hot path:** per-event (every serve frame, on the background queue)
- **The Issue:** `ServeContract.update(fromLine:)` constructs a new `JSONDecoder()` on every call — the single decode entry point invoked once per newline-delimited frame in the read loop. The decoder is stateless here, and all decoding runs on a single serial queue, so a shared static decoder has zero thread-safety risk.
- **The Impact:** Minor heap churn proportional to push rate, off the main thread. The allocation is dwarfed by the per-line decode work (the custom `init(from:)` chain building `BoardSnapshot`/`TrackerSnapshot`/`QuestPayload`). Trivially eliminable hygiene. (Note: this is the same code site flagged from two lenses; one fix resolves both.)
- **Remediation:**
  ```swift
  // Before
  public static func update(fromLine line: Data) throws -> RuntimeUpdate? {
      guard !line.isEmpty else { return nil }
      return try JSONDecoder().decode(ServeEnvelope.self, from: line).update
  }

  // After
  private static let decoder = JSONDecoder()
  public static func update(fromLine line: Data) throws -> RuntimeUpdate? {
      guard !line.isEmpty else { return nil }
      return try decoder.decode(ServeEnvelope.self, from: line).update
  }
  ```

#### Mutation client opens and tears down a new Unix socket connection for every mutation
- **Component/File:** `app/Sources/App/Runtime/ServeMutationClient.swift` (lines 52-65)
- **Hot path:** per-mutation (user actions; `dir_suggest` can be per-query while typing)
- **The Issue:** `UnixSocketMutationClient.sendObject` connects a brand-new socket, writes one JSON-RPC request, blocks reading one response line, then `shutdown()`+`close()`es the fd on every mutation. There is no connection reuse, even though the streaming `ServeClient` already holds a persistent connection to the same socket and the Go server's `handleConn` loop (`server.go:170-214`) already multiplexes multiple requests per connection (it `continue`s rather than returns on mutation and `dir_suggest`).
- **The Impact:** Per-call cost is a local Unix-socket connect+close (tens of microseconds), bounded by human action in one focused sheet — not on the render path or per-frame. A persistent pooled connection is server-compatible but adds reconnect/EOF state to a currently trivially-correct method. A cheaper, more KISS win is to **debounce `requestPathSuggestions`** (`NewSessionSheet.swift:230`), which currently fires per-keystroke with only stale-response suppression — that cuts the higher-frequency caller's volume directly while keeping the simple connect-per-call code.
- **Remediation:**
  ```swift
  // Before
  private static func sendObject(_ object: [String: Any], socketPath: String) throws -> ServeMutationAck {
      let fd = try UnixSocketIO.connect(path: socketPath)
      defer { shutdown(fd, SHUT_RDWR); close(fd) }
      // ...
  }

  // After (preferred KISS path): debounce the per-keystroke caller instead of pooling.
  // requestPathSuggestions(...) -> wrap in a small debounce so a fast typist
  // issues one suggestion request after input settles, not one per keystroke.
  // (Connection pooling remains an option but adds reconnect/EOF state.)
  ```

#### SessionViewStateStore copies the entire id-keyed dictionary on every mutate
- **Component/File:** `app/Sources/Core/Stores/SessionViewStateStore.swift` (lines 28-37)
- **Hot path:** change-gated during renderSnapshot reconciliation; otherwise per user action
- **The Issue:** `mutate()` does `var newStates = statesBySessionID` (line 32), edits one key, then reassigns the property — forcing a full CoW duplication of the dictionary on every call. The local-copy-then-reassign was deliberate to trigger `@Observable`, but subscript assignment to a stored `@Observable` property already routes through the observation registrar.
- **The Impact:** A full dictionary CoW copy per `mutate` call. Correction to the original framing: the render-path calls (`AppDelegate.swift:598, 626`) are change-gated (only fire when reconciliation produces a different state or the selected artifact changes), and the other call sites are user-action-driven. The dictionary holds one small struct per tracked tmux session (single digits to low tens), so the copy is tiny — pure hygiene.
- **Remediation:**
  ```swift
  // Before
  var newStates = statesBySessionID
  var state = newStates[cleaned] ?? .initial
  body(&state)
  newStates[cleaned] = state
  statesBySessionID = newStates

  // After
  var state = statesBySessionID[cleaned] ?? .initial
  body(&state)
  statesBySessionID[cleaned] = state // @Observable still observes subscript assignment
  ```

#### commentCount recomputed by filtering the full comments array on every QuestDocument decode
- **Component/File:** `app/Sources/Core/Models/QuestModels.swift` (line 77)
- **Hot path:** per-event (per quest decoded in board/active-quest pushes)
- **The Issue:** `QuestDocument.init(from:)` computes `commentCount` via `comments.filter { $0.status != "resolved" }.count`, allocating a throwaway array just to take `.count`. Decode runs per quest in board payloads (`decodeLossyArray`) and for active-quest pushes.
- **The Impact:** One throwaway array allocation per quest decode, proportional to comment count. Marginal — it sits alongside five existing `decodeLossyArray` allocations in the same `init`. Hygiene. (The same pattern at line 60 is in the memberwise initializer, off the decode hot path; fix both for consistency if desired.)
- **Remediation:**
  ```swift
  // Before
  commentCount = comments.filter { $0.status != "resolved" }.count

  // After
  commentCount = comments.reduce(0) { $0 + ($1.status != "resolved" ? 1 : 0) }
  ```

#### Full quest-document re-hash on every arrow keypress in the viewer
- **Component/File:** `app/Sources/App/Quests/ItemViewer.swift` (lines 425-432); render-key impl at `app/Sources/Core/Rendering/QuestDetailRenderKey.swift` (lines 19-151)
- **Hot path:** per-keystroke (arrow navigation in quest detail)
- **The Issue:** `detailTargets(for:)` calls `detailRenderKey(for: quest)` *before* the cache check, so the key is rebuilt on every call even on a hit. `QuestDetailRenderKey.key` FNV-hashes the entire document byte-by-byte: every gate, every comment (id/anchor/status/author/body/createdAt), every body block (text/items/content/fallback), related, attachments, and both runtime maps. `moveQuestFocus` (323-346) calls `detailTargets` and is invoked from the keyDown handler for up/down arrows, so each arrow press re-hashes the whole document on the main thread.
- **The Impact:** Per-keystroke main-thread CPU proportional to quest size. Correction to the original framing: real quests are small (a few gates/comments/blocks), so the hash is sub-millisecond — wasteful but not perceptible; the cited "200-block" large-payload self-test does not exist in the repo. **Do not** apply the originally proposed "trust cache if non-empty / same id" fix: it would break same-ID content updates (gate toggle, new/resolved comment, runtime push), which keep the same quest id, do *not* call `clearDetailRenderCache`, and rely precisely on the key comparison being removed — producing stale focus/highlight ranges and wrong command dispatch.
- **Remediation:**
  ```swift
  // Before
  private func detailTargets(for quest: QuestDocument) -> [QuestDetailTarget] {
      let detailKey = detailRenderKey(for: quest)
      guard detailTargetCacheKey != detailKey else { return detailTargetCache }
      let commentBuckets = QuestDetailCursorLogic.commentBuckets(in: quest)
      return cacheDetailTargets(QuestDetailCursorLogic.targets(in: quest, commentBuckets: commentBuckets), key: detailKey)
  }

  // After
  // Navigation does not mutate the quest. Reuse the key already computed by the
  // render path (renderedDetailKey) instead of recomputing it per keystroke, or
  // invalidate the targets cache on a cheap content-revision counter. Either way
  // keep a key comparison so same-ID content updates still rebuild targets.
  private func detailTargets(for quest: QuestDocument) -> [QuestDetailTarget] {
      if let key = renderedDetailKey, detailTargetCacheKey == key { return detailTargetCache }
      let detailKey = detailRenderKey(for: quest)
      let commentBuckets = QuestDetailCursorLogic.commentBuckets(in: quest)
      return cacheDetailTargets(QuestDetailCursorLogic.targets(in: quest, commentBuckets: commentBuckets), key: detailKey)
  }
  ```

#### Tinted SF Symbol images rebuilt from scratch on every render, no cache
- **Component/File:** `app/Sources/App/SharedUI/RuntimeRenderers.swift` (lines 92-124; call sites `appendSymbol` 44-60, `alignmentCenteredImage` 196-234; `QuestViewerRenderer.swift:554-573`; gated at `ItemViewer.swift:116`)
- **Hot path:** per-render, on quest content change / quest switch (not per keystroke)
- **The Issue:** `AppSymbolStyle.image()` builds a brand-new `NSImage` per call (`NSImage(systemSymbolName:)` + `withSymbolConfiguration`, then an `NSImage(size:flipped:)` draw block doing `base.draw` + `setFill` + `fill(.sourceAtop)`), and sets `cacheMode = .never` (line 121) with no memoization. `appendSymbol` is invoked ~10+ times per detail render and itself triggers a *second* `NSImage` draw via `alignmentCenteredImage`. The same handful of fixed icons (`checkmark.circle.fill`, `circle.dashed`, `bubble.left`, `doc.text`) with identical color/size are re-rasterized every time; `toggleCheckboxImage` similarly lock/unlock-focuses a fresh `NSImage` per gate.
- **The Impact:** ~10-20 off-screen rasterizations (two draw passes each when alignment-centered) per detail render. Bounded: gated behind `renderedDetailKey == detailKey` (`ItemViewer.swift:116`), so it fires only on quest content change or quest navigation, not per keystroke or per runtime poll. A small `NSCache` keyed on the symbol parameters eliminates the redundant Core Graphics work on repeated quest switches.
- **Remediation:**
  ```swift
  // Before
  static func image(name: String, ..., color: NSColor, canvasSize: NSSize? = nil) -> NSImage? {
      guard let base = NSImage(systemSymbolName: name, ...)?.withSymbolConfiguration(...) else { return nil }
      let tinted = NSImage(size: size, flipped: false) { rect in /* draw + sourceAtop fill */ }
      tinted.cacheMode = .never
      return tinted
  }

  // After
  private static let symbolCache = NSCache<NSString, NSImage>()
  static func image(name: String, ..., color: NSColor, canvasSize: NSSize? = nil) -> NSImage? {
      let key = "\(name)|\(pointSize)|\(weight.rawValue)|\(color.hashValue)|\(canvasSize?.width ?? -1)x\(canvasSize?.height ?? -1)" as NSString
      if let cached = symbolCache.object(forKey: key) { return cached }
      guard let base = NSImage(systemSymbolName: name, ...)?.withSymbolConfiguration(...) else { return nil }
      let tinted = NSImage(size: size, flipped: false) { rect in /* draw + sourceAtop fill */ }
      symbolCache.setObject(tinted, forKey: key) // keep default cacheMode so the bitmap is retained
      return tinted
  }
  ```

#### GhosttyKitTerminalHost installs a local NSEvent monitor with no deinit cleanup
- **Component/File:** `app/Sources/App/Terminal/TerminalHost.swift` (install 220-229, sole teardown in `stop()` 236-243; class 197-486 has no deinit)
- **Hot path:** per-event (mouse-down) **if leaked**; startup-only install in the normal path
- **The Issue:** `init()` calls `installFocusClickMonitor()` (line 228), registering a local `NSEvent` monitor for every left/right/other mouse-down across the app (line 387). It is torn down only in `stop()` (line 243); the class has no `deinit`. The sibling `NativeTextSurface` uses the identical pattern but removes its monitor in `deinit` (`NativeViews.swift:64-66`). If a host instance is ever released without `stop()`, the monitor and its captured closure are never removed and keep firing on every mouse-down for the app session.
- **The Impact:** Latent, not active. Today the host is an `AppDelegate` singleton reused via `DeferredTerminalHost.install`, which calls the old host's `stop()` (line 86), so the normal path does not leak. The missing `deinit` makes the cleanup contract fragile if the host ever becomes per-session. At most one stray monitor under current lifecycle.
- **Remediation:**
  ```swift
  // Before
  init(config: TerminalLaunchConfig, onTitle: @escaping (String) -> Void) throws {
      // ...
      installFocusClickMonitor()
  }
  // (no deinit)

  // After
  init(config: TerminalLaunchConfig, onTitle: @escaping (String) -> Void) throws {
      // ...
      installFocusClickMonitor()
  }

  deinit {
      // Inline removeMonitor (removeFocusClickMonitor() is @MainActor-isolated):
      if let focusClickMonitor { NSEvent.removeMonitor(focusClickMonitor) }
  }
  ```

## Verification Next Steps

1. **Go serve double-marshal (Major):** Add a benchmark over `pushChanged`/`writeEnvelope` with a realistic board (dozens of quests + full runtime) and tracker payload — `go test -buildvcs=false -bench=BenchmarkPushChanged -benchmem ./internal/serve` — and compare alloc/op and ns/op before/after the `json.RawMessage` change. Confirm the clock-driven tracker push defeats dedup by capturing a `-cpuprofile` over a 60s simulated 1Hz tick loop and inspecting `json.Marshal` cumulative time in `go tool pprof`.

2. **Go hook path (Major):** Benchmark a full hook event end-to-end (`go test -buildvcs=false -bench=BenchmarkHookEvent -benchmem ./cmd`, or an `internal/state` harness around `AppendStateEvent` + `UpdateSessionState`), measuring flock acquire count and wall-time per event against the documented <20ms budget. Use `-blockprofile` with `go tool pprof -block` to confirm lock-hold contention against serve-side fsnotify readers, then re-measure after folding both into one `UpdateAndLog` critical section.

3. **Swift render + decode (Optimization):** In Xcode Instruments, run the **Time Profiler** while reconnecting `qm serve` and driving agent activity to capture the uncoalesced `renderSnapshot()` main-thread cost (look for back-to-back `renderSnapshot`/`Set` builds per push), and the **Allocations** instrument filtered on `ISO8601DateFormatter`, `JSONDecoder`, and `NSImage` to quantify per-tracker-push formatter churn and per-quest-switch symbol rasterizations. For the quest-viewer hash, profile holding an arrow key in a large quest detail and confirm `QuestDetailRenderKey.key` time drops to ~zero after caching the render key.