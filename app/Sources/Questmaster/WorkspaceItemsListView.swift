import AppKit
import QuestmasterCore

final class WorkspaceItemsListView: NSView {
    private static let emptyStateMessage = "No workspace items.\nCreate them with qm item create, qm quest open, or worker session pushes."

    var onControlDirection: ((FocusDirection) -> Bool)? {
        didSet {
            listView.onControlDirection = onControlDirection
        }
    }
    var onSelectionChanged: ((String?) -> Void)?
    var onOpenItem: ((String) -> Void)?

    private let listView = RepoSectionedListView()
    private var snapshot: RuntimeSnapshot?
    private var selectedItemID: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = AppPalette.panelAlt.cgColor
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func focus(in window: NSWindow?) {
        listView.focus(in: window)
    }

    func setSnapshot(_ snapshot: RuntimeSnapshot, selectedItemID: String?) {
        self.snapshot = snapshot
        self.selectedItemID = selectedItemID
        render()
    }

    private func setup() {
        listView.translatesAutoresizingMaskIntoConstraints = false
        listView.onControlDirection = onControlDirection
        listView.onSelectionChanged = { [weak self] selectedID in
            self?.selectedItemID = selectedID
            self?.onSelectionChanged?(selectedID)
        }
        listView.onOpenRow = { [weak self] itemID in
            self?.onOpenItem?(itemID)
        }
        addSubview(listView)
        NSLayoutConstraint.activate([
            listView.topAnchor.constraint(equalTo: topAnchor),
            listView.leadingAnchor.constraint(equalTo: leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: trailingAnchor),
            listView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func render() {
        guard let snapshot else {
            listView.setSections([], preferredSelectionID: nil, emptyMessage: Self.emptyStateMessage)
            return
        }
        let rows = snapshot.items.map { item in
            RepoSectionedListRow(id: item.id, leadingDecoration: .color(AppPalette.accent), signature: itemRowSignature(item)) { selected in
                WorkspaceItemRowView(item: item, selected: selected)
            }
        }
        listView.setSections(
            [
                RepoSectionedListSection(
                    id: "workspace-items",
                    title: "state-root items",
                    path: "",
                    color: AppPalette.accent,
                    rows: rows
                ),
            ],
            preferredSelectionID: snapshot.validItemID(preferredID: selectedItemID),
            emptyMessage: snapshot.serviceStateMessage ?? Self.emptyStateMessage
        )
    }

    private func itemRowSignature(_ item: WorkspaceItem) -> String {
        [
            item.id,
            item.type,
            item.title,
            item.createdAt,
            item.artifact.path,
            item.artifact.inline,
            "\(item.loose)",
            "\(item.attachmentCount)",
            item.questIDs.joined(separator: "|"),
        ].joined(separator: "\u{1f}")
    }
}

private final class WorkspaceItemRowView: NSView {
    init(item: WorkspaceItem, selected: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: item.displayTitle)
        title.font = selected ? AppFonts.monoBold : AppFonts.mono
        title.textColor = selected ? AppPalette.bright : AppPalette.text
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.translatesAutoresizingMaskIntoConstraints = false

        let meta = NSTextField(labelWithString: item.metaLabel)
        meta.font = AppFonts.monoSmall
        meta.textColor = item.loose ? AppPalette.warn : AppPalette.dim
        meta.lineBreakMode = .byTruncatingTail
        meta.translatesAutoresizingMaskIntoConstraints = false

        let main = NSStackView()
        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = 1
        main.translatesAutoresizingMaskIntoConstraints = false
        main.addArrangedSubview(title)
        main.addArrangedSubview(meta)
        addSubview(main)

        NSLayoutConstraint.activate([
            main.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            main.leadingAnchor.constraint(equalTo: leadingAnchor),
            main.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -RepoSectionedListMetrics.rowTrailingInset),
            main.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),

            title.widthAnchor.constraint(lessThanOrEqualTo: main.widthAnchor),
            meta.widthAnchor.constraint(lessThanOrEqualTo: main.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
