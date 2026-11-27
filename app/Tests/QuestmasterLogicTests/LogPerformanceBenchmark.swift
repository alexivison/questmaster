import Foundation
import QuestmasterCore

/// Run with `QM_LOG_PERF_BENCH=1 swift run --package-path app QuestmasterLogicTests`.
/// Inputs and timed operations stay in memory; no app instance or live state is used.
enum LogPerformanceBenchmark {
    private static let workerCount = 8
    private static let receiveIterations = 15
    private static let questIterations = 21

    static func run() {
        let entries = syntheticEntries(count: 3_200)
        let boundedEntries = Array(entries.suffix(WorkerChatStore.maxRecords))
        let fullSamples = receiveSamples(entries: entries)
        let boundedSamples = receiveSamples(entries: boundedEntries)
        let questSamples = questSyncSamples()
        print("WorkerChatStore.receive, 3200 synthetic entries: median \(milliseconds(fullSamples)) ms, n=\(fullSamples.count)")
        print("WorkerChatStore.receive, newest 400 of those entries: median \(milliseconds(boundedSamples)) ms, n=\(boundedSamples.count)")
        print("QuestLogStore.sync, 500 synthetic 1 KiB quests, unchanged no-match filter: median \(milliseconds(questSamples)) ms, n=\(questSamples.count)")
    }

    private static func receiveSamples(entries: [WorkerFeedEntry]) -> [Double] {
        for _ in 0..<3 { _ = receiveOnce(entries: entries) }
        return (0..<receiveIterations).map { _ in receiveOnce(entries: entries) }
    }

    private static func receiveOnce(entries: [WorkerFeedEntry]) -> Double {
        let store = WorkerChatStore(calendar: Calendar(identifier: .gregorian))
        let sessions = [TrackerSession(id: "synthetic-master", title: "Synthetic Master", repoName: "example-app", agent: "claude", role: "master")]
            + (0..<workerCount).map { index in
                TrackerSession(id: "synthetic-worker-\(index)", title: "Synthetic Worker \(index)", repoName: "example-app", agent: "codex", role: "worker", parentID: "synthetic-master")
            }
        guard let request = store.sync(selectedSessionID: "synthetic-master", sessions: sessions, isVisible: true) else {
            fatalError("synthetic Worker Log setup did not produce a request")
        }
        let started = DispatchTime.now().uptimeNanoseconds
        _ = store.receive(WorkerFeedPayload(entries: entries), for: request)
        return Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
    }

    private static func questSyncSamples() -> [Double] {
        let quests = (0..<500).map { index in
            let prefix = "Synthetic quest \(index) "
            return QuestItem(
                id: "synthetic-quest-\(index)",
                content: prefix + String(repeating: "x", count: 1_024 - prefix.count),
                projectID: "synthetic-project",
                projectName: "Synthetic Project",
                createdAt: String(format: "2026-11-%02dT12:00:00Z", index % 27 + 1)
            )
        }
        let filter = QuestListFilter(text: "zzzz-never-present")
        let store = QuestLogStore()
        store.sync(quests: freshQuests(quests), repos: [], filter: filter)
        for _ in 0..<3 { store.sync(quests: freshQuests(quests), repos: [], filter: QuestListFilter(text: filter.text)) }
        return (0..<questIterations).map { _ in
            let snapshot = freshQuests(quests)
            let nextFilter = QuestListFilter(text: filter.text)
            let started = DispatchTime.now().uptimeNanoseconds
            store.sync(quests: snapshot, repos: [], filter: nextFilter)
            return Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        }
    }

    private static func freshQuests(_ quests: [QuestItem]) -> [QuestItem] {
        quests.map { quest in
            QuestItem(
                id: String(decoding: Array(quest.id.utf8), as: UTF8.self),
                content: String(decoding: Array(quest.content.utf8), as: UTF8.self),
                attachments: quest.attachments,
                types: quest.types,
                size: quest.size,
                projectID: quest.projectID,
                projectPath: quest.projectPath,
                projectName: quest.projectName,
                createdAt: quest.createdAt,
                updatedAt: quest.updatedAt,
                sessionID: quest.sessionID
            )
        }
    }

    private static func syntheticEntries(count: Int) -> [WorkerFeedEntry] {
        (0..<count).map { index in
            let prefix = "Synthetic log entry \(index) "
            return WorkerFeedEntry(
                timestamp: String(format: "2026-11-27T12:%02d:%02dZ", (index / 60) % 60, index % 60),
                workerID: "synthetic-worker-\(index % workerCount)",
                workerTitle: "Synthetic Worker \(index % workerCount)",
                kind: "say",
                text: prefix + String(repeating: "x", count: 1_024 - prefix.count)
            )
        }
    }

    private static func milliseconds(_ samples: [Double]) -> String {
        let sorted = samples.sorted()
        let middle = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        return String(format: "%.4f", median)
    }
}
