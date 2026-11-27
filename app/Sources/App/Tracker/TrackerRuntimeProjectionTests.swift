#if DEBUG
import Foundation
import QuestmasterCore

@MainActor
enum TrackerRuntimeProjectionTests {
    static func run() throws {
        try questOnlyUpdatesReuseTrackerAndRows()
        try sessionUpdatesDeriveTrackerAndRowsOnce()
        try expansionAndSelectionRecoveryUseCachedProjection()
    }

    private static func questOnlyUpdatesReuseTrackerAndRows() throws {
        let initial = snapshot(sessions: [master(), worker()], quests: [QuestItem(id: "quest", content: "before")])
        var projection = TrackerRenderProjection(snapshot: initial, expandedMasterIDs: ["master"])
        let initialTrackerCount = projection.trackerProjectionCount
        let initialRowsCount = projection.selectableRowsProjectionCount
        let initialRows = projection.selectableRows

        var questUpdate = initial
        questUpdate.tracker.quests[0].content = "after"
        let changes = projection.update(snapshot: questUpdate, expandedMasterIDs: ["master"])

        try expect(!changes.tracker && !changes.selectableRows, "a quest-only update should skip tracker and row projections")
        try expect(projection.trackerProjectionCount == initialTrackerCount, "a quest-only update rendered tracker rows")
        try expect(projection.selectableRowsProjectionCount == initialRowsCount, "a quest-only update rebuilt selectable rows")
        try expect(projection.selectableRows == initialRows, "a quest-only update changed the selectable rows")
    }

    private static func sessionUpdatesDeriveTrackerAndRowsOnce() throws {
        let initial = snapshot(sessions: [master(), worker()])
        var projection = TrackerRenderProjection(snapshot: initial, expandedMasterIDs: ["master"])
        let initialTrackerCount = projection.trackerProjectionCount
        let initialRowsCount = projection.selectableRowsProjectionCount

        var sessionUpdate = initial
        sessionUpdate.tracker.repos[0].sessions[1].state = "working"
        sessionUpdate.tracker.repos[0].sessions[1].lastExchange = TrackerExchange(
            kind: "report",
            at: Date(timeIntervalSince1970: 1_794_880_000)
        )
        let changes = projection.update(snapshot: sessionUpdate, expandedMasterIDs: ["master"])

        try expect(changes.tracker && changes.selectableRows, "a session update should refresh tracker and selectable rows")
        try expect(projection.trackerProjectionCount == initialTrackerCount + 1, "a session update should render tracker rows once")
        try expect(projection.selectableRowsProjectionCount == initialRowsCount + 1, "a session update should rebuild selectable rows once")
        try expect(projection.sessions[1].state == "working", "the avatar input kept the stale worker state")
        try expect(projection.sessions[1].lastExchange?.kind == "report", "the avatar input lost the worker report cue")
    }

    private static func expansionAndSelectionRecoveryUseCachedProjection() throws {
        let initial = snapshot(sessions: [master(), worker()])
        var projection = TrackerRenderProjection(snapshot: initial, expandedMasterIDs: [])
        var commandState = TrackerCommandState(selectedID: "worker")
        let collapsedRows = projection.selectableRows
        try expect(collapsedRows.map(\.id) == ["master"], "a collapsed worker should stay out of selectable rows")

        let trackerProjectionCount = projection.trackerProjectionCount
        let rowProjectionCount = projection.selectableRowsProjectionCount
        let expanded = projection.update(snapshot: initial, expandedMasterIDs: ["master"])
        try expect(!expanded.tracker && expanded.selectableRows, "expansion should reuse tracker rows and refresh visibility")
        try expect(projection.trackerProjectionCount == trackerProjectionCount, "expansion unnecessarily rendered tracker rows")
        try expect(projection.selectableRowsProjectionCount == rowProjectionCount + 1, "expansion should rebuild selectable rows once")
        try expect(projection.selectableRows.map(\.id) == ["master", "worker"], "expanded workers should be selectable")

        let previousRows = projection.selectableRows
        var workerRemoved = initial
        workerRemoved.tracker.repos[0].sessions.removeAll { $0.id == "worker" }
        _ = projection.update(snapshot: workerRemoved, expandedMasterIDs: ["master"])
        commandState.recoverStaleSelection(previousRows: previousRows, rows: projection.selectableRows, currentTerminalSessionID: nil)
        try expect(commandState.selectedID == "master", "selection recovery should use the prior cached row order")
    }

    private static func snapshot(sessions: [TrackerSession], quests: [QuestItem] = []) -> RuntimeSnapshot {
        var snapshot = RuntimeSnapshot.empty(sourceLabel: "synthetic")
        snapshot.apply(RuntimeUpdate(tracker: TrackerSnapshot(
            repos: [TrackerRepo(id: "project", name: "Project", color: "indigo", sessions: sessions)],
            quests: quests
        )))
        return snapshot
    }

    private static func master() -> TrackerSession {
        TrackerSession(id: "master", title: "Master", repoIdentity: "project", repoName: "Project", agent: "codex", role: "master")
    }

    private static func worker() -> TrackerSession {
        TrackerSession(id: "worker", title: "Worker", repoIdentity: "project", repoName: "Project", agent: "codex", role: "worker", parentID: "master")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw ProjectionFailure(message)
        }
    }
}

@MainActor
enum TrackerRuntimeProjectionBenchmark {
    private static let questUpdateCount = 80
    private static let sessionUpdateCount = 20
    private static let questCount = 100

    private struct UpdateSample {
        let update: RuntimeUpdate
        let isSessionUpdate: Bool
        let decodeMilliseconds: Double
    }

    private struct PipelineSample {
        let questApplyMilliseconds: [Double]
        let sessionApplyMilliseconds: [Double]
        let questTrackerProjections: Int
        let sessionTrackerProjections: Int

        var trackerProjections: Int { questTrackerProjections + sessionTrackerProjections }
    }

    static func run() throws {
        for sessionCount in [24, 120, 480] {
            let updates = try makeUpdates(sessionCount: sessionCount)
            let baseline = try measureLegacyPipeline(updates)
            let cached = try measureCachedPipeline(updates)
            let decode = updates.map(\.decodeMilliseconds)

            print(String(format:
                "TRACKER_BENCH sessions=%d updates=%d quests_per_snapshot=%d projections_total=%d/%d quest=%d/%d session=%d/%d quest_apply_p50_p95_ms=%.3f/%.3f->%.3f/%.3f session_apply_p50_p95_ms=%.3f/%.3f->%.3f/%.3f full_decode_p50_p95_ms=%.3f/%.3f",
                sessionCount,
                questUpdateCount + sessionUpdateCount,
                questCount,
                baseline.trackerProjections,
                cached.trackerProjections,
                baseline.questTrackerProjections,
                cached.questTrackerProjections,
                baseline.sessionTrackerProjections,
                cached.sessionTrackerProjections,
                percentile(baseline.questApplyMilliseconds, 0.50), percentile(baseline.questApplyMilliseconds, 0.95),
                percentile(cached.questApplyMilliseconds, 0.50), percentile(cached.questApplyMilliseconds, 0.95),
                percentile(baseline.sessionApplyMilliseconds, 0.50), percentile(baseline.sessionApplyMilliseconds, 0.95),
                percentile(cached.sessionApplyMilliseconds, 0.50), percentile(cached.sessionApplyMilliseconds, 0.95),
                percentile(decode, 0.50), percentile(decode, 0.95)
            ))
        }
    }

    private static func makeUpdates(sessionCount: Int) throws -> [UpdateSample] {
        var updates: [UpdateSample] = []
        updates.reserveCapacity(questUpdateCount + sessionUpdateCount + 1)
        for index in 0...(questUpdateCount + sessionUpdateCount) {
            let isSessionUpdate = index > questUpdateCount
            let state = isSessionUpdate && index.isMultiple(of: 2) ? "idle" : "working"
            let line = try trackerLine(
                sessionCount: sessionCount,
                questRevision: index,
                sessionState: state,
                exchangeRevision: isSessionUpdate ? index - questUpdateCount : nil
            )
            let started = DispatchTime.now().uptimeNanoseconds
            let update = try decodeOffMain(line)
            let decodeMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            updates.append(UpdateSample(update: update, isSessionUpdate: isSessionUpdate, decodeMilliseconds: decodeMilliseconds))
        }
        return updates
    }

    private static func decodeOffMain(_ line: Data) throws -> RuntimeUpdate {
        let semaphore = DispatchSemaphore(value: 0)
        let result = BenchmarkDecodeResult()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard let update = try ServeContract.update(fromLine: line) else {
                    throw ProjectionFailure("synthetic tracker line decoded no update")
                }
                result.finish(update: update)
            } catch {
                result.finish(error: error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.value()
    }

    private static func trackerLine(
        sessionCount: Int,
        questRevision: Int,
        sessionState: String,
        exchangeRevision: Int?
    ) throws -> Data {
        let sessions: [[String: Any]] = (0..<sessionCount).map { index in
            let groupIndex = index / 4
            let isMaster = index.isMultiple(of: 4)
            let id = isMaster ? "qm-m\(groupIndex)" : "qm-w\(index)"
            var session: [String: Any] = [
                "id": id,
                "title": "Synthetic session \(index)",
                "agent": "codex",
                "status": "active",
                "state": index == 0 ? sessionState : "working",
                "worker_count": isMaster ? 3 : 0,
                "elapsed_ms": 30_000,
                "repo": [
                    "identity": "synthetic-project",
                    "name": "Synthetic Project",
                    "path": "/tmp/synthetic-project",
                    "color": "indigo",
                ],
            ]
            if !isMaster {
                session["parent_id"] = "qm-m\(groupIndex)"
            }
            if index == 1, let exchangeRevision {
                let second = exchangeRevision % 60
                session["last_exchange"] = [
                    "kind": "report",
                    "at": String(format: "2026-11-27T00:00:%02dZ", second),
                ]
            }
            return session
        }
        let quests: [[String: Any]] = (0..<questCount).map { index in
            [
                "id": "quest-\(index)",
                "content": "Synthetic quest \(index), update \(questRevision), with a repeated body for a representative tracker payload.",
                "attachments": [[
                    "id": "attachment-\(index)",
                    "name": "fixture-\(questRevision).txt",
                    "path": "/tmp/synthetic/fixture-\(questRevision).txt",
                    "size": 4096,
                ]],
                "types": ["improvement"],
                "size": "M",
                "project_id": "synthetic-project",
                "project_name": "Synthetic Project",
            ] as [String: Any]
        }
        return try JSONSerialization.data(withJSONObject: [
            "protocol_version": ServeContract.protocolVersion,
            "type": "event",
            "topic": "tracker",
            "data": [
                "observed_at": "synthetic-\(questRevision)",
                "sessions": sessions,
                "quests": quests,
            ],
        ])
    }

    private static func measureLegacyPipeline(_ updates: [UpdateSample]) throws -> PipelineSample {
        let store = RuntimeStore(sourceLabel: "synthetic-benchmark", currentTerminalSessionID: "qm-m0")
        guard let initial = updates.first?.update else {
            throw ProjectionFailure("benchmark has no initial update")
        }
        store.apply(initial)
        var snapshot = store.snapshot
        var commandState = TrackerCommandState()
        let avatar = TrackerAvatarStage()
        let company = TrackerCompanyStage()
        var currentIsSessionUpdate = false
        var questProjectionCount = 0
        var sessionProjectionCount = 0
        let observation = store.observe {
            let previousRows = selectableRows(from: TrackerRenderer.tracker(snapshot))
            snapshot = store.snapshot
            let sessions = TrackerRenderer.flatSessions(in: TrackerRenderer.tracker(snapshot))
            TrackerAvatarLibrary.prefetch(for: sessions)
            let attachedID = TerminalSessionChipResolver.cleanSessionID(store.avatarAttachedSessionID)
            avatar.observe(sessions: sessions, attachedID: attachedID)
            company.observe(sessions: sessions, attachedID: attachedID)
            let rows = selectableRows(from: TrackerRenderer.tracker(snapshot))
            commandState.recoverStaleSelection(previousRows: previousRows, rows: rows, currentTerminalSessionID: store.currentTerminalSessionID)
            if currentIsSessionUpdate {
                sessionProjectionCount += 3
            } else {
                questProjectionCount += 3
            }
        }
        defer { observation.cancel() }
        var questSamples: [Double] = []
        var sessionSamples: [Double] = []
        for sample in updates.dropFirst() {
            currentIsSessionUpdate = sample.isSessionUpdate
            let started = DispatchTime.now().uptimeNanoseconds
            store.apply(sample.update)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            if sample.isSessionUpdate {
                sessionSamples.append(elapsed)
            } else {
                questSamples.append(elapsed)
            }
        }
        return PipelineSample(
            questApplyMilliseconds: questSamples,
            sessionApplyMilliseconds: sessionSamples,
            questTrackerProjections: questProjectionCount,
            sessionTrackerProjections: sessionProjectionCount
        )
    }

    private static func measureCachedPipeline(_ updates: [UpdateSample]) throws -> PipelineSample {
        let store = RuntimeStore(sourceLabel: "synthetic-benchmark", currentTerminalSessionID: "qm-m0")
        guard let initial = updates.first?.update else {
            throw ProjectionFailure("benchmark has no initial update")
        }
        store.apply(initial)
        var snapshot = store.snapshot
        var projection = TrackerRenderProjection(snapshot: snapshot, expandedMasterIDs: [])
        var commandState = TrackerCommandState()
        let avatar = TrackerAvatarStage()
        let company = TrackerCompanyStage()
        var currentIsSessionUpdate = false
        var questProjectionCount = 0
        var sessionProjectionCount = 0
        let observation = store.observe {
            let previousRows = projection.selectableRows
            snapshot = store.snapshot
            let countBeforeUpdate = projection.trackerProjectionCount
            _ = projection.update(snapshot: snapshot, expandedMasterIDs: [])
            let derivedCount = projection.trackerProjectionCount - countBeforeUpdate
            if currentIsSessionUpdate {
                sessionProjectionCount += derivedCount
            } else {
                questProjectionCount += derivedCount
            }
            let sessions = projection.sessions
            TrackerAvatarLibrary.prefetch(for: sessions)
            let attachedID = TerminalSessionChipResolver.cleanSessionID(store.avatarAttachedSessionID)
            avatar.observe(sessions: sessions, attachedID: attachedID)
            company.observe(sessions: sessions, attachedID: attachedID)
            let rows = projection.selectableRows
            commandState.recoverStaleSelection(previousRows: previousRows, rows: rows, currentTerminalSessionID: store.currentTerminalSessionID)
        }
        defer { observation.cancel() }
        var questSamples: [Double] = []
        var sessionSamples: [Double] = []
        for sample in updates.dropFirst() {
            currentIsSessionUpdate = sample.isSessionUpdate
            let started = DispatchTime.now().uptimeNanoseconds
            store.apply(sample.update)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            if sample.isSessionUpdate {
                sessionSamples.append(elapsed)
            } else {
                questSamples.append(elapsed)
            }
        }
        return PipelineSample(
            questApplyMilliseconds: questSamples,
            sessionApplyMilliseconds: sessionSamples,
            questTrackerProjections: questProjectionCount,
            sessionTrackerProjections: sessionProjectionCount
        )
    }

    private static func selectableRows(from tracker: TrackerRenderedTracker) -> [TrackerSession] {
        TrackerSessionShortcuts.selectableSessions(TrackerRenderer.flatSessions(in: tracker), expandedMasterIDs: [])
    }

    private static func percentile(_ values: [Double], _ percentile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count) * percentile).rounded(.up)) - 1))
        return sorted[index]
    }
}

private final class BenchmarkDecodeResult: @unchecked Sendable {
    private let lock = NSLock()
    private var update: RuntimeUpdate?
    private var error: Error?

    func finish(update: RuntimeUpdate) {
        lock.lock()
        self.update = update
        lock.unlock()
    }

    func finish(error: Error) {
        lock.lock()
        self.error = error
        lock.unlock()
    }

    func value() throws -> RuntimeUpdate {
        lock.lock()
        defer { lock.unlock() }
        if let error { throw error }
        guard let update else {
            throw ProjectionFailure("background benchmark decode returned no result")
        }
        return update
    }
}

private struct ProjectionFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
#endif
