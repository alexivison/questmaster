import AppKit
import QuestmasterCore
import SwiftUI

/// Positions from user-quests-modal-v3.svg (900 x 780), and from -v2-nobody.svg for the plain page, whose ink v3
/// keeps, re-fitted to the 5pt rhythm (2026-10-22). Baselines are where the design's glyph outlines sit. The sheet
/// is fixed at `QuestLogMetrics.sheetSize`; `QuestLogLayout` places its parts.
enum QuestLogMetrics {
    /// The sheet's fixed size. A window smaller than it shrinks the modal to fit (`ModalScaleView`), as other modals do.
    static let sheetSize = CGSize(width: 1280, height: 860)

    /// Rounds a length to the nearest grid line.
    static func snapToGrid(_ length: CGFloat) -> CGFloat {
        (length / gridStep).rounded() * gridStep
    }
    /// The tabs and the page start `ModalFormMetrics.contentTop` down, under the shared header.
    static let contentTop = ModalFormMetrics.contentTop
    /// The left column, top to bottom: the tabs, the filter, the list. Columns are `columnGap` apart.
    static let filterHeight = FilterBarMetrics.height
    static let tabsHeight = TextTabMetrics.height
    static let columnGap = Space.item
    /// Between the page and the outer edges, and between the list and the page.
    static let inset = Space.section
    /// Below the page: `inset` to the buttons, which are `ControlHeight.control` high, then `Space.item` under them.
    static let buttonBandHeight = Space.section + ControlHeight.control + Space.item * 2
    /// A row is one title line (`rowHeight`), with its tag chips under it (a tagged row). Rows are `rowSpacing` apart.
    static let rowHeight = ControlHeight.compact
    /// A tagged row is its title line and the chip line under it (`QuestTagChipMetrics.height`) with `Space.row` below.
    static let taggedRowHeight = ControlHeight.row
    static let rowSpacing = Space.item
    static let rowBaseline: CGFloat = 16.5
    static let rowTextInset = Space.item
    static let rowCornerRadius: CGFloat = 3
    static let markSize: CGFloat = 5
    /// Page: the design's 473 wide page, its parchment clipped to the top 594.
    static let svgPageWidth: CGFloat = 473
    static let svgParchmentHeight: CGFloat = 594
    /// The sheet's sizes and the columns' widths sit on this grid.
    static let gridStep = Space.row
    /// The list's share of the width the two columns share; the page takes the rest.
    static let listShare: CGFloat = 0.42
    static let pageCornerRadius: CGFloat = 5
    static let parchmentEdgeStroke: CGFloat = 3
    static let parchmentEdgeOpacity = 0.35
    static let parchmentOpacity = 0.7
    /// Page ink, page-local: the titled page's title baseline 34 down, the 12pt description's 36 below it on a
    /// 16pt line, 20 in on each side; a plain page's line sits on a baseline 32 down. Then the rule 24 below the last
    /// baseline and the footer's baseline 32 below the rule. The vines and rules scale with the page; the text doesn't.
    static let inkInset = Space.section
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
    static let footerDiamondSvgSize: CGFloat = 5.66
    static let footerDiamondGap = Space.item
    static let footerDiamondRaise: CGFloat = 3.5
    /// Buttons: the shared angled buttons at the design's 200 wide, 10 apart, centred.
    static let buttonWidth: CGFloat = 200
    static let buttonSpacing = Space.item
}

/// Where the Quest Log's parts sit in a sheet of one size. The page takes the sheet's height under the tabs and the
/// larger share of the width; the left column takes the rest, its list on the grid.
struct QuestLogLayout: Equatable {
    let sheetSize: CGSize
    let pageSize: CGSize
    let listWidth: CGFloat

    init(sheetSize: CGSize) {
        self.sheetSize = sheetSize
        let height = sheetSize.height - QuestLogMetrics.contentTop - QuestLogMetrics.buttonBandHeight
        let columnsWidth = sheetSize.width - 2 * QuestLogMetrics.inset - QuestLogMetrics.columnGap
        listWidth = QuestLogMetrics.snapToGrid(columnsWidth * QuestLogMetrics.listShare)
        pageSize = CGSize(width: columnsWidth - listWidth, height: height)
    }

    /// The uniform scale of the page's ornaments and text guides: the design's page width at this page's width.
    var pageScale: CGFloat { pageSize.width / QuestLogMetrics.svgPageWidth }
    /// The parchment fills the page exactly, its height scaled on its own, so its torn edges keep all four sides at any
    /// page shape. The width keeps `pageScale`, so the edges' widths stay true.
    var parchmentScaleY: CGFloat { pageSize.height / QuestLogMetrics.svgParchmentHeight }
    var bodyWidth: CGFloat { pageSize.width - 2 * QuestLogMetrics.inkInset }
    var pageOrigin: CGPoint {
        CGPoint(x: sheetSize.width - QuestLogMetrics.inset - pageSize.width, y: QuestLogMetrics.contentTop)
    }
    var tabsOrigin: CGPoint { CGPoint(x: QuestLogMetrics.inset, y: QuestLogMetrics.contentTop) }
    var filterOrigin: CGPoint {
        CGPoint(x: QuestLogMetrics.inset, y: tabsOrigin.y + QuestLogMetrics.tabsHeight + QuestLogMetrics.columnGap)
    }
    var listOrigin: CGPoint {
        CGPoint(x: QuestLogMetrics.inset, y: filterOrigin.y + QuestLogMetrics.filterHeight + QuestLogMetrics.columnGap)
    }
    var listHeight: CGFloat { pageOrigin.y + pageSize.height - listOrigin.y }
    var buttonTop: CGFloat { pageOrigin.y + pageSize.height + QuestLogMetrics.inset }
}

struct QuestLogView: View {
    let store: QuestLogStore
    let filter: QuestLogFilter
    let layout: QuestLogLayout
    var pageScroll = QuestLogPageScroll()
    /// Offscreen renders can't focus the field; this draws it as focused (its border, its suggestions).
    var previewFocused = false
    var onCommand: (ListCommand) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            ModalSheetHeader(title: "Quest Log")
                .frame(width: layout.sheetSize.width)
            TextTabRow(titles: store.tabTitles, selectedIndex: store.selectedTabIndex, areaFocused: true, alignment: .leading, onSelect: store.selectTab)
                .frame(width: layout.listWidth)
                .offset(x: layout.tabsOrigin.x, y: layout.tabsOrigin.y)
            FilterBar(
                tokens: filter.tokens,
                query: Binding(get: { filter.query }, set: { filter.setQuery($0) }),
                placeholder: "@type or @size or text...",
                focusNonce: filter.focusNonce,
                suggestions: filter.suggestions,
                highlightedSuggestionID: filter.selectedSuggestionID,
                accessibilityLabel: "Filter quests",
                previewFocused: previewFocused,
                onCommand: { filter.handleCommand($0) },
                onRemoveToken: { filter.removeToken($0) },
                onSelectSuggestion: { filter.acceptSuggestion($0) }
            )
            .frame(width: layout.listWidth)
            .offset(x: layout.filterOrigin.x, y: layout.filterOrigin.y)
            QuestLogList(store: store)
                .frame(width: layout.listWidth, height: layout.listHeight, alignment: .top)
                .offset(x: layout.listOrigin.x, y: layout.listOrigin.y)
            QuestLogPageView(page: store.selectedPage, pageID: store.selectedID, pageScroll: pageScroll, layout: layout)
                .offset(x: layout.pageOrigin.x, y: layout.pageOrigin.y)
            buttons
                .frame(width: layout.sheetSize.width)
                .offset(y: layout.buttonTop)
        }
        .frame(width: layout.sheetSize.width, height: layout.sheetSize.height, alignment: .topLeading)
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
/// The shared modal monitor routes ⇧⌘H/J/K/L here before disabled menus can swallow them. A modal it opens (Edit,
/// Abandon's confirmation, New Session) goes on top and takes the keys until it closes.
struct QuestLogModal: View {
    static let stackID: AnyHashable = "quest-log"

    let store: QuestLogStore
    let filter: QuestLogFilter
    let pageScroll: QuestLogPageScroll
    var onCommand: (ListCommand) -> Void

    var body: some View {
        // A fresh page per opening, so the parchment unrolls when the log opens and not on later changes.
        QuestLogView(
            store: store,
            filter: filter,
            layout: QuestLogLayout(sheetSize: QuestLogMetrics.sheetSize),
            pageScroll: pageScroll,
            onCommand: onCommand
        )
        .id(store.openGeneration)
        .background(SheetKeyEventMonitor(onKeyDown: handle))
    }

    private func handleNavigation(_ direction: NavigationDirection) {
        if let command = ListCommand.navigation(for: direction) {
            onCommand(command)
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        // ⇧⌘H/J/K/L move the list before the command check and before the filter's text sees the press.
        if let direction = Keymap.NavigationChord.direction(for: event.keymapPress) {
            handleNavigation(direction)
            return true
        }
        if event.modifierFlags.contains(.command) {
            return false
        }
        // While the filter is being edited its field editor takes the keys (its arrows, Return and Esc come
        // back through `QuestLogFilter.handleCommand`).
        if event.window?.firstResponder is NSTextView {
            return false
        }
        if let command = store.command(for: event.keymapPress) {
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

/// One row per visible quest, newest first. A tagged row shows its chips under the title.
private struct QuestLogList: View {
    let store: QuestLogStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: QuestLogMetrics.rowSpacing) {
                    ForEach(store.visibleQuests) { quest in
                        row(quest).id(quest.id)
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

    private func scroll(_ proxy: ScrollViewProxy, to id: String?) {
        guard let id else {
            return
        }
        proxy.scrollTo(id)
    }

    private func row(_ quest: QuestItem) -> some View {
        let look = RowLook.lasting(selected: quest.id == store.selectedID)
        let chips = QuestDisplayState.tagChipNames(for: quest)
        return VStack(alignment: .leading, spacing: 0) {
            BaselineText(
                QuestLogPage(quest: quest, project: "").title,
                font: look.bold ? AppFonts.questLogRowSelected : AppFonts.questLogRow,
                color: look.text.color,
                baseline: QuestLogMetrics.rowBaseline
            )
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: QuestLogMetrics.rowHeight, maxHeight: QuestLogMetrics.rowHeight, alignment: .topLeading)
            if !chips.isEmpty {
                chipRow(chips)
            }
        }
        .padding(.leading, QuestLogMetrics.rowTextInset)
        .frame(maxWidth: .infinity, minHeight: rowHeight(chips), maxHeight: rowHeight(chips), alignment: .topLeading)
        // The pointer shows the hover look; a click or the keys change the selection, which the page follows.
        .stateRow(look, cornerRadius: QuestLogMetrics.rowCornerRadius)
        .overlay(alignment: .topLeading) {
            if store.markedIDs.contains(quest.id) {
                DiamondShape()
                    .fill(AppPalette.accent.swiftUI)
                    .frame(width: QuestLogMetrics.markSize, height: QuestLogMetrics.markSize)
                    .padding(.leading, (QuestLogMetrics.rowTextInset - QuestLogMetrics.markSize) / 2)
                    .padding(.top, (QuestLogMetrics.rowHeight - QuestLogMetrics.markSize) / 2)
            }
        }
        .onTapGesture { store.select(quest.id) }
    }

    private func rowHeight(_ chips: [String]) -> CGFloat {
        chips.isEmpty ? QuestLogMetrics.rowHeight : QuestLogMetrics.taggedRowHeight
    }

    private func chipRow(_ names: [String]) -> some View {
        HStack(spacing: QuestTagChipMetrics.spacing) {
            ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                QuestTagChip(name: name)
            }
        }
        .padding(.bottom, Space.row)
    }
}

// MARK: - Page

private struct QuestLogPageView: View {
    let page: QuestLogPage?
    let pageID: String?
    let pageScroll: QuestLogPageScroll
    let layout: QuestLogLayout
    @State private var unrolled = false
    @State private var inked = false

    var body: some View {
        ZStack(alignment: .top) {
            paper
                .modifier(UnrollMask(progress: unrolled ? 1 : 0))
            ink
                .frame(maxHeight: .infinity, alignment: .top)
                .animation(Motion.animation(.fast), value: pageID)
                .opacity(inked ? 1 : 0)
        }
        .frame(width: layout.pageSize.width, height: layout.pageSize.height)
        .onAppear(perform: unroll)
    }

    /// The paper is exactly the page's rectangle. The parchment covers it, so it can be taller: the clip keeps it inside.
    private var paper: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: QuestLogMetrics.pageCornerRadius)
                .fill(AppPalette.item.swiftUI)
            QuestLogParchment(layout: layout)
                .frame(width: layout.pageSize.width, height: layout.pageSize.height)
        }
        .frame(width: layout.pageSize.width, height: layout.pageSize.height, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: QuestLogMetrics.pageCornerRadius))
    }

    /// Plays once per opening (the view is rebuilt for each): the paper unrolls top to bottom as the modal's fade-in
    /// ends, and the ink follows it down. Reduce Motion skips it: the paper is just there.
    private func unroll() {
        withAnimation(Motion.animation(.standard, after: .fast)) {
            unrolled = true
        }
        withAnimation(Motion.animation(.standard, after: .standard)) {
            inked = true
        }
    }

    @ViewBuilder private var ink: some View {
        if let page {
            ScrollView(.vertical) {
                QuestLogInk(page: page, layout: layout)
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
            .animation(Motion.animation(.fast), value: pageScroll.moreBelow)
            .animation(Motion.animation(.fast), value: pageScroll.moreAbove)
            .id(pageID)
            .transition(.opacity)
        } else {
            EmptyState(color: AppPalette.panel)
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
    let layout: QuestLogLayout

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
        Text(QuestLogPage.wrapped(text, columns: columns(layout.bodyWidth, AppFonts.questLogBody)))
            .font(AppFonts.questLogBody.swiftUI)
            .lineSpacing(QuestLogMetrics.bodyLineHeight - naturalLineHeight(AppFonts.questLogBody))
            .foregroundStyle(AppPalette.panel.swiftUI)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: layout.bodyWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, QuestLogMetrics.inkInset)
    }

    /// The title, centred, with the vines on its first baseline.
    private var title: some View {
        ZStack(alignment: Alignment(horizontal: .center, vertical: .firstTextBaseline)) {
            QuestLogOrnaments(layout: layout, pieces: QuestLogOrnaments.titleVines, lines: QuestLogMetrics.titleVineLines, band: QuestLogMetrics.titleVineBand)
                .alignmentGuide(.firstTextBaseline) { _ in (QuestLogMetrics.titleBaseline - QuestLogMetrics.titleVineBand.top) * layout.pageScale }
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
        QuestLogOrnaments(layout: layout, pieces: QuestLogOrnaments.ruleVines, lines: [QuestLogMetrics.rule], band: QuestLogMetrics.ruleVineBand)
            .alignmentGuide(.firstTextBaseline) { _ in (QuestLogMetrics.rule.minY - QuestLogMetrics.ruleVineBand.top) * layout.pageScale }
            .alignmentGuide(.lastTextBaseline) { _ in (QuestLogMetrics.rule.minY - QuestLogMetrics.ruleVineBand.top) * layout.pageScale }
    }

    /// "project ◆ Created: … ◆ Updated: …", wrapped between parts when it doesn't fit (QuestLogPage.footerLines).
    private var footer: some View {
        // The separator's width in whole columns, rounded up, so a line never runs past the body.
        let separatorWidth = 2 * QuestLogMetrics.footerDiamondGap + QuestLogMetrics.footerDiamondSvgSize
        let separatorColumns = Int((separatorWidth / columnWidth(AppFonts.monoSmall)).rounded(.up))
        let lines = page.footerLines(columns: columns(layout.bodyWidth, AppFonts.monoSmall), separatorColumns: separatorColumns)
        return VStack(alignment: .leading, spacing: QuestLogMetrics.footerLinePitch - naturalLineHeight(AppFonts.monoSmall)) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, parts in
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                        if index > 0 {
                            SVGShape(d: QuestLogArt.footerDiamond, origin: CGPoint(x: 81, y: 231.672))
                                .fill(AppPalette.panel.swiftUI)
                                .frame(width: QuestLogMetrics.footerDiamondSvgSize, height: QuestLogMetrics.footerDiamondSvgSize)
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

/// The user's parchment, drawn from the design's path data to fill the page (scaled per axis, see
/// `QuestLogLayout.parchmentScaleY`): the paper, the folds masked to its outline, and a 3pt edge stroke of which only
/// the inner half shows, all at the design's 0.7 group opacity.
private struct QuestLogParchment: View {
    let layout: QuestLogLayout
    private static let outline = SVGPath.parse(QuestLogArt.parchmentOutline)
    private static let edge = SVGPath.parse(QuestLogArt.parchmentEdge)
    private static let pieces = QuestLogArt.parchment.map { (color(for: $0.role).swiftUI.opacity($0.opacity), SVGPath.parse($0.d)) }

    var body: some View {
        Canvas { context, size in
            #if DEBUG
            QuestLogDebug.parchmentDraws += 1
            #endif
            context.clip(to: Path(CGRect(origin: .zero, size: size)))
            context.scaleBy(x: layout.pageScale, y: layout.parchmentScaleY)
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
    let layout: QuestLogLayout

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
            context.scaleBy(x: layout.pageScale, y: layout.pageScale)
            context.translateBy(x: 0, y: -band.top)
            let color = GraphicsContext.Shading.color(AppPalette.line.swiftUI)
            for piece in pieces {
                context.fill(piece.path, with: color, style: FillStyle(eoFill: piece.evenOdd))
            }
            for line in lines {
                context.fill(Path(line), with: color)
            }
        }
        .frame(width: layout.pageSize.width, height: band.height * layout.pageScale)
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
        let width = proposal.width ?? 0
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
