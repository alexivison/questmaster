import Foundation

/// One run of text in a chat line; the view maps `style` to a font and colour.
public struct WorkerChatSegment: Equatable {
    public enum Style: Equatable {
        case name
        case normal
        case muted
        case working
        case done
        case blocked
    }

    public let text: String
    public let style: Style

    public init(_ text: String, _ style: Style) {
        self.text = text
        self.style = style
    }
}

public struct WorkerChatLine: Identifiable, Equatable {
    public enum Content: Equatable {
        case timeHeader(String)
        case entry(agent: String, segments: [WorkerChatSegment])
    }

    public let id: String
    public let content: Content

    public init(id: String, content: Content) {
        self.id = id
        self.content = content
    }
}

/// One feed entry the store keeps; `sequence` is its arrival order and gives its line a stable id.
struct WorkerChatRecord: Equatable {
    enum Kind: Equatable {
        case status(WorkerChatSegment.Style)
        case action(tool: String)
        case say
        case message
        case report
    }

    let sequence: Int
    let timestamp: Date
    let workerID: String
    let kind: Kind
    let text: String
}

enum WorkerChatLineBuilder {
    static let maxNameLength = 16
    private static let actionVerb = "Cast"
    private static let reportTag = "[Report]"

    private struct Tool {
        let name: String
        var count: Int
    }

    private enum Body {
        case record(WorkerChatRecord)
        case run([Tool])
    }

    private struct Draft {
        let id: String
        let timestamp: Date
        let workerID: String
        var body: Body
    }

    /// `records` must already be in chronological order. A worker's tool actions in the same
    /// calendar minute fold into one line at the first action's position; other workers' entries
    /// do not close it, but that worker's next non-action or later-minute action starts a new line.
    static func lines(
        from records: [WorkerChatRecord],
        names: [String: String],
        agents: [String: String],
        calendar: Calendar
    ) -> [WorkerChatLine] {
        var drafts: [Draft] = []
        var openRuns: [String: Int] = [:]
        for record in records {
            guard case .action(let tool) = record.kind else {
                openRuns[record.workerID] = nil
                drafts.append(Draft(id: "e\(record.sequence)", timestamp: record.timestamp, workerID: record.workerID, body: .record(record)))
                continue
            }
            if let index = openRuns[record.workerID],
               case .run(var tools) = drafts[index].body,
               calendar.isDate(record.timestamp, equalTo: drafts[index].timestamp, toGranularity: .minute) {
                if let toolIndex = tools.firstIndex(where: { $0.name == tool }) {
                    tools[toolIndex].count += 1
                } else {
                    tools.append(Tool(name: tool, count: 1))
                }
                drafts[index].body = .run(tools)
                continue
            }
            openRuns[record.workerID] = drafts.count
            drafts.append(Draft(id: "e\(record.sequence)", timestamp: record.timestamp, workerID: record.workerID, body: .run([Tool(name: tool, count: 1)])))
        }

        var lines: [WorkerChatLine] = []
        var lastHeader: Date?
        for draft in drafts {
            if lastHeader.map({ !calendar.isDate(draft.timestamp, equalTo: $0, toGranularity: .minute) }) ?? true {
                let parts = calendar.dateComponents([.hour, .minute], from: draft.timestamp)
                lines.append(WorkerChatLine(
                    id: "h\(draft.id)",
                    content: .timeHeader(String(format: "[%02d:%02d]", parts.hour ?? 0, parts.minute ?? 0))
                ))
                lastHeader = draft.timestamp
            }
            let name = displayName(names[draft.workerID] ?? draft.workerID) + ":"
            lines.append(WorkerChatLine(
                id: draft.id,
                content: .entry(agent: agents[draft.workerID] ?? "", segments: [WorkerChatSegment(name, .name)] + segments(for: draft.body))
            ))
        }
        return lines
    }

    static func displayName(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxNameLength else {
            return trimmed
        }
        return String(trimmed.prefix(maxNameLength)) + "…"
    }

    private static func segments(for body: Body) -> [WorkerChatSegment] {
        switch body {
        case .run(let tools):
            let calls = tools.map { $0.count > 1 ? "[\($0.name)](x\($0.count))" : "[\($0.name)]" }
            return [
                WorkerChatSegment(" \(actionVerb) ", .muted),
                WorkerChatSegment(calls.joined(separator: " "), .normal),
            ]
        case .record(let record):
            return segments(for: record)
        }
    }

    private static func segments(for record: WorkerChatRecord) -> [WorkerChatSegment] {
        let text = record.text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch record.kind {
        case .status(let style):
            return [
                WorkerChatSegment(" Received status ", .muted),
                WorkerChatSegment("[\(text.capitalized)]", style),
            ]
        case .report:
            return [
                WorkerChatSegment(" \(reportTag) ", .normal),
                WorkerChatSegment(text, .muted),
            ]
        case .say, .message, .action:
            return [WorkerChatSegment(" " + text, .normal)]
        }
    }
}
