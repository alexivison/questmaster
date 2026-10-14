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
        case rarity(WorkerChatRarity)
    }

    public let text: String
    public let style: Style

    public init(_ text: String, _ style: Style) {
        self.text = text
        self.style = style
    }
}

/// The RPG tier a bracketed tag is drawn in. Tool calls are common; item tags carry their own tier.
public enum WorkerChatRarity: Equatable {
    case common
    case rare
    case epic
}

/// One feed entry: its HH:MM time, the agent whose logo it shows, and its text runs.
public struct WorkerChatLine: Identifiable, Equatable {
    public let id: String
    public let time: String
    public let agent: String
    public let segments: [WorkerChatSegment]

    public init(id: String, time: String, agent: String, segments: [WorkerChatSegment]) {
        self.id = id
        self.time = time
        self.agent = agent
        self.segments = segments
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
        case instructions
    }

    let sequence: Int
    let timestamp: Date
    let workerID: String
    let kind: Kind
    let text: String
}

/// Lines built from a record list. `sources[i]` lists the sequences of the records that line `i` shows.
struct WorkerChatLineBuild {
    var lines: [WorkerChatLine]
    var sources: [[Int]]

    /// The newest `count` lines, with the records they show.
    func newest(_ count: Int) -> WorkerChatLineBuild {
        WorkerChatLineBuild(lines: Array(lines.suffix(count)), sources: Array(sources.suffix(count)))
    }
}

enum WorkerChatLineBuilder {
    static let maxNameLength = 16
    private static let actionVerb = "Cast"

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
        var sequence: Int
        var sources: [Int]
        var body: Body
    }

    /// `records` must already be in chronological order. Same-worker actions in one minute fold
    /// unless a same-worker non-action or earlier-arriving other-worker line follows the run.
    static func build(
        from records: [WorkerChatRecord],
        names: [String: String],
        agents: [String: String],
        calendar: Calendar
    ) -> WorkerChatLineBuild {
        var drafts: [Draft] = []
        var openRuns: [String: Int] = [:]
        for record in records {
            guard case .action(let tool) = record.kind else {
                openRuns[record.workerID] = nil
                drafts.append(Draft(id: "e\(record.sequence)", timestamp: record.timestamp, workerID: record.workerID, sequence: record.sequence, sources: [record.sequence], body: .record(record)))
                continue
            }
            if let index = openRuns[record.workerID],
               case .run(var tools) = drafts[index].body,
               calendar.isDate(record.timestamp, equalTo: drafts[index].timestamp, toGranularity: .minute),
               !drafts.dropFirst(index + 1).contains(where: { $0.workerID != record.workerID && $0.sequence < record.sequence }) {
                if let toolIndex = tools.firstIndex(where: { $0.name == tool }) {
                    tools[toolIndex].count += 1
                } else {
                    tools.append(Tool(name: tool, count: 1))
                }
                drafts[index].sequence = min(drafts[index].sequence, record.sequence)
                drafts[index].sources.append(record.sequence)
                drafts[index].body = .run(tools)
                continue
            }
            openRuns[record.workerID] = drafts.count
            drafts.append(Draft(id: "e\(record.sequence)", timestamp: record.timestamp, workerID: record.workerID, sequence: record.sequence, sources: [record.sequence], body: .run([Tool(name: tool, count: 1)])))
        }

        return WorkerChatLineBuild(
            lines: drafts.map { draft in
                WorkerChatLine(
                    id: draft.id,
                    time: timeLabel(draft.timestamp, calendar: calendar),
                    agent: agents[draft.workerID] ?? "",
                    segments: [WorkerChatSegment(displayName(names[draft.workerID] ?? draft.workerID) + ":", .name)] + segments(for: draft.body)
                )
            },
            sources: drafts.map(\.sources)
        )
    }

    static func displayName(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxNameLength else {
            return trimmed
        }
        return String(trimmed.prefix(maxNameLength)) + "…"
    }

    private static func timeLabel(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    private static func segments(for body: Body) -> [WorkerChatSegment] {
        switch body {
        case .run(let tools):
            let calls = tools.map { $0.count > 1 ? "[\($0.name)](x\($0.count))" : "[\($0.name)]" }
            return [
                WorkerChatSegment(" \(actionVerb) ", .muted),
                WorkerChatSegment(calls.joined(separator: " "), .rarity(.common)),
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
            return itemSegments(verb: "Used item", item: "Debriefing Stone", rarity: .rare)
        case .instructions:
            return itemSegments(verb: "Received item", item: "Scroll of Orders", rarity: .epic)
        case .say, .message, .action:
            return [WorkerChatSegment(" " + text, .normal)]
        }
    }

    /// Report and instruction entries show their item tag only; their text is never drawn.
    private static func itemSegments(verb: String, item: String, rarity: WorkerChatRarity) -> [WorkerChatSegment] {
        [
            WorkerChatSegment(" \(verb) ", .muted),
            WorkerChatSegment("[\(item)]", .rarity(rarity)),
        ]
    }
}
