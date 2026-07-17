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
    var onEffect: (TrackerEffect) -> Bool

    private let keyboardBridge: TrackerKeyboardBridge?
    @ObservedObject private var newSessionPresenter: NewSessionSheetPresenter
    @ObservedObject private var destructiveConfirmationPresenter: DestructiveConfirmationPresenter

    @State private var commandState = TrackerCommandState()
    @State private var renameSession: TrackerRenameSession?
    @State private var snapshot: RuntimeSnapshot
    @State private var runtimeObservation: RuntimeStoreObservation?

    init(
        store: RuntimeStore,
        keyboardBridge: TrackerKeyboardBridge? = nil,
        newSessionPresenter: NewSessionSheetPresenter,
        destructiveConfirmationPresenter: DestructiveConfirmationPresenter,
        onEffect: @escaping (TrackerEffect) -> Bool = { _ in false }
    ) {
        self.store = store
        self.keyboardBridge = keyboardBridge
        self.onEffect = onEffect
        _newSessionPresenter = ObservedObject(wrappedValue: newSessionPresenter)
        _destructiveConfirmationPresenter = ObservedObject(wrappedValue: destructiveConfirmationPresenter)
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
        .sheet(item: $destructiveConfirmationPresenter.presentation) { request in
            DestructiveConfirmationSheetView(spec: request.spec) { confirmed in
                destructiveConfirmationPresenter.dismiss()
                request.onDecision(confirmed)
            }
        }
        .sheet(item: $renameSession) { session in
            TrackerRenameSessionSheet(
                session: session,
                dismiss: { renameSession = nil },
                rename: { title in rename(session, to: title) }
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
        // Powers only the row tooltip below now (the held-Command hint badges were
        // replaced with native tooltips) -- always available on hover, not gated on any
        // modifier-key state.
        let shortcutNumbers = TrackerSessionShortcuts.numbersByID(rows)

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
                                onActivate: activate(_:),
                                onRename: presentRename(_:)
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
                lastCurrentSessionID = currentSessionID
            } else if currentSessionID == nil || currentSessionID == lastCurrentSessionID {
                // A newly spawned session's row may not exist in `rows` yet on the tick the
                // ID first changes -- don't advance here, so the next snapshot (once the row
                // appears) still sees the ID as "changed" and resyncs instead of silently
                // giving up.
                lastCurrentSessionID = currentSessionID
            }
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
        case .listCommand(.copySessionID):
            guard let sessionID = commandState.selectedSession(in: rows)?.id else {
                return false
            }
            return dispatchEffect(.copySessionID(sessionID))
        case .listCommand(.rename):
            guard let session = commandState.selectedSession(in: rows) else {
                return false
            }
            presentRename(session)
            return true
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

    private func presentRename(_ session: TrackerSession) {
        commandState.select(session.id)
        renameSession = TrackerRenameSession(sessionID: session.id, title: session.title)
    }

    private func rename(_ session: TrackerRenameSession, to title: String) -> Bool {
        guard let request = try? ServeMutationRequests.renameSession(sessionID: session.sessionID, title: title) else {
            return false
        }
        return dispatchEffect(.sendMutation(TrackerMutationDispatch(request: request, label: "rename \(session.sessionID)")))
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

private struct TrackerRenameSession: Identifiable {
    let sessionID: String
    let title: String

    var id: String { sessionID }
}

private struct TrackerRenameSessionSheet: View {
    let dismiss: () -> Void
    let rename: (String) -> Bool

    @State private var title: String
    @State private var errorMessage: String?
    @FocusState private var titleFocused: Bool

    init(session: TrackerRenameSession, dismiss: @escaping () -> Void, rename: @escaping (String) -> Bool) {
        self.dismiss = dismiss
        self.rename = rename
        _title = State(initialValue: session.title)
    }

    var body: some View {
        ModalSheetScaffold(
            title: "Rename Session",
            footerText: "",
            errorMessage: errorMessage,
            errorHeight: 24,
            cancelLabel: "Cancel",
            onCancel: dismiss,
            primaryLabel: "Save",
            onPrimary: submit
        ) {
            ModalFormRow(label: "Title", labelWidth: 52) {
                TextField("Session title", text: $title)
                    .styledTextField(focused: titleFocused)
                    .focused($titleFocused)
                    .onSubmit(submit)
            }
            .padding(.bottom, Token.Spacing.card)
        }
        .frame(width: 420)
        .background(AppPalette.panel.swiftUI)
        .background(SheetKeyEventMonitor { event in
            guard Keymap.NewSession.cancel.matches(event.keyCode) else {
                return false
            }
            dismiss()
            return true
        })
        .onAppear { titleFocused = true }
    }

    private func submit() {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else {
            errorMessage = "title is required"
            return
        }
        guard rename(cleanTitle) else {
            errorMessage = "could not rename session"
            return
        }
        dismiss()
    }
}

private struct TrackerRepoSection: View {
    let repo: TrackerRenderedRepo
    let selectedID: String?
    let shortcutNumbers: [String: Int]
    var onSelect: (String) -> Void
    var onActivate: (TrackerSession) -> Void
    var onRename: (TrackerSession) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(
                title: repo.repo.name.isEmpty ? "ungrouped" : repo.repo.name,
                color: repo.color
            )

            ForEach(Array(repo.groups.enumerated()), id: \.offset) { _, group in
                TrackerSessionRow(rendered: group.root, selectedID: selectedID, shortcutNumber: shortcutNumbers[group.root.session.id], onSelect: onSelect, onActivate: onActivate, onRename: onRename)
                ForEach(group.workers, id: \.session.id) { worker in
                    TrackerSessionRow(rendered: worker, selectedID: selectedID, shortcutNumber: shortcutNumbers[worker.session.id], onSelect: onSelect, onActivate: onActivate, onRename: onRename)
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
    var onRename: (TrackerSession) -> Void

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
                // Recolor edit swaps the card's own selection glow and hover
                // border for a neutral border, so the mode is obvious
                // without competing with the color preview shown at the
                // gutter/repo title.
                let isRecoloring = rendered.recolorEditHint != nil
                ItemCardShape(
                    selected: !isRecoloring && selected,
                    hovered: !isRecoloring && hovered,
                    extraLeadingInset: cardExtraLeadingInset,
                    accentColor: rendered.groupColor
                )
            },
            content: {
                TrackerSessionRowContent(rendered: rendered, selected: isSelected)
            }
        )
            .overlay {
                if rendered.recolorEditHint != nil {
                    // Neutral border, not the live preview color — the color
                    // itself previews at the gutter/repo title; this border
                    // only marks the row as being edited.
                    cardBorder(color: AppPalette.hoverBackground, lineWidth: 2)
                } else if rendered.status.kind == .needsInput {
                    cardBorder(color: AppPalette.trackerNeedsInput, lineWidth: 1)
                }
            }
            .help(shortcutTooltip)
            .contextMenu {
                Button("Rename Session…") {
                    onRename(session)
                }
            }
            .id(session.id)
    }

    @ViewBuilder
    private var leadingDecoration: some View {
        if rendered.depth > 0 {
            TrackerWorkerConnectorShape()
                .stroke(
                    AppPalette.connectorLine.withAlphaComponent(0.9).swiftUI,
                    style: StrokeStyle(lineWidth: 2, lineCap: .square)
                )
                .frame(width: TrackerListMetrics.workerContentInset)
        }
    }

    private var contentInset: CGFloat {
        rendered.depth == 0 ? TrackerListMetrics.rootContentInset : TrackerListMetrics.workerContentInset
    }

    // How much further left of the card's usual margin the connector needs —
    // zero at the top level, since there's no connector to clear there.
    private var cardExtraLeadingInset: CGFloat {
        rendered.depth == 0 ? 0 : TrackerListMetrics.workerContentInset - Token.Spacing.card
    }

    private func cardBorder(color: NSColor, lineWidth: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: Token.Radius.card)
            .stroke(color.swiftUI, lineWidth: lineWidth)
            .itemCardMargins(extraLeadingInset: cardExtraLeadingInset)
    }

    // Empty string suppresses the tooltip for rows past the first nine.
    private var shortcutTooltip: String {
        guard let shortcutNumber else {
            return ""
        }
        return "Switch to session \(shortcutNumber)  \(Keymap.Command.selectSession[shortcutNumber - 1].displayGlyph)"
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
        (session.isCurrent ? AppFonts.itemTitleEmphasized : AppFonts.itemTitle).swiftUI
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
            .padding(.bottom, ItemCardShape.contentPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, ItemCardShape.contentPadding)
        .padding(.trailing, ItemCardShape.trailingContentPadding)
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
            Text(metadata)
                .font(AppFonts.monoSmall.swiftUI)
                .foregroundStyle(AppPalette.dim.swiftUI)
                .lineLimit(1)
                .truncationMode(.middle)
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

/// Shared wall-clock phase so the tracker's continuous animations (the
/// working dot's ripple, etc.) run from one timebase.
private enum TrackerPulse {
    static let period: TimeInterval = 1.35
    /// Cap for continuous tracker animations. Ghostty draws synchronously on
    /// the main thread; display-rate SwiftUI ticks contend with it directly.
    static let minimumInterval: TimeInterval = 1.0 / 20

    static func phase(_ date: Date) -> Double {
        let raw = date.timeIntervalSinceReferenceDate / period
        return raw - floor(raw)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var pulseOpacity: Double {
        pulse ? 0.7 : 0.6
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
            guard !reduceMotion else {
                pulse = true
                return
            }
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
            .fill(AppPalette.dim.swiftUI)
            .opacity(pulseOpacity)
            .frame(width: width, height: height)
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
