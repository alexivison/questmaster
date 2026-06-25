import AppKit
import QuestmasterCore
import SwiftUI

private enum TrackerSwiftUITiming {
    static let spinnerInterval: TimeInterval = 0.125
}

final class TrackerKeyboardBridge {
    var handler: ((NSEvent) -> Bool)?

    func handle(_ event: NSEvent) -> Bool {
        handler?(event) ?? false
    }
}

final class TrackerKeyboardHostingView<Content: View>: NSHostingView<Content> {
    private let keyboardBridge: TrackerKeyboardBridge

    required init(rootView: Content) {
        keyboardBridge = TrackerKeyboardBridge()
        super.init(rootView: rootView)
    }

    init(rootView: Content, keyboardBridge: TrackerKeyboardBridge) {
        self.keyboardBridge = keyboardBridge
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    @MainActor dynamic required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        if keyboardBridge.handle(event) {
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        keyboardBridge.handle(event) || super.performKeyEquivalent(with: event)
    }
}

private struct TrackerKeyboardHandlerUpdater: NSViewRepresentable {
    let bridge: TrackerKeyboardBridge?
    let onKeyDown: (NSEvent) -> Bool

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        bridge?.handler = onKeyDown
    }
}

/// SwiftUI port of the tracker pane (Phase 2 of `app/docs/architecture-modernization-plan.md`).
///
/// This is the first real SwiftUI pane and the template the other panes follow: it reads the
/// `@Observable` `RuntimeStore` directly (no manual snapshot push / signature diffing), reuses the
/// pure `TrackerRenderer` from Core for layout data, and styles itself entirely from the shared
/// `AppPalette` / `AppFonts` / `Token` design tokens via the `.swiftUI` bridges.
///
/// It is wired in behind the `QUESTMASTER_SWIFTUI_TRACKER` flag; the AppKit `TrackerView` remains
/// the default. Scope of this proof: rendering, selection, activation, delete, recolor, and basic
/// list keyboard movement/open. Broader relay/broadcast/attach/spawn commands are deliberately not
/// ported yet — they follow once the pattern is build-verified.
struct TrackerRootView: View {
    let store: RuntimeStore
    var onEffect: (TrackerEffect) -> Bool

    private let keyboardBridge: TrackerKeyboardBridge?

    @State private var commandState = TrackerCommandState()
    @State private var snapshot: RuntimeSnapshot
    @State private var runtimeObservation: RuntimeStoreObservation?

    init(
        store: RuntimeStore,
        keyboardBridge: TrackerKeyboardBridge? = nil,
        onEffect: @escaping (TrackerEffect) -> Bool = { _ in false }
    ) {
        self.store = store
        self.keyboardBridge = keyboardBridge
        self.onEffect = onEffect
        _snapshot = State(initialValue: store.snapshot)
    }

    var body: some View {
        TimelineView(.periodic(from: Date(), by: TrackerSwiftUITiming.spinnerInterval)) { context in
            trackerContent(now: context.date)
        }
        .background(TrackerKeyboardHandlerUpdater(bridge: keyboardBridge) { event in
            handleKeyDown(event)
        })
        .onAppear(perform: installRuntimeObservation)
        .onDisappear(perform: removeRuntimeObservation)
    }

    private func trackerContent(now: Date) -> some View {
        let repos = TrackerRenderer.tracker(snapshot, recolorPreview: commandState.recolorEdit)
        let rows = TrackerRenderer.flatSessions(in: repos)
        let selectedID = commandState.renderedSelectedID(in: rows)
        let emptyMessage = snapshot.serviceStateMessage ?? "No tracker data yet."

        return Group {
            if isServeStartingMessage(snapshot.serviceStateMessage) {
                TrackerSkeletonPlaceholder()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if rows.isEmpty {
                                TrackerEmptyState(message: emptyMessage)
                            } else {
                                ForEach(Array(repos.enumerated()), id: \.offset) { _, repo in
                                    TrackerRepoSection(
                                        repo: repo,
                                        selectedID: selectedID,
                                        now: now,
                                        onSelect: select(_:),
                                        onActivate: activate(_:)
                                    )
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: commandState.selectedID) { _, nextID in
                        guard let nextID, rows.contains(where: { $0.id == nextID }) else {
                            return
                        }
                        proxy.scrollTo(nextID, anchor: .center)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppPalette.panel.swiftUI)
    }

    private func select(_ id: String) {
        commandState.select(id)
        _ = dispatchEffect(.focusTracker)
    }

    private func installRuntimeObservation() {
        snapshot = store.snapshot
        guard runtimeObservation == nil else {
            return
        }
        runtimeObservation = store.observe {
            snapshot = store.snapshot
            let rows = TrackerRenderer.flatSessions(in: TrackerRenderer.tracker(snapshot))
            commandState.clearStaleRecolorEdit(rows: rows)
        }
    }

    private func removeRuntimeObservation() {
        runtimeObservation?.cancel()
        runtimeObservation = nil
        keyboardBridge?.handler = nil
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let action = TrackerEventCommandResolver.action(
            for: event,
            isInlineRecolorActive: commandState.recolorEdit != nil
        ) else {
            return false
        }

        let rows = TrackerRenderer.flatSessions(in: TrackerRenderer.tracker(snapshot, recolorPreview: commandState.recolorEdit))
        switch action {
        case .nativeRegionTab:
            return true
        case .inlineRecolor(let command):
            return dispatch(.applyInlineRecolor(command), rows: rows)
        case .focusDirection(let direction):
            if dispatchEffect(.focusDirection(direction)) {
                return true
            }
            switch direction {
            case .up:
                return moveSelection(delta: -1, rows: rows)
            case .down:
                return moveSelection(delta: 1, rows: rows)
            case .left, .right:
                return false
            }
        case .moveSelection(let delta):
            return moveSelection(delta: delta, rows: rows)
        case .openSelection:
            return dispatch(.activate(openedID: nil), rows: rows)
        case .listCommand(.delete):
            return dispatch(.deleteSelected, rows: rows)
        case .listCommand(.recolorSession):
            return dispatch(.beginRecolor(.session), rows: rows)
        case .listCommand(.recolorRepo):
            return dispatch(.beginRecolor(.repo), rows: rows)
        case .listCommand:
            return false
        }
    }

    private func moveSelection(delta: Int, rows: [TrackerSession]) -> Bool {
        commandState.moveSelection(delta: delta, rows: rows)
    }

    private func activate(_ session: TrackerSession) {
        let rows = TrackerRenderer.flatSessions(in: TrackerRenderer.tracker(snapshot, recolorPreview: commandState.recolorEdit))
        _ = dispatch(.activate(openedID: session.id), rows: rows)
    }

    private func dispatch(_ command: TrackerCommand, rows: [TrackerSession]) -> Bool {
        guard let effects = commandState.effects(
            for: command,
            rows: rows,
            currentTerminalSessionID: store.currentTerminalSessionID
        ) else {
            return false
        }
        return dispatchEffects(effects)
    }

    @discardableResult
    private func dispatchEffect(_ effect: TrackerEffect) -> Bool {
        onEffect(effect)
    }

    private func dispatchEffects(_ effects: [TrackerEffect]) -> Bool {
        var handled = false
        for effect in effects {
            handled = dispatchEffect(effect) || handled
        }
        return handled
    }
}

private struct TrackerRepoSection: View {
    let repo: TrackerRenderedRepo
    let selectedID: String?
    let now: Date
    var onSelect: (String) -> Void
    var onActivate: (TrackerSession) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TrackerRepoSectionHeader(repo: repo)

            ForEach(Array(repo.groups.enumerated()), id: \.offset) { _, group in
                TrackerSessionRow(rendered: group.root, selectedID: selectedID, now: now, onSelect: onSelect, onActivate: onActivate)
                ForEach(group.workers, id: \.session.id) { worker in
                    TrackerSessionRow(rendered: worker, selectedID: selectedID, now: now, onSelect: onSelect, onActivate: onActivate)
                }
            }
        }
    }
}

private struct TrackerSessionRow: View {
    let rendered: TrackerRenderedSession
    let selectedID: String?
    let now: Date
    var onSelect: (String) -> Void
    var onActivate: (TrackerSession) -> Void

    @State private var isHovered = false

    private var session: TrackerSession { rendered.session }
    private var isSelected: Bool { selectedID == session.id }

    var body: some View {
        TrackerSessionRowContent(rendered: rendered, selected: isSelected, now: now)
            .padding(.leading, contentInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .overlay(alignment: .leading) {
                leadingDecoration
            }
            .overlay {
                if rendered.recolorEditHint == nil && rendered.status.kind == .needsInput {
                    RoundedRectangle(cornerRadius: Token.Radius.hairline)
                        .stroke(AppPalette.trackerNeedsInput.swiftUI, lineWidth: 1)
                }
            }
            .onHover { isHovered = $0 }
            .contentShape(Rectangle())
            // Matches the AppKit tracker's `.singleClick` open policy (see `TrackerViews.swift` and
            // `RepoListClickTests.trackerSingleClickSelectsAndOpensClickedRow`): a single click both
            // selects and activates the clicked row.
            .onTapGesture {
                onSelect(session.id)
                onActivate(session)
            }
            .id(session.id)
    }

    @ViewBuilder
    private var leadingDecoration: some View {
        if rendered.depth == 0 {
            TrackerTopLevelGutterShape()
                .fill(rendered.groupColor.swiftUI)
                .frame(width: RepoSectionedListMetrics.baseContentInset)
        } else {
            TrackerWorkerConnectorShape()
                .stroke(
                    AppPalette.connectorLine.withAlphaComponent(0.9).swiftUI,
                    style: StrokeStyle(lineWidth: 2, lineCap: .square)
                )
                .frame(width: RepoSectionedListMetrics.workerContentInset)
        }
    }

    private var contentInset: CGFloat {
        rendered.depth == 0
            ? RepoSectionedListMetrics.baseContentInset
            : RepoSectionedListMetrics.workerContentInset
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: Token.Radius.hairline)
            .fill(backgroundColor.swiftUI)
    }

    private var backgroundColor: NSColor {
        if isSelected {
            return AppPalette.selection
        }
        return isHovered ? AppPalette.hoverBackground : .clear
    }
}

private struct TrackerRepoSectionHeader: View {
    let repo: TrackerRenderedRepo

    private var title: String {
        repo.repo.name.isEmpty ? "ungrouped" : repo.repo.name
    }

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(repo.color.swiftUI)
                .frame(width: 6, height: 6)

            Text(title)
                .font(AppFonts.monoSmall.swiftUI)
                .foregroundStyle(repo.color.swiftUI)
                .lineLimit(1)
                .truncationMode(.tail)

            Rectangle()
                .fill(AppPalette.line.swiftUI)
                .frame(height: 1)
        }
        .padding(.leading, RepoSectionedListMetrics.headerLeadingInset)
        .padding(.trailing, 12)
        .padding(.top, 12)
        .padding(.bottom, 5)
        .frame(minHeight: 28, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TrackerSessionRowContent: View {
    let rendered: TrackerRenderedSession
    let selected: Bool
    let now: Date

    private var session: TrackerSession {
        rendered.session
    }

    private var title: String {
        session.title.isEmpty ? session.id : session.title
    }

    private var titleFont: Font {
        (session.isCurrent || selected ? AppFonts.bodyBold : AppFonts.body).swiftUI
    }

    private var titleColor: Color {
        (selected ? AppPalette.bright : AppPalette.text).swiftUI
    }

    private var agentTopInset: CGFloat {
        RepoSectionedListMetrics.trackerAgentVisualCenterY
            - (RepoSectionedListMetrics.trackerAgentFrameHeight / 2)
    }

    var body: some View {
        HStack(alignment: .top, spacing: RepoSectionedListMetrics.topLevelAgentGap) {
            TrackerAgentMark(agent: session.agent)
                .padding(.top, agentTopInset)

            VStack(alignment: .leading, spacing: 2) {
                titleRow
                snippetRow
                metadataRow
            }
            .padding(.top, RepoSectionedListMetrics.trackerTitleTopInset)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.trailing, RepoSectionedListMetrics.rowTrailingInset)
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(title)
                .font(titleFont)
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            Spacer(minLength: 8)

            TrackerStatusBadge(
                status: rendered.status,
                duration: TrackerRenderer.durationLabel(for: session, now: now),
                now: now
            )
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(minHeight: 18, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var snippetRow: some View {
        let snippet = TrackerRenderer.snippet(for: session)
        if !snippet.isEmpty {
            Text(snippet)
                .font(AppFonts.monoSmall.swiftUI)
                .italic()
                .foregroundStyle(AppPalette.muted.swiftUI)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder
    private var metadataRow: some View {
        let metadata = TrackerRenderer.metadata(for: session)
        if !metadata.isEmpty {
            HStack(spacing: 5) {
                TrackerPathIcon()
                Text(metadata)
                    .font(AppFonts.monoSmall.swiftUI)
                    .foregroundStyle(AppPalette.dim.swiftUI)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

private struct TrackerAgentMark: View {
    let agent: String

    var body: some View {
        Group {
            if let image = Self.image(for: agent) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: TrackerAgentGlyphMetrics.iconSide, height: TrackerAgentGlyphMetrics.iconSide)
            }
        }
        .frame(
            width: TrackerAgentGlyphMetrics.columnWidth,
            height: RepoSectionedListMetrics.trackerAgentFrameHeight,
            alignment: .center
        )
    }

    private static func image(for agentName: String) -> NSImage? {
        let clean = agentName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let canvasSize = NSSize(width: TrackerAgentGlyphMetrics.iconSide, height: TrackerAgentGlyphMetrics.iconSide)
        switch clean {
        case "claude":
            return AppSymbolStyle.resourceImage(
                name: "claude",
                fileExtension: "svg",
                subdirectory: "AgentLogos",
                canvasSize: canvasSize
            )
        case "codex":
            return AppSymbolStyle.resourceImage(
                name: "codex-openai-color",
                fileExtension: "svg",
                subdirectory: "AgentLogos",
                canvasSize: canvasSize
            )
        case "pi":
            return AppSymbolStyle.glyphImage(
                "π",
                font: NSFont.systemFont(ofSize: TrackerAgentGlyphMetrics.glyphPointSize, weight: .semibold),
                color: AppPalette.pi,
                canvasSize: canvasSize
            )
        case "omp":
            return AppSymbolStyle.glyphImage(
                "Ω",
                font: NSFont.systemFont(ofSize: TrackerAgentGlyphMetrics.glyphPointSize, weight: .semibold),
                color: AppPalette.omp,
                canvasSize: canvasSize
            )
        default:
            return AppSymbolStyle.image(
                name: "questionmark.circle",
                pointSize: 10,
                weight: .medium,
                color: AppPalette.muted,
                canvasSize: canvasSize
            )
        }
    }
}

private struct TrackerStatusBadge: View {
    let status: TrackerStatusStyle
    let duration: String
    let now: Date

    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            TrackerStatusIndicator(status: status, now: now)

            Text(status.label)
                .font(AppFonts.monoSmall.swiftUI)
                .foregroundStyle(status.color.swiftUI)
                .lineLimit(1)

            if !duration.isEmpty {
                Text(duration)
                    .font(AppFonts.monoSmall.swiftUI)
                    .foregroundStyle(AppPalette.dim.swiftUI)
                    .lineLimit(1)
            }
        }
    }
}

private struct TrackerStatusIndicator: View {
    let status: TrackerStatusStyle
    let now: Date

    private var spinnerRotation: Angle {
        let tick = Int(now.timeIntervalSinceReferenceDate / TrackerSwiftUITiming.spinnerInterval) % 8
        return .degrees(Double(-80 + (tick * 45)))
    }

    var body: some View {
        ZStack {
            switch status.indicatorAffordance {
            case .spinner:
                Circle()
                    .trim(from: 0, to: 0.83)
                    .stroke(status.color.swiftUI, style: StrokeStyle(lineWidth: 2, lineCap: .butt))
                    .rotationEffect(spinnerRotation)
                    .padding(2)
            case .square:
                RoundedRectangle(cornerRadius: 2)
                    .fill(status.color.swiftUI)
                    .frame(width: 8, height: 8)
            case .roundedSquare:
                RoundedRectangle(cornerRadius: 2)
                    .fill(status.color.withAlphaComponent(0.55).swiftUI)
                    .frame(width: 8, height: 8)
            case .ring:
                Circle()
                    .stroke(status.color.withAlphaComponent(0.55).swiftUI, lineWidth: 2)
                    .frame(width: 12, height: 12)
                Circle()
                    .fill(status.color.swiftUI)
                    .frame(width: 8, height: 8)
            case .circle:
                Circle()
                    .fill(status.color.swiftUI)
                    .frame(width: 8, height: 8)
            }
        }
        .frame(width: 12, height: 12)
    }
}

private struct TrackerPathIcon: View {
    var body: some View {
        Group {
            if let image = AppSymbolStyle.image(
                name: "folder",
                pointSize: 10,
                color: AppPalette.dim,
                canvasSize: NSSize(width: 12, height: 12)
            ) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(AppPalette.dim.swiftUI)
            }
        }
        .frame(width: 12, height: 12)
    }
}

private struct TrackerEmptyState: View {
    let message: String

    var body: some View {
        Text(message)
            .font(AppFonts.body.swiftUI)
            .foregroundStyle(AppPalette.muted.swiftUI)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 28)
            .padding(.horizontal, Token.Spacing.content)
            .padding(.bottom, 10)
    }
}

private struct TrackerSkeletonPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            skeletonBar(width: 88, height: 8)
                .padding(.top, 4)
                .padding(.bottom, 8)
            skeletonDotRow(indent: 0, width: 150)
            skeletonDotRow(indent: 18, width: 185)
            skeletonDotRow(indent: 18, width: 120)
            skeletonBar(width: 96, height: 8)
                .padding(.top, 14)
                .padding(.bottom, 8)
            skeletonDotRow(indent: 0, width: 160)
        }
        .padding(.top, Token.Spacing.content)
        .padding(.leading, Token.Spacing.content)
        .padding(.trailing, Token.Spacing.content)
        .padding(.bottom, Token.Spacing.content)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppPalette.panel.swiftUI)
    }

    private func skeletonDotRow(indent: CGFloat, width: CGFloat) -> some View {
        HStack(spacing: 10) {
            skeletonBar(width: 9, height: 9, radius: 4.5)
            skeletonBar(width: width, height: 9)
        }
        .padding(.leading, indent)
        .padding(.vertical, 8)
    }

    private func skeletonBar(width: CGFloat, height: CGFloat, radius: CGFloat = 3) -> some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(AppPalette.controlFill.swiftUI)
            .frame(width: width, height: height)
    }
}

private struct TrackerTopLevelGutterShape: Shape {
    func path(in rect: CGRect) -> Path {
        let width = min(RepoSectionedListMetrics.gutterWidth, rect.width)
        let height = rect.height
        let radius = min(width, height / 2)
        let control = radius * 0.5522847498
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: width - radius, y: 0))
        path.addCurve(
            to: CGPoint(x: width, y: radius),
            control1: CGPoint(x: width - radius + control, y: 0),
            control2: CGPoint(x: width, y: radius - control)
        )
        path.addLine(to: CGPoint(x: width, y: height - radius))
        path.addCurve(
            to: CGPoint(x: width - radius, y: height),
            control1: CGPoint(x: width, y: height - radius + control),
            control2: CGPoint(x: width - radius + control, y: height)
        )
        path.addLine(to: CGPoint(x: 0, y: height))
        path.closeSubpath()
        return path
    }
}

private struct TrackerWorkerConnectorShape: Shape {
    func path(in rect: CGRect) -> Path {
        let branchY = min(rect.height - 1, RepoSectionedListMetrics.trackerAgentVisualCenterY)
        let trunkX = RepoSectionedListMetrics.workerConnectorTrunkX
        let endX = RepoSectionedListMetrics.workerConnectorEndX
        let radius = min(CGFloat(6), max(0, endX - trunkX))
        var path = Path()
        path.move(to: CGPoint(x: trunkX, y: 0))
        path.addLine(to: CGPoint(x: trunkX, y: max(0, branchY - radius)))
        path.addCurve(
            to: CGPoint(x: trunkX + radius, y: branchY),
            control1: CGPoint(x: trunkX, y: branchY - radius / 2),
            control2: CGPoint(x: trunkX + radius / 2, y: branchY)
        )
        path.addLine(to: CGPoint(x: endX, y: branchY))
        return path
    }
}
