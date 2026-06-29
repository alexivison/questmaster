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

    var onShowQuestListIntent: (() -> Void)? {
        get { model.onShowQuestListIntent }
        set { model.onShowQuestListIntent = newValue }
    }

    var onOpenQuestDetailIntent: ((String) -> Void)? {
        get { model.onOpenQuestDetailIntent }
        set { model.onOpenQuestDetailIntent = newValue }
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

    func focusCurrentRoute(in window: NSWindow?) {
        if model.currentMode == .board, model.currentQuestRoute == .detail {
            model.focusViewer(in: window)
            return
        }
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

    var currentQuestRoute: QuestDockRoute {
        model.currentQuestRoute
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

    func currentQuestTitle(snapshot: RuntimeSnapshot) -> String? {
        let quest: QuestDocument?
        if model.currentQuestRoute == .detail {
            quest = QuestBoardLogic.quest(
                in: snapshot,
                id: model.questDetailQuestID,
                selectedSection: model.selectedSection
            )
        } else {
            quest = QuestBoardLogic.selectedQuest(
                in: snapshot,
                selectedQuestID: model.selectedQuestID,
                selectedSection: model.selectedSection
            )
        }
        guard let quest else { return nil }
        let title = quest.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? quest.id : title
    }

    var currentArtifactTitle: String? {
        model.currentArtifactTitle
    }

    @discardableResult
    func copyCurrentArtifactPath() -> Bool {
        model.copyCurrentArtifactPath()
    }

    func refreshCurrentArtifact() {
        model.refreshCurrentArtifact()
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
                boardRoute
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

    @ViewBuilder
    private var boardRoute: some View {
        switch model.currentQuestRoute {
        case .list:
            QuestBoardPane(
                snapshot: store.snapshot,
                selectedSection: model.selectedSection,
                selectedQuestID: model.selectedQuestID,
                expandedQuestIDs: model.expandedQuestIDs,
                onToggleQuestDisclosure: model.toggleQuestDisclosure(questID:),
                onQuestClick: { questID, clickCount in
                    model.handleQuestClick(questID: questID, clickCount: clickCount, snapshot: store.snapshot)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .detail:
            QuestDetailPane(
                snapshot: store.snapshot,
                questID: model.questDetailQuestID,
                selectedSection: model.selectedSection,
                model: model
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct QuestBoardPane: View {
    let snapshot: RuntimeSnapshot
    let selectedSection: QuestBoardSection
    let selectedQuestID: String?
    let expandedQuestIDs: Set<String>
    var onToggleQuestDisclosure: (String) -> Void
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppPalette.questListColumn.swiftUI)
    }

    @ViewBuilder
    private var boardList: some View {
        if renderedRepos.isEmpty {
            DockEmptyState(message: snapshot.serviceStateMessage ?? "No quests in \(selectedSection.title).")
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(renderedRepos) { repo in
                            QuestBoardRepoSection(
                                repo: repo,
                                selectedID: selectedQuestID,
                                expandedQuestIDs: expandedQuestIDs,
                                onToggleQuestDisclosure: onToggleQuestDisclosure,
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
    let questID: String?
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
        return .quest(QuestBoardLogic.quest(
            in: snapshot,
            id: questID,
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
    let expandedQuestIDs: Set<String>
    var onToggleQuestDisclosure: (String) -> Void
    var onQuestClick: (String, Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            QuestBoardSectionHeader(repo: repo)
            ForEach(Array(repo.quests.enumerated()), id: \.element.id) { index, quest in
                QuestBoardRow(
                    quest: quest,
                    selected: quest.id == selectedID,
                    isExpanded: expandedQuestIDs.contains(quest.id),
                    showsSeparator: index < repo.quests.index(before: repo.quests.endIndex),
                    onToggleExpanded: {
                        onToggleQuestDisclosure(quest.id)
                    },
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
    let selected: Bool
    let isExpanded: Bool
    let showsSeparator: Bool
    var onToggleExpanded: () -> Void
    var onMouseDown: (Int) -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Token.Spacing.inline) {
                openTarget
                if !displayGates.isEmpty {
                    gateCountRow
                    if isExpanded {
                        QuestBoardGateDisclosure(gates: displayGates)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            .padding(.horizontal, Token.Spacing.element)
            .padding(.vertical, Token.Spacing.element)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(backgroundColor.swiftUI)

            if showsSeparator {
                Rectangle()
                    .fill(AppPalette.line.swiftUI)
                    .frame(height: Token.Size.divider)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { isHovered = $0 }
        .help(quest.title)
        .animation(.default, value: isExpanded)
    }

    private var displayGates: [QuestBoardDisplayGate] {
        QuestBoardLogic.displayGates(for: quest)
    }

    private var openTarget: some View {
        VStack(alignment: .leading, spacing: Token.Spacing.inline) {
            titleRow
            objectiveRow
            if !displayGates.isEmpty {
                QuestBoardGateProgressStrip(gates: displayGates)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onMouseDown(2)
        }
        .onTapGesture {
            onMouseDown(1)
        }
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Token.Spacing.inline) {
            Text(cleanTitle)
                .font(AppFonts.bodyBold.swiftUI)
                .foregroundStyle((selected ? AppPalette.bright : AppPalette.text).swiftUI)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            if quest.commentCount > 0 {
                commentBadge
            }
        }
    }

    @ViewBuilder
    private var objectiveRow: some View {
        let objective = cleanObjective
        if !objective.isEmpty {
            Text(objective)
                .font(AppFonts.body.swiftUI)
                .foregroundStyle(AppPalette.muted.swiftUI)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var gateCountRow: some View {
        Button {
            withAnimation(.default) {
                onToggleExpanded()
            }
        } label: {
            HStack(spacing: Token.Spacing.inline) {
                Image(systemName: "checkmark.circle.fill")
                    .font(AppFonts.monoSmall.swiftUI)
                    .foregroundStyle(AppPalette.added.swiftUI)
                    .frame(width: Token.Size.questBoardIcon, height: Token.Size.questBoardIcon)

                Text(gateProgress.label)
                    .font(AppFonts.monoSmall.swiftUI)
                    .foregroundStyle(AppPalette.muted.swiftUI)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: Token.Spacing.inline)

                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(AppFonts.monoSmall.swiftUI)
                    .foregroundStyle(AppPalette.dim.swiftUI)
                    .frame(width: Token.Size.questBoardIcon, height: Token.Size.questBoardIcon)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
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

    private var gateProgress: QuestGateProgress {
        QuestBoardRenderer.gateProgress(for: quest)
    }

    private var cleanTitle: String {
        let clean = quest.title.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? quest.id : clean
    }

    private var cleanObjective: String {
        quest.summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var backgroundColor: NSColor {
        if selected {
            return AppPalette.selection
        }
        return isHovered ? AppPalette.hoverBackground : .clear
    }
}

private struct QuestBoardGateProgressStrip: View {
    let gates: [QuestBoardDisplayGate]

    var body: some View {
        HStack(spacing: Token.Spacing.hairline) {
            ForEach(Array(progressSegments.enumerated()), id: \.offset) { _, gate in
                RoundedRectangle(cornerRadius: Token.Radius.dot)
                    .fill(gate.status.progressColor.swiftUI)
                    .frame(height: Token.Size.questGateStripHeight)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var progressSegments: [QuestBoardDisplayGate] {
        gates.sorted { $0.status.progressRank < $1.status.progressRank }
    }
}

private struct QuestBoardGateDisclosure: View {
    let gates: [QuestBoardDisplayGate]

    private var incompleteGates: [QuestBoardDisplayGate] {
        gates.filter { $0.status != .done }
    }

    private var doneGates: [QuestBoardDisplayGate] {
        gates.filter { $0.status == .done }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Token.Spacing.hairline) {
            ForEach(Array(incompleteGates.enumerated()), id: \.offset) { _, gate in
                QuestBoardDisclosureGateRow(gate: gate)
            }
            if !doneGates.isEmpty {
                Text("Done")
                    .font(AppFonts.monoSmall.swiftUI)
                    .foregroundStyle(AppPalette.dim.swiftUI)
                    .padding(.top, Token.Spacing.tight)
                    .padding(.horizontal, Token.Spacing.inline)
                ForEach(Array(doneGates.enumerated()), id: \.offset) { _, gate in
                    QuestBoardDisclosureGateRow(gate: gate)
                }
            }
        }
        .padding(.top, Token.Spacing.tight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct QuestBoardDisclosureGateRow: View {
    let gate: QuestBoardDisplayGate

    var body: some View {
        HStack(alignment: .center, spacing: Token.Spacing.inline) {
            Image(systemName: gate.status.markerSystemName)
                .font(AppFonts.monoSmall.swiftUI)
                .foregroundStyle(gate.status.accentColor.swiftUI)
                .frame(width: Token.Size.questBoardIcon, height: Token.Size.questBoardIcon)

            Text(primaryText)
                .font(AppFonts.monoSmall.swiftUI)
                .foregroundStyle(gate.status.textColor.swiftUI)
                .strikethrough(gate.status == .done, color: AppPalette.dim.swiftUI)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            Text(gate.status.badgeText)
                .font(AppFonts.monoSmall.swiftUI)
                .foregroundStyle(gate.status.accentColor.swiftUI)
                .padding(.horizontal, Token.Spacing.inline)
                .padding(.vertical, Token.Spacing.hairline)
                .background {
                    RoundedRectangle(cornerRadius: Token.Radius.segment)
                        .fill(gate.status.badgeBackground.swiftUI)
                }
        }
        .padding(.vertical, Token.Spacing.tight)
        .padding(.horizontal, Token.Spacing.inline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if gate.status == .next {
                RoundedRectangle(cornerRadius: Token.Radius.control)
                    .fill(AppPalette.questNextGateBackground.swiftUI)
            }
        }
    }

    private var primaryText: String {
        let name = clean(gate.name)
        if !name.isEmpty {
            return name
        }
        let check = clean(gate.check)
        return check.isEmpty ? "(unnamed gate)" : check
    }

    private func clean(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension QuestBoardGateDisplayStatus {
    var progressRank: Int {
        switch self {
        case .done:
            return 0
        case .next:
            return 1
        case .pending:
            return 2
        }
    }

    var progressColor: NSColor {
        switch self {
        case .done:
            return AppPalette.added
        case .next:
            return AppPalette.warn
        case .pending:
            return AppPalette.controlFill
        }
    }

    var markerSystemName: String {
        switch self {
        case .next:
            return "arrowtriangle.right.fill"
        case .pending:
            return "circle"
        case .done:
            return "checkmark"
        }
    }

    var badgeText: String {
        switch self {
        case .next:
            return "Next"
        case .pending:
            return "Pending"
        case .done:
            return "Done"
        }
    }

    var accentColor: NSColor {
        switch self {
        case .next:
            return AppPalette.warn
        case .pending:
            return AppPalette.dim
        case .done:
            return AppPalette.added
        }
    }

    var textColor: NSColor {
        switch self {
        case .next:
            return AppPalette.text
        case .pending, .done:
            return AppPalette.muted
        }
    }

    var badgeBackground: NSColor {
        switch self {
        case .next:
            return AppPalette.questNextGateBadgeBackground
        case .pending:
            return AppPalette.controlFill
        case .done:
            return AppPalette.questDoneGateBadgeBackground
        }
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
