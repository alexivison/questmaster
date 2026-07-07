import AppKit
import QuestmasterCore
import SwiftUI

private enum TrackerSwiftUITiming {
    static let durationRefreshInterval: TimeInterval = 1
}

func isServeStartingMessage(_ message: String?) -> Bool {
    let normalized = message?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized == "starting qm serve..." || normalized == "connecting to serve..."
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

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        if keyboardBridge.handle(event) {
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard viewOwnsKeyFocus(self) else {
            return super.performKeyEquivalent(with: event)
        }
        // Ctrl+J/K move THIS region's selection and must act only when it is the
        // first responder (via keyDown). performKeyEquivalent is broadcast to
        // every sibling view, so consuming vertical nav here would steal it from
        // a focused terminal; decline it so the event falls through to tmux.
        if focusDirection(from: event, includeHorizontal: true) != nil {
            return super.performKeyEquivalent(with: event)
        }
        return keyboardBridge.handle(event) || super.performKeyEquivalent(with: event)
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

/// SwiftUI tracker pane.
///
/// This is the first real SwiftUI pane and the template the other panes follow: it reads the
/// `@Observable` `RuntimeStore` directly (no manual snapshot push / signature diffing), reuses the
/// pure `TrackerRenderer` from Core for layout data, and styles itself entirely from the shared
/// `AppPalette` / `AppFonts` / `Token` design tokens via the `.swiftUI` bridges.
///
/// Scope: rendering, selection, activation, delete, recolor, and list keyboard movement/open.
/// Broader tracker relay/broadcast/spawn prompts were removed instead of ported.
struct TrackerRootView: View {
    let store: RuntimeStore
    let navigation: NavigationStore
    var onEffect: (TrackerEffect) -> Bool

    private let keyboardBridge: TrackerKeyboardBridge?
    @ObservedObject private var newSessionPresenter: NewSessionSheetPresenter

    @State private var commandState = TrackerCommandState()
    @State private var snapshot: RuntimeSnapshot
    @State private var runtimeObservation: RuntimeStoreObservation?

    init(
        store: RuntimeStore,
        navigation: NavigationStore,
        keyboardBridge: TrackerKeyboardBridge? = nil,
        newSessionPresenter: NewSessionSheetPresenter,
        onEffect: @escaping (TrackerEffect) -> Bool = { _ in false }
    ) {
        self.store = store
        self.navigation = navigation
        self.keyboardBridge = keyboardBridge
        self.onEffect = onEffect
        _newSessionPresenter = ObservedObject(wrappedValue: newSessionPresenter)
        _snapshot = State(initialValue: store.snapshot)
    }

    var body: some View {
        trackerContent()
        .background(TrackerKeyboardHandlerUpdater(bridge: keyboardBridge) { event in
            handleKeyDown(event)
        })
        .sheet(item: $newSessionPresenter.presentation) { presentation in
            NewSessionSheetView(
                presentation: presentation,
                dismiss: {
                    newSessionPresenter.dismiss()
                }
            )
        }
        .onAppear(perform: installRuntimeObservation)
        .onDisappear(perform: removeRuntimeObservation)
    }

    private func trackerContent() -> some View {
        let repos = TrackerRenderer.tracker(snapshot, recolorPreview: commandState.recolorEdit)
        let rows = TrackerRenderer.flatSessions(in: repos)
        let selectedID = commandState.renderedSelectedID(in: rows)
        let emptyMessage = snapshot.serviceStateMessage ?? "No sessions yet."
        let shortcutNumbers = navigation.shortcutHintsVisible ? TrackerSessionShortcuts.numbersByID(rows) : [:]

        return Group {
            if isServeStartingMessage(snapshot.serviceStateMessage) {
                TrackerSkeletonPlaceholder()
            } else {
                SectionedList(selectedID: selectedID) {
                    if rows.isEmpty {
                        TrackerEmptyState(message: emptyMessage)
                    } else {
                        ForEach(Array(repos.enumerated()), id: \.offset) { _, repo in
                            TrackerRepoSection(
                                repo: repo,
                                selectedID: selectedID,
                                shortcutNumbers: shortcutNumbers,
                                onSelect: select(_:),
                                onActivate: activate(_:)
                            )
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppPalette.panel.swiftUI)
    }

    private func select(_ id: String) {
        // A row click selects, then onActivate immediately focuses the terminal.
        // Don't dispatch .focusTracker here: it would make the tracker first
        // responder for one run-loop turn before activation hops focus to the
        // terminal -- a visible flicker. Keyboard navigation uses moveSelection,
        // not this path, so arrow-key selection still keeps focus in the tracker.
        commandState.select(id)
    }

    private func installRuntimeObservation() {
        snapshot = store.snapshot
        guard runtimeObservation == nil else {
            return
        }
        var lastCurrentSessionID = store.currentTerminalSessionID
        runtimeObservation = store.observe {
            let previousRows = TrackerRenderer.flatSessions(in: TrackerRenderer.tracker(snapshot))
            snapshot = store.snapshot
            let rows = TrackerRenderer.flatSessions(in: TrackerRenderer.tracker(snapshot))
            commandState.clearStaleRecolorEdit(rows: rows)
            commandState.recoverStaleSelection(previousRows: previousRows, rows: rows)

            // The highlight should follow the active session by any path -- a click already
            // sets selectedID itself, but a keyboard/menu-driven switch (e.g. Cmd+N) only
            // ever changes store.currentTerminalSessionID, so resync here too. Gated on the
            // active session actually changing, so arrow-key browsing of a different row
            // survives an unrelated snapshot refresh.
            let currentSessionID = store.currentTerminalSessionID
            if let resyncID = TrackerSelection.followCurrentSessionID(
                previousCurrentSessionID: lastCurrentSessionID,
                currentSessionID: currentSessionID,
                sessions: rows
            ) {
                commandState.select(resyncID)
            }
            lastCurrentSessionID = currentSessionID
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
    let shortcutNumbers: [String: Int]
    var onSelect: (String) -> Void
    var onActivate: (TrackerSession) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(
                title: repo.repo.name.isEmpty ? "ungrouped" : repo.repo.name,
                color: repo.color
            )

            ForEach(Array(repo.groups.enumerated()), id: \.offset) { _, group in
                TrackerSessionRow(rendered: group.root, selectedID: selectedID, shortcutNumber: shortcutNumbers[group.root.session.id], onSelect: onSelect, onActivate: onActivate)
                ForEach(group.workers, id: \.session.id) { worker in
                    TrackerSessionRow(rendered: worker, selectedID: selectedID, shortcutNumber: shortcutNumbers[worker.session.id], onSelect: onSelect, onActivate: onActivate)
                }
            }
        }
    }
}

private struct TrackerSessionRow: View {
    let rendered: TrackerRenderedSession
    let selectedID: String?
    let shortcutNumber: Int?
    var onSelect: (String) -> Void
    var onActivate: (TrackerSession) -> Void

    @State private var doneEchoTrigger = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var session: TrackerSession { rendered.session }
    private var isSelected: Bool { selectedID == session.id }

    var body: some View {
        ListRow(
            selected: isSelected,
            leadingInset: contentInset,
            onTap: {
                onSelect(session.id)
                onActivate(session)
            },
            leadingDecoration: { leadingDecoration },
            background: { selected, hovered in
                RoundedRectangle(cornerRadius: Token.Radius.hairline)
                    .fill((selected ? AppPalette.selection : (hovered ? AppPalette.hoverBackground : .clear)).swiftUI)
            },
            content: {
                TrackerSessionRowContent(rendered: rendered, selected: isSelected)
                    // Bloom rides above the row fill but behind the content, emanating
                    // from the status dot's measured centre.
                    .backgroundPreferenceValue(TrackerDotAnchorKey.self) { anchor in
                        doneEchoBloom(anchor: anchor)
                    }
            }
        )
            .overlay {
                TrackerDoneEchoFrame(color: rendered.status.color, trigger: doneEchoTrigger)
            }
            .overlay {
                if rendered.recolorEditHint == nil && rendered.status.kind == .needsInput {
                    RoundedRectangle(cornerRadius: Token.Radius.hairline)
                        .stroke(AppPalette.trackerNeedsInput.swiftUI, lineWidth: 1)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                // Bottom-trailing, not top-trailing: the status badge (working/blocked/...)
                // lives in the top-trailing corner of the title row, and a top-trailing
                // shortcut badge sat right on top of it, clipping the status label.
                if let shortcutNumber {
                    ShortcutHintBadge(binding: Keymap.Command.selectSession[shortcutNumber - 1])
                        .padding(4)
                }
            }
            // Fire the card-wide echo only on a live transition to done — not when
            // an already-done row first appears — so launch and scroll stay quiet.
            .onChange(of: rendered.status.kind) { _, kind in
                if kind == .done && !reduceMotion {
                    doneEchoTrigger &+= 1
                }
            }
            .id(session.id)
    }

    @ViewBuilder
    private func doneEchoBloom(anchor: Anchor<CGPoint>?) -> some View {
        GeometryReader { proxy in
            if let anchor {
                TrackerDoneEchoBloom(
                    color: rendered.status.color,
                    center: proxy[anchor],
                    size: proxy.size,
                    trigger: doneEchoTrigger
                )
            }
        }
    }

    @ViewBuilder
    private var leadingDecoration: some View {
        if rendered.depth == 0 {
            TrackerTopLevelGutterShape()
                .fill(rendered.groupColor.swiftUI)
                .frame(width: TrackerListMetrics.baseContentInset)
        } else {
            TrackerWorkerConnectorShape()
                .stroke(
                    AppPalette.connectorLine.withAlphaComponent(0.9).swiftUI,
                    style: StrokeStyle(lineWidth: 2, lineCap: .square)
                )
                .frame(width: TrackerListMetrics.workerContentInset)
        }
    }

    private var contentInset: CGFloat {
        rendered.depth == 0
            ? TrackerListMetrics.baseContentInset
            : TrackerListMetrics.workerContentInset
    }

}

private struct TrackerSessionRowContent: View {
    let rendered: TrackerRenderedSession
    let selected: Bool

    private var session: TrackerSession {
        rendered.session
    }

    private var title: String {
        session.title.isEmpty ? session.id : session.title
    }

    private var titleFont: Font {
        (session.isCurrent ? AppFonts.bodyBold : AppFonts.body).swiftUI
    }

    private var titleColor: Color {
        (selected ? AppPalette.bright : AppPalette.text).swiftUI
    }

    private var agentTopInset: CGFloat {
        TrackerListMetrics.trackerAgentVisualCenterY
            - (TrackerListMetrics.trackerAgentFrameHeight / 2)
    }

    var body: some View {
        HStack(alignment: .top, spacing: TrackerListMetrics.topLevelAgentGap) {
            TrackerAgentMark(agent: session.agent, role: session.role)
                .padding(.top, agentTopInset)

            VStack(alignment: .leading, spacing: 2) {
                titleRow
                snippetRow
                metadataRow
            }
            .padding(.top, TrackerListMetrics.trackerTitleTopInset)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.trailing, TrackerListMetrics.rowTrailingInset)
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

            if rendered.status.showsBadge {
                TrackerStatusBadge(
                    status: rendered.status,
                    session: session
                )
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(minHeight: 18, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var snippetRow: some View {
        let snippet = TrackerRenderer.snippet(for: session)
        if !snippet.isEmpty {
            snippetText(snippet)
        } else if AgentKind(name: session.agent) == .shell {
            snippetText(" ")
                .hidden()
        }
    }

    private func snippetText(_ text: String) -> some View {
        Text(text)
            .font(AppFonts.monoSmall.swiftUI)
            .italic()
            .foregroundStyle(AppPalette.muted.swiftUI)
            .lineLimit(1)
            .truncationMode(.tail)
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
    let role: String

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let image = Self.image(for: agent) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: TrackerAgentGlyphMetrics.iconSide, height: TrackerAgentGlyphMetrics.iconSide)
            }
            if isMaster {
                masterBadge
                    .offset(x: 5, y: -5)
            }
        }
        .frame(
            width: TrackerAgentGlyphMetrics.columnWidth,
            height: TrackerListMetrics.trackerAgentFrameHeight,
            alignment: .center
        )
    }

    private var isMaster: Bool {
        SessionRoleKind(role: role) == .master
    }

    @ViewBuilder
    private var masterBadge: some View {
        if let image = AppSymbolStyle.image(
            name: "crown.fill",
            pointSize: 7,
            weight: .semibold,
            color: AppPalette.masterRole,
            canvasSize: NSSize(width: 10, height: 10)
        ) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 10, height: 10)
        } else {
            Text("M")
                .font(.system(size: 7, weight: .semibold, design: .monospaced))
                .foregroundStyle(AppPalette.masterRole.swiftUI)
                .frame(width: 10, height: 10)
        }
    }

    private static func image(for agentName: String) -> NSImage? {
        let canvasSize = NSSize(width: TrackerAgentGlyphMetrics.iconSide, height: TrackerAgentGlyphMetrics.iconSide)
        switch AgentKind(name: agentName) {
        case .claude:
            return AppSymbolStyle.resourceImage(
                name: "claude",
                fileExtension: "svg",
                subdirectory: "AgentLogos",
                canvasSize: canvasSize
            )
        case .codex:
            return AppSymbolStyle.resourceImage(
                name: "codex-openai-color",
                fileExtension: "svg",
                subdirectory: "AgentLogos",
                canvasSize: canvasSize
            )
        case .opencode:
            if let image = AppSymbolStyle.resourceImage(
                name: "opencode",
                fileExtension: "svg",
                subdirectory: "AgentLogos",
                canvasSize: canvasSize,
                tintColor: AppPalette.bright
            ) {
                return image
            }
            return AppSymbolStyle.glyphImage(
                "□",
                font: NSFont.systemFont(ofSize: TrackerAgentGlyphMetrics.glyphPointSize, weight: .semibold),
                color: AppPalette.bright,
                canvasSize: canvasSize
            )
        case .pi:
            if let image = AppSymbolStyle.resourceImage(
                name: "pi",
                fileExtension: "svg",
                subdirectory: "AgentLogos",
                canvasSize: canvasSize
            ) {
                return image
            }
            return AppSymbolStyle.glyphImage(
                "π",
                font: NSFont.systemFont(ofSize: TrackerAgentGlyphMetrics.glyphPointSize, weight: .semibold),
                color: AppPalette.pi,
                canvasSize: canvasSize
            )
        case .shell:
            return AppSymbolStyle.image(
                name: "apple.terminal",
                pointSize: TrackerAgentGlyphMetrics.glyphPointSize,
                weight: .medium,
                color: AppPalette.muted,
                canvasSize: canvasSize
            )
        case .unknown:
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
    let session: TrackerSession

    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            TrackerStatusIndicator(status: status)
                .id(status.kind)
                // No cross-fade between status stages — the change snaps and the
                // dot pop / done echo carry the transition.
                .transition(.identity)

            TrackerStatusLabel(
                text: status.label,
                color: status.color,
                shimmering: status.kind == .working
            )

            if status.kind == .working {
                // The only per-second datum in the tracker. Scoping the 1s
                // timeline here (instead of around the whole pane) means an
                // idle tracker schedules no periodic re-render at all.
                TimelineView(.periodic(from: .now, by: TrackerSwiftUITiming.durationRefreshInterval)) { context in
                    let duration = TrackerRenderer.durationLabel(for: session, now: context.date)
                    if !duration.isEmpty {
                        Text(duration)
                            .font(AppFonts.monoSmall.swiftUI)
                            .foregroundStyle(AppPalette.dim.swiftUI)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}

/// Shared wall-clock phase so the working dot's ripple and the status text's
/// shimmer animate from one timebase (and stay in sync) instead of each running
/// its own independent animation.
private enum TrackerPulse {
    static let period: TimeInterval = 1.35
    /// Cap for continuous tracker animations. Ghostty draws synchronously on
    /// the main thread; display-rate SwiftUI ticks contend with it directly.
    static let minimumInterval: TimeInterval = 1.0 / 20
    /// The shimmer trails the dot by this fraction of a cycle, so the pulse
    /// reads as rippling outward from the dot into the text.
    static let shimmerDelay: Double = 0.12
    /// Fraction of the cycle the shimmer sweep takes; it rests off-screen after.
    static let shimmerSweepFraction: Double = 0.65

    static func phase(_ date: Date, delay: Double = 0) -> Double {
        let raw = date.timeIntervalSinceReferenceDate / period - delay
        return raw - floor(raw)
    }
}

/// Status text that cross-fades on change and shimmers while the session works.
/// The shimmer overlays a moving highlight clipped to an independent copy of the
/// text (never the layout view itself), so the base label always stays visible.
private struct TrackerStatusLabel: View {
    let text: String
    let color: NSColor
    let shimmering: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shimmerActive: Bool {
        shimmering && !reduceMotion
    }

    var body: some View {
        label
            .contentTransition(.opacity)
            .overlay {
                if shimmerActive {
                    GeometryReader { geometry in
                        let width = max(geometry.size.width, 1)
                        TimelineView(.animation(minimumInterval: TrackerPulse.minimumInterval)) { context in
                            let raw = TrackerPulse.phase(context.date, delay: TrackerPulse.shimmerDelay)
                            let progress = min(raw / TrackerPulse.shimmerSweepFraction, 1)
                            LinearGradient(
                                gradient: Gradient(stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: Color.white.opacity(0.5), location: 0.5),
                                    .init(color: .clear, location: 1),
                                ]),
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: width * 0.6)
                            .offset(x: -width * 0.6 + progress * (width * 1.6))
                            .blendMode(.screen)
                        }
                    }
                    .mask(label)
                    .allowsHitTesting(false)
                }
            }
    }

    private var label: some View {
        Text(text)
            .font(AppFonts.monoSmall.swiftUI)
            .foregroundStyle(color.swiftUI)
            .lineLimit(1)
    }
}

private struct TrackerStatusIndicator: View {
    let status: TrackerStatusStyle

    var body: some View {
        ZStack {
            switch status.kind {
            case .blocked:
                TrackerBlockedPulseDot(color: status.color)
            case .done:
                TrackerDonePopDot(color: status.color)
            default:
                indicatorShape
            }
        }
        .frame(width: 12, height: 12)
        // Publish the dot centre so the row's done echo can bloom from it.
        .anchorPreference(key: TrackerDotAnchorKey.self, value: .center) { $0 }
    }

    @ViewBuilder
    private var indicatorShape: some View {
        ZStack {
            switch status.indicatorAffordance {
            case .spinner:
                TrackerWorkingPulseDot(color: status.color)
            case .square:
                RoundedRectangle(cornerRadius: Token.Radius.dot)
                    .fill(status.color.swiftUI)
                    .frame(width: 8, height: 8)
            case .roundedSquare:
                RoundedRectangle(cornerRadius: Token.Radius.dot)
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

private struct TrackerWorkingPulseDot: View {
    let color: NSColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if reduceMotion {
                core
            } else {
                TimelineView(.animation(minimumInterval: TrackerPulse.minimumInterval)) { context in
                    let phase = TrackerPulse.phase(context.date)
                    let eased = 1 - pow(1 - phase, 2) // easeOut
                    ZStack {
                        Circle()
                            .stroke(color.withAlphaComponent(0.86).swiftUI, lineWidth: 1.5)
                            .frame(width: 8, height: 8)
                            .scaleEffect(0.72 + eased * (1.95 - 0.72))
                            .opacity(0.9 * (1 - eased))
                        core
                    }
                }
            }
        }
        .frame(width: 12, height: 12)
    }

    private var core: some View {
        Circle()
            .fill(color.swiftUI)
            .frame(width: 8, height: 8)
            .shadow(color: color.withAlphaComponent(0.28).swiftUI, radius: reduceMotion ? 0 : 1.5)
    }
}

private struct TrackerBlockedPulseDot: View {
    let color: NSColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Full up-and-back cycle; matches the old 0.75s autoreversing pulse.
    private static let period: TimeInterval = 1.5

    var body: some View {
        if reduceMotion {
            dot(scale: 1, opacity: 1)
        } else {
            TimelineView(.animation(minimumInterval: TrackerPulse.minimumInterval)) { context in
                let cycle = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: Self.period) / Self.period
                let triangle = cycle < 0.5 ? cycle * 2 : 2 - cycle * 2
                let eased = triangle * triangle * (3 - 2 * triangle) // smoothstep ~ easeInOut
                dot(scale: 0.82 + eased * (1.18 - 0.82), opacity: 0.55 + eased * 0.45)
            }
        }
    }

    private func dot(scale: Double, opacity: Double) -> some View {
        Circle()
            .fill(color.swiftUI)
            .frame(width: 8, height: 8)
            .scaleEffect(scale)
            .opacity(opacity)
            .frame(width: 12, height: 12)
    }
}

/// One-time celebration when a session reaches `done`: the dot pops in with a
/// spring overshoot while a single ring pings outward and fades. Fires once on
/// appear (the indicator's identity is keyed on the status kind, so it isn't
/// recreated on routine re-renders).
private struct TrackerDonePopDot: View {
    let color: NSColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var popped = false
    @State private var pinged = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.swiftUI, lineWidth: 1.5)
                .frame(width: 8, height: 8)
                .scaleEffect(pinged ? 2.6 : 0.9)
                .opacity(pinged ? 0 : 0.85)
            Circle()
                .fill(color.swiftUI)
                .frame(width: 8, height: 8)
                .scaleEffect(popped ? 1 : 0.3)
        }
        .frame(width: 12, height: 12)
        .onAppear {
            guard !reduceMotion else {
                popped = true
                pinged = true
                return
            }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.55)) {
                popped = true
            }
            withAnimation(.easeOut(duration: 0.55)) {
                pinged = true
            }
        }
    }
}

/// Card-wide "echo" when a session reaches `done`: a circular bloom of the done
/// colour disperses outward from the status dot (Bloom) and, a beat behind it,
/// the card border ignites and fades (Frame). One-shot, done only — blocked stays
/// in the dot. Tuned to the locked feel (intensity 1.0, speed 0.8 → base ÷ 0.8).
private enum TrackerDoneEchoTiming {
    private static let speed: Double = 0.8
    static let bloomDuration: Double = 1.0 / speed       // 1.25s
    static let bloomRise: Double = bloomDuration * 0.12  // brighten while still small
    static let bloomFall: Double = bloomDuration * 0.88  // fade as it expands
    static let bloomPeakOpacity: Double = 0.26
    static let bloomStartScale: CGFloat = 0.02
    static let bloomDiameterFactor: CGFloat = 2.2        // covers the card from any dot
    static let frameDelay: Double = 0.27 / speed         // border catches after the wave
    static let frameRise: Double = (0.7 / speed) * 0.30
    static let frameFall: Double = (0.7 / speed) * 0.70
    static let framePeakOpacity: Double = 0.45
}

/// Captures the status dot's centre (in the row's space) so the bloom emanates from it.
private struct TrackerDotAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGPoint>? = nil
    static func reduce(value: inout Anchor<CGPoint>?, nextValue: () -> Anchor<CGPoint>?) {
        value = value ?? nextValue()
    }
}

/// The Bloom: a circle centred on the dot, grown from a speck to cover the card and
/// faded out — clipped to the card so it stays contained. Replays on each `trigger`.
private struct TrackerDoneEchoBloom: View {
    let color: NSColor
    let center: CGPoint
    let size: CGSize
    let trigger: Int

    private struct Values: Equatable {
        var scale: CGFloat = TrackerDoneEchoTiming.bloomStartScale
        var opacity: Double = 0
    }

    var body: some View {
        let diameter = size.width * TrackerDoneEchoTiming.bloomDiameterFactor
        Circle()
            .fill(gradient(radius: diameter / 2))
            .frame(width: diameter, height: diameter)
            .keyframeAnimator(initialValue: Values(), trigger: trigger) { content, value in
                content
                    .scaleEffect(value.scale, anchor: .center)
                    .opacity(value.opacity)
                    .blendMode(.screen)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    CubicKeyframe(1, duration: TrackerDoneEchoTiming.bloomDuration)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(TrackerDoneEchoTiming.bloomPeakOpacity, duration: TrackerDoneEchoTiming.bloomRise)
                    CubicKeyframe(0, duration: TrackerDoneEchoTiming.bloomFall)
                }
            }
            .position(center)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: Token.Radius.hairline))
            .allowsHitTesting(false)
    }

    private func gradient(radius: CGFloat) -> RadialGradient {
        RadialGradient(
            gradient: Gradient(stops: [
                .init(color: color.swiftUI, location: 0),
                .init(color: color.withAlphaComponent(0.45).swiftUI, location: 0.52),
                .init(color: color.withAlphaComponent(0).swiftUI, location: 0.72),
            ]),
            center: .center,
            startRadius: 0,
            endRadius: radius
        )
    }
}

/// The Frame: the card border ignites in the done colour and fades, delayed so it
/// lands just behind the bloom front. Replays on each `trigger`.
private struct TrackerDoneEchoFrame: View {
    let color: NSColor
    let trigger: Int

    private struct Values: Equatable { var opacity: Double = 0 }

    var body: some View {
        RoundedRectangle(cornerRadius: Token.Radius.hairline)
            .strokeBorder(color.swiftUI, lineWidth: 1)
            .shadow(color: color.withAlphaComponent(0.35).swiftUI, radius: 5)
            .keyframeAnimator(initialValue: Values(), trigger: trigger) { content, value in
                content.opacity(value.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(0, duration: TrackerDoneEchoTiming.frameDelay)
                    CubicKeyframe(TrackerDoneEchoTiming.framePeakOpacity, duration: TrackerDoneEchoTiming.frameRise)
                    CubicKeyframe(0, duration: TrackerDoneEchoTiming.frameFall)
                }
            }
            .allowsHitTesting(false)
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
        EmptyStatePane(
            message: message,
            symbolName: "sparkles",
            symbolFallback: "*",
            symbolPointSize: 16,
            symbolColor: AppPalette.dim,
            alignment: .center,
            textAlignment: .center,
            frameAlignment: .center,
            padding: EdgeInsets(
                top: 28,
                leading: Token.Spacing.content,
                bottom: Token.Spacing.element,
                trailing: Token.Spacing.content
            ),
            expandHeight: false
        )
    }
}

private struct TrackerSkeletonPlaceholder: View {
    @State private var pulse = false

    private var pulseOpacity: Double {
        pulse ? 1 : 0.45
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            skeletonBar(width: 88, height: 8)
                .padding(.top, 4)
                .padding(.bottom, Token.Spacing.card)
            skeletonDotRow(indent: 0, width: 150)
            skeletonDotRow(indent: 18, width: 185)
            skeletonDotRow(indent: 18, width: 120)
            skeletonBar(width: 96, height: 8)
                .padding(.top, Token.Spacing.content)
                .padding(.bottom, Token.Spacing.card)
            skeletonDotRow(indent: 0, width: 160)
        }
        .padding(.top, Token.Spacing.content)
        .padding(.leading, Token.Spacing.content)
        .padding(.trailing, Token.Spacing.content)
        .padding(.bottom, Token.Spacing.content)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppPalette.panel.swiftUI)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .onDisappear {
            pulse = false
        }
    }

    private func skeletonDotRow(indent: CGFloat, width: CGFloat) -> some View {
        HStack(spacing: 10) {
            skeletonBar(width: 9, height: 9, radius: 4.5)
            skeletonBar(width: width, height: 9)
        }
        .padding(.leading, indent)
        .padding(.vertical, Token.Spacing.card)
    }

    private func skeletonBar(width: CGFloat, height: CGFloat, radius: CGFloat = 3) -> some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(AppPalette.controlFill.swiftUI)
            .opacity(pulseOpacity)
            .frame(width: width, height: height)
    }
}

private struct TrackerTopLevelGutterShape: Shape {
    func path(in rect: CGRect) -> Path {
        let width = min(TrackerListMetrics.gutterWidth, rect.width)
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
        let branchY = min(rect.height - 1, TrackerListMetrics.trackerAgentVisualCenterY)
        let trunkX = TrackerListMetrics.workerConnectorTrunkX
        let endX = TrackerListMetrics.workerConnectorEndX
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
