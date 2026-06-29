import AppKit
import QuestmasterCore
import SwiftUI

final class SwiftUIDockPane: NSHostingView<DockRootView> {
    private let store: RuntimeStore
    private let model: DockPaneModel

    init(store: RuntimeStore) {
        self.store = store
        let model = DockPaneModel()
        self.model = model
        super.init(rootView: DockRootView(store: store, model: model))
        configureModelCallbacks()
    }

    required init(rootView: DockRootView) {
        self.store = rootView.store
        self.model = rootView.model
        super.init(rootView: rootView)
        configureModelCallbacks()
    }

    private func configureModelCallbacks() {
        model.onRequestBoardFocus = { [weak self] in
            self?.focusBoard(in: self?.window)
        }
        model.onRequestViewerFocus = { [weak self] in
            self?.focusViewer(in: self?.window)
        }
        model.onConfirmDestructive = { [weak self] confirmation in
            MutationPrompts.confirm(confirmation, relativeTo: self?.window)
        }
        model.onOpenURL = { url in
            NSWorkspace.shared.open(url)
        }
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

    override func mouseDown(with event: NSEvent) {
        model.onFocusRequested?()
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if model.handleKeyDown(event, snapshot: store.snapshot) {
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        model.handleKeyDown(event, snapshot: store.snapshot) || super.performKeyEquivalent(with: event)
    }

    var onMutationRequest: ((ServeMutationRequest, String) -> Void)? {
        get { model.onMutationRequest }
        set { model.onMutationRequest = newValue }
    }

    var onMutationFailure: ((String, Error) -> Void)? {
        get { model.onMutationFailure }
        set { model.onMutationFailure = newValue }
    }

    var onBoardSectionChanged: ((QuestBoardSection) -> Void)? {
        get { model.onBoardSectionChanged }
        set { model.onBoardSectionChanged = newValue }
    }

    var onShowBoardIntent: (() -> Void)? {
        get { model.onShowBoardIntent }
        set { model.onShowBoardIntent = newValue }
    }

    var onShowArtifactListIntent: (() -> Void)? {
        get { model.onShowArtifactListIntent }
        set { model.onShowArtifactListIntent = newValue }
    }

    var onOpenArtifactIntent: ((String) -> Void)? {
        get { model.onOpenArtifactIntent }
        set { model.onOpenArtifactIntent = newValue }
    }

    var onFocusRequested: (() -> Void)? {
        get { model.onFocusRequested }
        set { model.onFocusRequested = newValue }
    }

    var onControlDirection: ((NavigationDirection) -> Bool)? {
        get { model.onControlDirection }
        set { model.onControlDirection = newValue }
    }

    @discardableResult
    func apply(
        _ desired: SessionViewState,
        snapshot: RuntimeSnapshot,
        preferredArtifactSessionID: String? = nil
    ) -> ArtifactDisplayUpdate {
        model.apply(
            desired,
            snapshot: snapshot,
            preferredArtifactSessionID: preferredArtifactSessionID
        )
    }

    func focusBoard(in window: NSWindow?) {
        window?.makeFirstResponder(self)
    }

    func focusViewer(in window: NSWindow?) {
        if model.currentMode == .artifacts {
            window?.makeFirstResponder(self)
            return
        }
        model.focusViewer(in: window)
    }

    var currentSection: QuestBoardSection {
        model.selectedSection
    }

    var currentMode: DockContentMode {
        model.currentMode
    }

    var currentWidthMode: RightDockWidthMode {
        model.currentWidthMode
    }

    var currentArtifactRoute: ArtifactDockRoute {
        model.currentArtifactRoute
    }

    func selectSection(_ section: QuestBoardSection) {
        model.selectSection(section, snapshot: store.snapshot)
    }

    func pruneArtifactSessions(keeping liveIDs: Set<String>, active activeID: String?) {
        model.pruneArtifactSessions(keeping: liveIDs, active: activeID)
    }
}

struct DockRootView: View {
    let store: RuntimeStore
    @ObservedObject var model: DockPaneModel

    var body: some View {
        Group {
            switch model.currentMode {
            case .board:
                boardAndDetail
            case .artifacts:
                ArtifactDockView(
                    model: model.artifactModel,
                    onSelectArtifact: model.openArtifact(_:),
                    onOpenExternal: model.openURL(_:)
                )
            }
        }
        .background(AppPalette.panel.swiftUI)
    }

    private var boardAndDetail: some View {
        GeometryReader { geometry in
            let boardWidth = model.boardColumnWidth(totalWidth: geometry.size.width)
            HStack(spacing: 0) {
                QuestBoardPane(
                    snapshot: store.snapshot,
                    selectedSection: model.selectedSection,
                    selectedQuestID: model.selectedQuestID,
                    onQuestClick: { questID, clickCount in
                        model.handleQuestClick(questID: questID, clickCount: clickCount, snapshot: store.snapshot)
                    }
                )
                .frame(width: boardWidth)

                Rectangle()
                    .fill(AppPalette.lineSoft.swiftUI)
                    .frame(width: Token.Size.divider)

                QuestDetailPane(
                    snapshot: store.snapshot,
                    selectedQuestID: model.selectedQuestID,
                    selectedSection: model.selectedSection,
                    model: model
                )
            }
        }
    }
}

private struct QuestBoardPane: View {
    let snapshot: RuntimeSnapshot
    let selectedSection: QuestBoardSection
    let selectedQuestID: String?
    var onQuestClick: (String, Int) -> Void

    private var renderedRepos: [QuestBoardRenderedRepo] {
        snapshot.board.repos.enumerated().compactMap { repoIndex, repo in
            let quests = QuestBoardLogic.quests(in: repo, section: selectedSection)
            guard !quests.isEmpty else {
                return nil
            }
            return QuestBoardRenderedRepo(
                id: repo.id.isEmpty ? "\(repoIndex)-\(repo.name)" : repo.id,
                title: repo.name,
                color: QuestBoardRenderer.repoColor(for: repo, repoIndex: repoIndex, snapshot: snapshot),
                quests: quests
            )
        }
    }

    var body: some View {
        Group {
            if isServeStartingMessage(snapshot.serviceStateMessage) {
                SkeletonPlaceholderRepresentable(kind: .questList)
            } else {
                boardList
            }
        }
        .background(AppPalette.questListColumn.swiftUI)
    }

    @ViewBuilder
    private var boardList: some View {
        if renderedRepos.isEmpty {
            DockEmptyState(message: snapshot.serviceStateMessage ?? "No quests in \(selectedSection.title).")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(renderedRepos) { repo in
                            QuestBoardRepoSection(
                                repo: repo,
                                selectedID: selectedQuestID,
                                onQuestClick: onQuestClick
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: selectedQuestID) { _, nextID in
                    guard let nextID else {
                        return
                    }
                    proxy.scrollTo(nextID, anchor: .center)
                }
            }
        }
    }
}

private struct QuestDetailPane: View {
    let snapshot: RuntimeSnapshot
    let selectedQuestID: String?
    let selectedSection: QuestBoardSection
    @ObservedObject var model: DockPaneModel

    var body: some View {
        ZStack(alignment: .top) {
            QuestViewerSurfaceRepresentable(
                content: content,
                model: model,
                snapshot: snapshot
            )
            Rectangle()
                .fill(AppPalette.lineSoft.swiftUI)
                .frame(height: Token.Size.divider)
        }
        .background(AppPalette.questViewerBackground.swiftUI)
    }

    private var content: QuestViewerSurfaceContent {
        if let message = snapshot.serviceStateMessage {
            if isServeStartingMessage(message) {
                return .skeleton
            }
            return .status(
                title: "Quest detail",
                message: message,
                detail: "Waiting for qm serve; no fabricated data is shown."
            )
        }
        return .quest(QuestBoardLogic.selectedQuest(
            in: snapshot,
            selectedQuestID: selectedQuestID,
            selectedSection: selectedSection
        ))
    }
}

private struct QuestBoardRenderedRepo: Identifiable {
    let id: String
    let title: String
    let color: NSColor
    let quests: [QuestDocument]
}

private struct QuestBoardRepoSection: View {
    let repo: QuestBoardRenderedRepo
    let selectedID: String?
    var onQuestClick: (String, Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            QuestBoardSectionHeader(repo: repo)
            ForEach(repo.quests, id: \.id) { quest in
                QuestBoardRow(
                    quest: quest,
                    color: repo.color,
                    selected: quest.id == selectedID,
                    onMouseDown: { clickCount in
                        onQuestClick(quest.id, clickCount)
                    }
                )
                .id(quest.id)
            }
        }
    }
}

private struct QuestBoardSectionHeader: View {
    let repo: QuestBoardRenderedRepo

    private var title: String {
        repo.title.isEmpty ? "ungrouped" : repo.title
    }

    var body: some View {
        HStack(spacing: Token.Spacing.card) {
            RoundedRectangle(cornerRadius: Token.Radius.dot)
                .fill(repo.color.swiftUI)
                .frame(width: Token.Size.repoIndicator, height: Token.Size.repoIndicator)

            Text(title)
                .font(AppFonts.monoSmall.swiftUI)
                .foregroundStyle(repo.color.swiftUI)
                .lineLimit(1)
                .truncationMode(.tail)

            Rectangle()
                .fill(AppPalette.line.swiftUI)
                .frame(height: Token.Size.divider)
        }
        .padding(.leading, Token.Spacing.content)
        .padding(.trailing, Token.Spacing.section)
        .padding(.top, Token.Spacing.section)
        .padding(.bottom, Token.Spacing.rowCompact)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct QuestBoardRow: View {
    let quest: QuestDocument
    let color: NSColor
    let selected: Bool
    var onMouseDown: (Int) -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: Token.Spacing.hairline) {
            titleRow
            metadataRow
        }
        .padding(.leading, Token.Spacing.content)
        .padding(.trailing, Token.Spacing.element)
        .padding(.vertical, Token.Spacing.rowCompact)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: Token.Radius.hairline)
                .fill(color.swiftUI)
                .frame(width: Token.Spacing.tight)
        }
        .overlay {
            QuestBoardRowClickLayer(onMouseDown: onMouseDown)
        }
        .onHover { isHovered = $0 }
        .help(quest.title)
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Token.Spacing.inline) {
            Text(cleanTitle)
                .font(AppFonts.mono.swiftUI)
                .foregroundStyle((selected ? AppPalette.bright : AppPalette.text).swiftUI)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            if quest.commentCount > 0 {
                commentBadge
            }
        }
    }

    private var metadataRow: some View {
        HStack(spacing: Token.Spacing.card) {
            let progress = QuestBoardRenderer.gateProgress(for: quest)
            Image(systemName: progress.symbolName)
                .font(AppFonts.monoSmall.swiftUI)
                .foregroundStyle(progress.color.swiftUI)
                .frame(width: Token.Size.questBoardIcon, height: Token.Size.questBoardIcon)

            Text(progress.label)
                .font(AppFonts.monoSmall.swiftUI)
                .foregroundStyle((progress.completed > 0 ? AppPalette.muted : AppPalette.dim).swiftUI)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var commentBadge: some View {
        HStack(spacing: Token.Spacing.tight) {
            Image(systemName: "pencil")
                .font(AppFonts.monoSmall.swiftUI)
                .foregroundStyle(AppPalette.accent.swiftUI)
                .frame(width: Token.Size.questBoardCommentIcon, height: Token.Size.questBoardCommentIcon)
            Text("\(quest.commentCount)")
                .font(AppFonts.monoSmall.swiftUI)
                .foregroundStyle(AppPalette.accent.swiftUI)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var cleanTitle: String {
        let clean = quest.title.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? quest.id : clean
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: Token.Radius.hairline)
            .fill(backgroundColor.swiftUI)
    }

    private var backgroundColor: NSColor {
        if selected {
            return AppPalette.selection
        }
        return isHovered ? AppPalette.hoverBackground : .clear
    }
}

private struct DockEmptyState: View {
    let message: String

    var body: some View {
        Text(message)
            .font(AppFonts.body.swiftUI)
            .foregroundStyle(AppPalette.muted.swiftUI)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(Token.Spacing.content)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private enum QuestViewerSurfaceContent {
    case quest(QuestDocument?)
    case status(title: String, message: String, detail: String)
    case skeleton
}

private struct QuestViewerSurfaceRepresentable: NSViewRepresentable {
    let content: QuestViewerSurfaceContent
    let model: DockPaneModel
    let snapshot: RuntimeSnapshot

    func makeCoordinator() -> DockPaneModel {
        model
    }

    func makeNSView(context: Context) -> ItemViewerSurface {
        let surface = ItemViewerSurface()
        configure(surface)
        model.attachViewerSurface(surface)
        return surface
    }

    func updateNSView(_ surface: ItemViewerSurface, context: Context) {
        configure(surface)
        switch content {
        case .quest(let quest):
            surface.showQuest(quest)
        case .status(let title, let message, let detail):
            surface.showStatus(title: title, message: message, detail: detail)
        case .skeleton:
            surface.showSkeleton()
        }
    }

    static func dismantleNSView(_ surface: ItemViewerSurface, coordinator: DockPaneModel) {
        coordinator.detachViewerSurface(surface)
        surface.onQuestCommand = nil
        surface.onBack = nil
        surface.onFocusRequested = nil
        surface.onControlDirection = nil
    }

    private func configure(_ surface: ItemViewerSurface) {
        surface.onQuestCommand = { command in
            model.handleQuestCommand(command, snapshot: snapshot)
        }
        surface.onBack = {
            model.handleBack()
        }
        surface.onFocusRequested = {
            model.onFocusRequested?()
        }
        surface.onControlDirection = model.onControlDirection
    }
}

private struct SkeletonPlaceholderRepresentable: NSViewRepresentable {
    let kind: SkeletonPlaceholderKind

    func makeNSView(context: Context) -> SkeletonPlaceholderView {
        SkeletonPlaceholderView(kind: kind)
    }

    func updateNSView(_ nsView: SkeletonPlaceholderView, context: Context) {}
}

private struct QuestBoardRowClickLayer: NSViewRepresentable {
    var onMouseDown: (Int) -> Void

    func makeNSView(context: Context) -> MouseCaptureView {
        MouseCaptureView(onMouseDown: onMouseDown)
    }

    func updateNSView(_ nsView: MouseCaptureView, context: Context) {
        nsView.onMouseDown = onMouseDown
    }

    final class MouseCaptureView: NSView {
        var onMouseDown: (Int) -> Void

        init(onMouseDown: @escaping (Int) -> Void) {
            self.onMouseDown = onMouseDown
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }

        override func mouseDown(with event: NSEvent) {
            onMouseDown(event.clickCount)
        }
    }
}
