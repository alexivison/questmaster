import AppKit
import QuestmasterCore
import SwiftUI

/// Positions measured from user-quests-modal-v2.svg and -v2-nobody.svg (900 x 780). Baselines are where the
/// design's glyph outlines sit.
private enum QuestLogMetrics {
    static let sheetSize = CGSize(width: 900, height: 780)
    /// Filter field: 357 x 40 at (30, 40), window fill, 1pt line border, radius 5. "/" 12 in; a token chip
    /// (16 high, radius 4.5, at most 117 wide) and the text field follow, all centred on the field.
    static let filterOrigin = CGPoint(x: 30, y: 40)
    static let filterHeight: CGFloat = 40
    static let filterCornerRadius: CGFloat = 5
    static let filterInset: CGFloat = 12
    static let filterSpacing: CGFloat = 10
    static let chipHeight: CGFloat = 16
    static let chipMaxWidth: CGFloat = 117
    static let chipCornerRadius: CGFloat = 4.5
    static let chipTextInset: CGFloat = 6
    static let suggestionsGap: CGFloat = 4
    /// NSTextField sets its text lower and further left than the design's placeholder, measured against it.
    static let filterTextNudge = CGSize(width: 1.5, height: -2)
    /// List column, under the field: x 30-387. A section title's baseline sits 21 below the previous box
    /// (the field or the last row) and 9 above its first row; rows are 26 high, 5 apart (a 31pt pitch),
    /// with the text baseline 17 down and 10 in.
    static let listOrigin = CGPoint(x: 30, y: 80)
    static let listWidth: CGFloat = 357
    static let rowHeight: CGFloat = 26
    static let rowSpacing: CGFloat = 5
    static let rowBaseline: CGFloat = 17
    static let rowTextInset: CGFloat = 10
    static let rowCornerRadius: CGFloat = 3
    static let sectionHeight: CGFloat = 30
    static let sectionBaseline: CGFloat = 21
    static let markSize: CGFloat = 5
    /// Page: a 473 x 658 base with the parchment clipped to its top 656.
    static let pageOrigin = CGPoint(x: 397, y: 40)
    static let pageSize = CGSize(width: 473, height: 658)
    static let parchmentHeight: CGFloat = 656
    static let pageCornerRadius: CGFloat = 5
    static let parchmentEdgeWidth: CGFloat = 3
    static let parchmentEdgeOpacity = 0.35
    static let parchmentOpacity = 0.7
    /// Page ink, page-local: the titled page's title baseline 34 down, the 12pt description 36 below it on
    /// a 16pt pitch, 20 in on each side; a plain page's line sits on a baseline 32 down. Then the rule 24
    /// below the last baseline and the footer's baseline 32 below the rule.
    static let inkInset: CGFloat = 20
    static let bodyWidth = pageSize.width - 2 * inkInset
    static let titleWidth: CGFloat = 306
    static let titleBaseline: CGFloat = 34
    static let plainBaseline: CGFloat = 32
    static let bodyGap: CGFloat = 36
    static let bodyLinePitch: CGFloat = 16
    static let ruleGap: CGFloat = 24
    static let footerGap: CGFloat = 32
    static let inkBottomInset: CGFloat = 24
    /// The vine strips, page-local: the title's spans y 20-38 with the title baseline at 34; the rule's
    /// spans y 190-207 with the rule at 198.
    static let titleVineBand = (top: CGFloat(20), height: CGFloat(18))
    static let ruleVineBand = (top: CGFloat(190), height: CGFloat(17))
    static let titleVineLines: [CGRect] = [
        CGRect(x: 20, y: 28.5, width: 18.6394, height: 1),
        CGRect(x: 434.361, y: 28.5, width: 18.6394, height: 1),
    ]
    static let rule = CGRect(x: 22.946, y: 198, width: 427.845, height: 1)
    /// Footer: the diamond starts 8.4 after the project and the date 8.1 after the diamond; its centre sits 3.5 above the baseline.
    static let footerDiamondSize: CGFloat = 5.66
    static let footerDiamondLead: CGFloat = 8.4
    static let footerDateLead: CGFloat = 8.1
    static let footerDiamondRaise: CGFloat = 3.5
    /// Buttons: the shared angled buttons at the design's 200 wide, 10 apart, centred, at y 728.
    static let buttonWidth: CGFloat = 200
    static let buttonSpacing: CGFloat = 10
    static let buttonTop: CGFloat = 728
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
    /// Offscreen renders can't focus the field; this shows its suggestions as if it were focused.
    var previewShowsSuggestions = false
    var onCommand: (QuestLogCommand) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            QuestLogList(store: store)
                .frame(width: QuestLogMetrics.listWidth, height: QuestLogMetrics.pageOrigin.y + QuestLogMetrics.pageSize.height - QuestLogMetrics.listOrigin.y, alignment: .top)
                .offset(x: QuestLogMetrics.listOrigin.x, y: QuestLogMetrics.listOrigin.y)
            QuestLogPageView(page: store.selectedPage, pageID: store.selectedID, isFiltering: filter.isActive)
                .offset(x: QuestLogMetrics.pageOrigin.x, y: QuestLogMetrics.pageOrigin.y)
            buttons
                .frame(width: QuestLogMetrics.sheetSize.width)
                .offset(y: QuestLogMetrics.buttonTop)
            QuestLogFilterField(filter: filter, previewShowsSuggestions: previewShowsSuggestions)
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

/// The Quest Log over the window, laid out like every other in-window modal.
struct QuestLogOverlayView: View {
    let store: QuestLogStore
    let filter: QuestLogFilter
    var onCommand: (QuestLogCommand) -> Void

    var body: some View {
        // A fresh page per opening, so the parchment unrolls when the log opens and not on later changes.
        ModalLayer { QuestLogView(store: store, filter: filter, onCommand: onCommand).id(store.openGeneration) }
            .modalFade(closing: !store.isOpen)
    }
}

// MARK: - Filter

/// The field over the list: "/", the `@project:` token chips, then the text field. Suggestions open under it
/// while it has focus.
private struct QuestLogFilterField: View {
    let filter: QuestLogFilter
    var previewShowsSuggestions: Bool
    @State private var focused = false

    var body: some View {
        HStack(spacing: QuestLogMetrics.filterSpacing) {
            Text("/")
                .font(AppFonts.questLogBody.swiftUI)
                .foregroundStyle(AppPalette.questLogFilterHint.swiftUI)
            ForEach(filter.tokens) { token in
                chip(token)
            }
            CommandTextField(
                text: Binding(get: { filter.query }, set: { filter.setQuery($0) }),
                placeholder: "@project: or text",
                focusNonce: filter.focusNonce,
                onCommand: { filter.handleCommand(keyCode: $0) },
                onEndEditing: {},
                onFocusChanged: { focused = $0 },
                font: AppFonts.monoSmall,
                textColor: AppPalette.questLogRow,
                placeholderColor: AppPalette.questLogFilterHint
            )
            .padding(.leading, QuestLogMetrics.filterTextNudge.width)
            .offset(y: QuestLogMetrics.filterTextNudge.height)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, QuestLogMetrics.filterInset)
        .frame(height: QuestLogMetrics.filterHeight)
        .background(RoundedRectangle(cornerRadius: QuestLogMetrics.filterCornerRadius).fill(AppPalette.window.swiftUI))
        .overlay(RoundedRectangle(cornerRadius: QuestLogMetrics.filterCornerRadius).strokeBorder(AppPalette.line.swiftUI, lineWidth: Token.Size.divider))
        .overlay(alignment: .topLeading) {
            if (focused || previewShowsSuggestions) && !filter.suggestions.isEmpty {
                FilterSuggestionList(
                    suggestions: filter.suggestions,
                    selectedID: filter.selectedSuggestionID,
                    onSelect: { filter.acceptSuggestion($0) }
                )
                .offset(y: QuestLogMetrics.filterHeight + QuestLogMetrics.suggestionsGap)
            }
        }
        .accessibilityLabel("Filter quests")
    }

    /// A token, "@project questmaster": click to remove it, as Backspace in an empty field does.
    private func chip(_ token: ArtifactFilterToken) -> some View {
        Text("\(token.kind.prefix) \(token.title)")
            .font(AppFonts.monoSmall.swiftUI)
            .foregroundStyle(AppPalette.muted.swiftUI)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, QuestLogMetrics.chipTextInset)
            .frame(maxWidth: QuestLogMetrics.chipMaxWidth, minHeight: QuestLogMetrics.chipHeight, maxHeight: QuestLogMetrics.chipHeight, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: QuestLogMetrics.chipCornerRadius).fill(AppPalette.item.swiftUI))
            .overlay(RoundedRectangle(cornerRadius: QuestLogMetrics.chipCornerRadius).stroke(AppPalette.line.swiftUI, lineWidth: Token.Size.divider))
            .fixedSize()
            .onTapGesture { filter.removeToken(token) }
            .help("Remove \(token.kind.rawValue) filter")
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
                        BaselineText(section.title, font: AppFonts.monoSmall, color: AppPalette.accent, baseline: QuestLogMetrics.sectionBaseline)
                            .frame(height: QuestLogMetrics.sectionHeight, alignment: .top)
                        VStack(alignment: .leading, spacing: QuestLogMetrics.rowSpacing) {
                            ForEach(section.quests) { quest in
                                row(quest).id(quest.id)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ScrollerHider())
            }
            .scrollIndicators(.hidden)
            .onChange(of: store.selectedID) { _, id in
                if let id {
                    proxy.scrollTo(id)
                }
            }
        }
    }

    private func row(_ quest: QuestItem) -> some View {
        let selected = quest.id == store.selectedID
        return BaselineText(
            QuestLogPage(quest: quest, project: "").title,
            font: selected ? AppFonts.questLogRowSelected : AppFonts.questLogRow,
            color: selected ? AppPalette.questLogRowSelected : AppPalette.questLogRow,
            baseline: QuestLogMetrics.rowBaseline
        )
        .lineLimit(1)
        .padding(.leading, QuestLogMetrics.rowTextInset)
        .frame(maxWidth: .infinity, minHeight: QuestLogMetrics.rowHeight, maxHeight: QuestLogMetrics.rowHeight, alignment: .topLeading)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: QuestLogMetrics.rowCornerRadius)
                    .fill(AppPalette.item.swiftUI)
            }
        }
        .overlay(alignment: .leading) {
            if store.markedIDs.contains(quest.id) {
                DiamondShape()
                    .fill(AppPalette.accent.swiftUI)
                    .frame(width: QuestLogMetrics.markSize, height: QuestLogMetrics.markSize)
                    .padding(.leading, (QuestLogMetrics.rowTextInset - QuestLogMetrics.markSize) / 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { store.select(quest.id) }
    }
}

// MARK: - Page

private struct QuestLogPageView: View {
    let page: QuestLogPage?
    let pageID: String?
    let isFiltering: Bool
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
                    .background(ScrollerHider())
            }
            .scrollIndicators(.hidden)
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
                BaselineColumn(gaps: [QuestLogMetrics.titleBaseline, QuestLogMetrics.bodyGap, QuestLogMetrics.ruleGap, QuestLogMetrics.footerGap]) {
                    title
                    paragraph(page.body)
                    rule
                    footer
                }
            case .plain:
                BaselineColumn(gaps: [QuestLogMetrics.plainBaseline, QuestLogMetrics.ruleGap, QuestLogMetrics.footerGap]) {
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
            .lineSpacing(QuestLogMetrics.bodyLinePitch - naturalLineHeight(AppFonts.questLogBody))
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
                .alignmentGuide(.firstTextBaseline) { _ in QuestLogMetrics.titleBaseline - QuestLogMetrics.titleVineBand.top }
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
            .alignmentGuide(.firstTextBaseline) { _ in QuestLogMetrics.rule.minY - QuestLogMetrics.ruleVineBand.top }
            .alignmentGuide(.lastTextBaseline) { _ in QuestLogMetrics.rule.minY - QuestLogMetrics.ruleVineBand.top }
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(page.project)
            if !page.date.isEmpty {
                SVGShape(d: QuestLogArt.footerDiamond, origin: CGPoint(x: 101, y: 223.672))
                    .fill(AppPalette.panel.swiftUI)
                    .frame(width: QuestLogMetrics.footerDiamondSize, height: QuestLogMetrics.footerDiamondSize)
                    .alignmentGuide(.firstTextBaseline) { d in d.height / 2 + QuestLogMetrics.footerDiamondRaise }
                    .padding(.leading, QuestLogMetrics.footerDiamondLead)
                Text(page.date)
                    .padding(.leading, QuestLogMetrics.footerDateLead)
            }
        }
        .font(AppFonts.monoSmall.swiftUI)
        .foregroundStyle(AppPalette.panel.swiftUI)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, QuestLogMetrics.inkInset)
    }
}

/// The user's parchment, drawn from the design's path data: the paper, the folds masked to its outline,
/// and a 3pt edge stroke of which only the inner half shows, all at the design's 0.7 group opacity.
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
            context.fill(Self.outline, with: .color(AppPalette.parchment.swiftUI))
            context.clip(to: Self.outline)
            for (color, path) in Self.pieces {
                context.fill(path, with: .color(color))
            }
            context.stroke(Self.edge, with: .color(AppPalette.parchmentInk.swiftUI.opacity(QuestLogMetrics.parchmentEdgeOpacity)), lineWidth: QuestLogMetrics.parchmentEdgeWidth)
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
            context.translateBy(x: 0, y: -band.top)
            let color = GraphicsContext.Shading.color(AppPalette.line.swiftUI)
            for piece in pieces {
                context.fill(piece.path, with: color, style: FillStyle(eoFill: piece.evenOdd))
            }
            for line in lines {
                context.fill(Path(line), with: color)
            }
        }
        .frame(width: QuestLogMetrics.pageSize.width, height: band.height)
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

/// Text whose first baseline sits `baseline` below the top of its frame.
private struct BaselineText: View {
    let text: String
    let font: NSFont
    let color: NSColor
    let baseline: CGFloat

    init(_ text: String, font: NSFont, color: NSColor, baseline: CGFloat) {
        self.text = text
        self.font = font
        self.color = color
        self.baseline = baseline
    }

    var body: some View {
        Text(text)
            .font(font.swiftUI)
            .foregroundStyle(color.swiftUI)
            .alignmentGuide(.top) { $0[.firstTextBaseline] - baseline }
            .frame(maxHeight: .infinity, alignment: .top)
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
    Int(width / ("M" as NSString).size(withAttributes: [.font: font]).width)
}

/// The line height SwiftUI sets a font on: its ascent and descent each rounded to whole points (measured
/// 14 for the 11pt mono, 16 for the 12pt).
private func naturalLineHeight(_ font: NSFont) -> CGFloat {
    font.ascender.rounded() + (-font.descender).rounded() + font.leading
}

#if DEBUG
/// Self-test instrumentation: how often the parchment Canvas has drawn, to prove the unroll doesn't redraw it.
enum QuestLogDebug {
    nonisolated(unsafe) static var parchmentDraws = 0
}
#endif

// MARK: - AppKit host

/// Hosts the Quest Log over the window's content. While it is visible and no sheet is attached it takes
/// every plain key: the Quest Log's own keys become commands and the rest are swallowed so they never
/// reach the terminal underneath. Command-key shortcuts pass through to the menus.
final class QuestLogOverlayHost: NSHostingView<QuestLogOverlayView> {
    var onCommand: ((QuestLogCommand) -> Void)?
    private var keyMonitor: Any?
    private let hiding = FadeOutHiding()

    init(store: QuestLogStore, filter: QuestLogFilter) {
        var forward: ((QuestLogCommand) -> Void)?
        super.init(rootView: QuestLogOverlayView(store: store, filter: filter, onCommand: { forward?($0) }))
        forward = { [weak self] in self?.onCommand?($0) }
        // Sized only by the window edges it's pinned to, never by the log's own size (see InWindowModalHost).
        sizingOptions = []
        isHidden = true
    }

    @available(*, unavailable)
    required init(rootView: QuestLogOverlayView) {
        fatalError("init(rootView:) has not been implemented")
    }

    @available(*, unavailable)
    @MainActor dynamic required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    /// Shows the host at once; on close the log fades out first and the host hides once the fade ends.
    func setVisible(_ visible: Bool) {
        if visible {
            hiding.show(self)
        } else {
            hiding.hideAfterFadeOut(self)
        }
        if visible, keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) == true ? nil : event
            }
        } else if !visible, let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        // Edit, Abandon's confirmation and New Session open as in-window modals above the log; they take the keys.
        guard hiding.isShowing, let window, event.window === window, window.attachedSheet == nil, InWindowModalStack.shared.isEmpty else {
            return false
        }
        if event.modifierFlags.contains(.command) {
            return false
        }
        // While the filter is being edited its field editor takes the keys (its arrows, Return and Esc come
        // back through `QuestLogFilter.handleCommand`).
        if let editor = window.firstResponder as? NSTextView, editor.isDescendant(of: self) {
            return false
        }
        if let command = QuestLogCommand.from(characters: event.charactersIgnoringModifiers, keyCode: event.keyCode) {
            onCommand?(command)
        }
        return true
    }
}
