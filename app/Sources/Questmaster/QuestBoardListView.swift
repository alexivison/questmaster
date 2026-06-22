import AppKit
import QuestmasterCore

final class QuestBoardListView: NSView {
    var onControlDirection: ((FocusDirection) -> Bool)? {
        didSet {
            listView.onControlDirection = onControlDirection
        }
    }
    var onSelectionChanged: ((String?) -> Void)?
    var onOpenQuest: ((String) -> Void)?
    var onSectionChanged: ((QuestBoardSection) -> Void)?
    var onDeleteQuest: ((QuestDocument) -> Bool)?

    private let listView = RepoSectionedListView()
    private let skeletonView = SkeletonPlaceholderView(kind: .questList)
    private var snapshot: RuntimeSnapshot?
    private var selectedSection: QuestBoardSection = .active
    private var selectedQuestID: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = AppPalette.questListColumn.cgColor
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func focus(in window: NSWindow?) {
        listView.focus(in: window)
    }

    func setSnapshot(_ snapshot: RuntimeSnapshot, selectedQuestID: String?, selectedSection: QuestBoardSection) {
        self.snapshot = snapshot
        self.selectedQuestID = selectedQuestID
        self.selectedSection = selectedSection
        render()
    }

    func select(_ questID: String?) {
        selectedQuestID = questID
        listView.select(questID)
    }

    func selectSection(_ section: QuestBoardSection) {
        switchSection(to: section)
    }

    private func setup() {
        listView.translatesAutoresizingMaskIntoConstraints = false
        listView.layer?.backgroundColor = AppPalette.questListColumn.cgColor
        listView.onControlDirection = onControlDirection
        listView.onSelectionChanged = { [weak self] selectedID in
            self?.selectedQuestID = selectedID
            self?.onSelectionChanged?(selectedID)
        }
        listView.onOpenRow = { [weak self] questID in
            self?.onOpenQuest?(questID)
        }
        listView.onCommand = { [weak self] command in
            guard let self else {
                return false
            }
            switch command {
            case .previousTab:
                self.switchSection(to: self.selectedSection.previous)
                return true
            case .nextTab:
                self.switchSection(to: self.selectedSection.next)
                return true
            case .jumpToNextAttention:
                return false
            case .deleteQuest:
                guard let quest = self.selectedQuest() else {
                    return false
                }
                return self.onDeleteQuest?(quest) ?? false
            case .relay, .broadcast, .delete, .attachToQuest, .spawn, .recolorSession, .recolorRepo:
                return false
            }
        }

        addSubview(listView)
        skeletonView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(skeletonView)

        NSLayoutConstraint.activate([
            listView.topAnchor.constraint(equalTo: topAnchor),
            listView.leadingAnchor.constraint(equalTo: leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: trailingAnchor),
            listView.bottomAnchor.constraint(equalTo: bottomAnchor),

            skeletonView.topAnchor.constraint(equalTo: topAnchor),
            skeletonView.leadingAnchor.constraint(equalTo: leadingAnchor),
            skeletonView.trailingAnchor.constraint(equalTo: trailingAnchor),
            skeletonView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        skeletonView.isHidden = true
    }

    private func render() {
        guard let snapshot else {
            skeletonView.isHidden = false
            listView.isHidden = true
            listView.setSections([], preferredSelectionID: nil, emptyMessage: "No board data yet.")
            return
        }

        let showsSkeleton = isServeStartingMessage(snapshot.serviceStateMessage)
        skeletonView.isHidden = !showsSkeleton
        listView.isHidden = showsSkeleton
        let sections = boardSections(snapshot)
        let selectedID = QuestBoardRenderer.validSelectionID(
            in: snapshot,
            preferredID: selectedQuestID,
            selectedSection: selectedSection
        )
        selectedQuestID = selectedID
        listView.setSections(
            sections,
            preferredSelectionID: selectedID,
            emptyMessage: snapshot.serviceStateMessage ?? "No quests in \(selectedSection.title)."
        )
    }

    private func switchSection(to section: QuestBoardSection) {
        selectedSection = section
        render()
        onSectionChanged?(section)
    }

    private func selectedQuest() -> QuestDocument? {
        guard let snapshot else {
            return nil
        }
        return QuestBoardRenderer.selectedQuest(
            in: snapshot,
            selectedQuestID: selectedQuestID,
            selectedSection: selectedSection
        )
    }

    private func boardSections(_ snapshot: RuntimeSnapshot) -> [RepoSectionedListSection] {
        snapshot.board.repos.enumerated().map { repoIndex, repo in
            let color = boardRepoColor(for: repo, repoIndex: repoIndex, snapshot: snapshot)
            let quests = repo.quests.filter { QuestBoardRenderer.section(for: $0) == selectedSection }
            return RepoSectionedListSection(
                id: repo.id.isEmpty ? repo.name : repo.id,
                title: repo.name,
                path: repo.path,
                color: color,
                rows: quests.map { quest in
                    RepoSectionedListRow(id: quest.id, leadingDecoration: .color(color), signature: boardRowSignature(quest, color: color)) { selected in
                        QuestBoardRowView(quest: quest, selected: selected)
                    }
                }
            )
        }
    }

    private func boardRepoColor(for repo: QuestRepo, repoIndex: Int, snapshot: RuntimeSnapshot) -> NSColor {
        let boardKeys = repoIdentityKeys(id: repo.id, name: repo.name, path: repo.path)
        for (trackerIndex, trackerRepo) in snapshot.tracker.repos.enumerated() {
            let trackerKeys = repoIdentityKeys(id: trackerRepo.id, name: trackerRepo.name, path: trackerRepo.path)
            if !boardKeys.isDisjoint(with: trackerKeys) {
                return AppPalette.repo(trackerRepo.color, index: trackerIndex)
            }
        }
        return AppPalette.repo(repo.color, index: repoIndex)
    }

    private func repoIdentityKeys(id: String, name: String, path: String) -> Set<String> {
        let keys = [id, name, path]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        return Set(keys)
    }

    private func boardRowSignature(_ quest: QuestDocument, color: NSColor) -> String {
        let progress = QuestBoardRenderer.gateProgress(for: quest)
        return [quest.id, quest.title, quest.status, "\(quest.commentCount)", "\(progress.completed)", "\(progress.total)", "\(color)"].joined(separator: "\u{1f}")
    }
}

private final class QuestBoardRowView: NSView {
    init(quest: QuestDocument, selected: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.spacing = 6
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: truncatedTitle(quest.title))
        title.font = selected ? AppFonts.monoBold : AppFonts.mono
        title.textColor = selected ? AppPalette.bright : AppPalette.text
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleRow.addArrangedSubview(title)

        if quest.commentCount > 0 {
            titleRow.addArrangedSubview(commentBadge(count: quest.commentCount))
        }

        let metaRow = NSStackView()
        metaRow.orientation = .horizontal
        metaRow.alignment = .firstBaseline
        metaRow.spacing = 8
        metaRow.translatesAutoresizingMaskIntoConstraints = false

        let progress = QuestBoardRenderer.gateProgress(for: quest)
        let icon = NSImageView()
        icon.image = AppSymbolStyle.image(name: progress.symbolName, color: progress.color)
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 12),
            icon.heightAnchor.constraint(equalToConstant: 12),
        ])
        metaRow.addArrangedSubview(icon)

        let progressLabel = NSTextField(labelWithString: progress.label)
        progressLabel.font = AppFonts.monoSmall
        progressLabel.textColor = progress.completed > 0 ? AppPalette.muted : AppPalette.dim
        progressLabel.lineBreakMode = .byTruncatingTail
        progressLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        metaRow.addArrangedSubview(progressLabel)

        let main = NSStackView()
        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = 1
        main.translatesAutoresizingMaskIntoConstraints = false
        main.addArrangedSubview(titleRow)
        main.addArrangedSubview(metaRow)

        addSubview(main)

        NSLayoutConstraint.activate([
            main.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            main.leadingAnchor.constraint(equalTo: leadingAnchor),
            main.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -RepoSectionedListMetrics.rowTrailingInset),
            main.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),

            titleRow.widthAnchor.constraint(lessThanOrEqualTo: main.widthAnchor),
            metaRow.widthAnchor.constraint(lessThanOrEqualTo: main.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func truncatedTitle(_ title: String) -> String {
        let clean = title.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = 30
        guard clean.count > limit else {
            return clean
        }
        return String(clean.prefix(limit - 1)) + "…"
    }

    private func commentBadge(count: Int) -> NSView {
        let icon = NSImageView()
        icon.image = AppSymbolStyle.image(name: "pencil", pointSize: 11, color: AppPalette.accent)
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 11),
            icon.heightAnchor.constraint(equalToConstant: 11),
        ])

        let countLabel = NSTextField(labelWithString: "\(count)")
        countLabel.font = AppFonts.monoSmall
        countLabel.textColor = AppPalette.accent

        let badge = NSStackView(views: [icon, countLabel])
        badge.orientation = .horizontal
        badge.alignment = .centerY
        badge.spacing = 3
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        return badge
    }
}
