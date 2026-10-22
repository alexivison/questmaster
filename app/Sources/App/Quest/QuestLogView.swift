import AppKit
import QuestmasterCore
import SwiftUI

/// Positions from user-quests-modal-v3.svg (900 x 780), and from -v2-nobody.svg for the plain page, whose ink v3
/// keeps, re-fitted to the 5pt rhythm (2026-10-22): 20 from the panel's edges and 10 under the shared header
/// (ModalSheetHeader), where v3 draws 30 and 30. Baselines are where the design's glyph outlines sit.
private enum QuestLogMetrics {
    static let sheetSize = CGSize(width: 900, height: 780)
    /// Filter field (`FilterBar`): 350 x 35 at (20, 80).
    static let filterOrigin = CGPoint(x: Space.section, y: ModalFormMetrics.contentTop)
    static let filterHeight = FilterBarMetrics.height
    /// List column, straight under the field: x 20-370. A section title's baseline sits 21 below the previous
    /// box (the field or the last row) and 9 above its first row; rows are 25 high, 5 apart (a 30pt pitch),
    /// with the text baseline 16.5 down and 10 in.
    static let listOrigin = CGPoint(x: filterOrigin.x, y: filterOrigin.y + filterHeight)
    static let listWidth: CGFloat = 350
    static let rowHeight = ControlHeight.compact
    static let rowSpacing = Space.row
    static let rowBaseline: CGFloat = 16.5
    static let rowTextInset = Space.item
    static let rowCornerRadius: CGFloat = 3
    static let sectionHeight: CGFloat = 30
    static let sectionBaseline: CGFloat = 21
    static let markSize: CGFloat = 5
    /// Page: the design's 473 x 596 page (its parchment clipped to the top 594) scaled whole to 500 x 630, the same
    /// proportions, 10 right of the list, its top on the filter's.
    static let artPageWidth: CGFloat = 473
    static let artParchmentHeight: CGFloat = 594
    static let pageOrigin = CGPoint(x: listOrigin.x + listWidth + Space.item, y: filterOrigin.y)
    static let pageSize = CGSize(width: 500, height: 630)
    static let pageScale = pageSize.width / artPageWidth
    static let parchmentHeight = artParchmentHeight * pageScale
    static let pageCornerRadius: CGFloat = 5
    static let parchmentEdgeStroke: CGFloat = 3
    static let parchmentEdgeOpacity = 0.35
    static let parchmentOpacity = 0.7
    /// Page ink, page-local: the titled page's title baseline 34 down, the 12pt description's 36 below it on a
    /// 16pt line, 20 in on each side; a plain page's line sits on a baseline 32 down. Then the rule 24 below the last
    /// baseline and the footer's baseline 32 below the rule. The vines and rules scale with the page; the text doesn't.
    static let inkInset = Space.section
    static let bodyWidth = pageSize.width - 2 * inkInset
    static let titleWidth: CGFloat = 325
    static let titleBaseline: CGFloat = 34
    static let plainBaseline: CGFloat = 32
    static let bodyBaselineGap: CGFloat = 36
    static let bodyLineHeight: CGFloat = 16
    static let ruleBaselineGap: CGFloat = 24
    static let footerBaselineGap: CGFloat = 32
    static let inkBottomInset: CGFloat = 25
    /// How far in from the page's bottom (top) edge the ink fades while more of it lies below (above).
    static let overflowFadeHeight: CGFloat = 30
    /// The vine strips in the design's page points: the title's spans y 20-38 with the title baseline at 34; the
    /// rule's spans y 198-215 with the rule at 206.
    static let titleVineBand = (top: CGFloat(20), height: CGFloat(18))
    static let ruleVineBand = (top: CGFloat(198), height: CGFloat(17))
    static let titleVineLines: [CGRect] = [
        CGRect(x: 20, y: 28.5, width: 18.6394, height: 1),
        CGRect(x: 434.361, y: 28.5, width: 18.6394, height: 1),
    ]
    static let rule = CGRect(x: 22.946, y: 206, width: 427.845, height: 1)
    /// Footer: each diamond sits `footerDiamondGap` after the part before it and before the next part; its centre
    /// sits 3.5 above the baseline. Wrapped lines sit on the 15pt pitch.
    static let footerLinePitch: CGFloat = 15
    static let footerDiamondArtSize: CGFloat = 5.66
    static let footerDiamondGap = Space.item
    static let footerDiamondRaise: CGFloat = 3.5
    /// Buttons: the shared angled buttons at the design's 200 wide, 10 apart, centred, 20 under the page.
    static let buttonWidth: CGFloat = 200
    static let buttonSpacing = Space.item
    static let buttonTop = pageOrigin.y + pageSize.height + Space.section
    static let pageTransition = 0.12
    /// Opening: the paper unrolls top to bottom as the fade-in ends, and the ink follows it down.
    static let unrollDelay = 0.12 * ModalFade.slowdown
    static let unrollDuration = 0.25 * ModalFade.slowdown
    static let inkInDelay = 0.25 * ModalFade.slowdown
    static let inkInDuration = 0.18 * ModalFade.slowdown
}

struct QuestLogView: View {
    static let size = QuestLogMetrics.sheetSize

    let store: QuestLogStore
    let filter: QuestLogFilter
    var pageScroll = QuestLogPageScroll()
    /// Offscreen renders can't focus the field; this draws it as focused (its border, its suggestions).
    var previewFocused = false
    var onCommand: (QuestLogCommand) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            ModalSheetHeader(title: "Quest Log")
                .frame(width: QuestLogMetrics.sheetSize.width)
            QuestLogList(store: store)
                .frame(width: QuestLogMetrics.listWidth, height: QuestLogMetrics.pageOrigin.y + QuestLogMetrics.pageSize.height - QuestLogMetrics.listOrigin.y, alignment: .top)
                .offset(x: QuestLogMetrics.listOrigin.x, y: QuestLogMetrics.listOrigin.y)
            QuestLogPageView(page: store.selectedPage, pageID: store.selectedID, isFiltering: filter.isActive, pageScroll: pageScroll)
                .offset(x: QuestLogMetrics.pageOrigin.x, y: QuestLogMetrics.pageOrigin.y)
            buttons
                .frame(width: QuestLogMetrics.sheetSize.width)
                .offset(y: QuestLogMetrics.buttonTop)
            FilterBar(
                tokens: filter.tokens,
                query: Binding(get: { filter.query }, set: { filter.setQuery($0) }),
                placeholder: "@project: or text",
                focusNonce: filter.focusNonce,
                suggestions: filter.suggestions,
                highlightedSuggestionID: filter.selectedSuggestionID,
                accessibilityLabel: "Filter quests",
                previewFocused: previewFocused,
                onCommand: { filter.handleCommand(keyCode: $0) },
                onRemoveToken: { filter.removeToken($0) },
                onSelectSuggestion: { filter.acceptSuggestion($0) }
            )
            .frame(width: QuestLogMetrics.listWidth)
            .offset(x: QuestLogMetrics.filterOrigin.x, y: QuestLogMetrics.filterOrigin.y)
        }
        .frame(width: QuestLogMetrics.sheetSize.width, height: QuestLogMetrics.sheetSize.height, alignment: .topLeading)
        .scoopedPanel()
    }

    private var buttons: some View {
        HStack(spacing: QuestLogMetrics.buttonSpacing) {
            Button("Send forth") { onCommand(.start) }
                .buttonStyle(GoldButtonStyle(width: QuestLogMetrics.buttonWidth))
            Button("Edit") { onCommand(.edit) }
                .buttonStyle(OutlineButtonStyle(width: QuestLogMetrics.buttonWidth))
            Button("Abandon") { onCommand(.delete) }
                .buttonStyle(DangerButtonStyle(width: QuestLogMetrics.buttonWidth))
        }
        .disabled(store.selectedID == nil)
    }
}

/// The Quest Log as an entry on the in-window modal stack. While it is the top modal it takes every plain key:
/// its own keys become commands and the rest are swallowed so they never reach the terminal underneath.
/// Command-key shortcuts pass through to the menus. A modal it opens (Edit, Abandon's confirmation, New
/// Session) goes on top and takes the keys until it closes.
struct QuestLogModal: View {
    static let stackID: AnyHashable = "quest-log"

    let store: QuestLogStore
    let filter: QuestLogFilter
    let pageScroll: QuestLogPageScroll
    var onCommand: (QuestLogCommand) -> Void

    var body: some View {
        // A fresh page per opening, so the parchment unrolls when the log opens and not on later changes.
        QuestLogView(store: store, filter: filter, pageScroll: pageScroll, onCommand: onCommand)
            .id(store.openGeneration)
            .background(SheetKeyEventMonitor { handle($0) })
    }

    private func handle(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            return false
        }
        // While the filter is being edited its field editor takes the keys (its arrows, Return and Esc come
        // back through `QuestLogFilter.handleCommand`).
        if event.window?.firstResponder is NSTextView {
            return false
        }
        var modifiers: Set<Keymap.Modifier> = []
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if let command = QuestLogCommand.from(characters: event.charactersIgnoringModifiers, keyCode: event.keyCode, modifiers: modifiers) {
            onCommand(command)
        }
        return true
    }
}

extension InWindowModalStack {
    func presentQuestLog(_ modal: QuestLogModal) {
        present(id: QuestLogModal.stackID, kind: .questLog, AnyView(modal))
    }
}

// MARK: - List

private struct QuestLogList: View {
    let store: QuestLogStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(store.sections) { section in
                        // The title and the first row scroll into view together.
                        VStack(alignment: .leading, spacing: 0) {
                            BaselineText(section.title, font: AppFonts.monoSmall, color: AppPalette.accent, baseline: QuestLogMetrics.sectionBaseline)
                                .frame(height: QuestLogMetrics.sectionHeight, alignment: .top)
                            if let first = section.quests.first {
                                row(first).id(first.id)
                            }
                        }
                        .id(Self.sectionStartID(section.id))
                        VStack(alignment: .leading, spacing: QuestLogMetrics.rowSpacing) {
                            ForEach(section.quests.dropFirst()) { quest in
                                row(quest).id(quest.id)
                            }
                        }
                        .padding(.top, section.quests.count > 1 ? QuestLogMetrics.rowSpacing : 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ScrollerHider())
            }
            .scrollIndicators(.hidden)
            // The view is rebuilt per opening, so the kept selection is scrolled to as it appears.
            .onAppear { scroll(proxy, to: store.selectedID) }
            .onChange(of: store.selectedID) { _, id in
                scroll(proxy, to: id)
            }
            .onChange(of: store.scrollNonce) { _, _ in
                scroll(proxy, to: store.selectedID)
            }
        }
    }

    private static func sectionStartID(_ sectionID: String) -> String {
        "section-start:\(sectionID)"
    }

    private func scroll(_ proxy: ScrollViewProxy, to id: String?) {
        switch QuestDisplayState.scrollTarget(for: id, in: store.sections) {
        case .top:
            if let first = store.sections.first {
                proxy.scrollTo(Self.sectionStartID(first.id), anchor: .top)
            }
        case .sectionStart(let sectionID):
            proxy.scrollTo(Self.sectionStartID(sectionID))
        case .row(let id):
            proxy.scrollTo(id)
        case nil:
            break
        }
    }

    private func row(_ quest: QuestItem) -> some View {
        let look = RowLook.lasting(selected: quest.id == store.selectedID)
        return BaselineText(
            QuestLogPage(quest: quest, project: "").title,
            font: look.bold ? AppFonts.questLogRowSelected : AppFonts.questLogRow,
            color: look.text.color,
            baseline: QuestLogMetrics.rowBaseline
        )
        .lineLimit(1)
        .padding(.leading, QuestLogMetrics.rowTextInset)
        .frame(maxWidth: .infinity, minHeight: QuestLogMetrics.rowHeight, maxHeight: QuestLogMetrics.rowHeight, alignment: .topLeading)
        // The pointer shows the hover look; a click or the keys change the selection, which the page follows.
        .stateRow(look, cornerRadius: QuestLogMetrics.rowCornerRadius)
        .overlay(alignment: .leading) {
            if store.markedIDs.contains(quest.id) {
                DiamondShape()
                    .fill(AppPalette.accent.swiftUI)
                    .frame(width: QuestLogMetrics.markSize, height: QuestLogMetrics.markSize)
                    .padding(.leading, (QuestLogMetrics.rowTextInset - QuestLogMetrics.markSize) / 2)
            }
        }
        .onTapGesture { store.select(quest.id) }
    }
}

// MARK: - Page

private struct QuestLogPageView: View {
    let page: QuestLogPage?
    let pageID: String?
    let isFiltering: Bool
    let pageScroll: QuestLogPageScroll
    @State private var unrolled = false
    @State private var inked = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            paper
                .modifier(UnrollMask(progress: unrolled ? 1 : 0))
            ink
                .frame(height: QuestLogMetrics.parchmentHeight)
                .frame(maxHeight: .infinity, alignment: .top)
                .animation(.easeOut(duration: QuestLogMetrics.pageTransition), value: pageID)
                .opacity(inked ? 1 : 0)
        }
        .frame(width: QuestLogMetrics.pageSize.width, height: QuestLogMetrics.pageSize.height)
        .onAppear(perform: unroll)
    }

    private var paper: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: QuestLogMetrics.pageCornerRadius)
                .fill(AppPalette.item.swiftUI)
            QuestLogParchment()
                .frame(height: QuestLogMetrics.parchmentHeight)
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// Plays once per opening (the view is rebuilt for each). Reduce Motion skips it: the paper is just there.
    private func unroll() {
        guard !reduceMotion else {
            unrolled = true
            inked = true
            return
        }
        withAnimation(.easeOut(duration: QuestLogMetrics.unrollDuration).delay(QuestLogMetrics.unrollDelay)) {
            unrolled = true
        }
        withAnimation(.easeOut(duration: QuestLogMetrics.inkInDuration).delay(QuestLogMetrics.inkInDelay)) {
            inked = true
        }
    }

    @ViewBuilder private var ink: some View {
        if let page {
            ScrollView(.vertical) {
                QuestLogInk(page: page)
                    .background(ScrollerHider(onApply: { scrollView in
                        hideScroller(on: scrollView)
                        pageScroll.attach(scrollView)
                    }))
            }
            .scrollIndicators(.hidden)
            // The overflow cue: while more ink lies below (or above, once scrolled), it fades out over the
            // page's last (or first) lines. Only the ink fades; the paper stays as it is.
            .mask {
                let ink = AppPalette.mask.swiftUI
                VStack(spacing: 0) {
                    LinearGradient(colors: [pageScroll.moreAbove ? .clear : ink, ink], startPoint: .top, endPoint: .bottom)
                        .frame(height: QuestLogMetrics.overflowFadeHeight)
                    ink
                    LinearGradient(colors: [ink, pageScroll.moreBelow ? .clear : ink], startPoint: .top, endPoint: .bottom)
                        .frame(height: QuestLogMetrics.overflowFadeHeight)
                }
            }
            .animation(.easeOut(duration: QuestLogMetrics.pageTransition), value: pageScroll.moreBelow)
            .animation(.easeOut(duration: QuestLogMetrics.pageTransition), value: pageScroll.moreAbove)
            .id(pageID)
            .transition(.opacity)
        } else {
            Text(isFiltering ? "No quest matches the filter." : "No quests yet. ⌘T posts one.")
                .font(AppFonts.monoSmall.swiftUI)
                .foregroundStyle(AppPalette.panel.swiftUI)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The unroll: the paper shows from the top down to `progress` of its height. SwiftUI animates the one
/// value and only this mask's scale changes per frame; the parchment Canvas under it never redraws.
private struct UnrollMask: ViewModifier, Animatable {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.mask(alignment: .top) {
            Rectangle().scaleEffect(x: 1, y: progress, anchor: .top)
        }
    }
}

private struct QuestLogInk: View {
    let page: QuestLogPage

    var body: some View {
        Group {
            switch page.layout {
            case .titled:
                BaselineColumn(gaps: [QuestLogMetrics.titleBaseline, QuestLogMetrics.bodyBaselineGap, QuestLogMetrics.ruleBaselineGap, QuestLogMetrics.footerBaselineGap]) {
                    title
                    paragraph(page.body)
                    rule
                    footer
                }
            case .plain:
                BaselineColumn(gaps: [QuestLogMetrics.plainBaseline, QuestLogMetrics.ruleBaselineGap, QuestLogMetrics.footerBaselineGap]) {
                    paragraph(page.title)
                    rule
                    footer
                }
            }
        }
        .padding(.bottom, QuestLogMetrics.inkBottomInset)
    }

    /// Plain page text: the description, or a title-only quest's one line.
    private func paragraph(_ text: String) -> some View {
        Text(QuestLogPage.wrapped(text, columns: columns(QuestLogMetrics.bodyWidth, AppFonts.questLogBody)))
            .font(AppFonts.questLogBody.swiftUI)
            .lineSpacing(QuestLogMetrics.bodyLineHeight - naturalLineHeight(AppFonts.questLogBody))
            .foregroundStyle(AppPalette.panel.swiftUI)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: QuestLogMetrics.bodyWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, QuestLogMetrics.inkInset)
    }

    /// The title, centred, with the vines on its first baseline.
    private var title: some View {
        ZStack(alignment: Alignment(horizontal: .center, vertical: .firstTextBaseline)) {
            QuestLogOrnaments(pieces: QuestLogOrnaments.titleVines, lines: QuestLogMetrics.titleVineLines, band: QuestLogMetrics.titleVineBand)
                .alignmentGuide(.firstTextBaseline) { _ in (QuestLogMetrics.titleBaseline - QuestLogMetrics.titleVineBand.top) * QuestLogMetrics.pageScale }
            Text(QuestLogPage.wrapped(page.title, columns: columns(QuestLogMetrics.titleWidth, AppFonts.questLogTitle)))
                .font(AppFonts.questLogTitle.swiftUI)
                .foregroundStyle(AppPalette.panel.swiftUI)
                .multilineTextAlignment(.center)
                .frame(width: QuestLogMetrics.titleWidth)
        }
        .frame(maxWidth: .infinity)
    }

    /// The rule and its vines; its "baseline" is the rule's top edge.
    private var rule: some View {
        QuestLogOrnaments(pieces: QuestLogOrnaments.ruleVines, lines: [QuestLogMetrics.rule], band: QuestLogMetrics.ruleVineBand)
            .alignmentGuide(.firstTextBaseline) { _ in (QuestLogMetrics.rule.minY - QuestLogMetrics.ruleVineBand.top) * QuestLogMetrics.pageScale }
            .alignmentGuide(.lastTextBaseline) { _ in (QuestLogMetrics.rule.minY - QuestLogMetrics.ruleVineBand.top) * QuestLogMetrics.pageScale }
    }

    /// "project ◆ Created: … ◆ Updated: …", wrapped between parts when it doesn't fit (QuestLogPage.footerLines).
    private var footer: some View {
        // The separator's width in whole columns, rounded up, so a line never runs past the body.
        let separatorWidth = 2 * QuestLogMetrics.footerDiamondGap + QuestLogMetrics.footerDiamondArtSize
        let separatorColumns = Int((separatorWidth / columnWidth(AppFonts.monoSmall)).rounded(.up))
        let lines = page.footerLines(columns: columns(QuestLogMetrics.bodyWidth, AppFonts.monoSmall), separatorColumns: separatorColumns)
        return VStack(alignment: .leading, spacing: QuestLogMetrics.footerLinePitch - naturalLineHeight(AppFonts.monoSmall)) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, parts in
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                        if index > 0 {
                            SVGShape(d: QuestLogArt.footerDiamond, origin: CGPoint(x: 81, y: 231.672))
                                .fill(AppPalette.panel.swiftUI)
                                .frame(width: QuestLogMetrics.footerDiamondArtSize, height: QuestLogMetrics.footerDiamondArtSize)
                                .alignmentGuide(.firstTextBaseline) { d in d.height / 2 + QuestLogMetrics.footerDiamondRaise }
                                .padding(.leading, QuestLogMetrics.footerDiamondGap)
                        }
                        Text(part)
                            .padding(.leading, index > 0 ? QuestLogMetrics.footerDiamondGap : 0)
                    }
                }
            }
        }
        .font(AppFonts.monoSmall.swiftUI)
        .foregroundStyle(AppPalette.panel.swiftUI)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, QuestLogMetrics.inkInset)
    }
}

/// The user's parchment, drawn from the design's path data at the page's scale: the paper, the folds masked to its
/// outline, and a 3pt edge stroke of which only the inner half shows, all at the design's 0.7 group opacity.
private struct QuestLogParchment: View {
    private static let outline = SVGPath.parse(QuestLogArt.parchmentOutline)
    private static let edge = SVGPath.parse(QuestLogArt.parchmentEdge)
    private static let pieces = QuestLogArt.parchment.map { (color(for: $0.role).swiftUI.opacity($0.opacity), SVGPath.parse($0.d)) }

    var body: some View {
        Canvas { context, size in
            #if DEBUG
            QuestLogDebug.parchmentDraws += 1
            #endif
            context.clip(to: Path(CGRect(origin: .zero, size: size)))
            context.scaleBy(x: QuestLogMetrics.pageScale, y: QuestLogMetrics.pageScale)
            context.fill(Self.outline, with: .color(AppPalette.parchment.swiftUI))
            context.clip(to: Self.outline)
            for (color, path) in Self.pieces {
                context.fill(path, with: .color(color))
            }
            context.stroke(Self.edge, with: .color(AppPalette.parchmentInk.swiftUI.opacity(QuestLogMetrics.parchmentEdgeOpacity)), lineWidth: QuestLogMetrics.parchmentEdgeStroke)
        }
        .opacity(QuestLogMetrics.parchmentOpacity)
    }

    private static func color(for role: QuestLogArt.Role) -> NSColor {
        switch role {
        case .paper: AppPalette.parchment
        case .paperShade: AppPalette.parchmentShade
        case .ink: AppPalette.parchmentInk
        case .rust: AppPalette.parchmentRust
        case .plum: AppPalette.parchmentPlum
        case .highlight: AppPalette.parchmentHighlight
        case .highlightWarm: AppPalette.parchmentHighlightWarm
        case .white: AppPalette.parchmentWhite
        }
    }
}

/// Vines and lines drawn at their page-local design positions, in a strip that starts at `band.top`.
private struct QuestLogOrnaments: View {
    typealias Piece = (path: Path, evenOdd: Bool)

    static let titleVines = parsed(QuestLogArt.titleVineLeft + QuestLogArt.titleVineRight)
    static let ruleVines = parsed(QuestLogArt.ruleVineLeft + QuestLogArt.ruleVineRight)

    let pieces: [Piece]
    let lines: [CGRect]
    let band: (top: CGFloat, height: CGFloat)

    private static func parsed(_ ornaments: [QuestLogArt.Ornament]) -> [Piece] {
        ornaments.map { (SVGPath.parse($0.d), $0.evenOdd) }
    }

    var body: some View {
        Canvas { context, _ in
            context.scaleBy(x: QuestLogMetrics.pageScale, y: QuestLogMetrics.pageScale)
            context.translateBy(x: 0, y: -band.top)
            let color = GraphicsContext.Shading.color(AppPalette.line.swiftUI)
            for piece in pieces {
                context.fill(piece.path, with: color, style: FillStyle(eoFill: piece.evenOdd))
            }
            for line in lines {
                context.fill(Path(line), with: color)
            }
        }
        .frame(width: QuestLogMetrics.pageSize.width, height: band.height * QuestLogMetrics.pageScale)
    }
}

// MARK: - Shared pieces

/// Absolute SVG path data as a shape, shifted so `origin` lands at the frame's top-left.
private struct SVGShape: Shape {
    let path: Path

    init(d: String, origin: CGPoint = .zero) {
        path = SVGPath.parse(d, dx: -origin.x, dy: -origin.y)
    }

    func path(in rect: CGRect) -> Path {
        path.offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

/// Stacks views so each one's first baseline sits `gaps[i]` below the previous one's last baseline
/// (the first one's below the top), the way the design spaces the page.
private struct BaselineColumn: Layout {
    let gaps: [CGFloat]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? QuestLogMetrics.pageSize.width
        return CGSize(width: width, height: frames(width: width, subviews: subviews).last?.maxY ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: bounds.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        var lastBaseline: CGFloat = 0
        return subviews.enumerated().map { index, subview in
            let dimensions = subview.dimensions(in: ProposedViewSize(width: width, height: nil))
            let top = lastBaseline + (index < gaps.count ? gaps[index] : 0) - dimensions[.firstTextBaseline]
            lastBaseline = top + dimensions[.lastTextBaseline]
            return CGRect(x: 0, y: top, width: width, height: dimensions.height)
        }
    }
}

/// How many characters of a monospaced `font` fit in `width`.
private func columns(_ width: CGFloat, _ font: NSFont) -> Int {
    Int(width / columnWidth(font))
}

/// One character's advance in a monospaced `font`.
private func columnWidth(_ font: NSFont) -> CGFloat {
    ("M" as NSString).size(withAttributes: [.font: font]).width
}

/// The line height SwiftUI sets a font on: its ascent and descent each rounded to whole points (measured
/// 14 for the 11pt mono, 16 for the 12pt).
private func naturalLineHeight(_ font: NSFont) -> CGFloat {
    font.ascender.rounded() + (-font.descender).rounded() + font.leading
}

/// The page's scroll view, for the page keys (PageUp/PageDown, ⌃u/⌃d) and for the overflow cue. It follows
/// whichever page is showing; `moreBelow` changes only when the ink starts or stops running past the bottom.
@Observable
@MainActor
final class QuestLogPageScroll {
    private(set) var moreBelow = false
    private(set) var moreAbove = false
    @ObservationIgnored private weak var scrollView: NSScrollView?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// DEBUG renders: open the page scrolled this far down.
    @ObservationIgnored var previewOffset: CGFloat?

    func attach(_ scrollView: NSScrollView) {
        guard scrollView !== self.scrollView else {
            refresh()
            return
        }
        observers.forEach(NotificationCenter.default.removeObserver)
        self.scrollView = scrollView
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView?.postsFrameChangedNotifications = true
        observers = [
            (NSView.boundsDidChangeNotification, scrollView.contentView as NSView),
            (NSView.frameDidChangeNotification, scrollView.documentView),
        ].compactMap { name, view in
            view.map { NotificationCenter.default.addObserver(forName: name, object: $0, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            } }
        }
        if let previewOffset {
            scroll(to: previewOffset, glides: false)
        }
        refresh()
    }

    /// Scrolls by `pages` of the visible height, gliding, clamped to the ink.
    func scroll(byPages pages: Double) {
        guard let clipView = scrollView?.contentView else {
            return
        }
        scroll(to: clipView.bounds.origin.y + clipView.bounds.height * CGFloat(pages), glides: true)
    }

    private func scroll(to offset: CGFloat, glides: Bool) {
        guard let scrollView else {
            return
        }
        let maxOffset = max(0, (scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.height)
        WorkerChatMotion.scroll(scrollView, toOffset: min(max(0, offset), maxOffset), glides: glides)
        refresh()
    }

    private func refresh() {
        guard let scrollView else {
            return
        }
        let below = (scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.maxY > 1
        let above = scrollView.contentView.bounds.minY > 1
        if below != moreBelow {
            moreBelow = below
        }
        if above != moreAbove {
            moreAbove = above
        }
    }
}

#if DEBUG
/// Self-test instrumentation: how often the parchment Canvas has drawn, to prove the unroll doesn't redraw it.
enum QuestLogDebug {
    nonisolated(unsafe) static var parchmentDraws = 0
}
#endif
