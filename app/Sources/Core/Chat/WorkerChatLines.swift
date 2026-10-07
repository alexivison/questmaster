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

public enum WorkerChatTimeHeaderPolicy {
    public static let minimumGap: TimeInterval = 5 * 60

    /// A header precedes the first line, and any line stamped in a different clock minute at least
    /// `minimumGap` after the previous line.
    public static func needsHeader(after previous: Date?, at current: Date, calendar: Calendar) -> Bool {
        guard let previous else {
            return true
        }
        guard current.timeIntervalSince(previous) >= minimumGap else {
            return false
        }
        return clockMinute(previous, calendar) != clockMinute(current, calendar)
    }

    public static func label(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "[%02d:%02d]", parts.hour ?? 0, parts.minute ?? 0)
    }

    private static func clockMinute(_ date: Date, _ calendar: Calendar) -> DateComponents {
        calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }
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

    /// `records` must already be in chronological order. A worker's consecutive tool actions fold
    /// into one line that keeps its place while the run stays open; only that worker's next
    /// non-action entry closes it.
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
            if let index = openRuns[record.workerID], case .run(var tools) = drafts[index].body {
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
        var previous: Date?
        for draft in drafts {
            if WorkerChatTimeHeaderPolicy.needsHeader(after: previous, at: draft.timestamp, calendar: calendar) {
                lines.append(WorkerChatLine(
                    id: "h\(draft.id)",
                    content: .timeHeader(WorkerChatTimeHeaderPolicy.label(for: draft.timestamp, calendar: calendar))
                ))
            }
            previous = draft.timestamp
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
