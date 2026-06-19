import AppKit
import QuestmasterAppCore

struct RepoSectionedListSection {
    let id: String
    let title: String
    let path: String
    let color: NSColor
    let rows: [RepoSectionedListRow]
}

enum RepoSectionedListLeadingDecoration {
    case color(NSColor)
    case tree(isLast: Bool)
    case none
}

enum RepoSectionedListMetrics {
    static let leadingLaneWidth: CGFloat = 32
    static let gutterWidth: CGFloat = 3
    static let rowTrailingInset: CGFloat = 10
}

struct RepoSectionedListRow {
    let id: String
    let leadingDecoration: RepoSectionedListLeadingDecoration
    let attentionBorderColor: NSColor?
    let makeContent: (_ selected: Bool) -> NSView

    init(
        id: String,
        leadingDecoration: RepoSectionedListLeadingDecoration = .none,
        attentionBorderColor: NSColor? = nil,
        makeContent: @escaping (_ selected: Bool) -> NSView
    ) {
        self.id = id
        self.leadingDecoration = leadingDecoration
        self.attentionBorderColor = attentionBorderColor
        self.makeContent = makeContent
    }
}

enum RepoSectionedListCommand {
    case previousTab
    case nextTab
    case jumpToNextAttention
}

final class RepoSectionedListView: NSView {
    var onControlDirection: ((FocusDirection) -> Bool)?
    var onSelectionChanged: ((String?) -> Void)?
    var onOpenRow: ((String) -> Void)?
    var onCommand: ((RepoSectionedListCommand) -> Bool)?

    private let scrollView = NSScrollView()
    private let contentView = RepoListDocumentView()
    private let stackView = NSStackView()
    private var sections: [RepoSectionedListSection] = []
    private var rowViews: [String: NSView] = [:]
    private(set) var selectedID: String?
    private var emptyMessage = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = AppPalette.panel.cgColor
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    func focus(in window: NSWindow?) {
        window?.makeFirstResponder(self)
    }

    func setSections(
        _ sections: [RepoSectionedListSection],
        preferredSelectionID: String?,
        emptyMessage: String
    ) {
        self.sections = sections
        self.emptyMessage = emptyMessage
        let ids = rowIDs(in: sections)
        selectedID = preferredSelectionID.flatMap { ids.contains($0) ? $0 : nil }
            ?? RepoListSelection.validSelectionID(currentID: selectedID, ids: ids)
        render()
    }

    func select(_ id: String?) {
        let ids = rowIDs(in: sections)
        selectedID = RepoListSelection.validSelectionID(currentID: id, ids: ids)
        render()
        onSelectionChanged?(selectedID)
    }

    override func keyDown(with event: NSEvent) {
        if isNativeRegionTabEvent(event) {
            return
        }
        if let direction = FocusDirection(event: event),
           onControlDirection?(direction) == true {
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.command), !flags.contains(.control), !flags.contains(.option), !flags.contains(.shift) else {
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 33:
            if onCommand?(.previousTab) == true {
                return
            }
        case 30:
            if onCommand?(.nextTab) == true {
                return
            }
        case 36, 76:
            openSelected()
            return
        case 123, 126:
            moveSelection(delta: -1)
            return
        case 124, 125:
            moveSelection(delta: 1)
            return
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "h", "k":
                moveSelection(delta: -1)
                return
            case "j", "l":
                moveSelection(delta: 1)
                return
            case "n":
                if onCommand?(.jumpToNextAttention) == true {
                    return
                }
            default:
                break
            }
        }

        super.keyDown(with: event)
    }

    private func setup() {
        stackView.orientation = .vertical
        stackView.alignment = .width
        stackView.spacing = 0
        stackView.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stackView)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = contentView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stackView.topAnchor.constraint(equalTo: contentView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])
    }

    private func render() {
        clear(stackView)
        rowViews.removeAll()

        let visibleSections = sections.filter { !$0.rows.isEmpty }
        guard !visibleSections.isEmpty else {
            addEmptyState(emptyMessage)
            return
        }

        for section in visibleSections {
            let sectionView = RepoSectionView(section: section, selectedID: selectedID)
            rowViews.merge(sectionView.rowViews) { current, _ in current }
            stackView.addArrangedSubview(sectionView)
            sectionView.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        }

        if let selectedID, let rowView = rowViews[selectedID] {
            DispatchQueue.main.async {
                rowView.scrollToVisible(rowView.bounds.insetBy(dx: 0, dy: -12))
            }
        }
    }

    private func moveSelection(delta: Int) {
        let nextID = RepoListSelection.nextSelectionID(currentID: selectedID, ids: rowIDs(in: sections), delta: delta)
        guard nextID != selectedID else {
            return
        }
        selectedID = nextID
        render()
        onSelectionChanged?(selectedID)
    }

    private func openSelected() {
        guard let selectedID else {
            return
        }
        onOpenRow?(selectedID)
    }

    private func addEmptyState(_ message: String) {
        let label = NSTextField(labelWithString: message)
        label.font = AppFonts.body
        label.textColor = AppPalette.muted
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 28),
            label.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -14),
            label.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -10),
        ])
        stackView.addArrangedSubview(wrapper)
    }

    private func clear(_ stack: NSStackView) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func rowIDs(in sections: [RepoSectionedListSection]) -> [String] {
        sections.flatMap { section in section.rows.map(\.id) }
    }
}

private final class RepoSectionView: NSView {
    private let stackView = NSStackView()
    private(set) var rowViews: [String: NSView] = [:]

    init(section: RepoSectionedListSection, selectedID: String?) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        stackView.orientation = .vertical
        stackView.alignment = .width
        stackView.spacing = 0
        stackView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stackView)

        let header = RepoSectionHeaderView(section: section)
        stackView.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        for row in section.rows {
            let rowView = RepoSectionedRowContainer(
                row: row,
                selected: row.id == selectedID
            )
            rowViews[row.id] = rowView
            stackView.addArrangedSubview(rowView)
            rowView.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class RepoSectionHeaderView: NSView {
    init(section: RepoSectionedListSection) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let dot = RepoColorBlockView(color: section.color, cornerRadius: 2)
        dot.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: section.title.isEmpty ? "ungrouped" : section.title)
        label.font = AppFonts.monoSmall
        label.textColor = section.color
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        let rule = RepoColorBlockView(color: AppPalette.line, cornerRadius: 0)
        rule.translatesAutoresizingMaskIntoConstraints = false

        addSubview(dot)
        addSubview(label)
        addSubview(rule)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 28),

            dot.leadingAnchor.constraint(equalTo: leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),

            label.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),

            rule.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            rule.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class RepoSectionedRowContainer: NSView {
    init(row: RepoSectionedListRow, selected: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = selected ? AppPalette.selection.cgColor : NSColor.clear.cgColor
        layer?.cornerRadius = 3
        if let attentionBorderColor = row.attentionBorderColor {
            layer?.borderWidth = 1
            layer?.borderColor = attentionBorderColor.cgColor
        }

        let content = row.makeContent(selected)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        addDecoration(row.leadingDecoration)

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: RepoSectionedListMetrics.leadingLaneWidth),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func addDecoration(_ decoration: RepoSectionedListLeadingDecoration) {
        let decorationView: NSView
        switch decoration {
        case .color(let color):
            decorationView = RepoRowGutterView(color: color)
        case .tree(let isLast):
            decorationView = RepoRowTreeView(isLast: isLast)
        case .none:
            return
        }

        decorationView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(decorationView)
        NSLayoutConstraint.activate([
            decorationView.leadingAnchor.constraint(equalTo: leadingAnchor),
            decorationView.topAnchor.constraint(equalTo: topAnchor),
            decorationView.bottomAnchor.constraint(equalTo: bottomAnchor),
            decorationView.widthAnchor.constraint(equalToConstant: RepoSectionedListMetrics.leadingLaneWidth),
        ])
    }
}

private final class RepoListDocumentView: NSView {
    override var isFlipped: Bool {
        true
    }
}

private final class RepoColorBlockView: NSView {
    private var color: NSColor
    private let cornerRadius: CGFloat

    init(color: NSColor, cornerRadius: CGFloat) {
        self.color = color
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = cornerRadius
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setColor(_ color: NSColor) {
        self.color = color
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = cornerRadius
    }
}

private final class RepoRowGutterView: NSView {
    private let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: RepoSectionedListMetrics.gutterWidth, height: bounds.height)).fill()
    }
}

private final class RepoRowTreeView: NSView {
    private let isLast: Bool

    init(isLast: Bool) {
        self.isLast = isLast
        super.init(frame: .zero)
        wantsLayer = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        AppPalette.dim.setStroke()
        let line = NSBezierPath()
        let branchY = min(bounds.height - 1, max(1, bounds.height * 0.34))
        let trunkX = RepoSectionedListMetrics.gutterWidth / 2
        line.move(to: NSPoint(x: trunkX, y: 0))
        line.line(to: NSPoint(x: trunkX, y: isLast ? branchY : bounds.height))
        line.move(to: NSPoint(x: trunkX, y: branchY))
        line.line(to: NSPoint(x: RepoSectionedListMetrics.leadingLaneWidth - 5, y: branchY))
        line.lineWidth = 1.8
        line.lineCapStyle = .square
        line.stroke()
    }
}
