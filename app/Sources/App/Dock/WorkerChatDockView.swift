import AppKit
import QuestmasterCore
import SwiftUI

/// Geometry measured from `Chat Item.svg` and `Chat Item Text.svg`: JetBrains Mono at 12pt (7.2pt
/// advance, 16pt lines). Each item starts with its HH:MM time in a 41pt column (five characters, then
/// a 5pt gap), then the agent logo and bold name in a 20pt logo column. Wrapped lines start `wrapIndent`
/// in from the item's left edge, so they run under the time. Items sit 10pt apart (the design's 9 on the
/// 5pt rhythm), 20pt from the card edge on every side.
enum WorkerChatMetrics {
    static let inset = Space.section
    /// The font's line, typography rather than spacing: JetBrains Mono 12's 15.84 ceiled.
    static let lineHeight: CGFloat = 16
    static let itemGap = Space.item
    /// The HH:MM time's five 7.2pt character advances.
    static let timeAdvance: CGFloat = 36
    static let timeColumnWidth = timeAdvance + Space.row
    static let logoColumnWidth: CGFloat = 20
    static let logoSide: CGFloat = 15
    /// Wrapped lines start this far in from the item's left edge, under the time.
    static let wrapIndent = Space.item
    /// Where the name starts on the first line, measured from the wrapped lines' left edge.
    static let nameLead: CGFloat = timeColumnWidth + logoColumnWidth - wrapIndent
    /// The design sets the time about half a point above the name's baseline.
    static let timeLift: CGFloat = 0.5

    /// SwiftUI sizes a text line at the font's ceiled height (JetBrains Mono 12: 15.84 → 16). Any
    /// shortfall to `lineHeight` (a smaller fallback font) is added between wrapped lines and
    /// under each entry, so every row is a whole number of 16pt lines.
    static var lineSlack: CGFloat {
        lineHeight - (AppFonts.chat.ascender - AppFonts.chat.descender + AppFonts.chat.leading).rounded(.up)
    }

    /// Design `#D8DEE9` and `#9DA7B1` land on the nearest palette tokens by RGB; `#768390` is exact, and
    /// `#E8B34A` has its own `chatWorking` token. Worker free text is `#D9DBB8`, which has its own `chatSpeech` token. Tags are
    /// named by RPG rarity: common (white) for tool calls, rare and epic for item tags. Status tags keep
    /// their status colours.
    enum Color {
        static let text = AppPalette.bright
        static let speech = AppPalette.chatSpeech
        static let muted = AppPalette.dim
        static let time = AppPalette.controlBorder
        static let common = AppPalette.bright
        static let rare = AppPalette.rarityRare
        static let epic = AppPalette.rarityEpic
        static let working = AppPalette.chatWorking
        static let done = AppPalette.trackerDone
        static let blocked = AppPalette.trackerBlocked
        static let logoTint = AppPalette.muted
    }

    static func color(for style: WorkerChatSegment.Style) -> NSColor {
        switch style {
        case .name: Color.text
        case .normal: Color.speech
        case .muted: Color.muted
        case .working: Color.working
        case .done: Color.done
        case .blocked: Color.blocked
        case .rarity(let rarity): color(for: rarity)
        }
    }

    private static func color(for rarity: WorkerChatRarity) -> NSColor {
        switch rarity {
        case .common: Color.common
        case .rare: Color.rare
        case .epic: Color.epic
        }
    }
}

/// The worker log dock: the filter's chips, then a chronological feed, newest at the bottom. The filter's dropdown
/// hangs `Space.row` under the top bar at the right, over the chips and the feed; a click on either closes it.
struct WorkerChatDockView: View {
    let store: WorkerChatStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !store.chips.isEmpty {
                WorkerLogChipRow(chips: store.chips, onClear: store.clearFilter)
            }
            if store.isKnownEmpty {
                EmptyState()
            } else if !store.lines.isEmpty {
                WorkerChatFeedView(lines: store.lines, revision: store.revision, trimCount: store.trimCount, appended: store.lastUpdateAppended)
            }
            readNotice
        }
        .overlay { filterMenu }
    }

    @ViewBuilder
    private var filterMenu: some View {
        if store.menu.isOpen {
            ZStack(alignment: .topTrailing) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { store.closeMenu() }
                WorkerLogFilterPanel(rows: store.menuRows, filter: store.filter, cursor: store.menu.cursor, onToggle: store.toggleRow)
                    .padding(.top, Space.row)
                    .padding(.trailing, WorkerChatMetrics.inset)
            }
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
}

/// A scrolling feed that keeps its bottom edge in view while the user stays at the bottom. The
/// rows sit in a plain VStack so their wrapped heights are exact (a lazy stack estimates them and
/// drifts off the bottom as lines arrive), and `WorkerChatBottomFollower` does the pinning.
struct WorkerChatFeedView: View {
    let lines: [WorkerChatLine]
    let revision: Int
    let trimCount: Int
    let appended: Bool

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    WorkerChatRows(lines: lines)
                }
                // The follower sits on the rows, not the padded frame: a short feed's frame keeps the viewport's
                // height, so only the rows' own frame shows an arrival.
                .background(WorkerChatBottomFollower(revision: revision, trimCount: trimCount, appended: appended))
                .padding(WorkerChatMetrics.inset)
                .frame(minHeight: viewport.size.height, alignment: .bottom)
                .background(ScrollerHider())
            }
            .scrollIndicators(.hidden)
        }
    }
}

/// Pins the enclosing scroll view to its bottom whenever the content resizes, until the user
/// scrolls above the bottom; scrolling back down (or `G`) resumes following. Observes the clip and
/// document views directly, so mouse, trackpad and key scrolling all count, with no per-frame work.
/// While following, arrivals glide in from their old place and fade in as they arrive.
private struct WorkerChatBottomFollower: NSViewRepresentable {
    let revision: Int
    let trimCount: Int
    let appended: Bool

    func makeNSView(context: Context) -> WorkerChatBottomFollowerView {
        WorkerChatBottomFollowerView()
    }

    func updateNSView(_ view: WorkerChatBottomFollowerView, context: Context) {
        view.noteLinesUpdate(revision: revision, trimCount: trimCount, appended: appended)
    }
}

final class WorkerChatBottomFollowerView: NSView {
    private(set) var isFollowing = true
    private var lastOffset: CGFloat?
    private var lastHeights: Heights?
    private var lastRevision = 0
    private var lastTrimCount = 0
    private var isTrimUpdate = false
    private var isAppendUpdate = false

    /// `rows` and `rowsTop` are this view's own height and its top in the document: the rows' place.
    private struct Heights: Equatable {
        let viewport: CGSize
        let content: CGFloat
        let rows: CGFloat
        let rowsTop: CGFloat
    }
    private var observers: [NSObjectProtocol] = []

    override var isFlipped: Bool { true }

    /// SwiftUI can render one lines update several times before its layout reports the new height.
    /// Only a new revision starts another update, so the trim and append flags are set once per update
    /// and hold until the next one, even when the trim leaves the height unchanged. An append counts
    /// only after a layout: the first lines of a feed have no old place to arrive from. Anything else
    /// ends the fades now, since an edit or a trim can leave the height unchanged and the bands stale.
    func noteLinesUpdate(revision: Int, trimCount: Int, appended: Bool) {
        guard revision != lastRevision else {
            return
        }
        lastRevision = revision
        isTrimUpdate = trimCount != lastTrimCount
        isAppendUpdate = appended && lastHeights != nil
        lastTrimCount = trimCount
        if !isAppendUpdate, let scrollView = enclosingScrollView {
            WorkerChatMotion.clearFades(scrollView)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard window != nil,
              let scrollView = enclosingScrollView,
              let documentView = scrollView.documentView else {
            return
        }
        scrollView.wantsLayer = true
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        clipView.postsFrameChangedNotifications = true
        documentView.postsFrameChangedNotifications = true
        postsFrameChangedNotifications = true
        observers = [
            observeSync(NSView.boundsDidChangeNotification, of: clipView, in: scrollView),
            observeSync(NSView.frameDidChangeNotification, of: clipView, in: scrollView),
            observeSync(NSView.frameDidChangeNotification, of: documentView, in: scrollView),
            observeSync(NSView.frameDidChangeNotification, of: self, in: scrollView),
            NotificationCenter.default.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scrollView, queue: .main) { [weak scrollView] _ in
                MainActor.assumeIsolated {
                    if let scrollView { WorkerChatMotion.cancelGlide(scrollView) }
                }
            },
        ]
        sync(scrollView)
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func observeSync(_ name: Notification.Name, of object: Any, in scrollView: NSScrollView) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self, weak scrollView] _ in
            MainActor.assumeIsolated {
                if let scrollView { self?.sync(scrollView) }
            }
        }
    }

    /// A size change (content grew, window resized) re-pins while following, and otherwise
    /// re-checks whether the bottom edge came into view. An origin change at unchanged sizes is the
    /// user scrolling, which decides whether to follow. Origin changes that come with a size change
    /// are AppKit clamping and say nothing about the user. Internal so the self-tests can run a layout
    /// through it without waiting for its notifications.
    func sync(_ scrollView: NSScrollView) {
        let clipView = scrollView.contentView
        guard let documentView = scrollView.documentView else {
            return
        }
        let rowsTop = convert(bounds, to: documentView).minY
        let heights = Heights(viewport: clipView.bounds.size, content: documentView.bounds.height, rows: bounds.height, rowsTop: rowsTop)
        if heights != lastHeights {
            // Content that grew or shrank under a steady viewport glides. The first layout doesn't (there
            // is no old place to glide from), a viewport resize doesn't, and neither does a trim: it
            // removes lines above the viewport, so the bottom shift it causes is not an arrival.
            let previous = lastHeights
            let glides = previous?.viewport == heights.viewport && !isTrimUpdate
            // A feed that crosses the viewport moves its rows in the document as well as the clip. Fades in
            // flight move with the rows, and the pin's glide covers the rows' move too.
            let rowsShift = heights.rowsTop - (previous?.rowsTop ?? heights.rowsTop)
            lastHeights = heights
            WorkerChatMotion.moveFades(scrollView, by: rowsShift)
            updateArrival(scrollView, previous: previous, heights: heights, glides: glides)
            if isFollowing {
                pinIfFollowing(scrollView, rowsShift: rowsShift, glides: glides)
            } else {
                lastOffset = clipView.bounds.origin.y
                isFollowing = WorkerChatScroll.isAtBottom(
                    offset: clipView.bounds.origin.y,
                    viewportHeight: heights.viewport.height,
                    contentHeight: heights.content
                )
            }
            return
        }
        guard clipView.bounds.origin.y != lastOffset else {
            return
        }
        lastOffset = clipView.bounds.origin.y
        isFollowing = WorkerChatScroll.isAtBottom(
            offset: clipView.bounds.origin.y,
            viewportHeight: clipView.bounds.height,
            contentHeight: documentView.bounds.height
        )
    }

    /// An append while following fades in the rows it added, which sit below the old ones. A layout that doesn't
    /// change the rows' height changes nothing. Any other change clears the fades, since it moves the rows they
    /// sit over.
    private func updateArrival(_ scrollView: NSScrollView, previous: Heights?, heights: Heights, glides: Bool) {
        guard glides, let previous else {
            WorkerChatMotion.clearFades(scrollView)
            return
        }
        guard heights.rows != previous.rows else {
            return
        }
        guard isAppendUpdate, isFollowing, heights.rows > previous.rows, let documentView = scrollView.documentView else {
            WorkerChatMotion.clearFades(scrollView)
            return
        }
        let addedRows = convert(NSRect(x: 0, y: previous.rows, width: bounds.width, height: heights.rows - previous.rows), to: documentView)
        WorkerChatMotion.fadeInRows(scrollView, from: addedRows.minY, to: addedRows.maxY)
    }

    private func pinIfFollowing(_ scrollView: NSScrollView, rowsShift: CGFloat, glides: Bool) {
        let clipView = scrollView.contentView
        guard isFollowing, let documentView = scrollView.documentView else {
            return
        }
        // A feed that fits the viewport keeps the clip at the top.
        let bottom = WorkerChatScroll.bottomOffset(viewportHeight: clipView.bounds.height, contentHeight: documentView.bounds.height) ?? 0
        lastOffset = bottom
        // Nothing moved in the clip or the rows, so there is nothing to glide. A new glide would restart one still running.
        guard bottom != clipView.bounds.origin.y || rowsShift != 0 else {
            return
        }
        WorkerChatMotion.scroll(scrollView, toOffset: bottom, rowsShift: rowsShift, glides: glides)
    }
}

struct WorkerChatRows: View {
    let lines: [WorkerChatLine]

    var body: some View {
        VStack(alignment: .leading, spacing: WorkerChatMetrics.itemGap) {
            ForEach(lines) { line in
                WorkerChatLineView(line: line)
            }
        }
    }
}

struct WorkerChatLineView: View {
    let line: WorkerChatLine
    var chatFont = AppFonts.chat
    var nameFont = AppFonts.chatName

    var body: some View {
        text
            .lineSpacing(WorkerChatMetrics.lineSlack)
            .padding(.bottom, WorkerChatMetrics.lineSlack)
            .padding(.leading, WorkerChatMetrics.wrapIndent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topLeading) { time }
            .overlay(alignment: .topLeading) { logo }
    }

    private var time: some View {
        Text(line.time)
            .font(chatFont.swiftUI)
            .foregroundStyle(WorkerChatMetrics.Color.time.swiftUI)
            .offset(y: -WorkerChatMetrics.timeLift)
    }

    /// A space kerned out to the name leads the first line. It sits on the first line only, so wrapped lines
    /// start at the block's left edge and run under the time. The kerning tops the space up to the full lead.
    private var text: Text {
        line.segments.reduce(
            Text(" ").font(chatFont.swiftUI).kerning(WorkerChatMetrics.nameLead - spaceAdvance)
        ) { text, segment in
            text + Text(segment.text)
                .font(font(for: segment.style).swiftUI)
                .foregroundStyle(WorkerChatMetrics.color(for: segment.style).swiftUI)
        }
    }

    private var spaceAdvance: CGFloat {
        (" " as NSString).size(withAttributes: [.font: chatFont]).width
    }

    private func font(for style: WorkerChatSegment.Style) -> NSFont {
        style == .name ? nameFont : chatFont
    }

    @ViewBuilder
    private var logo: some View {
        if let image = TrackerAgentMark.image(for: line.agent, side: WorkerChatMetrics.logoSide, tint: WorkerChatMetrics.Color.logoTint) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: WorkerChatMetrics.logoSide, height: WorkerChatMetrics.logoSide)
                .padding(.leading, WorkerChatMetrics.timeColumnWidth)
        }
    }
}
