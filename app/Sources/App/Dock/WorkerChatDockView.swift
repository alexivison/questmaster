import AppKit
import QuestmasterCore
import SwiftUI

/// Geometry measured from `Chat Item Text v2.svg` and `Worker Chat v2.svg`: JetBrains Mono at 12pt
/// (7.2pt advance, 16pt lines), rows 10pt apart, 8pt around a time header, the name starting 20pt
/// right of the text edge (the logo column), 20pt from the card edge on every side.
enum WorkerChatMetrics {
    static let inset: CGFloat = 20
    static let lineHeight: CGFloat = 16
    static let rowGap: CGFloat = 10
    static let headerGap: CGFloat = 8
    static let logoColumnWidth: CGFloat = 20
    static let logoSide: CGFloat = 15

    /// SwiftUI sizes a text line at the font's ceiled height (JetBrains Mono 12: 15.84 → 16). Any
    /// shortfall to `lineHeight` (a smaller fallback font) is added between wrapped lines and
    /// under each entry, so every row is a whole number of 16pt lines.
    static var lineSlack: CGFloat {
        lineHeight - (AppFonts.chat.ascender - AppFonts.chat.descender + AppFonts.chat.leading).rounded(.up)
    }

    /// Design `#D8DEE9`, `#9DA7B1`, `#768390` and the three tag colours; each lands on an existing
    /// palette token (nearest by RGB for the first two, exact for the rest).
    enum Color {
        static let text = AppPalette.bright
        static let muted = AppPalette.dim
        static let timeHeader = AppPalette.controlBorder
        static let working = AppPalette.trackerNeedsInput
        static let done = AppPalette.trackerDone
        static let blocked = AppPalette.trackerBlocked
        static let logoTint = ActionBarMetrics.SourceColor.logo
    }

    static func font(for style: WorkerChatSegment.Style) -> NSFont {
        style == .name ? AppFonts.chatName : AppFonts.chat
    }

    static func color(for style: WorkerChatSegment.Style) -> NSColor {
        switch style {
        case .name, .normal: Color.text
        case .muted: Color.muted
        case .working: Color.working
        case .done: Color.done
        case .blocked: Color.blocked
        }
    }

    static func topGap(before line: WorkerChatLine, after previous: WorkerChatLine?) -> CGFloat {
        guard let previous else {
            return 0
        }
        return isTimeHeader(line) || isTimeHeader(previous) ? headerGap : rowGap
    }

    private static func isTimeHeader(_ line: WorkerChatLine) -> Bool {
        if case .timeHeader = line.content {
            return true
        }
        return false
    }
}

/// The worker chat dock: a chronological feed, newest at the bottom. A tab bar can sit above
/// `WorkerChatFeedView` later without touching the feed itself.
struct WorkerChatDockView: View {
    let store: WorkerChatStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.lines.isEmpty {
                emptyState
            } else {
                WorkerChatFeedView(lines: store.lines)
            }
            readNotice
        }
    }

    @ViewBuilder
    private var readNotice: some View {
        if let notice = store.readNotice {
            Text(notice)
                .font(AppFonts.chat.swiftUI)
                .foregroundStyle(WorkerChatMetrics.Color.muted.swiftUI)
                .lineLimit(2)
                .padding(.horizontal, WorkerChatMetrics.inset)
                .padding(.bottom, WorkerChatMetrics.inset)
        }
    }

    private var emptyState: some View {
        EmptyStatePane(
            title: store.isAttached ? "No worker activity yet." : "No worker chat.",
            message: store.isAttached
                ? "Worker status, tool use and messages appear here."
                : "Attach to a master session or one of its workers.",
            padding: EdgeInsets(
                top: Token.Spacing.content,
                leading: Token.Spacing.content,
                bottom: Token.Spacing.content,
                trailing: Token.Spacing.content
            )
        )
    }
}

struct WorkerChatFeedView: View {
    let lines: [WorkerChatLine]
    @State private var isAtBottom = true

    private static let bottomID = "worker-chat-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    WorkerChatRows(lines: lines)
                    bottomSentinel
                }
                .padding(WorkerChatMetrics.inset)
            }
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(.bottom)
            .onChange(of: lines) { _, _ in
                guard isAtBottom else {
                    return
                }
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
        }
    }

    private var bottomSentinel: some View {
        Color.clear
            .frame(height: 1)
            .id(Self.bottomID)
            .onAppear { isAtBottom = true }
            .onDisappear { isAtBottom = false }
    }
}

struct WorkerChatRows: View {
    let lines: [WorkerChatLine]

    private struct Row: Identifiable {
        let line: WorkerChatLine
        let topGap: CGFloat
        var id: String { line.id }
    }

    private var rows: [Row] {
        lines.indices.map { index in
            Row(line: lines[index], topGap: WorkerChatMetrics.topGap(before: lines[index], after: index > 0 ? lines[index - 1] : nil))
        }
    }

    var body: some View {
        ForEach(rows) { row in
            WorkerChatLineView(line: row.line)
                .padding(.top, row.topGap)
        }
    }
}

private struct WorkerChatLineView: View {
    let line: WorkerChatLine

    var body: some View {
        switch line.content {
        case .timeHeader(let label):
            Text(label)
                .font(AppFonts.chat.swiftUI)
                .foregroundStyle(WorkerChatMetrics.Color.timeHeader.swiftUI)
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(height: WorkerChatMetrics.lineHeight)
        case .entry(let agent, let segments):
            HStack(alignment: .top, spacing: 0) {
                logo(agent: agent)
                    .frame(width: WorkerChatMetrics.logoColumnWidth, height: WorkerChatMetrics.logoSide, alignment: .leading)
                text(for: segments)
                    .lineSpacing(WorkerChatMetrics.lineSlack)
                    .padding(.bottom, WorkerChatMetrics.lineSlack)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func logo(agent: String) -> some View {
        if let image = TrackerAgentMark.image(for: agent, side: WorkerChatMetrics.logoSide, tint: WorkerChatMetrics.Color.logoTint) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: WorkerChatMetrics.logoSide, height: WorkerChatMetrics.logoSide)
        }
    }

    private func text(for segments: [WorkerChatSegment]) -> Text {
        segments.reduce(Text("")) { text, segment in
            text + Text(segment.text)
                .font(WorkerChatMetrics.font(for: segment.style).swiftUI)
                .foregroundStyle(WorkerChatMetrics.color(for: segment.style).swiftUI)
        }
    }
}
