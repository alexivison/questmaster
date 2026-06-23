import AppKit
import QuestmasterCore

final class RepoSectionView: NSView {
    var onRowMouseDown: ((String, NSEvent) -> Void)?

    private let stackView = NSStackView()
    private let header: RepoSectionHeaderView
    private(set) var rowViews: [String: RepoSectionedRowContainer] = [:]

    init(section: RepoSectionedListSection, selectedID: String?) {
        header = RepoSectionHeaderView(section: section)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        stackView.orientation = .vertical
        stackView.alignment = .width
        stackView.spacing = 0
        stackView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stackView)

        stackView.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        update(section: section, selectedID: selectedID)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(section: RepoSectionedListSection, selectedID: String?) {
        header.update(section)
        removeArrangedRows()

        var visibleIDs = Set<String>()
        for row in section.rows {
            visibleIDs.insert(row.id)
            let isNewRow = rowViews[row.id] == nil
            let rowView = rowViews[row.id] ?? RepoSectionedRowContainer(row: row, selected: row.id == selectedID)
            rowViews[row.id] = rowView
            rowView.update(row: row, selected: row.id == selectedID)
            rowView.onMouseDown = onRowMouseDown
            stackView.addArrangedSubview(rowView)
            if isNewRow {
                rowView.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
            }
        }

        let staleRowIDs = rowViews.keys.filter { !visibleIDs.contains($0) }
        for id in staleRowIDs {
            guard let view = rowViews[id] else {
                continue
            }
            view.removeFromSuperview()
            rowViews[id] = nil
        }
    }

    private func removeArrangedRows() {
        for view in stackView.arrangedSubviews where view !== header {
            view.removeFromSuperview()
        }
    }
}

private final class RepoSectionHeaderView: NSView {
    private let dot: RepoColorBlockView
    private let label: NSTextField

    init(section: RepoSectionedListSection) {
        dot = RepoColorBlockView(color: section.color, cornerRadius: 2)
        label = NSTextField(labelWithString: "")
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        dot.translatesAutoresizingMaskIntoConstraints = false

        label.font = AppFonts.monoSmall
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        let rule = RepoColorBlockView(color: AppPalette.line, cornerRadius: 0)
        rule.translatesAutoresizingMaskIntoConstraints = false

        addSubview(dot)
        addSubview(label)
        addSubview(rule)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 28),

            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: RepoSectionedListMetrics.headerLeadingInset),
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
        update(section)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(_ section: RepoSectionedListSection) {
        dot.setColor(section.color)
        label.stringValue = section.title.isEmpty ? "ungrouped" : section.title
        label.textColor = section.color
    }
}

final class RepoSectionedRowContainer: NSView {
    var onMouseDown: ((String, NSEvent) -> Void)?

    private var hoverTrackingArea: NSTrackingArea?
    private var rowID: String
    private var signature = ""
    private var selected = false
    private var isHovered = false
    private var content: NSView?
    private var decorationView: NSView?
    private var contentConstraints: [NSLayoutConstraint] = []

    init(row: RepoSectionedListRow, selected: Bool) {
        rowID = row.id
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        update(row: row, selected: selected)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let hoverTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(hoverTrackingArea)
        self.hoverTrackingArea = hoverTrackingArea
        super.updateTrackingAreas()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0, bounds.contains(point) else {
            return nil
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?(rowID, event)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        updateBackground()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            isHovered = false
            updateBackground()
        }
    }

    func update(row: RepoSectionedListRow, selected: Bool) {
        rowID = row.id
        updateChrome(row: row, selected: selected)
        if row.signature == signature,
           let content,
           (row.updateContent(content, selected) || selected == self.selected) {
            self.selected = selected
            return
        }
        replaceContent(row: row, selected: selected)
        self.signature = row.signature
        self.selected = selected
    }

    private func updateChrome(row: RepoSectionedListRow, selected: Bool) {
        layer?.backgroundColor = backgroundColor(selected: selected).cgColor
        layer?.cornerRadius = 3
        if let attentionBorderColor = row.attentionBorderColor {
            layer?.borderWidth = 1
            layer?.borderColor = attentionBorderColor.cgColor
        } else {
            layer?.borderWidth = 0
            layer?.borderColor = nil
        }
    }

    private func updateBackground() {
        layer?.backgroundColor = backgroundColor(selected: selected).cgColor
    }

    private func backgroundColor(selected: Bool) -> NSColor {
        if selected {
            return AppPalette.selection
        }
        return isHovered ? AppPalette.hoverBackground : .clear
    }

    private func replaceContent(row: RepoSectionedListRow, selected: Bool) {
        NSLayoutConstraint.deactivate(contentConstraints)
        contentConstraints.removeAll()
        content?.removeFromSuperview()
        decorationView?.removeFromSuperview()

        let content = row.makeContent(selected)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        addDecoration(row.leadingDecoration)

        contentConstraints = [
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: row.leadingDecoration.contentInset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        NSLayoutConstraint.activate(contentConstraints)
        self.content = content
    }

    private func addDecoration(_ decoration: RepoSectionedListLeadingDecoration) {
        let decorationView: NSView
        switch decoration {
        case .color(let color):
            decorationView = RepoRowGutterView(color: color)
        case .cornerConnector(let color):
            decorationView = RepoRowCornerConnectorView(color: color)
        case .none:
            return
        }

        decorationView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(decorationView)
        NSLayoutConstraint.activate([
            decorationView.leadingAnchor.constraint(equalTo: leadingAnchor),
            decorationView.topAnchor.constraint(equalTo: topAnchor),
            decorationView.bottomAnchor.constraint(equalTo: bottomAnchor),
            decorationView.widthAnchor.constraint(equalToConstant: decoration.width),
        ])
        self.decorationView = decorationView
    }
}

private extension RepoSectionedListLeadingDecoration {
    var contentInset: CGFloat {
        switch self {
        case .cornerConnector:
            return RepoSectionedListMetrics.workerContentInset
        case .color, .none:
            return RepoSectionedListMetrics.baseContentInset
        }
    }

    var width: CGFloat {
        switch self {
        case .cornerConnector:
            return RepoSectionedListMetrics.workerContentInset
        case .color, .none:
            return RepoSectionedListMetrics.baseContentInset
        }
    }
}

final class RepoListDocumentView: NSView {
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
        let width = RepoSectionedListMetrics.gutterWidth
        let height = bounds.height
        let radius = min(width, height / 2)
        let control = radius * 0.5522847498
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: 0))
        path.line(to: NSPoint(x: width - radius, y: 0))
        path.curve(
            to: NSPoint(x: width, y: radius),
            controlPoint1: NSPoint(x: width - radius + control, y: 0),
            controlPoint2: NSPoint(x: width, y: radius - control)
        )
        path.line(to: NSPoint(x: width, y: height - radius))
        path.curve(
            to: NSPoint(x: width - radius, y: height),
            controlPoint1: NSPoint(x: width, y: height - radius + control),
            controlPoint2: NSPoint(x: width - radius + control, y: height)
        )
        path.line(to: NSPoint(x: 0, y: height))
        path.close()
        path.fill()
    }
}

private final class RepoRowCornerConnectorView: NSView {
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
        color.withAlphaComponent(0.9).setStroke()
        let branchY = min(bounds.height - 1, RepoSectionedListMetrics.trackerAgentVisualCenterY)
        let trunkX = RepoSectionedListMetrics.workerConnectorTrunkX
        let endX = RepoSectionedListMetrics.workerContentInset - RepoSectionedListMetrics.workerTreeToAgentGap
        let radius: CGFloat = 6
        let line = NSBezierPath()
        line.move(to: NSPoint(x: trunkX, y: 0))
        line.line(to: NSPoint(x: trunkX, y: max(0, branchY - radius)))
        line.curve(
            to: NSPoint(x: trunkX + radius, y: branchY),
            controlPoint1: NSPoint(x: trunkX, y: branchY - radius / 2),
            controlPoint2: NSPoint(x: trunkX + radius / 2, y: branchY)
        )
        line.line(to: NSPoint(x: endX, y: branchY))
        line.lineWidth = 2
        line.lineCapStyle = .square
        line.stroke()
    }
}
